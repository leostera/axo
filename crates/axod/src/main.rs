#[cfg(unix)]
include!("unix.rs");

#[cfg(windows)]
mod windows;

#[cfg(windows)]
fn main() {
    windows::main();
}
