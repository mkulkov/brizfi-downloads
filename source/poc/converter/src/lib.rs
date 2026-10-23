//! Bounded, local EPUB conversion experiment. Mobile and Kindle acceptance are separate checks.

mod fb2;
mod validation;
pub use fb2::{fb2_to_epub, original_fb2_fixture};

use std::cell::Cell;
use std::fs::File;
use std::io::{Cursor, Read, Seek, SeekFrom, Write};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::Once;

use boko::{Book, Format};
use thiserror::Error;
use zip::write::SimpleFileOptions;

pub const MAX_INPUT_BYTES: u64 = 32 * 1024 * 1024;
pub const MAX_OUTPUT_BYTES: u64 = 32 * 1024 * 1024;
pub use validation::{
    MAX_ENTRIES, MAX_ENTRY_BYTES, MAX_UNPACKED_BYTES, MAX_XML_DEPTH, MAX_XML_EVENTS,
};

#[derive(Debug, Error)]
pub enum ConversionError {
    #[error("input must be a regular file")]
    NotRegularFile,
    #[error("input exceeds experiment limit of 32 MiB")]
    TooLarge,
    #[error("input and output must differ")]
    SameFile,
    #[error("I/O failure")]
    Io,
    #[error("converter failure")]
    Converter,
    #[error("invalid EPUB archive")]
    Zip,
    #[error("unsafe archive entry")]
    UnsafeArchive,
    #[error("EPUB resource limit exceeded")]
    ResourceLimit,
    #[error("encrypted or protected book is unsupported")]
    EncryptedBook,
    #[error("unsupported EPUB content")]
    UnsupportedContent,
    #[error("converter panicked")]
    ConverterPanic,
    #[error("output already exists")]
    OutputExists,
    #[error("output exceeds 32 MiB")]
    OutputTooLarge,
    #[error("invalid FB2 document")]
    InvalidFb2,
    #[error("unsupported text encoding")]
    UnsupportedEncoding,
}

impl ConversionError {
    /// Stable, path-free error for application/FFI mapping. Never forward upstream diagnostics.
    pub fn code(&self) -> &'static str {
        match self {
            Self::NotRegularFile => "not_regular_file",
            Self::TooLarge => "input_too_large",
            Self::SameFile => "same_file",
            Self::Io => "io_failure",
            Self::Converter => "conversion_failed",
            Self::Zip => "invalid_epub",
            Self::UnsafeArchive => "unsafe_archive",
            Self::ResourceLimit => "resource_limit",
            Self::EncryptedBook => "encrypted_book",
            Self::UnsupportedContent => "unsupported_content",
            Self::ConverterPanic => "converter_panic",
            Self::OutputExists => "output_exists",
            Self::OutputTooLarge => "output_too_large",
            Self::InvalidFb2 => "invalid_fb2",
            Self::UnsupportedEncoding => "unsupported_encoding",
        }
    }
}

impl From<std::io::Error> for ConversionError {
    fn from(_: std::io::Error) -> Self {
        Self::Io
    }
}
impl From<boko::Error> for ConversionError {
    fn from(error: boko::Error) -> Self {
        match error {
            boko::Error::DrmProtected(_) => Self::EncryptedBook,
            _ => Self::Converter,
        }
    }
}
impl From<zip::result::ZipError> for ConversionError {
    fn from(_: zip::result::ZipError) -> Self {
        Self::Zip
    }
}

/// Convert a managed EPUB file; refuse existing output to avoid overwrites.
/// Validation and conversion consume the same bounded snapshot, avoiding a second path open.
/// This synchronous PoC does not preempt CPU time, allocation/OOM, aborts or cancellation.
/// The caller owns both paths and must serialize cleanup while this function runs.
pub fn convert_epub(input: &Path, output: &Path) -> Result<u64, ConversionError> {
    let bytes = read_input(input, output)?;
    convert_snapshot(&bytes, output)
}

/// Convert FB2 through a separately validated EPUB snapshot. Output/cleanup bounds
/// and cancellation limitations are identical to `convert_epub`.
pub fn convert_fb2(input: &Path, output: &Path) -> Result<u64, ConversionError> {
    let bytes = read_input(input, output)?;
    let epub = fb2_to_epub(&bytes)?;
    convert_snapshot(&epub, output)
}

/// Convert FB2 to a validated EPUB without passing through the AZW3 exporter.
/// Uses the same bounded snapshot and exclusive output ownership as AZW3 conversion.
pub fn convert_fb2_to_epub(input: &Path, output: &Path) -> Result<u64, ConversionError> {
    let bytes = read_input(input, output)?;
    let epub = catch_converter(|| fb2_to_epub(&bytes))?;
    catch_converter(|| validation::validate(&epub))?;
    write_output(output, |writer| {
        writer.write_all(&epub)?;
        Ok(())
    })
}

/// Convert a bounded, unencrypted AZW3/MOBI snapshot to EPUB (or MOBI to AZW3).
/// EPUB output is validated before it becomes a managed output file.
pub fn convert_kindle(input: &Path, output: &Path, target: &str) -> Result<u64, ConversionError> {
    if input
        .extension()
        .and_then(|s| s.to_str())
        .is_some_and(|s| s.eq_ignore_ascii_case("txt"))
    {
        if target != "epub" && target != "azw3" {
            return Err(ConversionError::UnsupportedContent);
        }
        let bytes = read_input(input, output)?;
        let text = std::str::from_utf8(&bytes)
            .map_err(|_| ConversionError::UnsupportedEncoding)?
            .trim_start_matches('\u{feff}');
        // Bound text before escaping; FB2's event/output limits also bound lines.
        if text.is_empty() || text.len() > MAX_ENTRY_BYTES as usize / 6 {
            return Err(ConversionError::ResourceLimit);
        }
        let mut paragraphs = String::new();
        for line in text.lines() {
            if line.trim().is_empty() {
                paragraphs.push_str("<empty-line/>");
            } else {
                paragraphs.push_str("<p>");
                paragraphs.push_str(&quick_xml::escape::escape(line));
                paragraphs.push_str("</p>");
            }
        }
        let fb2 = format!(
            "<FictionBook xmlns=\"http://www.gribuser.ru/xml/fictionbook/2.0\"><description><title-info><book-title>Text</book-title><lang>und</lang></title-info></description><body><section>{paragraphs}</section></body></FictionBook>"
        );
        let epub = catch_converter(|| fb2_to_epub(fb2.as_bytes()))?;
        if target == "azw3" {
            return convert_snapshot(&epub, output);
        }
        catch_converter(|| validation::validate(&epub))?;
        return write_output(output, |writer| {
            writer.write_all(&epub)?;
            Ok(())
        });
    }
    let format = match input
        .extension()
        .and_then(|s| s.to_str())
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("azw3") if target == "epub" => Format::Azw3,
        Some("mobi") if target == "epub" || target == "azw3" => Format::Mobi,
        _ => return Err(ConversionError::UnsupportedContent),
    };
    let bytes = read_input(input, output)?;
    let book = catch_converter(|| Book::from_bytes(&bytes, format).map_err(Into::into))?;
    if target == "azw3" {
        return write_output(output, |writer| {
            book.export(Format::Azw3, writer).map_err(Into::into)
        });
    }
    // Bound the in-memory export as well as the final file, since EPUB needs validation.
    let mut writer = LimitedWriter::new(Cursor::new(Vec::new()));
    catch_converter(|| {
        let result = book.export(Format::Epub, &mut writer);
        if writer.exceeded {
            return Err(ConversionError::OutputTooLarge);
        }
        result.map_err(Into::into)
    })?;
    let epub = normalize_exported_epub(&writer.inner.into_inner())?;
    catch_converter(|| validation::validate(&epub))?;
    write_output(output, |writer| {
        writer.write_all(&epub)?;
        Ok(())
    })
}

// Boko emits static HTML/NCX doctypes. Remove only these known declarations from
// its generated archive so the conservative no-DTD validator remains unchanged.
fn normalize_exported_epub(bytes: &[u8]) -> Result<Vec<u8>, ConversionError> {
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes))?;
    if archive.len() > MAX_ENTRIES {
        return Err(ConversionError::ResourceLimit);
    }
    let mut writer = zip::ZipWriter::new(LimitedWriter::new(Cursor::new(Vec::new())));
    let mut total = 0u64;
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index)?;
        let name = entry.name().to_owned();
        let mut content = Vec::new();
        (&mut entry)
            .take(MAX_ENTRY_BYTES + 1)
            .read_to_end(&mut content)?;
        total += content.len() as u64;
        if content.len() as u64 > MAX_ENTRY_BYTES || total > MAX_UNPACKED_BYTES {
            return Err(ConversionError::ResourceLimit);
        }
        if name.ends_with(".xhtml") || name.ends_with(".ncx") {
            let text =
                std::str::from_utf8(&content).map_err(|_| ConversionError::UnsupportedContent)?;
            content = text.replace("<!DOCTYPE html>", "").replace("<!DOCTYPE ncx PUBLIC \"-//NISO//DTD ncx 2005-1//EN\" \"http://www.daisy.org/z3986/2005/ncx-2005-1.dtd\">", "").into_bytes();
        }
        writer.start_file(
            name,
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored),
        )?;
        writer.write_all(&content)?;
    }
    let writer = writer.finish()?;
    if writer.exceeded {
        return Err(ConversionError::OutputTooLarge);
    }
    Ok(writer.inner.into_inner())
}

fn read_input(input: &Path, output: &Path) -> Result<Vec<u8>, ConversionError> {
    let metadata = std::fs::symlink_metadata(input)?;
    if !metadata.is_file() {
        return Err(ConversionError::NotRegularFile);
    }
    if metadata.len() > MAX_INPUT_BYTES {
        return Err(ConversionError::TooLarge);
    }
    if input == output || (output.exists() && input.canonicalize()? == output.canonicalize()?) {
        return Err(ConversionError::SameFile);
    }
    let mut bytes = Vec::new();
    File::open(input)?
        .take(MAX_INPUT_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_INPUT_BYTES {
        return Err(ConversionError::TooLarge);
    }
    Ok(bytes)
}

fn convert_snapshot(bytes: &[u8], output: &Path) -> Result<u64, ConversionError> {
    catch_converter(|| validation::validate(bytes))?;
    let book = catch_converter(|| Book::from_bytes(bytes, Format::Epub).map_err(Into::into))?;
    write_output(output, |writer| {
        book.export(Format::Azw3, writer).map_err(Into::into)
    })
}

fn write_output(
    output: &Path,
    export: impl FnOnce(&mut LimitedWriter<File>) -> Result<(), ConversionError>,
) -> Result<u64, ConversionError> {
    let writer = File::options()
        .write(true)
        .create_new(true)
        .open(output)
        .map_err(|error| {
            if error.kind() == std::io::ErrorKind::AlreadyExists {
                ConversionError::OutputExists
            } else {
                ConversionError::Io
            }
        })?;
    let mut writer = LimitedWriter::new(writer);
    let result = catch_converter(|| {
        let export = export(&mut writer);
        if writer.exceeded {
            return Err(ConversionError::OutputTooLarge);
        }
        export?;
        writer.inner.sync_all()?;
        Ok(writer.inner.metadata()?.len())
    });
    drop(writer); // Close the handle before removal, including on Windows.
    if result.is_err() {
        let _ = std::fs::remove_file(output);
    }
    result
}

fn catch_converter<T>(
    operation: impl FnOnce() -> Result<T, ConversionError>,
) -> Result<T, ConversionError> {
    // The default hook runs before catch_unwind and could print EPUB metadata/private
    // diagnostics. Suppress it only in this thread's guarded converter operation;
    // retain the previously installed hook for every other panic in the process.
    static INSTALL_HOOK: Once = Once::new();
    INSTALL_HOOK.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            if !CONVERTER_PANIC_SCOPE.get() {
                previous(info);
            }
        }));
    });
    let prior = CONVERTER_PANIC_SCOPE.replace(true);
    struct Scope(bool);
    impl Drop for Scope {
        fn drop(&mut self) {
            CONVERTER_PANIC_SCOPE.set(self.0);
        }
    }
    let _scope = Scope(prior);
    catch_unwind(AssertUnwindSafe(operation)).unwrap_or(Err(ConversionError::ConverterPanic))
}

thread_local! { static CONVERTER_PANIC_SCOPE: Cell<bool> = const { Cell::new(false) }; }

struct LimitedWriter<W> {
    inner: W,
    position: u64,
    length: u64,
    exceeded: bool,
}
impl<W> LimitedWriter<W> {
    fn new(inner: W) -> Self {
        Self {
            inner,
            position: 0,
            length: 0,
            exceeded: false,
        }
    }
    fn check(&mut self, position: u64) -> std::io::Result<()> {
        if position > MAX_OUTPUT_BYTES {
            self.exceeded = true;
            Err(std::io::Error::other("output limit exceeded"))
        } else {
            Ok(())
        }
    }
}
impl<W: Write> Write for LimitedWriter<W> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.check(self.position.saturating_add(bytes.len() as u64))?;
        let written = self.inner.write(bytes)?;
        self.position += written as u64;
        self.length = self.length.max(self.position);
        Ok(written)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}
impl<W: Seek> Seek for LimitedWriter<W> {
    fn seek(&mut self, from: SeekFrom) -> std::io::Result<u64> {
        let target = match from {
            SeekFrom::Start(position) => i128::from(position),
            SeekFrom::Current(offset) => i128::from(self.position) + i128::from(offset),
            SeekFrom::End(offset) => i128::from(self.length) + i128::from(offset),
        };
        let target =
            u64::try_from(target).map_err(|_| std::io::Error::other("invalid output seek"))?;
        self.check(target)?;
        self.position = self.inner.seek(SeekFrom::Start(target))?;
        Ok(self.position)
    }
}

/// Original CC0 fixture: two Cyrillic chapters, SVG cover/image, metadata and EPUB navigation.
/// ZIP entry order, timestamps and compression are fixed for reproducibility.
pub fn original_fixture() -> Result<Vec<u8>, ConversionError> {
    let entries = [
        ("mimetype", "application/epub+zip"),
        (
            "META-INF/container.xml",
            r#"<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#,
        ),
        (
            "EPUB/package.opf",
            r#"<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:uuid:6e00c555-c8cc-4776-b025-86cf7aa481f3</dc:identifier><dc:title>Бриз: проверочная книга</dc:title><dc:creator>BRIZFI PoC</dc:creator><dc:language>ru</dc:language><meta property="dcterms:modified">2026-10-08T00:00:00Z</meta></metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="cover" href="cover.svg" media-type="image/svg+xml" properties="cover-image"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>"#,
        ),
        (
            "EPUB/one.xhtml",
            r#"<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Первая глава</title></head><body><h1 id="first">Первая глава</h1><p>Утром над морем поднялся лёгкий бриз. Ёжик читал книгу: «Всё начинается с первой страницы».</p><img src="cover.svg" alt="Синяя волна"/></body></html>"#,
        ),
        (
            "EPUB/two.xhtml",
            r#"<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Вторая глава</title></head><body><h1 id="second">Вторая глава</h1><p>Вечером книга осталась на столе. Это оригинальный короткий текст для проверки кириллицы и переходов.</p><a href="one.xhtml#first">Вернуться к началу</a></body></html>"#,
        ),
        (
            "EPUB/nav.xhtml",
            r#"<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Содержание</title></head><body><nav epub:type="toc"><h1>Содержание</h1><ol><li><a href="one.xhtml#first">Первая глава</a></li><li><a href="two.xhtml#second">Вторая глава</a></li></ol></nav></body></html>"#,
        ),
        (
            "EPUB/cover.svg",
            r##"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="180" viewBox="0 0 120 180"><rect width="120" height="180" fill="#eef6ff"/><path d="M0 100 Q30 70 60 100 T120 100 V180 H0Z" fill="#245fa5"/></svg>"##,
        ),
    ];
    let mut archive = zip::ZipWriter::new(Cursor::new(Vec::new()));
    let options = SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Stored)
        .last_modified_time(zip::DateTime::default());
    for (name, contents) in entries {
        archive.start_file(name, options)?;
        archive.write_all(contents.as_bytes())?;
    }
    Ok(archive.finish()?.into_inner())
}

/// Exported no-pointer probe keeps the actual converter linked into the Android cdylib.
/// Returns 0 on conversion success, 1 on Result error. Not an application FFI API.
#[unsafe(no_mangle)]
pub extern "C" fn brizfi_converter_poc_probe() -> i32 {
    let result = catch_converter(|| -> Result<(), ConversionError> {
        let epub = original_fixture()?;
        validation::validate(&epub)?;
        let book = Book::from_bytes(&epub, Format::Epub)?;
        let mut output = LimitedWriter::new(Cursor::new(Vec::new()));
        book.export(Format::Azw3, &mut output)?;
        Ok(())
    });
    i32::from(result.is_err())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn partial_output_is_removed_on_error_panic_and_limit() -> Result<(), Box<dyn std::error::Error>>
    {
        let directory = tempfile::tempdir()?;
        let output = directory.path().join("partial.azw3");
        let error = write_output(&output, |writer| {
            writer.write_all(b"partial")?;
            Err(ConversionError::Converter)
        });
        assert_eq!(error.err().map(|e| e.code()), Some("conversion_failed"));
        assert!(!output.exists());
        let panic = write_output(&output, |writer| {
            writer.write_all(b"partial")?;
            panic!("untrusted diagnostic must not escape");
        });
        assert_eq!(panic.err().map(|e| e.code()), Some("converter_panic"));
        assert!(!output.exists());
        let limit = write_output(&output, |writer| {
            writer.seek(SeekFrom::Start(MAX_OUTPUT_BYTES))?;
            writer.write_all(b"x")?;
            Ok(())
        });
        assert_eq!(limit.err().map(|e| e.code()), Some("output_too_large"));
        assert!(!output.exists());
        std::fs::write(&output, b"existing owned elsewhere")?;
        assert_eq!(
            write_output(&output, |_| Ok(())).err().map(|e| e.code()),
            Some("output_exists")
        );
        assert_eq!(std::fs::read(&output)?, b"existing owned elsewhere");
        Ok(())
    }

    #[test]
    fn limited_writer_bounds_sparse_and_backward_seeks() -> Result<(), Box<dyn std::error::Error>> {
        let mut writer = LimitedWriter::new(Cursor::new(Vec::new()));
        writer.write_all(b"abc")?;
        writer.seek(SeekFrom::End(-1))?;
        writer.write_all(b"z")?;
        assert_eq!(writer.inner.get_ref(), b"abz");
        assert!(writer.seek(SeekFrom::Start(MAX_OUTPUT_BYTES + 1)).is_err());
        assert!(writer.exceeded);
        assert!(writer.seek(SeekFrom::Start(0)).is_ok());
        assert!(writer.seek(SeekFrom::Current(-1)).is_err());
        Ok(())
    }

    #[test]
    fn cyrillic_fixture_converts_and_reopens() -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let input = directory.path().join("original.epub");
        let output = directory.path().join("original.azw3");
        let fixture = original_fixture()?;
        assert_eq!(fixture, original_fixture()?);
        std::fs::write(&input, fixture)?;
        assert!(convert_epub(&input, &output)? > 0);
        let book = Book::open_format(&output, Format::Azw3)?;
        assert_eq!(book.metadata().title, "Бриз: проверочная книга");
        assert_eq!(book.spine().len(), 2);
        assert!(!book.toc().is_empty());
        assert!(convert_epub(&input, &output).is_err());
        assert!(matches!(
            convert_epub(&input, &input),
            Err(ConversionError::SameFile)
        ));
        Ok(())
    }

    #[test]
    fn oversize_and_invalid_inputs_fail() -> Result<(), Box<dyn std::error::Error>> {
        let directory = tempfile::tempdir()?;
        let input = directory.path().join("large.epub");
        File::create(&input)?.set_len(MAX_INPUT_BYTES + 1)?;
        let output = directory.path().join("out.azw3");
        assert!(matches!(
            convert_epub(&input, &output),
            Err(ConversionError::TooLarge)
        ));
        std::fs::write(&input, b"not an EPUB")?;
        assert!(convert_epub(&input, &output).is_err());
        assert!(!output.exists());
        Ok(())
    }
}
