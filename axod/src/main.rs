use std::{io, path::Path};

fn main() -> io::Result<()> {
    let arguments: Vec<String> = std::env::args().collect();
    if !matches!(arguments.len(), 3 | 5)
        || arguments[1] != "serve"
        || (arguments.len() == 5 && arguments[3] != "--relay-config")
    {
        return Err(io::Error::other(
            "Usage: axod serve /absolute/private/state-directory [--relay-config /absolute/private/config.json]",
        ));
    }
    let relay = if arguments.len() == 5 {
        Some(axod::relay::Config::read(Path::new(&arguments[4]))?)
    } else {
        None
    };
    axod::server::serve_with_relay(Path::new(&arguments[2]), relay)
}
