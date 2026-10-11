use std::process::Command;
fn main() {
    println!("cargo:rerun-if-changed=../.git/HEAD");
    println!("cargo:rerun-if-changed=../.git/refs/heads/main");
    println!("cargo:rerun-if-changed=src");
    let revision = Command::new("git")
        .args(["describe", "--always", "--dirty", "--abbrev=8"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|value| value.trim().to_owned())
        .filter(|value| {
            value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
        .unwrap_or_else(|| "unknown".into());
    println!("cargo:rustc-env=AXOD_BUILD_REVISION={revision}");
    let build = Command::new("git")
        .args(["rev-list", "--count", "HEAD"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .and_then(|value| value.trim().parse::<u64>().ok())
        .unwrap_or(0);
    println!("cargo:rustc-env=AXOD_BUILD_NUMBER={build}");
}
