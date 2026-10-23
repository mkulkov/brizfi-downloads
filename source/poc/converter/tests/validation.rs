use std::io::{Cursor, Read, Write};

use brizfi_converter_poc::{MAX_ENTRIES, MAX_ENTRY_BYTES, convert_epub, original_fixture};
use zip::write::SimpleFileOptions;

type TestResult = Result<(), Box<dyn std::error::Error>>;
type Entries = Vec<(String, Vec<u8>)>;

fn entries() -> Result<Entries, Box<dyn std::error::Error>> {
    let mut archive = zip::ZipArchive::new(Cursor::new(original_fixture()?))?;
    let mut entries = Vec::new();
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index)?;
        let name = entry.name().to_owned();
        let mut contents = Vec::new();
        entry.read_to_end(&mut contents)?;
        entries.push((name, contents));
    }
    Ok(entries)
}

fn archive(entries: Entries, compressed: bool) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
    let options = SimpleFileOptions::default().compression_method(if compressed {
        zip::CompressionMethod::Deflated
    } else {
        zip::CompressionMethod::Stored
    });
    for (name, contents) in entries {
        writer.start_file(name, options)?;
        writer.write_all(&contents)?;
    }
    Ok(writer.finish()?.into_inner())
}

fn rejection(bytes: &[u8], code: &str) -> TestResult {
    let directory = tempfile::tempdir()?;
    let input = directory.path().join("managed.epub");
    let output = directory.path().join("new.azw3");
    std::fs::write(&input, bytes)?;
    let error = convert_epub(&input, &output).expect_err("hostile fixture must fail");
    assert_eq!(error.code(), code, "{error}");
    assert!(!output.exists());
    assert_eq!(std::fs::read(&input)?, bytes);
    Ok(())
}

fn replaced_document(value: &str) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let mut entries = entries()?;
    entries
        .iter_mut()
        .find(|(name, _)| name == "EPUB/one.xhtml")
        .ok_or("missing fixture entry")?
        .1 = value.as_bytes().to_vec();
    archive(entries, false)
}

#[test]
fn compressed_fixture_converts() -> TestResult {
    let directory = tempfile::tempdir()?;
    let input = directory.path().join("original.epub");
    let output = directory.path().join("original.azw3");
    std::fs::write(&input, archive(entries()?, true)?)?;
    assert!(convert_epub(&input, &output)? > 0);
    assert_eq!(
        convert_epub(&input, &output).expect_err("exists").code(),
        "output_exists"
    );
    Ok(())
}

#[test]
fn bomb_entry_and_total_limits() -> TestResult {
    let mut oversized = entries()?;
    oversized.push((
        "EPUB/bomb.png".into(),
        vec![0; MAX_ENTRY_BYTES as usize + 1],
    ));
    rejection(&archive(oversized, true)?, "resource_limit")?;
    let mut total = entries()?;
    for index in 0..8 {
        total.push((
            format!("EPUB/{index}.png"),
            vec![0; MAX_ENTRY_BYTES as usize],
        ));
    }
    rejection(&archive(total, true)?, "resource_limit")
}

#[test]
fn actual_decompression_is_bounded_despite_lying_size() -> TestResult {
    let mut entries = entries()?;
    entries.push((
        "EPUB/bomb.png".into(),
        vec![0; MAX_ENTRY_BYTES as usize + 1],
    ));
    let mut bytes = archive(entries, true)?;
    // Lie about the uncompressed size in both header copies, retaining the valid
    // compressed stream/CRC. The stream must hit the actual cap or fail CRC/size.
    for at in 0..bytes.len().saturating_sub(46) {
        let size_at = if bytes.get(at..at + 4) == Some(b"PK\x01\x02")
            && bytes.get(at + 46..at + 59) == Some(b"EPUB/bomb.png")
        {
            Some(at + 24)
        } else if bytes.get(at..at + 4) == Some(b"PK\x03\x04")
            && bytes.get(at + 30..at + 43) == Some(b"EPUB/bomb.png")
        {
            Some(at + 22)
        } else {
            None
        };
        if let Some(at) = size_at {
            bytes[at..at + 4].copy_from_slice(&32u32.to_le_bytes());
        }
    }
    let directory = tempfile::tempdir()?;
    let input = directory.path().join("lying.epub");
    let output = directory.path().join("new.azw3");
    std::fs::write(&input, bytes)?;
    let error = convert_epub(&input, &output).expect_err("lying expansion must fail");
    assert!(matches!(error.code(), "resource_limit" | "invalid_epub"));
    assert!(!output.exists());
    Ok(())
}

#[test]
fn entry_count_limit() -> TestResult {
    let mut entries = entries()?;
    for index in entries.len()..=MAX_ENTRIES {
        entries.push((format!("EPUB/{index}.png"), Vec::new()));
    }
    rejection(&archive(entries, false)?, "resource_limit")
}

#[test]
fn unsafe_paths_and_case_collisions() -> TestResult {
    for name in [
        "../outside.xhtml",
        "/outside.xhtml",
        "C:/outside.xhtml",
        "EPUB\\outside.xhtml",
        "EPUB/./outside.xhtml",
        "EPUB/%2e%2e/out.xhtml",
        "EPUB/trailing./out.xhtml",
    ] {
        let mut entries = entries()?;
        entries.push((name.into(), b"<html/>".to_vec()));
        rejection(&archive(entries, false)?, "unsafe_archive")?;
    }
    let mut entries = entries()?;
    entries.push(("EPUB/ONE.XHTML".into(), b"<html/>".to_vec()));
    rejection(&archive(entries, false)?, "unsafe_archive")
}

#[test]
fn exact_duplicate_names_are_not_hidden_by_zip_library() -> TestResult {
    let mut bytes = original_fixture()?;
    for at in 0..bytes.len().saturating_sub(8) {
        if bytes.get(at..at + 9) == Some(b"two.xhtml") {
            bytes[at..at + 9].copy_from_slice(b"one.xhtml");
        }
    }
    rejection(&bytes, "unsafe_archive")
}

#[test]
fn encryption_and_symlinks_are_rejected() -> TestResult {
    let mut bytes = original_fixture()?;
    bytes[6] |= 1;
    let central = bytes
        .windows(4)
        .position(|w| w == b"PK\x01\x02")
        .ok_or("central header missing")?;
    bytes[central + 8] |= 1;
    rejection(&bytes, "encrypted_book")?;
    let mut bytes = original_fixture()?;
    let central = bytes
        .windows(4)
        .position(|w| w == b"PK\x01\x02")
        .ok_or("central header missing")?;
    bytes[central + 38..central + 42].copy_from_slice(&(0o120777u32 << 16).to_le_bytes());
    rejection(&bytes, "unsafe_archive")
}

#[test]
fn corruption_is_rejected_before_output() -> TestResult {
    let mut bytes = original_fixture()?;
    let at = bytes
        .windows(20)
        .position(|w| w == b"application/epub+zip")
        .ok_or("mimetype missing")?;
    bytes[at] ^= 1;
    rejection(&bytes, "invalid_epub")?;
    rejection(b"not an EPUB", "invalid_epub")
}

#[test]
fn doctype_entities_drm_and_complexity_are_rejected() -> TestResult {
    for xml in [
        r#"<!DOCTYPE html [<!ENTITY private SYSTEM "file:///private">]><html>&private;</html>"#,
        r#"<!DOCTYPE html><html/>"#,
        r#"<html>&undeclared;</html>"#,
        r#"<?xml version="1.0" encoding="UTF-16"?><html/>"#,
    ] {
        rejection(&replaced_document(xml)?, "unsupported_content")?;
    }
    for name in [
        "META-INF/encryption.xml",
        "META-INF/rights.xml",
        "EPUB/license.lcpl",
    ] {
        let mut entries = entries()?;
        entries.push((name.into(), b"<encrypted/>".to_vec()));
        rejection(&archive(entries, false)?, "encrypted_book")?;
    }
    let deep = format!("{}{}", "<div>".repeat(65), "</div>".repeat(65));
    rejection(&replaced_document(&deep)?, "resource_limit")?;
    let many = format!("<html>{}</html>", "<p/>".repeat(100_001));
    rejection(&replaced_document(&many)?, "resource_limit")
}

#[test]
fn external_xml_and_css_resources_are_rejected() -> TestResult {
    for xml in [
        r#"<html><img src="https://example.test/private"/></html>"#,
        r#"<html><img SRC="//example.test/private"/></html>"#,
        r#"<html><img src="%68%74%74%70%73%3a//example.test/private"/></html>"#,
        r#"<html><img src="file:///private"/></html>"#,
        r#"<html><img src="data:image/png;base64,AA=="/></html>"#,
        r#"<html><script/></html>"#,
        r#"<html><SCRIPT/></html>"#,
        r#"<html><style>p { background: url('https://example.test/a') }</style></html>"#,
        r#"<html><style>p { background: url(\68 ttps://example.test/a) }</style></html>"#,
        r#"<html><style>@import "https://example.test/a.css";</style></html>"#,
        r#"<html><p style="background: url(&quot;https://example.test/a&quot;)"/></html>"#,
        r#"<svg><path fill="url(https://example.test/a)"/></svg>"#,
        r#"<html xml:base="https://example.test/"/>"#,
        r#"<html><body background="https://example.test/a"/></html>"#,
        r#"<svg><set attributeName="href" to="https://example.test/a"/></svg>"#,
        r#"<svg><animate attributeName="href" to="https://example.test/a"/></svg>"#,
        r#"<svg><animateMotion/></svg>"#,
        r#"<svg><animateTransform/></svg>"#,
        r#"<html><style>p { background: image-set("https://example.test/a" 1x) }</style></html>"#,
        r#"<html><style>p { background: -webkit-image-set("https://example.test/a" 1x) }</style></html>"#,
        r#"<html><a href="../../outside.xhtml"/></html>"#,
    ] {
        let expected = if xml.contains("../../") {
            "unsafe_archive"
        } else {
            "unsupported_content"
        };
        rejection(&replaced_document(xml)?, expected)?;
    }
    Ok(())
}

#[test]
fn manifest_cannot_disguise_xml_as_binary_or_spine_as_image() -> TestResult {
    let mut entries = entries()?;
    let package = &mut entries
        .iter_mut()
        .find(|(name, _)| name.ends_with("package.opf"))
        .ok_or("missing opf")?
        .1;
    let text = String::from_utf8(package.clone())?.replace("cover.svg", "cover.png");
    *package = text.into_bytes();
    entries
        .iter_mut()
        .find(|(name, _)| name.ends_with("cover.svg"))
        .ok_or("missing svg")?
        .0 = "EPUB/cover.png".into();
    // Also change the chapter reference, so the MIME mismatch is the rejection trigger.
    let chapter = &mut entries
        .iter_mut()
        .find(|(name, _)| name.ends_with("one.xhtml"))
        .ok_or("missing chapter")?
        .1;
    *chapter = String::from_utf8(chapter.clone())?
        .replace("cover.svg", "cover.png")
        .into_bytes();
    rejection(&archive(entries, false)?, "unsupported_content")?;
    let mut entries = self::entries()?;
    let package = &mut entries
        .iter_mut()
        .find(|(name, _)| name.ends_with("package.opf"))
        .ok_or("missing opf")?
        .1;
    *package = String::from_utf8(package.clone())?
        .replace("<itemref idref=\"one\"/>", "<itemref idref=\"cover\"/>")
        .into_bytes();
    rejection(&archive(entries, false)?, "unsupported_content")
}

#[test]
fn error_mapping_does_not_include_private_paths() -> TestResult {
    let directory = tempfile::tempdir()?;
    let error = convert_epub(
        &directory.path().join("private-book.epub"),
        &directory.path().join("out.azw3"),
    )
    .expect_err("missing input");
    assert_eq!(error.code(), "io_failure");
    assert_eq!(error.to_string(), "I/O failure");
    assert!(!format!("{error:?}").contains("private-book"));
    Ok(())
}
