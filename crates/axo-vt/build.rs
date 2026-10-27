//! Cargo builds link the libghostty-vt that Bazel's `@ghostty_vt` repository built; Bazel builds
//! ignore this script and link `@ghostty_vt` directly.

use std::path::PathBuf;
use std::process::Command;
use std::{env, fs};

/// Where the pinned Ghostty build installs libghostty-vt, relative to Bazel's output base.
const BAZEL_INSTALL_DIR: &str = "external/+ghostty_vt_repository+ghostty_vt";

fn main() {
    println!("cargo:rerun-if-env-changed=AXO_GHOSTTY_VT_DIR");
    let install_dir = env::var_os("AXO_GHOSTTY_VT_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(bazel_install_dir);
    let library = install_dir.join("lib/libghostty-vt.a");
    if fs::metadata(&library).is_err() {
        panic!(
            "libghostty-vt was not found at {}. Run `bazel build @ghostty_vt` first, \
             or set AXO_GHOSTTY_VT_DIR to a directory containing lib/libghostty-vt.a.",
            library.display()
        );
    }
    println!("cargo:rerun-if-changed={}", library.display());
    // The install directory also holds libghostty-vt.dylib, which the linker would prefer; link
    // a copy of the archive from a directory where it is the only candidate.
    let out_dir = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo sets OUT_DIR"));
    fs::copy(&library, out_dir.join("libghostty-vt.a")).expect("could not copy libghostty-vt");
    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=ghostty-vt");
}

fn bazel_install_dir() -> PathBuf {
    let workspace = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("Cargo sets it"))
        .join("../..");
    let output = Command::new("bazel")
        .args(["info", "output_base"])
        .current_dir(&workspace)
        .output()
        .expect("could not run `bazel info output_base`; set AXO_GHOSTTY_VT_DIR instead");
    assert!(
        output.status.success(),
        "`bazel info output_base` failed; set AXO_GHOSTTY_VT_DIR instead"
    );
    let output_base = String::from_utf8(output.stdout).expect("Bazel prints a UTF-8 path");
    PathBuf::from(output_base.trim()).join(BAZEL_INSTALL_DIR)
}
