use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

static ACTIVE: AtomicBool = AtomicBool::new(false);

pub struct ConversionResult {
    pub bytes: u64,
    pub error_code: Option<String>,
}

struct ActiveGuard;
impl Drop for ActiveGuard {
    fn drop(&mut self) {
        ACTIVE.store(false, Ordering::Release);
    }
}

/// FRB's default asynchronous Dart binding dispatches this blocking work to its pool.
/// Only managed input/output paths supplied by the application are permitted by the caller.
pub fn convert_epub(input: String, output: String) -> ConversionResult {
    convert(input, output, brizfi_converter_poc::convert_epub)
}

/// Parse bounded FB2, create an in-memory EPUB, then use the same AZW3 exporter.
pub fn convert_fb2(input: String, output: String) -> ConversionResult {
    convert(input, output, brizfi_converter_poc::convert_fb2)
}

/// Parse bounded FB2 and retain its validated EPUB output for EPUB readers.
pub fn convert_fb2_to_epub(input: String, output: String) -> ConversionResult {
    convert(input, output, brizfi_converter_poc::convert_fb2_to_epub)
}

/// Convert unencrypted AZW3/MOBI for a reader needing EPUB, or MOBI to AZW3.
pub fn convert_kindle(input: String, output: String, target_format: String) -> ConversionResult {
    convert_with(input, output, |input, output| {
        brizfi_converter_poc::convert_kindle(input, output, &target_format)
    })
}

fn convert(
    input: String,
    output: String,
    converter: fn(&Path, &Path) -> Result<u64, brizfi_converter_poc::ConversionError>,
) -> ConversionResult {
    convert_with(input, output, converter)
}

fn convert_with(
    input: String,
    output: String,
    converter: impl FnOnce(&Path, &Path) -> Result<u64, brizfi_converter_poc::ConversionError>,
) -> ConversionResult {
    if ACTIVE
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return ConversionResult {
            bytes: 0,
            error_code: Some("busy".to_owned()),
        };
    }
    let _guard = ActiveGuard;
    match converter(Path::new(&input), Path::new(&output)) {
        Ok(bytes) => ConversionResult {
            bytes,
            error_code: None,
        },
        Err(error) => ConversionResult {
            bytes: 0,
            error_code: Some(error.code().to_owned()),
        },
    }
}
