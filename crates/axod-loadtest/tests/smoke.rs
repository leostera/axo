//! Runs the smoke profile against an isolated axod: every request succeeds and nothing stalls.

use std::process::Command;

#[test]
fn smoke_profile_passes() {
    let binary = std::env::var_os("AXOD_LOADTEST_BINARY")
        .or_else(|| option_env!("CARGO_BIN_EXE_axod-loadtest").map(Into::into))
        .expect("Cargo or Bazel should provide the load-test binary");
    let output = Command::new(binary)
        .args(["--profile", "smoke"])
        .output()
        .unwrap();
    let report = String::from_utf8_lossy(&output.stdout);
    let errors = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "{report}\n{errors}");
    assert!(report.contains("axo.session.list"), "{report}");
}
