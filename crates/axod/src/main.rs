use std::path::PathBuf;

use clap::{CommandFactory, FromArgMatches, Parser};

#[derive(Parser)]
#[command(name = "axod", about = "Axo daemon command-line entrypoint")]
struct Cli {
    /// Override the default per-user Unix-domain socket path.
    #[arg(long)]
    socket: Option<PathBuf>,
}

fn main() {
    let version = format!(
        "{} (build {})",
        env!("CARGO_PKG_VERSION"),
        axo_server::BUILD_NUMBER
    );
    let matches = Cli::command().version(version).get_matches();
    let cli = Cli::from_arg_matches(&matches).expect("clap validated the arguments");

    if let Err(error) = axo_server::serve_ipc(cli.socket.as_deref()) {
        eprintln!("axod: {error}");
        std::process::exit(1);
    }
}
