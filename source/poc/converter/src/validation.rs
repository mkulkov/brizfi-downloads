//! Conservative EPUB PoC profile: UTF-8 XML, local resources, Stored/Deflate ZIP.
//! Bounds constrain input expansion, not Boko's peak memory or execution time.

use std::collections::{HashMap, HashSet};
use std::io::{Cursor, Read};

use cssparser::{ParseError, Parser, ParserInput, Token};
use quick_xml::Reader;
use quick_xml::events::{BytesStart, Event};

use crate::ConversionError;

pub const MAX_ENTRIES: usize = 2048;
pub const MAX_ENTRY_BYTES: u64 = 8 * 1024 * 1024;
pub const MAX_UNPACKED_BYTES: u64 = 64 * 1024 * 1024;
pub const MAX_XML_DEPTH: usize = 64;
/// Shared XML event/CSS token budget over the entire archive.
pub const MAX_XML_EVENTS: usize = 100_000;

fn word(bytes: &[u8], at: usize) -> Result<u16, ConversionError> {
    let data = bytes.get(at..at + 2).ok_or(ConversionError::Zip)?;
    Ok(u16::from_le_bytes([data[0], data[1]]))
}
fn dword(bytes: &[u8], at: usize) -> Result<u32, ConversionError> {
    let data = bytes.get(at..at + 4).ok_or(ConversionError::Zip)?;
    Ok(u32::from_le_bytes([data[0], data[1], data[2], data[3]]))
}

fn safe_path(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with('/')
        && !name.contains(['\\', ':', '%'])
        && !name.chars().any(char::is_control)
        && name.trim_end_matches('/').split('/').all(|part| {
            !part.is_empty() && part != "." && part != ".." && !part.ends_with(['.', ' '])
        })
}

/// Inspect the bounded classic central directory before ZipArchive can deduplicate names
/// or allocate entries. ZIP64, split/prefixed archives and overlapping entries are outside
/// this profile. ZIP64 is unnecessary for these size/count limits.
fn directory(bytes: &[u8]) -> Result<HashSet<String>, ConversionError> {
    let end = bytes.len().checked_sub(22).ok_or(ConversionError::Zip)?;
    let eocd = (bytes.len().saturating_sub(65_557)..=end)
        .rev()
        .find(|&at| {
            bytes.get(at..at + 4) == Some(b"PK\x05\x06")
                && word(bytes, at + 20).is_ok_and(|len| at + 22 + usize::from(len) == bytes.len())
        })
        .ok_or(ConversionError::Zip)?;
    let count = usize::from(word(bytes, eocd + 10)?);
    if count > MAX_ENTRIES {
        return Err(ConversionError::ResourceLimit);
    }
    if word(bytes, eocd + 4)? != 0
        || word(bytes, eocd + 6)? != 0
        || usize::from(word(bytes, eocd + 8)?) != count
    {
        return Err(ConversionError::UnsupportedContent);
    }
    let start = dword(bytes, eocd + 16)? as usize;
    let size = dword(bytes, eocd + 12)? as usize;
    if start.checked_add(size) != Some(eocd) {
        return Err(ConversionError::Zip);
    }
    let mut at = start;
    let mut names = HashSet::new();
    let mut folded = HashSet::new();
    let mut ranges = Vec::new();
    let mut total = 0u64;
    for _ in 0..count {
        if bytes.get(at..at + 4) != Some(b"PK\x01\x02") {
            return Err(ConversionError::Zip);
        }
        let flags = word(bytes, at + 8)?;
        if flags & (1 | 64 | 8192) != 0 {
            return Err(ConversionError::EncryptedBook);
        }
        let method = word(bytes, at + 10)?;
        if method != 0 && method != 8 {
            return Err(ConversionError::UnsupportedContent);
        }
        let compressed = u64::from(dword(bytes, at + 20)?);
        let unpacked = u64::from(dword(bytes, at + 24)?);
        total = total
            .checked_add(unpacked)
            .ok_or(ConversionError::ResourceLimit)?;
        if unpacked > MAX_ENTRY_BYTES || total > MAX_UNPACKED_BYTES {
            return Err(ConversionError::ResourceLimit);
        }
        if word(bytes, at + 34)? != 0 {
            return Err(ConversionError::UnsupportedContent);
        }
        let name_len = usize::from(word(bytes, at + 28)?);
        let extra_len = usize::from(word(bytes, at + 30)?);
        let comment_len = usize::from(word(bytes, at + 32)?);
        let raw = bytes
            .get(at + 46..at + 46 + name_len)
            .ok_or(ConversionError::Zip)?;
        let name = std::str::from_utf8(raw).map_err(|_| ConversionError::UnsafeArchive)?;
        if !safe_path(name) || !folded.insert(name.trim_end_matches('/').to_lowercase()) {
            return Err(ConversionError::UnsafeArchive);
        }
        names.insert(name.to_owned());
        // Unix symlinks and other special file types are never accepted.
        let mode = (dword(bytes, at + 38)? >> 16) & 0o170000;
        if mode != 0 && mode != 0o100000 && mode != 0o040000 {
            return Err(ConversionError::UnsafeArchive);
        }
        let local = dword(bytes, at + 42)? as usize;
        if local > start || local.checked_add(30).is_none_or(|end| end > start) {
            return Err(ConversionError::Zip);
        }
        if bytes.get(local..local + 4) != Some(b"PK\x03\x04")
            || word(bytes, local + 6)? != flags
            || word(bytes, local + 8)? != method
        {
            return Err(ConversionError::Zip);
        }
        let local_name = usize::from(word(bytes, local + 26)?);
        let local_extra = usize::from(word(bytes, local + 28)?);
        if bytes.get(local + 30..local + 30 + local_name) != Some(raw) {
            return Err(ConversionError::UnsafeArchive);
        }
        let data_end = (local + 30 + local_name + local_extra) as u64 + compressed;
        if data_end > start as u64 {
            return Err(ConversionError::Zip);
        }
        ranges.push((local as u64, data_end));
        at += 46 + name_len + extra_len + comment_len;
        if at > eocd {
            return Err(ConversionError::Zip);
        }
    }
    if at != eocd || !names.contains("mimetype") || !names.contains("META-INF/container.xml") {
        return Err(ConversionError::Zip);
    }
    ranges.sort_unstable();
    if ranges.first().is_none_or(|range| range.0 != 0)
        || ranges.windows(2).any(|pair| pair[0].1 > pair[1].0)
    {
        return Err(ConversionError::UnsafeArchive);
    }
    Ok(names)
}

pub(crate) fn validate(bytes: &[u8]) -> Result<(), ConversionError> {
    let names = directory(bytes)?;
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes))?;
    if archive.len() != names.len() {
        return Err(ConversionError::UnsafeArchive);
    }
    let mut total = 0u64;
    let mut budget = 0;
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index)?;
        let name = entry.name().to_owned();
        if entry.encrypted() {
            return Err(ConversionError::EncryptedBook);
        }
        if entry.is_symlink() {
            return Err(ConversionError::UnsafeArchive);
        }
        let lower = name.to_ascii_lowercase();
        if matches!(
            lower.as_str(),
            "meta-inf/encryption.xml" | "meta-inf/rights.xml"
        ) || lower.ends_with(".lcpl")
        {
            return Err(ConversionError::EncryptedBook);
        }
        let mut contents = Vec::new();
        // cap + 1 detects lying headers; reaching EOF also verifies ZIP CRC.
        (&mut entry)
            .take(MAX_ENTRY_BYTES + 1)
            .read_to_end(&mut contents)
            .map_err(|_| ConversionError::Zip)?;
        total += contents.len() as u64;
        if contents.len() as u64 > MAX_ENTRY_BYTES || total > MAX_UNPACKED_BYTES {
            return Err(ConversionError::ResourceLimit);
        }
        if contents.len() as u64 != entry.size() {
            return Err(ConversionError::Zip);
        }
        if entry.is_dir() {
            if !contents.is_empty() {
                return Err(ConversionError::Zip);
            }
            continue;
        }
        if name == "mimetype" {
            if contents != b"application/epub+zip" {
                return Err(ConversionError::Zip);
            }
            continue;
        }
        let extension = lower.rsplit('.').next().unwrap_or("");
        match extension {
            "xml" | "opf" | "ncx" | "xhtml" | "html" | "htm" | "svg" => {
                xml(&contents, &name, &names, &mut budget)?;
                if extension == "opf" {
                    package(&contents, &mut budget)?;
                }
            }
            "css" => {
                let css = std::str::from_utf8(&contents)
                    .map_err(|_| ConversionError::UnsupportedContent)?;
                css_check(css, &name, &names, &mut budget)?;
            }
            "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" | "ttf" | "otf" | "woff" | "woff2" => {}
            _ => return Err(ConversionError::UnsupportedContent),
        }
    }
    Ok(())
}

fn package(contents: &[u8], budget: &mut usize) -> Result<(), ConversionError> {
    let text = std::str::from_utf8(contents).map_err(|_| ConversionError::UnsupportedContent)?;
    let mut reader = Reader::from_str(text);
    let mut manifest = HashMap::new();
    let mut spine = Vec::new();
    loop {
        spend(budget)?;
        match reader
            .read_event()
            .map_err(|_| ConversionError::UnsupportedContent)?
        {
            Event::Start(element) | Event::Empty(element) => {
                if matches!(element.local_name().as_ref(), b"item" | b"itemref") {
                    let mut values = HashMap::new();
                    for attribute in element.attributes() {
                        let attribute =
                            attribute.map_err(|_| ConversionError::UnsupportedContent)?;
                        let value = attribute
                            .decode_and_unescape_value(reader.decoder())
                            .map_err(|_| ConversionError::UnsupportedContent)?;
                        values.insert(
                            attribute.key.local_name().as_ref().to_vec(),
                            value.into_owned(),
                        );
                    }
                    if element.local_name().as_ref() == b"item" {
                        let id = values
                            .remove(b"id".as_slice())
                            .ok_or(ConversionError::UnsupportedContent)?;
                        let href = values
                            .remove(b"href".as_slice())
                            .ok_or(ConversionError::UnsupportedContent)?;
                        let media = values
                            .remove(b"media-type".as_slice())
                            .ok_or(ConversionError::UnsupportedContent)?;
                        if manifest.insert(id, (href, media)).is_some() {
                            return Err(ConversionError::UnsupportedContent);
                        }
                    } else {
                        spine.push(
                            values
                                .remove(b"idref".as_slice())
                                .ok_or(ConversionError::UnsupportedContent)?,
                        );
                    }
                }
            }
            Event::Eof => break,
            _ => (),
        }
    }
    // Ensure upstream cannot interpret a nominally binary entry as unchecked XML/CSS.
    for (href, media) in manifest.values() {
        let href = href.to_ascii_lowercase();
        let extension = href.rsplit('.').next().unwrap_or("");
        let valid = match media.as_str() {
            "application/xhtml+xml" => matches!(extension, "xhtml" | "html" | "htm"),
            "application/x-dtbncx+xml" => extension == "ncx",
            "text/css" => extension == "css",
            "image/svg+xml" => extension == "svg",
            "image/png" => extension == "png",
            "image/jpeg" => matches!(extension, "jpg" | "jpeg"),
            "image/gif" => extension == "gif",
            "image/webp" => extension == "webp",
            "image/bmp" => extension == "bmp",
            "font/ttf" | "application/x-font-truetype" => extension == "ttf",
            "font/otf" | "application/vnd.ms-opentype" => extension == "otf",
            "application/font-sfnt" => matches!(extension, "ttf" | "otf"),
            "font/woff" | "application/font-woff" => extension == "woff",
            "font/woff2" => extension == "woff2",
            _ => false,
        };
        if !valid {
            return Err(ConversionError::UnsupportedContent);
        }
    }
    if spine.is_empty() {
        return Err(ConversionError::UnsupportedContent);
    }
    for id in spine {
        if manifest
            .get(&id)
            .is_none_or(|(_, media)| media != "application/xhtml+xml")
        {
            return Err(ConversionError::UnsupportedContent);
        }
    }
    Ok(())
}

fn spend(budget: &mut usize) -> Result<(), ConversionError> {
    *budget += 1;
    if *budget > MAX_XML_EVENTS {
        Err(ConversionError::ResourceLimit)
    } else {
        Ok(())
    }
}

fn reference(value: &str, document: &str, names: &HashSet<String>) -> Result<(), ConversionError> {
    let value = value.trim();
    if value.starts_with('#') || value.is_empty() {
        return Ok(());
    }
    let value = value.split('#').next().unwrap_or(value);
    let mut decoded = Vec::new();
    let mut input = value.as_bytes().iter().copied();
    while let Some(byte) = input.next() {
        if byte == b'%' {
            let high = input.next().and_then(|b| (b as char).to_digit(16));
            let low = input.next().and_then(|b| (b as char).to_digit(16));
            match (high, low) {
                (Some(high), Some(low)) => decoded.push((high * 16 + low) as u8),
                _ => return Err(ConversionError::UnsupportedContent),
            }
        } else {
            decoded.push(byte);
        }
    }
    let value = std::str::from_utf8(&decoded).map_err(|_| ConversionError::UnsupportedContent)?;
    if value.starts_with('/')
        || value.contains([':', '\\', '?', '%'])
        || value.chars().any(char::is_control)
    {
        return Err(ConversionError::UnsupportedContent);
    }
    let mut parts: Vec<_> = document
        .rsplit_once('/')
        .map(|(base, _)| base.split('/').collect())
        .unwrap_or_default();
    for part in value.split('/') {
        match part {
            "" | "." => (),
            ".." => {
                if parts.pop().is_none() {
                    return Err(ConversionError::UnsafeArchive);
                }
            }
            _ => parts.push(part),
        }
    }
    if !names.contains(&parts.join("/")) {
        return Err(ConversionError::UnsupportedContent);
    }
    Ok(())
}

fn attributes(
    element: &BytesStart<'_>,
    reader: &Reader<&[u8]>,
    document: &str,
    names: &HashSet<String>,
    budget: &mut usize,
) -> Result<(), ConversionError> {
    let name = element.local_name().as_ref().to_ascii_lowercase();
    if matches!(
        name.as_slice(),
        b"script"
            | b"iframe"
            | b"object"
            | b"embed"
            | b"base"
            | b"set"
            | b"animate"
            | b"animatemotion"
            | b"animatetransform"
    ) {
        return Err(ConversionError::UnsupportedContent);
    }
    for (index, attribute) in element.attributes().enumerate() {
        if index >= 64 {
            return Err(ConversionError::ResourceLimit);
        }
        spend(budget)?;
        let attribute = attribute.map_err(|_| ConversionError::UnsupportedContent)?;
        let value = attribute
            .decode_and_unescape_value(reader.decoder())
            .map_err(|_| ConversionError::UnsupportedContent)?;
        let key = attribute.key.local_name().as_ref().to_ascii_lowercase();
        if attribute.key.as_ref().eq_ignore_ascii_case(b"xml:base")
            || key.starts_with(b"on")
            || matches!(
                key.as_slice(),
                b"srcset" | b"action" | b"formaction" | b"http-equiv" | b"background"
            )
        {
            return Err(ConversionError::UnsupportedContent);
        }
        if matches!(key.as_slice(), b"href" | b"src" | b"poster" | b"data") {
            reference(&value, document, names)?;
        } else if key == b"full-path" {
            if !value.to_ascii_lowercase().ends_with(".opf") {
                return Err(ConversionError::UnsupportedContent);
            }
            reference(&value, "container.xml", names)?;
        } else if matches!(
            key.as_slice(),
            b"style"
                | b"fill"
                | b"stroke"
                | b"filter"
                | b"mask"
                | b"clip-path"
                | b"cursor"
                | b"marker"
                | b"marker-start"
                | b"marker-mid"
                | b"marker-end"
        ) {
            css_check(&value, document, names, budget)?;
        } else if key == b"properties" && value.split_whitespace().any(|v| v == "remote-resources")
        {
            return Err(ConversionError::UnsupportedContent);
        }
    }
    Ok(())
}

fn xml(
    contents: &[u8],
    document: &str,
    names: &HashSet<String>,
    budget: &mut usize,
) -> Result<(), ConversionError> {
    let text = std::str::from_utf8(contents).map_err(|_| ConversionError::UnsupportedContent)?;
    let mut reader = Reader::from_str(text);
    let mut depth = 0;
    let mut style_depth = None;
    let mut style = String::new();
    let mut roots = 0;
    loop {
        spend(budget)?;
        let event = reader
            .read_event()
            .map_err(|_| ConversionError::UnsupportedContent)?;
        match event {
            Event::Start(element) => {
                if depth == 0 {
                    roots += 1;
                }
                depth += 1;
                if depth > MAX_XML_DEPTH {
                    return Err(ConversionError::ResourceLimit);
                }
                attributes(&element, &reader, document, names, budget)?;
                if element.local_name().as_ref().eq_ignore_ascii_case(b"style") {
                    style_depth = Some(depth);
                }
            }
            Event::Empty(element) => {
                if depth == 0 {
                    roots += 1;
                }
                if depth + 1 > MAX_XML_DEPTH {
                    return Err(ConversionError::ResourceLimit);
                }
                attributes(&element, &reader, document, names, budget)?;
            }
            Event::End(_) => {
                if style_depth == Some(depth) {
                    css_check(&style, document, names, budget)?;
                    style.clear();
                    style_depth = None;
                }
                depth = depth
                    .checked_sub(1)
                    .ok_or(ConversionError::UnsupportedContent)?;
            }
            Event::Decl(decl) => {
                if let Some(encoding) = decl.encoding() {
                    let encoding = encoding.map_err(|_| ConversionError::UnsupportedContent)?;
                    if !encoding.eq_ignore_ascii_case(b"utf-8") {
                        return Err(ConversionError::UnsupportedContent);
                    }
                }
            }
            Event::DocType(_) | Event::PI(_) => return Err(ConversionError::UnsupportedContent),
            Event::GeneralRef(entity) => {
                let character = entity
                    .resolve_char_ref()
                    .map_err(|_| ConversionError::UnsupportedContent)?;
                if character.is_none()
                    && !matches!(&*entity, b"amp" | b"lt" | b"gt" | b"apos" | b"quot")
                {
                    return Err(ConversionError::UnsupportedContent);
                }
                if style_depth.is_some() {
                    let character = character
                        .or_else(|| match &*entity {
                            b"amp" => Some('&'),
                            b"lt" => Some('<'),
                            b"gt" => Some('>'),
                            b"apos" => Some('\''),
                            b"quot" => Some('"'),
                            _ => None,
                        })
                        .ok_or(ConversionError::UnsupportedContent)?;
                    style.push(character);
                }
            }
            Event::Text(text) => {
                let value = text
                    .xml_content()
                    .map_err(|_| ConversionError::UnsupportedContent)?;
                if depth == 0 && !value.trim().is_empty() {
                    return Err(ConversionError::UnsupportedContent);
                }
                if style_depth.is_some() {
                    style.push_str(&value);
                }
            }
            Event::CData(text) => {
                if depth == 0 {
                    return Err(ConversionError::UnsupportedContent);
                }
                if style_depth.is_some() {
                    style.push_str(
                        &text
                            .xml_content()
                            .map_err(|_| ConversionError::UnsupportedContent)?,
                    );
                }
            }
            Event::Eof => break,
            _ => (),
        }
    }
    if depth != 0 || roots != 1 {
        return Err(ConversionError::UnsupportedContent);
    }
    Ok(())
}

fn css_check(
    css: &str,
    document: &str,
    names: &HashSet<String>,
    budget: &mut usize,
) -> Result<(), ConversionError> {
    let mut input = ParserInput::new(css);
    let mut parser = Parser::new(&mut input);
    css_tokens(&mut parser, document, names, budget, 0).map_err(|error| match error.kind {
        cssparser::ParseErrorKind::Custom(error) => error,
        _ => ConversionError::UnsupportedContent,
    })
}

fn css_tokens<'i>(
    parser: &mut Parser<'i, '_>,
    document: &str,
    names: &HashSet<String>,
    budget: &mut usize,
    depth: usize,
) -> Result<(), ParseError<'i, ConversionError>> {
    if depth > MAX_XML_DEPTH {
        return Err(parser.new_custom_error(ConversionError::ResourceLimit));
    }
    while !parser.is_exhausted() {
        spend(budget).map_err(|error| parser.new_custom_error(error))?;
        let token = parser.next_including_whitespace_and_comments()?.clone();
        match token {
            Token::Function(name)
                if name.eq_ignore_ascii_case("image-set")
                    || name.eq_ignore_ascii_case("-webkit-image-set") =>
            {
                return Err(parser.new_custom_error(ConversionError::UnsupportedContent));
            }
            Token::UnquotedUrl(value) => reference(&value, document, names)
                .map_err(|error| parser.new_custom_error(error))?,
            Token::Function(name) if name.eq_ignore_ascii_case("url") => {
                parser.parse_nested_block(|nested| {
                    let value = nested.expect_string()?.clone();
                    reference(&value, document, names)
                        .map_err(|error| nested.new_custom_error(error))
                })?;
            }
            Token::AtKeyword(name) if name.eq_ignore_ascii_case("import") => {
                return Err(parser.new_custom_error(ConversionError::UnsupportedContent));
            }
            Token::Function(_)
            | Token::ParenthesisBlock
            | Token::SquareBracketBlock
            | Token::CurlyBracketBlock => {
                parser.parse_nested_block(|nested| {
                    css_tokens(nested, document, names, budget, depth + 1)
                })?;
            }
            Token::BadUrl(_) | Token::BadString(_) => {
                return Err(parser.new_custom_error(ConversionError::UnsupportedContent));
            }
            _ => (),
        }
    }
    Ok(())
}
