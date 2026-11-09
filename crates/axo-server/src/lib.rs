// Platform entry points share the protocol, catalog and agent crates.
#[cfg(unix)]
include!("unix.rs");

#[cfg(windows)]
pub mod windows;
