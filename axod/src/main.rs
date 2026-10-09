use std::{io, path::Path};

fn main() -> io::Result<()> {
    let arguments: Vec<String> = std::env::args().collect();
    if arguments.len() != 3 || arguments[1] != "serve" {
        return Err(io::Error::other(
            "Usage: axod serve /absolute/private/state-directory",
        ));
    }
    axod::server::serve(Path::new(&arguments[2]))
}
