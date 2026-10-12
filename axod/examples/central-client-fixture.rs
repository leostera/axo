//! Disposable central RPC fixture for native client contract/transport tests.
//! No Pi policy, cloud configuration or installed-service registration is read.
use std::{io, path::PathBuf};
fn main() -> io::Result<()> {
    let mut args = std::env::args_os().skip(1);
    let root = PathBuf::from(
        args.next()
            .ok_or_else(|| io::Error::other("Owned fixture root required"))?,
    );
    if !root.is_absolute() || args.next().is_some() {
        return Err(io::Error::other("Owned absolute fixture root required"));
    }
    axod::server::serve_central(&root, None, None)
}
