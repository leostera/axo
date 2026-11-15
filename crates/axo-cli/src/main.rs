//! A thin, same-user axod client. No daemon/runtime startup, credential reads, or cloud retries.
mod installation;
mod transport;
use axo_protocol::cli::{Effect, OPERATIONS, Operation, Parameter, Projection, ValueKind};
use axo_protocol::rpc::{self, method};
use clap::{Arg, ArgAction, ArgMatches, Command};
use serde_json::{Map, Value, json};
use std::io::{self, BufRead, IsTerminal, Read, Write};
use std::path::PathBuf;
use std::time::Duration;

const INPUT_LIMIT: u64 = 8 * 1024 * 1024;
#[derive(Debug)]
struct Failure {
    code: u8,
    message: String,
}
impl Failure {
    fn input(message: impl Into<String>) -> Self {
        Self {
            code: 2,
            message: message.into(),
        }
    }
    fn transport(message: impl Into<String>) -> Self {
        Self {
            code: 3,
            message: message.into(),
        }
    }
}
impl From<io::Error> for Failure {
    fn from(error: io::Error) -> Self {
        Self::input(error.to_string())
    }
}
fn main() -> std::process::ExitCode {
    let matches = command().get_matches();
    match run(&matches) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            if error.code != 0 {
                eprintln!("axo: {}", safe_diagnostic(&error.message));
            }
            std::process::ExitCode::from(error.code)
        }
    }
}
fn safe_diagnostic(text: &str) -> String {
    text.chars()
        .flat_map(|c| {
            if c.is_control() && c != '\n' && c != '\t' {
                c.escape_default().collect::<Vec<_>>()
            } else {
                vec![c]
            }
        })
        .collect()
}
fn parameter(p: &Parameter) -> Arg {
    let mut arg = Arg::new(p.flag)
        .help(p.help)
        .required(p.required)
        .num_args(1);
    if !p.positional {
        arg = arg.long(p.flag);
    }
    if matches!(p.kind, ValueKind::Integer) {
        arg = arg.value_parser(clap::value_parser!(u64));
    }
    arg
}
fn insert(command: Command, path: &[&'static str], leaf: Command) -> Command {
    if path.len() == 1 {
        return command.subcommand(leaf);
    }
    let group = path[0];
    if command.find_subcommand(group).is_some() {
        command.mut_subcommand(group, |existing| insert(existing, &path[1..], leaf))
    } else {
        command.subcommand(insert(
            Command::new(group)
                .subcommand_required(true)
                .arg_required_else_help(true),
            &path[1..],
            leaf,
        ))
    }
}
fn command() -> Command {
    let mut root = Command::new("axo")
        .about("Control Axo Sessions and the local daemon")
        .version(env!("CARGO_PKG_VERSION"))
        .subcommand_required(true)
        .arg_required_else_help(true)
        .arg(
            Arg::new("socket")
                .long("socket")
                .global(true)
                .value_name("PATH")
                .help("Unix socket (otherwise AXO_SOCKET or the app's default)"),
        )
        .arg(
            Arg::new("json")
                .long("json")
                .global(true)
                .action(ArgAction::SetTrue)
                .help("Machine-readable JSON; streams use NDJSON"),
        )
        .arg(
            Arg::new("yes")
                .long("yes")
                .global(true)
                .action(ArgAction::SetTrue)
                .help("Explicitly confirm disruptive local commands; never approves questions"),
        )
        .arg(
            Arg::new("timeout-ms")
                .long("timeout-ms")
                .global(true)
                .value_parser(clap::value_parser!(u64).range(1..=3_600_000))
                .help("Whole-call deadline in milliseconds"),
        );
    for op in OPERATIONS {
        let mut leaf =
            Command::new(*op.path.last().expect("nonempty operation path")).about(op.about);
        for p in op.parameters {
            leaf = leaf.arg(parameter(p));
        }
        if op.path == ["session", "create"] {
            leaf = leaf.group(
                clap::ArgGroup::new("location")
                    .args(["folder", "like"])
                    .multiple(false),
            );
        }
        if op.path == ["session", "prompt"] {
            leaf = leaf.group(
                clap::ArgGroup::new("message-source")
                    .args(["message", "message-file"])
                    .required(true),
            );
        }
        root = insert(root, op.path, leaf);
    }
    root = insert(
        root,
        &["daemon", "restart"],
        Command::new("restart")
            .about("Restart the registered macOS LaunchAgent; terminals restart"),
    );
    root = insert(
        root,
        &["session", "watch"],
        Command::new("watch")
            .about("Stream Session events as NDJSON; closes on lag")
            .arg(
                Arg::new("sid")
                    .long("sid")
                    .help("Optional Session UUID, or self"),
            )
            .arg(
                Arg::new("terminal-output")
                    .long("terminal-output")
                    .action(ArgAction::SetTrue),
            ),
    );
    root =
        root.subcommand(Command::new("capabilities").about(
            "Read the compiled command catalog and deliberate exclusions; no daemon contacted",
        ));
    root = insert(
        root,
        &["rpc", "methods"],
        Command::new("methods").about("Read the running daemon's negotiated method names"),
    );
    root = insert(
        root,
        &["rpc", "call"],
        Command::new("call")
            .about("Call an advertised local method; server caller checks still apply")
            .arg(Arg::new("method").required(true))
            .arg(
                Arg::new("params")
                    .long("params")
                    .conflicts_with("params-file")
                    .help("Parameters as a JSON object"),
            )
            .arg(
                Arg::new("params-file")
                    .long("params-file")
                    .help("Parameters JSON file, or - for stdin"),
            ),
    );
    root = insert(
        root,
        &["cli", "install"],
        Command::new("install")
            .about("Link this executable into a bin directory; never overwrite a file")
            .arg(
                Arg::new("dir")
                    .long("dir")
                    .help("Bin directory; defaults to ~/.local/bin")
                    .conflicts_with("system"),
            )
            .arg(
                Arg::new("system")
                    .long("system")
                    .action(ArgAction::SetTrue)
                    .help("Install in /usr/local/bin; macOS asks for administrator approval only if needed"),
            ),
    );
    root
}
fn selection(matches: &ArgMatches) -> (Vec<&str>, &ArgMatches) {
    let mut path = Vec::new();
    let mut leaf = matches;
    while let Some((name, child)) = leaf.subcommand() {
        path.push(name);
        leaf = child;
    }
    (path, leaf)
}
fn home() -> Result<PathBuf, Failure> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute());
    home.ok_or_else(|| {
        Failure::input("HOME must be an absolute directory; otherwise pass --socket")
    })
}
fn default_socket() -> Result<PathBuf, Failure> {
    Ok(home()?.join("Library/Application Support/Axo/run/axod.sock"))
}
fn socket(matches: &ArgMatches) -> Result<PathBuf, Failure> {
    let path = matches
        .get_one::<String>("socket")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("AXO_SOCKET").map(PathBuf::from));
    let path = match path {
        Some(path) => path,
        None => default_socket()?,
    };
    if !path.is_absolute() {
        return Err(Failure::input("--socket/AXO_SOCKET must be absolute"));
    }
    Ok(path)
}
fn sid(text: &str) -> Result<String, Failure> {
    let text = if text == "self" {
        std::env::var("AXO_SESSION_ID").map_err(|_| {
            Failure::input("self requires AXO_SESSION_ID; pass --sid <uuid> outside Axo")
        })?
    } else {
        text.to_owned()
    };
    axo_protocol::SessionId::parse(&text)
        .map(|id| id.to_string())
        .ok_or_else(|| Failure::input("Session ID must be a UUID"))
}
fn read_input(path: &str) -> Result<String, Failure> {
    let input: Box<dyn Read> = if path == "-" {
        Box::new(io::stdin())
    } else {
        Box::new(std::fs::File::open(path)?)
    };
    let mut bytes = Vec::new();
    input.take(INPUT_LIMIT + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > INPUT_LIMIT {
        return Err(Failure::input("input exceeds 8 MiB; nothing was sent"));
    }
    String::from_utf8(bytes).map_err(|_| Failure::input("input must be UTF-8; nothing was sent"))
}
fn parse_json(text: &str) -> Result<Value, Failure> {
    serde_json::from_str(text).map_err(|e| {
        Failure::input(format!(
            "invalid JSON at line {}, column {}",
            e.line(),
            e.column()
        ))
    })
}
struct Prepared {
    params: Value,
    target: Option<String>,
}
fn prepare(op: &Operation, matches: &ArgMatches) -> Result<Prepared, Failure> {
    let mut params = Map::new();
    for p in op.parameters {
        let value = if matches!(p.kind, ValueKind::Integer) {
            matches.get_one::<u64>(p.flag).map(|n| json!(n))
        } else {
            match matches.get_one::<String>(p.flag) {
                None => None,
                Some(text) => Some(match p.kind {
                    ValueKind::Session => json!(sid(text)?),
                    ValueKind::Json => parse_json(text)?,
                    ValueKind::File => json!(read_input(text)?),
                    ValueKind::JsonFile => parse_json(&read_input(text)?)?,
                    _ => json!(text),
                }),
            }
        };
        if let Some(value) = value {
            params.insert(p.wire.to_owned(), value);
        }
    }
    if let Some(folder) = params.get("folder").and_then(Value::as_str) {
        let absolute = std::fs::canonicalize(folder)
            .map_err(|_| Failure::input("--folder must name an existing directory"))?;
        params.insert("folder".into(), json!(absolute));
    }
    if op.method == method::SESSION_PROMPT {
        if let Ok(sender) = std::env::var("AXO_SESSION_ID") {
            params.insert("fromSessionId".into(), json!(sid(&sender)?));
        }
        if params
            .get("text")
            .and_then(Value::as_str)
            .is_none_or(|text| text.trim().is_empty())
        {
            return Err(Failure::input(
                "message must not be blank; nothing was sent",
            ));
        }
    }
    let target = if op.projection == Projection::SelfSession {
        Some(sid("self")?)
    } else if matches!(
        op.projection,
        Projection::Session | Projection::Shells | Projection::Layout
    ) {
        params
            .remove("sessionId")
            .and_then(|v| v.as_str().map(str::to_owned))
    } else {
        None
    };
    let params = op
        .request
        .parse(Value::Object(params))
        .map_err(|e| Failure::input(format!("invalid parameters: {e}; nothing was sent")))?;
    Ok(Prepared { params, target })
}
fn confirm(matches: &ArgMatches, about: &str) -> Result<(), Failure> {
    if matches.get_flag("yes") {
        return Ok(());
    }
    if !io::stdin().is_terminal() {
        return Err(Failure::input(format!(
            "{about}. Pass --yes to confirm; nothing was sent"
        )));
    }
    eprint!("{about}. Continue? [y/N] ");
    io::stderr().flush()?;
    let mut answer = String::new();
    io::BufReader::new(io::stdin().take(256)).read_line(&mut answer)?;
    if answer.trim().eq_ignore_ascii_case("y") || answer.trim().eq_ignore_ascii_case("yes") {
        Ok(())
    } else {
        Err(Failure::input("cancelled; nothing was sent"))
    }
}
fn project(op: &Operation, result: Value, target: Option<&str>) -> Result<Value, Failure> {
    if op.method == method::SESSION_CATALOG {
        serde_json::from_value::<rpc::SessionCatalog>(result.clone())
            .map_err(|_| Failure::transport("daemon returned an invalid Session catalog"))?;
    }
    if op.method == method::PEER_SESSIONS_LIST {
        serde_json::from_value::<rpc::PeerSessionList>(result.clone())
            .map_err(|_| Failure::transport("daemon returned an invalid peer catalog"))?;
    }
    match op.projection {
        Projection::Identity => Ok(result),
        Projection::Sessions => result
            .get("sessions")
            .cloned()
            .ok_or_else(|| Failure::transport("daemon returned no Session catalog")),
        Projection::Hosts => Ok(json!({"connected":result["connected"],"hosts":result["hosts"]})),
        Projection::Session | Projection::SelfSession | Projection::Shells | Projection::Layout => {
            let row = result["sessions"]
                .as_array()
                .into_iter()
                .flatten()
                .chain(result["archived"].as_array().into_iter().flatten())
                .find(|row| row["id"].as_str() == target)
                .ok_or_else(|| Failure {
                    code: 4,
                    message: "Session not found; no other Session was selected".into(),
                })?;
            Ok(match op.projection {
                Projection::Shells => row["shells"].clone(),
                Projection::Layout => row["layout"].clone(),
                _ => row.clone(),
            })
        }
    }
}
fn session_table(value: &Value) -> Result<(), Failure> {
    let rows: Vec<axo_protocol::SessionRecord> = serde_json::from_value(value.clone())
        .map_err(|_| Failure::transport("daemon returned an invalid Session list"))?;
    let clean = |text: &str| {
        text.chars()
            .take(60)
            .flat_map(|c| {
                if c.is_control() {
                    c.escape_default().collect::<Vec<_>>()
                } else {
                    vec![c]
                }
            })
            .collect::<String>()
    };
    let mut out = io::stdout().lock();
    let written = (|| -> io::Result<()> {
        writeln!(
            out,
            "{:36}  {:14}  {:32}  FOLDER",
            "SESSION", "STATUS", "NAME"
        )?;
        for row in rows {
            let status = serde_json::to_value(row.status).expect("status serializes");
            writeln!(
                out,
                "{}  {:14}  {:32}  {}",
                row.id,
                status.as_str().unwrap_or("?"),
                clean(row.manual_name.as_deref().unwrap_or(&row.name)),
                clean(&row.folder.to_string_lossy())
            )?;
        }
        Ok(())
    })();
    match written {
        Err(e) if e.kind() == io::ErrorKind::BrokenPipe => Err(Failure {
            code: 0,
            message: String::new(),
        }),
        Err(e) => Err(e.into()),
        Ok(()) => Ok(()),
    }
}
fn output(value: &Value, json_output: bool) -> Result<(), Failure> {
    let mut out = io::stdout().lock();
    let written = if json_output || !io::stdout().is_terminal() {
        serde_json::to_writer(&mut out, value)
    } else {
        serde_json::to_writer_pretty(&mut out, value)
    };
    if let Err(error) = written {
        if error.io_error_kind() == Some(io::ErrorKind::BrokenPipe) {
            return Err(Failure {
                code: 0,
                message: String::new(),
            });
        }
        return Err(Failure::transport(format!("cannot write output: {error}")));
    }
    match writeln!(out) {
        Err(e) if e.kind() == io::ErrorKind::BrokenPipe => Err(Failure {
            code: 0,
            message: String::new(),
        }),
        Err(e) => Err(e.into()),
        Ok(()) => Ok(()),
    }
}
fn run(matches: &ArgMatches) -> Result<(), Failure> {
    let (path, leaf) = selection(matches);
    if path == ["capabilities"] {
        return output(
            &json!({"catalogVersion":1,"scope":"compiled local CLI projections, not runtime authorization","commands":OPERATIONS,"excluded":axo_protocol::cli::EXCLUDED,
            "adapters":["daemon restart","session watch","rpc methods","rpc call","cli install"],
            "notImplemented":["local session stop/model/commands/continue","native AI CLI","direct computer CLI","interactive terminal attach","app upgrade CLI"]}),
            true,
        );
    }
    if path == ["cli", "install"] {
        return installation::install(leaf);
    }
    let socket = socket(matches)?;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| Failure::transport(e.to_string()))?;
    if path == ["daemon", "restart"] {
        if socket != default_socket()? {
            return Err(Failure::input(
                "daemon restart cannot target a custom socket; nothing was restarted",
            ));
        }
        confirm(
            matches,
            "Restart registered axod: terminal processes restart; Pi conversations recover",
        )?;
        let timeout = Duration::from_millis(
            matches
                .get_one::<u64>("timeout-ms")
                .copied()
                .unwrap_or(30_000),
        );
        return runtime.block_on(bounded(timeout, restart(matches)));
    }
    if path == ["session", "watch"] {
        let session = leaf
            .get_one::<String>("sid")
            .map(|text| sid(text))
            .transpose()?;
        return runtime.block_on(transport::watch(
            &socket,
            json!({"sessionId":session,"includeTerminalOutput":leaf.get_flag("terminal-output")}),
            matches
                .get_one::<u64>("timeout-ms")
                .copied()
                .map(Duration::from_millis),
        ));
    }
    if path == ["rpc", "methods"] {
        let timeout = Duration::from_millis(
            matches
                .get_one::<u64>("timeout-ms")
                .copied()
                .unwrap_or(60_000),
        );
        return runtime.block_on(bounded(timeout, async {
            let mut client = transport::Client::connect(&socket).await?;
            let value = client.negotiate().await?;
            output(&value, matches.get_flag("json"))
        }));
    }
    let (name, params, op, target) = if path == ["rpc", "call"] {
        let params = if let Some(file) = leaf.get_one::<String>("params-file") {
            parse_json(&read_input(file)?)?
        } else {
            parse_json(
                leaf.get_one::<String>("params")
                    .map(String::as_str)
                    .unwrap_or("{}"),
            )?
        };
        if !params.is_object() {
            return Err(Failure::input("--params must be a JSON object"));
        }
        confirm(
            matches,
            "Raw RPC may change state; all server-side caller checks still apply",
        )?;
        (
            leaf.get_one::<String>("method").expect("required").as_str(),
            params,
            None,
            None,
        )
    } else {
        let op = OPERATIONS
            .iter()
            .find(|op| op.path == path)
            .expect("command generated from catalog");
        let prepared = prepare(op, leaf)?;
        if matches!(op.effect, Effect::Disruptive) {
            confirm(matches, op.about)?;
        }
        (op.method, prepared.params, Some(op), prepared.target)
    };
    let timeout = matches
        .get_one::<u64>("timeout-ms")
        .copied()
        .map(Duration::from_millis)
        .or_else(|| rpc::forwarded::client_timeout(name))
        .or_else(|| {
            (name == method::ELICITATION_REQUEST)
                .then(|| Duration::from_millis(axo_protocol::elicitation::TIMEOUT_MS + 5_000))
        })
        .unwrap_or(Duration::from_secs(60));
    let value = runtime.block_on(bounded(timeout, async {
        let mut client = transport::Client::connect(&socket).await?;
        client.negotiate().await?;
        client.call(name, params).await
    }))?;
    let value = if let Some(op) = op {
        project(op, value, target.as_deref())?
    } else {
        value
    };
    if op.is_some_and(|op| op.projection == Projection::Sessions)
        && io::stdout().is_terminal()
        && !matches.get_flag("json")
    {
        session_table(&value)
    } else {
        output(&value, matches.get_flag("json"))
    }
}
async fn bounded<T>(
    timeout: Duration,
    work: impl std::future::Future<Output = Result<T, Failure>>,
) -> Result<T, Failure> {
    tokio::select! {
        result = tokio::time::timeout(timeout, work) => result.map_err(|_| Failure::transport("deadline exceeded; dispatched actions may have run. Do not blindly retry"))?,
        _ = tokio::signal::ctrl_c() => Err(Failure { code:130, message:"interrupted; dispatched actions may have run".into() }),
    }
}
async fn restart(matches: &ArgMatches) -> Result<(), Failure> {
    if !cfg!(target_os = "macos") {
        return Err(Failure::input(
            "daemon restart currently supports the macOS LaunchAgent only",
        ));
    }
    let uid = tokio::process::Command::new("/usr/bin/id")
        .arg("-u")
        .output()
        .await?;
    if !uid.status.success() {
        return Err(Failure::transport("cannot determine current user"));
    }
    let uid = String::from_utf8(uid.stdout)
        .map_err(|_| Failure::transport("cannot determine current user"))?;
    let uid = uid.trim();
    if uid.is_empty() || !uid.bytes().all(|c| c.is_ascii_digit()) {
        return Err(Failure::transport("cannot determine current user"));
    }
    let status = tokio::process::Command::new("/bin/launchctl")
        .args([
            "kickstart",
            "-k",
            &format!("gui/{uid}/dev.leostera.axo.axod"),
        ])
        .kill_on_drop(true)
        .status()
        .await?;
    if !status.success() {
        return Err(Failure::transport(
            "launchd could not restart the registered daemon; open Axo and enable it in Settings",
        ));
    }
    let timeout = Duration::from_millis(
        matches
            .get_one::<u64>("timeout-ms")
            .copied()
            .unwrap_or(30_000),
    );
    let socket = default_socket()?;
    tokio::time::timeout(timeout, async {
        loop {
            let probe = async {
                let mut client = transport::Client::connect(&socket).await?;
                client.negotiate().await?;
                client.call(method::DAEMON_HEALTH, json!({})).await
            };
            if let Ok(Ok(health)) = tokio::time::timeout(Duration::from_millis(500), probe).await {
                if health["ready"] == true {
                    return output(&health, matches.get_flag("json"));
                }
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    })
    .await
    .map_err(|_| {
        Failure::transport("restart requested, but daemon readiness timed out; inspect axod logs")
    })?
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn command_tree_is_valid_and_all_projections_have_help() {
        command().debug_assert();
        for op in OPERATIONS {
            assert!(!op.about.is_empty());
        }
    }
    #[test]
    fn every_generated_operation_parses_its_flags_into_its_wire_type() {
        let root = std::env::temp_dir().join(format!(
            "axo-cli-flags-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&root).unwrap();
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(root.clone());
        let source = root.join("input.js");
        let object = root.join("input.json");
        std::fs::write(&source, "async () => 42").unwrap();
        std::fs::write(&object, r#"{"kind":"pane","shellId":1}"#).unwrap();
        for op in OPERATIONS {
            let mut args = vec!["axo".to_owned()];
            args.extend(op.path.iter().map(|p| p.to_string()));
            for p in op.parameters.iter().filter(|p| p.required) {
                if !p.positional {
                    args.push(format!("--{}", p.flag));
                }
                let value = match p.kind {
                    ValueKind::Session => "11111111-2222-4333-8444-555555555555".to_owned(),
                    ValueKind::Integer => "1".to_owned(),
                    ValueKind::Json => "{}".to_owned(),
                    ValueKind::JsonFile => object.to_str().unwrap().to_owned(),
                    ValueKind::File => source.to_str().unwrap().to_owned(),
                    ValueKind::Text => match p.flag {
                        "key" => "agent.command",
                        "code" => "ABCD-EFGH",
                        "data" => "eA==",
                        "url" => "https://example.test/mcp",
                        "method" => "axo.remote.session.create",
                        _ => "fixture",
                    }
                    .to_owned(),
                };
                args.push(value);
            }
            if op.method == method::SESSION_PROMPT {
                args.extend(["--message".into(), "hello".into()]);
            }
            // whoami deliberately needs a Session environment and is separately context-bound.
            if op.projection == Projection::SelfSession {
                continue;
            }
            let matches = command().try_get_matches_from(args).unwrap();
            let (_, leaf) = selection(&matches);
            assert!(prepare(op, leaf).is_ok(), "{}", op.path.join(" "));
        }
    }
    #[test]
    fn create_and_prompt_parse_exclusive_inputs_before_effects() {
        assert!(
            command()
                .try_get_matches_from([
                    "axo", "session", "create", "--folder", ".", "--like", "self"
                ])
                .is_err()
        );
        assert!(
            command()
                .try_get_matches_from(["axo", "session", "prompt", "--sid", "self"])
                .is_err()
        );
        assert!(
            command()
                .try_get_matches_from([
                    "axo",
                    "session",
                    "prompt",
                    "--sid",
                    "self",
                    "--message",
                    "x",
                    "--message-file",
                    "-"
                ])
                .is_err()
        );
        assert!(
            command()
                .try_get_matches_from(["axo", "relay", "connect"])
                .is_err()
        );
        assert!(
            command()
                .try_get_matches_from(["axo", "relay", "disconnect"])
                .is_err()
        );
    }
}
