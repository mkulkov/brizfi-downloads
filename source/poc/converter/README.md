# BRIZFI Rust converter core

Local conversion core used by the Android Flutter bridge in `rust/`. Host checks,
Android runtime and physical Kindle acceptance are separate evidence; see
`docs/evidence/converter-poc.md` at the repository root.

## Dependency and formats

Boko v0.5.0 is pinned to commit `8f412fb1a507399bce320d591feb517467cdb5f7`
from https://github.com/zacharydenton/boko, with `default-features = false`.
Its license is GPL-3.0-or-later. Application licensing/distribution must be
resolved before release. This local experiment does not settle store eligibility.
Rust 1.98.1 and Cargo.lock pin the toolchain and dependencies.

Boko imports EPUB and exports AZW3. `fb2.rs` provides a separate conservative
FB2 2.0 parser and generates a validated intermediate EPUB. Supported FB2 text
encodings are UTF-8 and explicitly declared Windows-1251. Meaningful unsupported
markup is rejected rather than silently removed. Plain text, headings, basic
inline formatting, poems, local notes/links and embedded PNG/JPEG are handled;
this is not a complete FictionBook implementation.

Original fixtures are `original_fixture()` and `original_fb2_fixture()`. Their
text, metadata and artwork are authored for this project and dedicated to
CC0-1.0. No third-party books are included. Generated books are ignored by Git.

## Reproduce from repository root (PowerShell)

```powershell
cargo fmt --manifest-path poc/converter/Cargo.toml --check
cargo clippy --manifest-path poc/converter/Cargo.toml --all-targets --locked -- -D warnings
cargo test --manifest-path poc/converter/Cargo.toml --locked
New-Item -ItemType Directory -Force poc/converter/artifacts | Out-Null
cargo run --manifest-path poc/converter/Cargo.toml --locked -- fixture poc/converter/artifacts/original-cyrillic.epub
cargo run --manifest-path poc/converter/Cargo.toml --locked -- poc/converter/artifacts/original-cyrillic.epub poc/converter/artifacts/original-cyrillic.azw3
cargo run --manifest-path poc/converter/Cargo.toml --locked -- fixture-fb2 poc/converter/artifacts/original-cyrillic.fb2
cargo run --manifest-path poc/converter/Cargo.toml --locked -- fb2 poc/converter/artifacts/original-cyrillic.fb2 poc/converter/artifacts/original-fb2.azw3
```

Use new filenames on subsequent runs: existing output is never overwritten.
Conversion reads a bounded input snapshot. AZW3 output uses `create_new`; an owned
partial is removed best effort on failure. Neither source books nor preexisting
output files are deleted. Structured errors omit paths and upstream diagnostics.

## Bounds and limitations

Input and output: 32 MiB each. EPUB: at most 2048 ZIP entries, 8 MiB per entry,
64 MiB actual unpacked data. XML depth 64, attributes 64 per element, total event
budget 100000. EPUB ZIP paths, duplicates, encryption, special files, CRC,
XML/CSS, remote/active content and OPF spine are checked. FB2 rejects DTD,
external entities/resources and unsupported encoding/content. Intermediate EPUB
passes the same EPUB validation before Boko.

These are conservative input/output guards, not a proof of safe processing of
all books. Hard CPU-time, peak allocation/OOM and global storage quotas are not
enforced. A synchronous Rust call cannot interrupt Boko mid-export. Android's
Dart service serializes work and acknowledges cancellation only after the Rust
call returns and its result is discarded.

For mobile checks use the repository's `integration_test/converter_test.dart`.
The exported `brizfi_converter_poc_probe` remains an isolated native EPUB probe;
it is not the application FFI. A host AZW3 round trip or `BOOKMOBI` signature
cannot prove correct rendering on a Kindle. Verify each new format fixture on
the physical reader. iOS builds and runtime are deferred until Android readiness
and require macOS/Xcode.
