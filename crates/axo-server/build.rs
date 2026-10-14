use std::{env, fs, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=AXO_BUILD_NUMBER");
    println!("cargo:rerun-if-env-changed=AXO_BUILD_NUMBER_FILE");

    let build_number = match env::var_os("AXO_BUILD_NUMBER_FILE") {
        Some(path) => {
            let path = PathBuf::from(path);
            println!("cargo:rerun-if-changed={}", path.display());
            fs::read_to_string(path).expect("could not read build-number file")
        }
        None => env::var("AXO_BUILD_NUMBER").unwrap_or_else(|_| "1".into()),
    };
    let build_number = build_number.trim_end_matches(['\r', '\n']);
    let parsed_build_number: u64 = build_number
        .parse()
        .expect("AXO_BUILD_NUMBER must be a positive decimal integer");
    assert!(
        parsed_build_number > 0 && parsed_build_number.to_string() == build_number,
        "AXO_BUILD_NUMBER must be a canonical positive decimal integer"
    );

    let generated = format!("pub const BUILD_NUMBER: u64 = {parsed_build_number};\n");
    let output_path =
        PathBuf::from(env::var_os("OUT_DIR").expect("Cargo sets OUT_DIR")).join("build_number.rs");
    fs::write(output_path, generated).expect("could not write generated build number");
}
