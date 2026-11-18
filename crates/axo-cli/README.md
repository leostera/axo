# axo

Control Axo Sessions from a shell. `axo` is a thin local client of axod, shipped as the signed `Axo.app/Contents/Helpers/axo` helper; it never starts a second daemon or reads pairing credentials.

Request/event framing lives in [`axo-client`](../axo-client/README.md), shared with
the native Linux workbench. This crate owns command parsing, output and exit codes;
it does not maintain another transport implementation.

## Install the command

The shell installer automatically installs `/usr/local/bin/axo` after the verified app reaches its stable location. macOS requests administrator approval only if that directory is not writable. Downloading the app directly offers the same setup once on first launch; **Axo → Install “axo” Command…** and **Settings → General → Command Line** remain available as fallbacks. Normal app upgrades preserve the link and replace the CLI with the app.

For manual setup or a different bin directory:

```sh
/Applications/Axo.app/Contents/Helpers/axo cli install --system
# No administrator authorization; defaults to ~/.local/bin, which must be in PATH:
/Applications/Axo.app/Contents/Helpers/axo cli install
/Applications/Axo.app/Contents/Helpers/axo cli install --dir "$HOME/bin"
```

`--system` and `--dir` are mutually exclusive. System installation is macOS-only; any authorization runs a fixed OS filesystem script, never the bundled executable as root. Installer users can opt out with `curl -fsSL https://axo.leostera.dev/install | AXO_INSTALL_CLI=0 sh`. Failed/cancelled installation does not undo app installation or immediately trigger another first-launch prompt; retry from Settings.

Installation creates a symlink, not a copied binary or wrapper. Repeating it is harmless; different regular files, directories and even dangling links are never replaced. Conflicting links, including links to a different/moved app, must be moved aside explicitly before setup. Shell profiles are never edited. Your shell must include the chosen directory in PATH (`/usr/local/bin` is the normal macOS system-bin location). Run setup from the installed app, not a temporary downloaded/test bundle; translocated copies must be moved first.

For development:

```sh
bazel run //crates/axo-cli:axo -- --help
bazel test //crates/axo-cli:test //crates/axo-cli:e2e_test
```

## Start here

```sh
axo session list
axo session create --folder .
axo session create --like <session-id>
axo session prompt --sid <session-id> --message 'Run the tests and summarize failures'
axo session prompt --sid self --message-file - < prompt.txt
axo session show --sid <session-id> --json
axo terminal screen --sid <session-id> --shell <shell-id> --lines 200
axo session watch --sid <session-id>

axo relay status
axo relay unlink --yes
axo daemon status
axo daemon permissions       # Live OS observations; never prompts
axo daemon restart --yes
```

Only the person links this Mac to their account, in Axo under **Settings › Remote Access**: a link gives the account commands on this Mac and every Session's transcript, so axod refuses `axo relay link` from anything but Axo.app. The CLI's `relay link` reaches only a loopback relay, for local Workers and tests. A link means “keep connected whenever possible.” There are no CLI `connect` or `disconnect` states. Unlink clears the saved account and any pending redemption before deleting unused credentials and closing relay admission. It works offline, is idempotent, and survives daemon restarts. A lost CLI receipt does not abandon an admitted link/unlink operation halfway. The transport closes asynchronously; already-dispatched work may have run. This does not delete cloud transcripts, other devices or the account's historical host record, or claim remote revocation of previously copied credentials.

Daemon restart is explicit macOS LaunchAgent coordination: it restarts terminal processes and uses the registered service definition, not a new daemon binary chosen by the CLI. It refuses custom sockets and does not register/re-register services or grant Login Items approval. Open Axo to enable/repair the service when needed.

## Generated operations

`crates/axo-protocol/src/cli.rs` declares command paths, flags, wire mappings, effects and typed RPC parsers. The CLI generates its command tree/help and compiled JSON catalog from that one projection table. A test requires every advertised local method to have a projection or an explicit exclusion. Server-side validation and caller authorization remain authoritative; this is the first projection catalog, not full runtime JSON Schema discovery or the entire RFD0051 inventory implemented at once.

```sh
axo capabilities --json       # Compiled projections, exclusions and remaining gaps; works offline
axo rpc methods --json        # What the running daemon actually advertises
axo session --help
axo apps --help
axo peer --help
```

Included groups: Session list/catalog/show/whoami/create/close/reopen/rename/prompt/recover/brief/share; shells; terminal input/write/screen/resize; layouts; daemon settings; peer/host discovery and remote calls; apps list/search/run/log/add/remove; questions list/ask; relay link/status/unlink; and bounded Session event watching. Close archives a Session; reopen selects the most recently closed Session, not an arbitrary ID. Listings use the passive catalog and do not consume the app's pending resume focus.

Native AI, direct computer commands, local agent stop/model/command APIs, message-free continuation, interactive terminal attach, app upgrade, shell completion, and the full descriptor/schema registry remain follow-up work. Use existing account codemode through `apps run` where appropriate; do not impersonate the relay or bypass computer-use gates to fabricate those commands.

## Automation contracts

- `--socket PATH`, then `AXO_SOCKET`, then the platform's per-user socket: `~/.axo/server/axod.sock` on Linux, `~/Library/Application Support/Axo/run/axod.sock` on macOS. Linux installations must configure the daemon with that explicit socket; this does not change the daemon's own default. Never silently route to another host. `--sid self` requires a valid `AXO_SESSION_ID`; it is convenience context, not authenticated identity. Prompts sent inside an Axo Session retain that sender's provenance.
- Session lists are tables in a TTY. `--json` and redirected output are JSON; watches are NDJSON batches. Errors/confirmations go to stderr. A closed output pipe exits successfully and releases its watch.
- Prompts use literal `--message` or bounded UTF-8 `--message-file` (`-` for stdin); no command execution or newline injection. Creation accepts a normalized existing folder or `--like`, never both.
- Disruptive operations ask in a TTY; automation must pass `--yes`. That flag **never** authorizes answering the person's approval/input requests. The signed CLI has its own identity, not Axo.app's or axod's.
- Ordinary calls default to 60 seconds; questions and forwarded apps use their longer protocol budgets. `--timeout-ms` can override the whole call (1..3,600,000 ms). Event watches run until interrupted unless an explicit timeout is set.
- A receipt means accepted, not an assistant turn completed. No automatic retries. Timeout/Ctrl-C/connection loss can leave an uncertain dispatched outcome; check before retrying. Closing the local wait does not guarantee cancellation of cloud work.
- Exit codes: `0` success/closed output pipe, `2` input/confirmation failure, `3` transport/protocol/deadline failure, `4` RPC/resource failure, `130` interrupted. Input JSON and replies are bounded and correlated; malformed or mismatched replies are never success.
- `axo rpc call METHOD --params-file request.json --yes` is an explicit debug escape hatch, not an authorization bypass. Only advertised local methods are sent; protected methods still reject a CLI.

See [RFD0051](../../docs/rfds/RFD0051-generated-axo-cli.md) for the broader inventory and remaining design work.
