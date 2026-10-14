use std::{env, fs, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=AXO_BUILD_NUMBER");
    println!("cargo:rerun-if-env-changed=AXO_BUILD_NUMBER_FILE");

    let build_number = match env::var("AXO_BUILD_NUMBER") {
        Ok(value) => value,
        Err(_) => {
            let path = env::var_os("AXO_BUILD_NUMBER_FILE")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    PathBuf::from(
                        env::var_os("CARGO_MANIFEST_DIR").expect("Cargo sets CARGO_MANIFEST_DIR"),
                    )
                    .join("../../BUILD_NUMBER")
                });
            println!("cargo:rerun-if-changed={}", path.display());
            fs::read_to_string(path).expect("could not read build-number file")
        }
    };
    let build_number = build_number.trim_end_matches(['\r', '\n']);
    let parsed_build_number: u64 = build_number
        .parse()
        .expect("AXO_BUILD_NUMBER must be a positive decimal integer");
    assert!(
        parsed_build_number > 0 && parsed_build_number.to_string() == build_number,
        "AXO_BUILD_NUMBER must be a canonical positive decimal integer"
    );

    println!("cargo:rustc-env=AXO_BUILD_NUMBER={parsed_build_number}");
}
