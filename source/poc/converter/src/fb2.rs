//! Conservative FictionBook 2.0 profile. No fetching, stylesheet execution or extraction.
//! UTF-8 and explicitly declared Windows-1251 are accepted; other encodings are rejected.
use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::io::{Cursor, Write};

use base64::{Engine, engine::general_purpose::STANDARD};
use quick_xml::NsReader;
use quick_xml::events::Event;
use quick_xml::name::ResolveResult;
use zip::write::SimpleFileOptions;

use crate::{
    ConversionError as Error, MAX_ENTRIES, MAX_ENTRY_BYTES, MAX_INPUT_BYTES, MAX_UNPACKED_BYTES,
    MAX_XML_DEPTH, MAX_XML_EVENTS, catch_converter, validation,
};

const FB: &[u8] = b"http://www.gribuser.ru/xml/fictionbook/2.0";
const XLINK: &[u8] = b"http://www.w3.org/1999/xlink";
const XML: &[u8] = b"http://www.w3.org/XML/1998/namespace";

#[derive(Debug)]
enum Part {
    Text(String),
    Node(usize),
}
#[derive(Debug)]
struct Node {
    name: String,
    attrs: HashMap<String, String>,
    parts: Vec<Part>,
}
impl Node {
    fn attr(&self, key: &str) -> Option<&str> {
        self.attrs.get(key).map(String::as_str)
    }
    fn children(&self) -> impl Iterator<Item = usize> + '_ {
        self.parts.iter().filter_map(|part| match part {
            Part::Node(n) => Some(*n),
            _ => None,
        })
    }
}

fn spend(budget: &mut usize) -> Result<(), Error> {
    *budget += 1;
    if *budget > MAX_XML_EVENTS {
        return Err(Error::ResourceLimit);
    }
    Ok(())
}
fn xml_char(c: char) -> bool {
    matches!(c, '\t' | '\n' | '\r') || c >= '\u{20}' && !matches!(c, '\u{fffe}' | '\u{ffff}')
}
fn decode(bytes: &[u8]) -> Result<Cow<'_, str>, Error> {
    if bytes.len() as u64 > MAX_INPUT_BYTES {
        return Err(Error::TooLarge);
    }
    if bytes.starts_with(&[0xff, 0xfe]) || bytes.starts_with(&[0xfe, 0xff]) || bytes.contains(&0) {
        return Err(Error::UnsupportedEncoding);
    }
    let bytes = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(bytes);
    // The declaration is ASCII even when the following document is Windows-1251.
    let mut encoding = b"UTF-8".to_vec();
    if bytes.starts_with(b"<?xml") {
        let end = bytes
            .windows(2)
            .position(|w| w == b"?>")
            .ok_or(Error::InvalidFb2)?;
        let declaration = std::str::from_utf8(&bytes[..end + 2]).map_err(|_| Error::InvalidFb2)?;
        let mut reader = quick_xml::Reader::from_str(declaration);
        if let Event::Decl(decl) = reader.read_event().map_err(|_| Error::InvalidFb2)? {
            if let Some(value) = decl.encoding() {
                encoding = value.map_err(|_| Error::InvalidFb2)?.into_owned();
            }
        } else {
            return Err(Error::InvalidFb2);
        }
    }
    let result =
        if encoding.eq_ignore_ascii_case(b"utf-8") || encoding.eq_ignore_ascii_case(b"utf8") {
            Cow::Borrowed(std::str::from_utf8(bytes).map_err(|_| Error::InvalidFb2)?)
        } else if encoding.eq_ignore_ascii_case(b"windows-1251")
            || encoding.eq_ignore_ascii_case(b"cp1251")
        {
            encoding_rs::WINDOWS_1251
                .decode_without_bom_handling_and_without_replacement(bytes)
                .ok_or(Error::InvalidFb2)?
        } else {
            return Err(Error::UnsupportedEncoding);
        };
    if !result.chars().all(xml_char) {
        return Err(Error::InvalidFb2);
    }
    Ok(result)
}

fn parse(text: &str) -> Result<Vec<Node>, Error> {
    let mut reader = NsReader::from_str(text);
    let mut nodes: Vec<Node> = Vec::new();
    let mut stack: Vec<usize> = Vec::new();
    let mut ids = HashSet::new();
    let mut budget = 0;
    let mut root_closed = false;
    let mut declared = false;
    loop {
        spend(&mut budget)?;
        let (namespace, event) = reader
            .read_resolved_event()
            .map_err(|_| Error::InvalidFb2)?;
        let fb_namespace = matches!(namespace, ResolveResult::Bound(ns) if ns.as_ref() == FB);
        match event {
            Event::Start(ref element) | Event::Empty(ref element) => {
                if !fb_namespace || root_closed {
                    return Err(Error::InvalidFb2);
                }
                if stack.len() >= MAX_XML_DEPTH {
                    return Err(Error::ResourceLimit);
                }
                let name = std::str::from_utf8(element.local_name().as_ref())
                    .map_err(|_| Error::InvalidFb2)?
                    .to_owned();
                if nodes.is_empty() && name != "FictionBook" {
                    return Err(Error::InvalidFb2);
                }
                let mut attrs = HashMap::new();
                for (index, attr) in element.attributes().enumerate() {
                    if index >= 64 {
                        return Err(Error::ResourceLimit);
                    }
                    spend(&mut budget)?;
                    let attr = attr.map_err(|_| Error::InvalidFb2)?;
                    if attr.key.as_ref() == b"xmlns" || attr.key.as_ref().starts_with(b"xmlns:") {
                        continue;
                    }
                    let (ns, local) = reader.resolver().resolve_attribute(attr.key);
                    let key = std::str::from_utf8(local.as_ref()).map_err(|_| Error::InvalidFb2)?;
                    let key = match ns {
                        ResolveResult::Unbound => key.to_owned(),
                        ResolveResult::Bound(ns)
                            if ns.as_ref() == XLINK && matches!(key, "href" | "type") =>
                        {
                            format!("xlink:{key}")
                        }
                        ResolveResult::Bound(ns) if ns.as_ref() == XML && key == "lang" => {
                            "xml:lang".to_owned()
                        }
                        _ => return Err(Error::UnsupportedContent),
                    };
                    let value = attr
                        .decode_and_unescape_value(reader.decoder())
                        .map_err(|_| Error::InvalidFb2)?
                        .into_owned();
                    if !value.chars().all(xml_char)
                        || attrs.insert(key.clone(), value.clone()).is_some()
                    {
                        return Err(Error::InvalidFb2);
                    }
                    if key == "id" && (value.is_empty() || !ids.insert(value)) {
                        return Err(Error::InvalidFb2);
                    }
                    if key == "xlink:href" && !attrs[&key].starts_with('#') {
                        return Err(Error::UnsupportedContent);
                    }
                    if !matches!(
                        key.as_str(),
                        "id" | "name"
                            | "content-type"
                            | "xlink:href"
                            | "xlink:type"
                            | "xml:lang"
                            | "type"
                            | "value"
                            | "number"
                            | "match"
                            | "info-type"
                            | "alt"
                            | "title"
                    ) {
                        return Err(Error::UnsupportedContent);
                    }
                }
                let index = nodes.len();
                nodes.push(Node {
                    name,
                    attrs,
                    parts: Vec::new(),
                });
                if let Some(&parent) = stack.last() {
                    nodes[parent].parts.push(Part::Node(index));
                } else if index != 0 {
                    return Err(Error::InvalidFb2);
                }
                if matches!(event, Event::Start(_)) {
                    stack.push(index);
                } else if index == 0 {
                    root_closed = true;
                }
            }
            Event::End(_) => {
                if stack.pop().is_none() {
                    return Err(Error::InvalidFb2);
                }
                if stack.is_empty() {
                    root_closed = true;
                }
            }
            Event::Text(t) => {
                let raw = t.xml_content().map_err(|_| Error::InvalidFb2)?;
                // quick-xml emits general references separately; never resolve custom entities.
                append_text(&mut nodes, &stack, raw.as_ref())?;
            }
            Event::CData(t) => append_text(
                &mut nodes,
                &stack,
                &t.xml_content().map_err(|_| Error::InvalidFb2)?,
            )?,
            Event::GeneralRef(reference) => {
                let reference = reference.decode().map_err(|_| Error::InvalidFb2)?;
                let escaped = format!("&{reference};");
                let value = quick_xml::escape::unescape(&escaped).map_err(|_| Error::InvalidFb2)?;
                append_text(&mut nodes, &stack, &value)?;
            }
            Event::DocType(_) | Event::PI(_) => return Err(Error::UnsupportedContent),
            Event::Decl(_) if !nodes.is_empty() || declared => return Err(Error::InvalidFb2),
            Event::Decl(_) => declared = true,
            Event::Comment(_) => (),
            Event::Eof => break,
        }
    }
    if nodes.is_empty() || !stack.is_empty() || !root_closed {
        return Err(Error::InvalidFb2);
    }
    Ok(nodes)
}
fn append_text(nodes: &mut [Node], stack: &[usize], text: &str) -> Result<(), Error> {
    if !text.chars().all(xml_char) {
        return Err(Error::InvalidFb2);
    }
    if let Some(&index) = stack.last() {
        nodes[index].parts.push(Part::Text(text.to_owned()));
    } else if !text.trim().is_empty() {
        return Err(Error::InvalidFb2);
    }
    Ok(())
}
fn plain(nodes: &[Node], index: usize) -> String {
    let mut result = String::new();
    for part in &nodes[index].parts {
        match part {
            Part::Text(t) => result.push_str(t),
            Part::Node(n) => result.push_str(&plain(nodes, *n)),
        }
    }
    result
}
fn child(nodes: &[Node], parent: usize, name: &str) -> Result<usize, Error> {
    let mut found = nodes[parent].children().filter(|&n| nodes[n].name == name);
    let result = found.next().ok_or(Error::InvalidFb2)?;
    if found.next().is_some() {
        return Err(Error::InvalidFb2);
    }
    Ok(result)
}
fn no_direct_text(node: &Node) -> Result<(), Error> {
    if node
        .parts
        .iter()
        .any(|p| matches!(p, Part::Text(t) if !t.trim().is_empty()))
    {
        return Err(Error::InvalidFb2);
    }
    Ok(())
}

#[derive(Default)]
struct Text(String);
impl Text {
    fn push(&mut self, s: &str) -> Result<(), Error> {
        if self.0.len().saturating_add(s.len()) as u64 > MAX_ENTRY_BYTES {
            return Err(Error::ResourceLimit);
        }
        self.0.push_str(s);
        Ok(())
    }
    fn escape(&mut self, s: &str) -> Result<(), Error> {
        for c in s.chars() {
            match c {
                '&' => self.push("&amp;")?,
                '<' => self.push("&lt;")?,
                '>' => self.push("&gt;")?,
                '"' => self.push("&quot;")?,
                '\'' => self.push("&apos;")?,
                _ => {
                    let mut buf = [0; 4];
                    self.push(c.encode_utf8(&mut buf))?;
                }
            }
        }
        Ok(())
    }
}
struct Image {
    node: usize,
    path: String,
    media: &'static str,
    bytes: Vec<u8>,
}
fn image(nodes: &[Node], n: usize, number: usize) -> Result<Image, Error> {
    let node = &nodes[n];
    if node.children().next().is_some() || node.attr("id").is_none() {
        return Err(Error::InvalidFb2);
    }
    let raw = plain(nodes, n);
    let compact: Vec<u8> = raw.bytes().filter(|c| !c.is_ascii_whitespace()).collect();
    if compact.len() > (MAX_ENTRY_BYTES as usize).div_ceil(3) * 4 {
        return Err(Error::ResourceLimit);
    }
    let bytes = STANDARD.decode(compact).map_err(|_| Error::InvalidFb2)?;
    if bytes.len() as u64 > MAX_ENTRY_BYTES {
        return Err(Error::ResourceLimit);
    }
    let (media, extension) = match node.attr("content-type") {
        Some("image/png") if bytes.starts_with(b"\x89PNG\r\n\x1a\n") => ("image/png", "png"),
        Some("image/jpeg")
            if bytes.starts_with(&[0xff, 0xd8, 0xff]) && bytes.ends_with(&[0xff, 0xd9]) =>
        {
            ("image/jpeg", "jpg")
        }
        Some("image/png" | "image/jpeg") => return Err(Error::InvalidFb2),
        _ => return Err(Error::UnsupportedContent),
    };
    check_raster(&bytes, extension)?;
    Ok(Image {
        node: n,
        path: format!("image{number}.{extension}"),
        media,
        bytes,
    })
}
fn dimensions(width: u32, height: u32) -> Result<(), Error> {
    if width == 0 || height == 0 {
        return Err(Error::InvalidFb2);
    }
    if u64::from(width) * u64::from(height) > 16 * 1024 * 1024 {
        return Err(Error::ResourceLimit);
    }
    Ok(())
}
fn check_raster(bytes: &[u8], extension: &str) -> Result<(), Error> {
    if extension == "png" {
        let mut at = 8;
        let mut header = false;
        let mut data = false;
        while let Some(chunk) = bytes.get(at..at + 8) {
            let size =
                u32::from_be_bytes(chunk[..4].try_into().map_err(|_| Error::InvalidFb2)?) as usize;
            let end = at
                .checked_add(12)
                .and_then(|n| n.checked_add(size))
                .ok_or(Error::InvalidFb2)?;
            if end > bytes.len() {
                return Err(Error::InvalidFb2);
            }
            match &chunk[4..8] {
                b"IHDR" if at == 8 && size == 13 => {
                    dimensions(
                        u32::from_be_bytes(
                            bytes[at + 8..at + 12]
                                .try_into()
                                .map_err(|_| Error::InvalidFb2)?,
                        ),
                        u32::from_be_bytes(
                            bytes[at + 12..at + 16]
                                .try_into()
                                .map_err(|_| Error::InvalidFb2)?,
                        ),
                    )?;
                    header = true;
                }
                b"IHDR" => return Err(Error::InvalidFb2),
                b"IDAT" => data = true,
                b"IEND" if size == 0 && end == bytes.len() && header && data => return Ok(()),
                _ => (),
            }
            at = end;
        }
        return Err(Error::InvalidFb2);
    }
    let mut at = 2;
    while at + 4 <= bytes.len() {
        if bytes[at] != 0xff {
            return Err(Error::InvalidFb2);
        }
        let marker = bytes[at + 1];
        if marker == 0xff {
            at += 1;
            continue;
        }
        let size = usize::from(u16::from_be_bytes([bytes[at + 2], bytes[at + 3]]));
        if size < 2 || at + 2 + size > bytes.len() {
            return Err(Error::InvalidFb2);
        }
        if matches!(marker, 0xc0..=0xc3 | 0xc5..=0xc7 | 0xc9..=0xcb | 0xcd..=0xcf) && size >= 8 {
            return dimensions(
                u32::from(u16::from_be_bytes([bytes[at + 7], bytes[at + 8]])),
                u32::from(u16::from_be_bytes([bytes[at + 5], bytes[at + 6]])),
            );
        }
        if marker == 0xda {
            break;
        }
        at += 2 + size;
    }
    Err(Error::InvalidFb2)
}

struct Render<'a> {
    nodes: &'a [Node],
    targets: HashMap<String, String>,
    images: HashMap<String, String>,
    toc: Vec<(String, String)>,
}
impl Render<'_> {
    fn node(&mut self, n: usize, path: &str, depth: usize, output: &mut Text) -> Result<(), Error> {
        self.node_as(n, path, depth, output, false)
    }
    fn node_as(
        &mut self,
        n: usize,
        path: &str,
        depth: usize,
        output: &mut Text,
        heading: bool,
    ) -> Result<(), Error> {
        let node = &self.nodes[n];
        let heading_tag = format!("h{}", depth.clamp(1, 6));
        let tag = if heading && node.name == "p" {
            heading_tag.as_str()
        } else {
            match node.name.as_str() {
                "body" | "section" | "stanza" | "poem" | "title" => "div",
                "p" | "v" | "text-author" => "p",
                "subtitle" => "h2",
                "epigraph" | "cite" => "blockquote",
                "emphasis" => "em",
                "strong" => "strong",
                "sub" => "sub",
                "sup" => "sup",
                "strikethrough" => "del",
                "code" => "code",
                "a" => "a",
                "empty-line" => "br",
                "image" => "img",
                _ => return Err(Error::UnsupportedContent),
            }
        };
        if node.attrs.keys().any(|k| {
            !matches!(
                k.as_str(),
                "id" | "xml:lang" | "name" | "xlink:href" | "xlink:type" | "type" | "alt" | "title"
            )
        }) {
            return Err(Error::UnsupportedContent);
        }
        if node.name == "section"
            && let Some(title) = node.children().find(|&c| self.nodes[c].name == "title")
        {
            self.toc.push((
                format!("{path}#n{n}"),
                plain(self.nodes, title)
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" "),
            ));
        }
        output.push(&format!("<{tag} id=\"n{n}\""))?;
        if let Some(lang) = node.attr("xml:lang") {
            output.push(" xml:lang=\"")?;
            output.escape(lang)?;
            output.push("\"")?;
        }
        if node.name == "title" {
            output.push(&format!(" class=\"heading{}\"", depth.min(6)))?;
        }
        if node.name == "a" || node.name == "image" {
            let target = node
                .attr("xlink:href")
                .ok_or(Error::InvalidFb2)?
                .strip_prefix('#')
                .ok_or(Error::UnsupportedContent)?;
            let resolved = if node.name == "a" {
                self.targets.get(target)
            } else {
                self.images.get(target)
            }
            .ok_or(Error::InvalidFb2)?;
            output.push(if node.name == "a" {
                " href=\""
            } else {
                " src=\""
            })?;
            output.escape(resolved)?;
            output.push("\"")?;
        }
        if node.name == "image" {
            output.push(" alt=\"")?;
            output.escape(node.attr("alt").or(node.attr("title")).unwrap_or(""))?;
            output.push("\"")?;
        }
        if matches!(node.name.as_str(), "empty-line" | "image") {
            if node.children().next().is_some()
                || node
                    .parts
                    .iter()
                    .any(|p| matches!(p, Part::Text(t) if !t.trim().is_empty()))
            {
                return Err(Error::InvalidFb2);
            }
            output.push("/>")?;
            return Ok(());
        }
        output.push(">")?;
        for part in &node.parts {
            match part {
                Part::Text(t) => output.escape(t)?,
                Part::Node(c) => {
                    // Avoid invalid nested paragraphs/blocks being repaired (and lost) by HTML parsers.
                    if matches!(
                        node.name.as_str(),
                        "p" | "v"
                            | "subtitle"
                            | "text-author"
                            | "emphasis"
                            | "strong"
                            | "sub"
                            | "sup"
                            | "strikethrough"
                            | "code"
                            | "a"
                    ) && !matches!(
                        self.nodes[*c].name.as_str(),
                        "emphasis"
                            | "strong"
                            | "sub"
                            | "sup"
                            | "strikethrough"
                            | "code"
                            | "a"
                            | "image"
                    ) {
                        return Err(Error::UnsupportedContent);
                    }
                    if node.name == "a" && self.nodes[*c].name == "a" {
                        return Err(Error::UnsupportedContent);
                    }
                    self.node_as(
                        *c,
                        path,
                        depth + usize::from(node.name == "section"),
                        output,
                        node.name == "title",
                    )?;
                }
            }
        }
        output.push(&format!("</{tag}>"))
    }
}
fn register_targets(nodes: &[Node], n: usize, path: &str, targets: &mut HashMap<String, String>) {
    if let Some(id) = nodes[n].attr("id") {
        targets.insert(id.to_owned(), format!("{path}#n{n}"));
    }
    for c in nodes[n].children() {
        register_targets(nodes, c, path, targets);
    }
}
fn html_start(title: &str, lang: &str) -> Result<Text, Error> {
    let mut t = Text::default();
    t.push("<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" xml:lang=\"")?;
    t.escape(lang)?;
    t.push("\"><head><title>")?;
    t.escape(title)?;
    t.push("</title></head><body>")?;
    Ok(t)
}

/// Build a bounded EPUB independently of AZW3 export, then validate/reopen it.
/// Meaningful unsupported body markup (including tables/styles) is rejected.
/// Extra bibliographic/source metadata is not copied; title, language, authors,
/// annotation, cover, all bodies, inline content and internal links are retained.
pub fn fb2_to_epub(bytes: &[u8]) -> Result<Vec<u8>, Error> {
    catch_converter(|| {
        let text = decode(bytes)?;
        let nodes = parse(&text)?;
        let epub = package(&nodes)?;
        validation::validate(&epub)?;
        boko::Book::from_bytes(&epub, boko::Format::Epub).map_err(|_| Error::Converter)?;
        Ok(epub)
    })
}
fn package(nodes: &[Node]) -> Result<Vec<u8>, Error> {
    no_direct_text(&nodes[0])?;
    for c in nodes[0].children() {
        if !matches!(nodes[c].name.as_str(), "description" | "body" | "binary") {
            return Err(Error::UnsupportedContent);
        }
    }
    let description = child(nodes, 0, "description")?;
    let info = child(nodes, description, "title-info")?;
    let title = plain(nodes, child(nodes, info, "book-title")?)
        .trim()
        .to_owned();
    let lang = plain(nodes, child(nodes, info, "lang")?).trim().to_owned();
    if title.is_empty() || lang.is_empty() {
        return Err(Error::InvalidFb2);
    }
    // Metadata is inert text. Reject undeclared extensions/active elements even here.
    fn metadata(nodes: &[Node], n: usize) -> Result<(), Error> {
        if !matches!(
            nodes[n].name.as_str(),
            "description"
                | "title-info"
                | "src-title-info"
                | "document-info"
                | "publish-info"
                | "custom-info"
                | "genre"
                | "author"
                | "translator"
                | "first-name"
                | "middle-name"
                | "last-name"
                | "nickname"
                | "home-page"
                | "email"
                | "id"
                | "book-title"
                | "annotation"
                | "keywords"
                | "date"
                | "coverpage"
                | "image"
                | "lang"
                | "src-lang"
                | "sequence"
                | "program-used"
                | "src-url"
                | "src-ocr"
                | "version"
                | "history"
                | "publisher"
                | "book-name"
                | "city"
                | "year"
                | "isbn"
                | "p"
                | "emphasis"
                | "strong"
                | "sub"
                | "sup"
                | "strikethrough"
                | "code"
                | "a"
                | "poem"
                | "stanza"
                | "v"
                | "title"
                | "subtitle"
                | "text-author"
                | "empty-line"
                | "cite"
        ) {
            return Err(Error::UnsupportedContent);
        }
        for c in nodes[n].children() {
            metadata(nodes, c)?;
        }
        Ok(())
    }
    metadata(nodes, description)?;
    let bodies: Vec<_> = nodes[0]
        .children()
        .filter(|&n| nodes[n].name == "body")
        .collect();
    if bodies.is_empty() {
        return Err(Error::InvalidFb2);
    }
    let images: Vec<_> = nodes[0]
        .children()
        .filter(|&n| nodes[n].name == "binary")
        .enumerate()
        .map(|(i, n)| image(nodes, n, i))
        .collect::<Result<_, _>>()?;
    if bodies.len() + images.len() + 5 > MAX_ENTRIES {
        return Err(Error::ResourceLimit);
    }
    let image_ids: HashMap<_, _> = images
        .iter()
        .map(|image| {
            (
                nodes[image.node].attr("id").unwrap_or("").to_owned(),
                image.path.clone(),
            )
        })
        .collect();
    let mut render = Render {
        nodes,
        targets: HashMap::new(),
        images: image_ids,
        toc: Vec::new(),
    };
    for (i, &body) in bodies.iter().enumerate() {
        register_targets(nodes, body, &format!("body{i}.xhtml"), &mut render.targets);
    }
    let mut entries: Vec<(String, Vec<u8>)> = vec![("mimetype".into(), b"application/epub+zip".to_vec()), ("META-INF/container.xml".into(), br#"<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#.to_vec())];
    let cover = nodes[info]
        .children()
        .find(|&n| nodes[n].name == "coverpage")
        .map(|c| child(nodes, c, "image"))
        .transpose()?;
    let cover_path = cover
        .map(|c| {
            nodes[c]
                .attr("xlink:href")
                .and_then(|v| v.strip_prefix('#'))
                .and_then(|id| render.images.get(id))
                .cloned()
                .ok_or(Error::InvalidFb2)
        })
        .transpose()?;
    for (i, &body) in bodies.iter().enumerate() {
        let path = format!("body{i}.xhtml");
        let mut html = html_start(&title, &lang)?;
        if i == 0 {
            if let Some(c) = cover {
                render.node(c, &path, 1, &mut html)?;
            }
            if let Some(a) = nodes[info]
                .children()
                .find(|&n| nodes[n].name == "annotation")
            {
                html.push("<div>")?;
                for part in &nodes[a].parts {
                    match part {
                        Part::Text(t) => html.escape(t)?,
                        Part::Node(n) => render.node(*n, &path, 1, &mut html)?,
                    }
                }
                html.push("</div>")?;
            }
        }
        render.node(body, &path, 1, &mut html)?;
        html.push("</body></html>")?;
        entries.push((format!("EPUB/{path}"), html.0.into_bytes()));
    }
    let mut nav = html_start(&title, &lang)?;
    nav.push("<nav epub:type=\"toc\"><ol>")?;
    if render.toc.is_empty() {
        render.toc.push(("body0.xhtml".to_owned(), title.clone()));
    }
    for (href, text) in &render.toc {
        nav.push("<li><a href=\"")?;
        nav.escape(href)?;
        nav.push("\">")?;
        nav.escape(text)?;
        nav.push("</a></li>")?;
    }
    nav.push("</ol></nav></body></html>")?;
    entries.push(("EPUB/nav.xhtml".into(), nav.0.into_bytes()));
    // Content identity avoids giving every imported book the same identifier.
    // This deterministic hash is an identifier only, never an integrity/security claim.
    let mut identity = DefaultHasher::new();
    for node in nodes {
        node.name.hash(&mut identity);
        let mut attrs: Vec<_> = node.attrs.iter().collect();
        attrs.sort_unstable_by_key(|(key, _)| *key);
        attrs.hash(&mut identity);
        for part in &node.parts {
            match part {
                Part::Text(t) => {
                    0u8.hash(&mut identity);
                    t.hash(&mut identity);
                }
                Part::Node(n) => {
                    1u8.hash(&mut identity);
                    n.hash(&mut identity);
                }
            }
        }
    }
    let mut opf = Text::default();
    opf.push("<?xml version=\"1.0\" encoding=\"UTF-8\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"book-id\">")?;
    opf.push(&format!("urn:brizfi:fb2:{:016x}", identity.finish()))?;
    opf.push("</dc:identifier><dc:title>")?;
    opf.escape(&title)?;
    opf.push("</dc:title><dc:language>")?;
    opf.escape(&lang)?;
    opf.push("</dc:language>")?;
    for author in nodes[info]
        .children()
        .filter(|&n| nodes[n].name == "author")
    {
        let mut parts = Vec::new();
        for name in ["first-name", "middle-name", "last-name"] {
            if let Some(c) = nodes[author].children().find(|&n| nodes[n].name == name) {
                parts.push(plain(nodes, c).trim().to_owned());
            }
        }
        if parts.is_empty()
            && let Some(c) = nodes[author]
                .children()
                .find(|&n| nodes[n].name == "nickname")
        {
            parts.push(plain(nodes, c).trim().to_owned());
        }
        opf.push("<dc:creator>")?;
        opf.escape(&parts.join(" "))?;
        opf.push("</dc:creator>")?;
    }
    opf.push("<meta property=\"dcterms:modified\">2026-10-09T00:00:00Z</meta></metadata><manifest><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>")?;
    for i in 0..bodies.len() {
        opf.push(&format!(
            "<item id=\"body{i}\" href=\"body{i}.xhtml\" media-type=\"application/xhtml+xml\"/>"
        ))?;
    }
    for (i, image) in images.iter().enumerate() {
        opf.push(&format!(
            "<item id=\"image{i}\" href=\"{}\" media-type=\"{}\"{} />",
            image.path,
            image.media,
            if cover_path.as_ref() == Some(&image.path) {
                " properties=\"cover-image\""
            } else {
                ""
            }
        ))?;
    }
    opf.push("</manifest><spine>")?;
    for i in 0..bodies.len() {
        opf.push(&format!(
            "<itemref idref=\"body{i}\"{} />",
            if i == 0 { "" } else { " linear=\"no\"" }
        ))?;
    }
    opf.push("</spine></package>")?;
    entries.push(("EPUB/package.opf".into(), opf.0.into_bytes()));
    for image in images {
        entries.push((format!("EPUB/{}", image.path), image.bytes));
    }
    let mut total = 0u64;
    let mut zip = zip::ZipWriter::new(Cursor::new(Vec::new()));
    let options = SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Stored)
        .last_modified_time(zip::DateTime::default());
    for (path, bytes) in entries {
        total += bytes.len() as u64;
        if bytes.len() as u64 > MAX_ENTRY_BYTES || total > MAX_UNPACKED_BYTES {
            return Err(Error::ResourceLimit);
        }
        zip.start_file(path, options)?;
        zip.write_all(&bytes)?;
    }
    Ok(zip.finish()?.into_inner())
}

/// Original CC0 FB2 text and a self-created single blue pixel PNG. No personal books.
pub fn original_fb2_fixture() -> Vec<u8> {
    r##"<?xml version="1.0" encoding="UTF-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
<description><title-info><genre>prose_contemporary</genre><author><first-name>BRIZFI</first-name><last-name>PoC</last-name></author><book-title>Бриз: FB2 на Android</book-title><coverpage><image l:href="#cover"/></coverpage><lang>ru</lang></title-info><document-info><author><nickname>BRIZFI</nickname></author><date value="2026-10-09">9 октября 2026</date><id>brizfi-original-fb2</id><version>1.0</version></document-info></description>
<body><section id="first"><title><p>Первая глава</p></title><p>Эта книга преобразована из FB2 на телефоне в BRIZFI. Ёжик смотрел на море, где поднялся лёгкий <emphasis>бриз</emphasis>.</p><p>Небольшое <a l:href="#note" type="note">примечание</a> объясняет слово.</p><image l:href="#cover"/></section><section id="second"><title><p>Вторая глава</p></title><p><strong>Книга осталась рядом.</strong> Можно <a l:href="#first">вернуться к началу</a>.</p><poem><stanza><v>Над морем ветер пел,</v><v>И вечер тихо тлел.</v></stanza><text-author>BRIZFI</text-author></poem></section></body>
<body name="notes"><section id="note"><title><p>Примечание</p></title><p>Бриз — лёгкий прибрежный ветер. <a l:href="#first">Назад</a>.</p></section></body>
<binary id="cover" content-type="image/png">iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNQiV8KAAHTASmn3e17AAAAAElFTkSuQmCC</binary>
</FictionBook>"##.as_bytes().to_vec()
}
