use std::{io, path::PathBuf};
fn usage() -> io::Error {
    io::Error::other(
        "Usage: axod serve /absolute/private/state-directory [--relay-config /absolute/private/config.json] [--profiles-config /absolute/private/profiles.json] [--pi-config /absolute/private/pi.json] | axod serve-user [--instance-id safe-id] | axod terminal-attach /absolute/private/state-directory machine-id host-generation session-id pane-id runtime-generation",
    )
}
fn identity<T: serde::de::DeserializeOwned>(text: Option<String>) -> io::Result<T> {
    T::deserialize(
        serde::de::value::StrDeserializer::<serde::de::value::Error>::new(&text.ok_or_else(usage)?),
    )
    .map_err(|_| usage())
}
fn main() -> io::Result<()> {
    let mut arguments = std::env::args().skip(1);
    match arguments.next().as_deref() {
        Some("--version") if arguments.next().is_none() => {
            println!("{}", axod::host::VERSION);
            return Ok(());
        }
        Some("terminal-attach") => {
            let root = PathBuf::from(arguments.next().ok_or_else(usage)?);
            let machine = identity(arguments.next())?;
            let runtime = axod::model::RuntimeRef {
                host_generation: identity(arguments.next())?,
                target: axod::model::TerminalTarget {
                    session_id: identity(arguments.next())?,
                    pane_id: identity(arguments.next())?,
                },
                runtime_generation: identity(arguments.next())?,
            };
            if !root.is_absolute() || arguments.next().is_some() {
                return Err(usage());
            }
            return axod::terminal_frontend::run(&root, machine, runtime);
        }
        Some("serve-user") => {
            let instance_id = match (arguments.next(), arguments.next()) {
                (None, None) => None,
                (Some(flag), Some(value))
                    if flag == "--instance-id" && arguments.next().is_none() =>
                {
                    Some(value)
                }
                _ => return Err(usage()),
            };
            return axod::user_service::serve(instance_id.as_deref());
        }
        Some("serve") => (),
        _ => return Err(usage()),
    }
    let root = PathBuf::from(arguments.next().ok_or_else(usage)?);
    let mut relay = None;
    let mut profiles = None;
    let mut pi = None;
    while let Some(flag) = arguments.next() {
        let path = PathBuf::from(arguments.next().ok_or_else(usage)?);
        match flag.as_str() {
            "--relay-config" if relay.is_none() => relay = Some(axod::relay::Config::read(&path)?),
            "--profiles-config" if profiles.is_none() => {
                profiles = Some(axod::profiles::Profiles::read(&path)?)
            }
            "--pi-config" if pi.is_none() => pi = Some(axod::PiPolicy::read(&path)?),
            _ => return Err(usage()),
        }
    }
    axod::server::serve_with_pi(&root, relay, profiles, pi)
}
