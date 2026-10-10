use std::{io, path::PathBuf};
fn usage() -> io::Error {
    io::Error::other(
        "Usage: axod serve /absolute/private/state-directory [--relay-config /absolute/private/config.json] [--profiles-config /absolute/private/profiles.json]",
    )
}
fn main() -> io::Result<()> {
    let mut arguments = std::env::args().skip(1);
    if arguments.next().as_deref() != Some("serve") {
        return Err(usage());
    }
    let root = PathBuf::from(arguments.next().ok_or_else(usage)?);
    let mut relay = None;
    let mut profiles = None;
    while let Some(flag) = arguments.next() {
        let path = PathBuf::from(arguments.next().ok_or_else(usage)?);
        match flag.as_str() {
            "--relay-config" if relay.is_none() => relay = Some(axod::relay::Config::read(&path)?),
            "--profiles-config" if profiles.is_none() => {
                profiles = Some(axod::profiles::Profiles::read(&path)?)
            }
            _ => return Err(usage()),
        }
    }
    axod::server::serve_configured(&root, relay, profiles)
}
