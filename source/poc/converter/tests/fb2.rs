use std::collections::HashMap;
use std::io::{Cursor, Read};

use boko::{Book, Format};
use brizfi_converter_poc::{
    ConversionError, MAX_INPUT_BYTES, convert_fb2, convert_fb2_to_epub, fb2_to_epub,
    original_fb2_fixture,
};

type TestResult = Result<(), Box<dyn std::error::Error>>;

#[test]
fn plain_text_is_escaped_and_encoding_is_explicit() -> TestResult {
    use brizfi_converter_poc::convert_kindle;
    let dir = tempfile::tempdir()?;
    let input = dir.path().join("plain.txt");
    let output = dir.path().join("plain.epub");
    std::fs::write(&input, "\u{feff}Текст <script> & книга\nстрока")?;
    convert_kindle(&input, &output, "epub")?;
    let files = entries(&std::fs::read(&output)?)?;
    let body = text(&files, "EPUB/body0.xhtml");
    assert!(body.contains("&lt;script&gt; &amp; книга"));
    assert!(body.contains("</p><p") && body.contains(">строка</p>"));
    let azw3 = dir.path().join("plain.azw3");
    convert_kindle(&input, &azw3, "azw3")?;
    assert!(!Book::open_format(&azw3, Format::Azw3)?.spine().is_empty());
    std::fs::write(&input, [0xff])?;
    let rejected = dir.path().join("rejected.epub");
    assert_eq!(
        convert_kindle(&input, &rejected, "epub")
            .expect_err("encoding")
            .code(),
        "unsupported_encoding"
    );
    assert!(!rejected.exists());
    Ok(())
}

#[test]
fn fb2_epub_output_reopens_and_preserves_output_ownership() -> TestResult {
    let dir = tempfile::tempdir()?;
    let input = dir.path().join("original.fb2");
    let output = dir.path().join("out.epub");
    std::fs::write(&input, original_fb2_fixture())?;
    let size = convert_fb2_to_epub(&input, &output)?;
    let bytes = std::fs::read(&output)?;
    assert_eq!(size, bytes.len() as u64);
    assert_eq!(bytes, fb2_to_epub(&original_fb2_fixture())?);
    let book = Book::open_format(&output, Format::Epub)?;
    assert_eq!(book.metadata().title, "Бриз: FB2 на Android");
    assert_eq!(book.spine().len(), 2);
    assert_eq!(
        convert_fb2_to_epub(&input, &output)
            .expect_err("existing output")
            .code(),
        "output_exists"
    );
    assert_eq!(std::fs::read(&output)?, bytes);
    assert!(matches!(
        convert_fb2_to_epub(&input, &input),
        Err(ConversionError::SameFile)
    ));
    std::fs::write(&input, b"invalid FB2")?;
    let invalid_output = dir.path().join("invalid.epub");
    assert_eq!(
        convert_fb2_to_epub(&input, &invalid_output)
            .expect_err("invalid input")
            .code(),
        "invalid_fb2"
    );
    assert!(!invalid_output.exists());
    Ok(())
}

#[test]
fn azw3_converts_back_to_valid_epub_and_rejects_drm() -> TestResult {
    use brizfi_converter_poc::convert_kindle;
    let dir = tempfile::tempdir()?;
    let input = dir.path().join("source.fb2");
    let azw3 = dir.path().join("book.azw3");
    let epub = dir.path().join("book.epub");
    std::fs::write(&input, original_fb2_fixture())?;
    convert_fb2(&input, &azw3)?;
    assert!(convert_kindle(&azw3, &epub, "epub")? > 0);
    let reopened = Book::open_format(&epub, Format::Epub)?;
    assert_eq!(reopened.metadata().title, "Бриз: FB2 на Android");
    assert!(!reopened.spine().is_empty());
    assert_eq!(
        convert_kindle(&azw3, &epub, "epub")
            .expect_err("existing output")
            .code(),
        "output_exists"
    );
    // PalmDOC encryption is the big-endian u16 at record-zero + 12.
    let mut bytes = std::fs::read(&azw3)?;
    let first = u32::from_be_bytes(bytes[78..82].try_into()?) as usize;
    bytes[first + 12..first + 14].copy_from_slice(&2u16.to_be_bytes());
    std::fs::write(&azw3, bytes)?;
    let protected_output = dir.path().join("protected.epub");
    assert_eq!(
        convert_kindle(&azw3, &protected_output, "epub")
            .expect_err("DRM")
            .code(),
        "encrypted_book"
    );
    assert!(!protected_output.exists());
    Ok(())
}
fn fixture() -> String {
    String::from_utf8(original_fb2_fixture()).expect("original UTF-8 fixture")
}
fn entries(bytes: &[u8]) -> Result<HashMap<String, Vec<u8>>, Box<dyn std::error::Error>> {
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes))?;
    let mut result = HashMap::new();
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        let mut bytes = Vec::new();
        entry.read_to_end(&mut bytes)?;
        result.insert(entry.name().to_owned(), bytes);
    }
    Ok(result)
}
fn text(entries: &HashMap<String, Vec<u8>>, path: &str) -> String {
    String::from_utf8(entries[path].clone()).expect("generated UTF-8")
}
fn code(input: &str) -> &'static str {
    fb2_to_epub(input.as_bytes())
        .expect_err("must reject")
        .code()
}

#[test]
fn intermediate_reopens_metadata_navigation_spine_images_and_notes() -> TestResult {
    let epub = fb2_to_epub(&original_fb2_fixture())?;
    assert_eq!(epub, fb2_to_epub(&original_fb2_fixture())?);
    let book = Book::from_bytes(&epub, Format::Epub)?;
    assert_eq!(book.metadata().title, "Бриз: FB2 на Android");
    let changed = fb2_to_epub(fixture().replace("Эта книга", "Другая книга").as_bytes())?;
    assert_ne!(
        book.metadata().identifier,
        Book::from_bytes(&changed, Format::Epub)?
            .metadata()
            .identifier
    );
    assert_eq!(book.metadata().authors, ["BRIZFI PoC"]);
    assert_eq!(book.spine().len(), 2);
    assert_eq!(book.toc().len(), 3);
    let files = entries(&epub)?;
    let opf = text(&files, "EPUB/package.opf");
    assert!(opf.contains("<dc:creator>BRIZFI PoC</dc:creator>"));
    assert!(opf.contains("<dc:language>ru</dc:language>"));
    assert!(opf.contains("properties=\"cover-image\""));
    assert!(files["EPUB/image0.png"].starts_with(b"\x89PNG"));
    let body = text(&files, "EPUB/body0.xhtml");
    assert!(body.contains("Эта книга преобразована из FB2 на телефоне в BRIZFI"));
    assert!(body.contains("<em ") && body.contains("<strong ") && body.contains("<h2 "));
    let note_href = body
        .split("href=\"body1.xhtml#")
        .nth(1)
        .ok_or("missing note link")?
        .split('"')
        .next()
        .ok_or("missing fragment")?;
    let notes = text(&files, "EPUB/body1.xhtml");
    assert!(notes.contains(&format!("id=\"{note_href}\"")));
    assert!(notes.contains("Бриз — лёгкий прибрежный ветер"));
    assert!(notes.contains("href=\"body0.xhtml#"));
    assert!(text(&files, "EPUB/nav.xhtml").contains("Вторая глава"));
    Ok(())
}

#[test]
fn utf8_bom_cp1251_and_prefixed_namespaces() -> TestResult {
    let original = original_fb2_fixture();
    let mut bom = b"\xef\xbb\xbf".to_vec();
    bom.extend_from_slice(&original);
    assert_eq!(fb2_to_epub(&bom)?, fb2_to_epub(&original)?);
    let source = fixture().replace("encoding=\"UTF-8\"", "encoding=\"windows-1251\"");
    let (encoded, _, errors) = encoding_rs::WINDOWS_1251.encode(&source);
    assert!(!errors);
    let book = Book::from_bytes(&fb2_to_epub(&encoded)?, Format::Epub)?;
    assert_eq!(book.metadata().title, "Бриз: FB2 на Android");
    // An alternate prefix must resolve by namespace URI, not a literal `l` prefix.
    assert!(
        fb2_to_epub(
            fixture()
                .replace("xmlns:l=", "xmlns:link=")
                .replace("l:href=", "link:href=")
                .as_bytes()
        )
        .is_ok()
    );
    let prefixed = fixture().replace("xmlns=", "xmlns:f=");
    let mut reader = quick_xml::Reader::from_str(&prefixed);
    let mut writer = quick_xml::Writer::new(Vec::new());
    loop {
        let event = reader.read_event()?;
        match event {
            quick_xml::events::Event::Start(mut e) => {
                let name = format!("f:{}", String::from_utf8(e.name().as_ref().to_vec())?);
                e.set_name(name.as_bytes());
                writer.write_event(quick_xml::events::Event::Start(e))?;
            }
            quick_xml::events::Event::Empty(mut e) => {
                let name = format!("f:{}", String::from_utf8(e.name().as_ref().to_vec())?);
                e.set_name(name.as_bytes());
                writer.write_event(quick_xml::events::Event::Empty(e))?;
            }
            quick_xml::events::Event::End(e) => {
                let name = format!("f:{}", String::from_utf8(e.name().as_ref().to_vec())?);
                writer.write_event(quick_xml::events::Event::End(
                    quick_xml::events::BytesEnd::new(name),
                ))?;
            }
            quick_xml::events::Event::Eof => break,
            other => writer.write_event(other)?,
        }
    }
    assert!(fb2_to_epub(&writer.into_inner()).is_ok());
    Ok(())
}

#[test]
fn hostile_xml_root_and_encodings_reject_without_private_diagnostics() {
    let original = fixture();
    let cases = [
        (
            original.replace(
                "<FictionBook ",
                "<!DOCTYPE FictionBook [<!ENTITY x SYSTEM 'file:///private/book'>]><FictionBook ",
            ),
            "unsupported_content",
        ),
        (original.replace("FictionBook", "OtherRoot"), "invalid_fb2"),
        (
            original.replace("http://www.gribuser.ru/xml/fictionbook/2.0", "urn:foreign"),
            "invalid_fb2",
        ),
        (
            original.replace("<p>Небольшое", "<p>&unknown;Небольшое"),
            "invalid_fb2",
        ),
        (
            original.replace("encoding=\"UTF-8\"", "encoding=\"UTF-16\""),
            "unsupported_encoding",
        ),
        (format!("{original}<extra/>"), "invalid_fb2"),
        (
            original.replace("id=\"second\"", "id=\"first\""),
            "invalid_fb2",
        ),
        (original.replace("</FictionBook>", ""), "invalid_fb2"),
    ];
    for (input, expected) in cases {
        let result = fb2_to_epub(input.as_bytes()).expect_err("hostile XML rejected");
        assert_eq!(result.code(), expected);
        assert!(!result.to_string().contains("private"));
    }
    assert_eq!(
        fb2_to_epub(&[0xff, 0xfe, 0x3c, 0])
            .expect_err("UTF16")
            .code(),
        "unsupported_encoding"
    );
    assert_eq!(
        fb2_to_epub(&[0xff]).expect_err("bad UTF8").code(),
        "invalid_fb2"
    );
}

#[test]
fn external_active_unknown_and_missing_references_are_rejected() {
    let original = fixture();
    for target in [
        "https://example.org/book",
        "file:///private/book",
        "../file.png",
        "javascript:alert(1)",
        "data:image/png,x",
    ] {
        assert_eq!(
            code(&original.replace("#cover", target)),
            "unsupported_content"
        );
    }
    for markup in [
        "<table><tr><td>meaningful text</td></tr></table>",
        "<script>alert(1)</script>",
        "<stylesheet type=\"text/css\">p{color:red}</stylesheet>",
        "<unknown>meaningful text</unknown>",
    ] {
        assert_eq!(
            code(&original.replace("<p>Небольшое", &format!("{markup}<p>Небольшое"))),
            "unsupported_content"
        );
    }
    assert_eq!(code(&original.replace("#note", "#missing")), "invalid_fb2");
    assert_eq!(
        code(&original.replace("<p>Небольшое", "<p onclick=\"alert(1)\">Небольшое")),
        "unsupported_content"
    );
    assert_eq!(
        code(&original.replace(
            "content-type=\"image/png\"",
            "content-type=\"image/svg+xml\""
        )),
        "unsupported_content"
    );
    assert_eq!(
        code(&original.replace("iVBORw0KGgo", "!bad64")),
        "invalid_fb2"
    );
}

#[test]
fn inline_poems_epigraphs_and_escaped_metadata_survive() -> TestResult {
    let source = fixture().replace("Бриз: FB2 на Android","Бриз &amp; &lt;Android&gt;").replace("<strong>Книга осталась рядом.</strong>","<strong>Книга</strong><sub>2</sub><sup>3</sup><strikethrough>лишнее</strikethrough><code>текст</code>").replace("<section id=\"second\">","<section id=\"second\"><epigraph><p>Эпиграф</p><text-author>Автор</text-author></epigraph>");
    let epub = fb2_to_epub(source.as_bytes())?;
    assert_eq!(
        Book::from_bytes(&epub, Format::Epub)?.metadata().title,
        "Бриз & <Android>"
    );
    let body = text(&entries(&epub)?, "EPUB/body0.xhtml");
    for tag in ["sub", "sup", "del", "code", "blockquote"] {
        assert!(body.contains(&format!("<{tag} ")));
    }
    assert!(body.contains("Над морем ветер пел"));
    Ok(())
}

#[test]
fn input_depth_attribute_event_and_xhtml_limits() {
    assert_eq!(
        fb2_to_epub(&vec![b'x'; MAX_INPUT_BYTES as usize + 1])
            .expect_err("input cap")
            .code(),
        "input_too_large"
    );
    let original = fixture();
    let nested = format!("{}text{}", "<section>".repeat(65), "</section>".repeat(65));
    assert_eq!(
        code(&original.replace(
            "<section id=\"second\">",
            &format!("<section id=\"second\">{nested}")
        )),
        "resource_limit"
    );
    let attrs = (0..65)
        .map(|n| format!(" xmlns:x{n}=\"urn:{n}\""))
        .collect::<String>();
    assert_eq!(
        code(&original.replace("<p>Небольшое", &format!("<p{attrs}>Небольшое"))),
        "resource_limit"
    );
    let events = "<empty-line/>".repeat(100_001);
    assert_eq!(
        code(&original.replace("<p>Небольшое", &format!("{events}<p>Небольшое"))),
        "resource_limit"
    );
    let expanded = "x".repeat(8 * 1024 * 1024);
    // XHTML expansion is bounded even though the source is under the input limit.
    assert_eq!(
        code(&original.replace("<p>Небольшое", &format!("<p>{expanded}</p><p>Небольшое"))),
        "resource_limit"
    );
}

#[test]
fn binary_aggregate_and_entry_caps() {
    use base64::Engine;
    let encoded = base64::engine::general_purpose::STANDARD.encode(vec![0; 8 * 1024 * 1024 + 1]);
    let original = fixture();
    let start = original.find("<binary ").expect("fixture binary");
    let start = start + original[start..].find('>').expect("binary start") + 1;
    let end = original.find("</binary>").expect("binary end");
    let oversized = format!("{}{}{}", &original[..start], encoded, &original[end..]);
    assert_eq!(code(&oversized), "resource_limit");
    let wrap = |bodies: &str| {
        format!(
            r#"<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info><book-title>Test</book-title><lang>ru</lang></title-info></description>{bodies}</FictionBook>"#
        )
    };
    assert_eq!(
        code(&wrap(
            &"<body><section><p>x</p></section></body>".repeat(2049)
        )),
        "resource_limit"
    );
    let paragraph = ">".repeat(1_700_000);
    let body = format!("<body><section><p>{paragraph}</p></section></body>");
    // Each escaped XHTML is below 8 MiB, their aggregate is above 64 MiB.
    assert_eq!(code(&wrap(&body.repeat(10))), "resource_limit");
}

#[test]
fn fb2_full_chain_reopens_and_never_overwrites_existing_output() -> TestResult {
    let dir = tempfile::tempdir()?;
    let input = dir.path().join("original.fb2");
    let output = dir.path().join("out.azw3");
    std::fs::write(&input, original_fb2_fixture())?;
    assert!(convert_fb2(&input, &output)? > 0);
    let book = Book::open_format(&output, Format::Azw3)?;
    assert_eq!(book.metadata().title, "Бриз: FB2 на Android");
    assert!(!book.toc().is_empty());
    assert!(book.spine().len() >= 2);
    let before = std::fs::read(&output)?;
    assert_eq!(
        convert_fb2(&input, &output)
            .expect_err("existing output")
            .code(),
        "output_exists"
    );
    assert_eq!(std::fs::read(&output)?, before);
    assert!(matches!(
        convert_fb2(&input, &input),
        Err(ConversionError::SameFile)
    ));
    let other = dir.path().join("other.azw3");
    std::fs::write(&input, b"invalid private data")?;
    assert_eq!(
        convert_fb2(&input, &other)
            .expect_err("invalid input")
            .code(),
        "invalid_fb2"
    );
    assert!(!other.exists());
    std::fs::File::create(&input)?.set_len(MAX_INPUT_BYTES + 1)?;
    assert!(matches!(
        convert_fb2(&input, &other),
        Err(ConversionError::TooLarge)
    ));
    assert!(!other.exists());
    Ok(())
}
