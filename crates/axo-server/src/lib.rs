// Keep the current Unix server intact; Windows has a local named-pipe backend.
#[cfg(unix)]
include!("unix.rs");

#[cfg(windows)]
pub mod windows;
