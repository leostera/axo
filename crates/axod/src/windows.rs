//! Native Windows entry point. The process stays alive when its desktop client closes.
use clap::Parser;
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "axod", version, about = "Axo Windows session daemon")]
struct Cli {
    #[command(subcommand)]
    command: Option<Subcommand>,
    /// Per-user catalog directory; defaults to LOCALAPPDATA/Axo/server.
    #[arg(long)]
    server_dir: Option<PathBuf>,
    /// Local named pipe; defaults to a name scoped to the current Windows SID.
    #[arg(long)]
    pipe: Option<String>,
    /// Path to codex.exe. By default the desktop client passes its discovered CLI.
    #[arg(long, default_value = "codex")]
    codex: PathBuf,
    /// Relay origin; defaults to the standard Axo service. Plain HTTP is loopback-only.
    #[arg(long)]
    relay_url: Option<String>,
}

#[derive(clap::Subcommand)]
enum Subcommand {
    /// MCP computer tools for a Codex session; connects to the running daemon.
    Mcp {
        #[arg(long)]
        pipe: Option<String>,
        #[arg(long)]
        session: String,
    },
}

pub fn main() {
    let cli = Cli::parse();
    if let Some(Subcommand::Mcp { pipe, session }) = cli.command {
        if let Err(error) = axo_server::windows::serve_mcp(pipe, session) {
            eprintln!("axod mcp: {error}");
            std::process::exit(1);
        }
        return;
    }
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    if let Err(error) = axo_server::windows::serve(
        cli.server_dir,
        cli.pipe,
        cli.codex,
        cli.relay_url
            .or_else(|| std::env::var("AXO_RELAY_URL").ok()),
    ) {
        eprintln!("axod: {error}");
        std::process::exit(1);
    }
}
