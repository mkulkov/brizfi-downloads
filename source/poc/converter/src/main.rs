use std::path::Path;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    if arguments.len() == 2 && (arguments[0] == "fixture" || arguments[0] == "fixture-fb2") {
        let bytes = if arguments[0] == "fixture-fb2" {
            brizfi_converter_poc::original_fb2_fixture()
        } else {
            brizfi_converter_poc::original_fixture()?
        };
        let mut output = std::fs::File::options()
            .write(true)
            .create_new(true)
            .open(&arguments[1])?;
        std::io::Write::write_all(&mut output, &bytes)?;
        println!("Original CC0 fixture: {} bytes", bytes.len());
        return Ok(());
    }
    if arguments.len() == 3 && arguments[0] == "fb2" {
        let bytes =
            brizfi_converter_poc::convert_fb2(Path::new(&arguments[1]), Path::new(&arguments[2]))?;
        println!("AZW3 written from FB2: {bytes} bytes; Kindle opening remains unverified");
        return Ok(());
    }
    if arguments.len() != 2 {
        return Err("usage: brizfi-convert <input.epub> <new-output.azw3> | fb2 <input.fb2> <new-output.azw3> | fixture <new-output.epub> | fixture-fb2 <new-output.fb2>".into());
    }
    let bytes =
        brizfi_converter_poc::convert_epub(Path::new(&arguments[0]), Path::new(&arguments[1]))?;
    println!("AZW3 written: {bytes} bytes; Kindle opening remains unverified");
    Ok(())
}
