# RFD0051 - Axo: CLI capability inventory

- Feature Name: `generated-axo-cli`
- Status: Partially implemented (Axo 0.64 first slice; broader inventory remains proposed)
- Author: leostera
- Start Date: 2026-11-14
- Updated: 2026-11-14
- Document Type: Proposal
- Related: [RFD0015](RFD0015-sessions-as-axo-clients.md), [RFD0034](RFD0034-axod-as-an-axp-server.md), [RFD0048](RFD0048-release-artifacts.md), [RFD0050](RFD0050-codemode-run-limits.md)

## Summary

Ship an `axo` client with Axo.app, exposing the same capabilities people and agents already use rather than implementing a second backend. First inventory the real surfaces, their callers and their gaps. Then give operations typed descriptors from which command parsing, help, completion and machine-readable discovery can be generated. Human-friendly names and multi-step operations still need explicit design: a list of RPC names alone is not a usable or safe CLI.

The inventory below assesses backend support at Axo 0.63, commit `502a1e2917942e54fc9aae9c9912b29e0f321bad`; it is not a claim that the entire candidate tree is implemented. Axo 0.64 implements the first slice described here. No running personal daemon, service registration, permission or Session was changed for development or testing.

## Implemented first slice (0.64)

- `crates/axo-cli` is a thin Unix-socket client, bundled and separately signed as `Contents/Helpers/axo`. `cli install` creates a non-overwriting symlink in a chosen bin directory; no shell profile edits.
- `crates/axo-protocol/src/cli.rs` declares supported command projections, flags, effects and typed RPC request parsers. Clap parsing/help and the compiled `capabilities --json` catalog are generated from it. Every advertised local method must have a projection or explicit exclusion. This is not yet a complete runtime schema/owner/caller descriptor registry.
- Supported command groups cover Session/catalog/provenance-safe prompts and recovery, shells, terminal reads/writes/input/resize, layouts, settings, peers/hosts, account apps/codemode and agent questions. Adapters provide event watching, explicit raw RPC, and guarded macOS registered-service restart. See the [crate README](../../crates/axo-cli/README.md) and generated help for exact flags.
- **User decision:** linked means keep trying to connect. The public relay commands are `link <code>`, `status`, `unlink`. There is no CLI connect/disconnect state. The existing connect RPC remains for current app retry compatibility, not as a new user lifecycle axis.
- New `axo.relay.unlink` clears the durable account and pending redemption before requesting connection reconciliation and deleting unused credentials. Link mutations share one owned coordinator slot and finish even if the requesting CLI disconnects; a cancelled receipt is an uncertain outcome, not rollback. Link/status/unlink expose no credential material.
- Relay status adds `linked` and nullable `accountId` alongside the existing connection fields. Unlink closes old socket/queued-command admission; in-progress work may already have run. Physical socket closure and job retirement finish asynchronously. Local unlink does not delete account history or claim revocation of copied cloud credentials.
- Limits, correlated/bounded replies, no automatic write retries, safe stderr, JSON/NDJSON, Ctrl-C and closed-pipe cleanup are tested. Disruptive commands require confirmation; `--yes` cannot answer a human approval or impersonate Axo.app.
- `specs/relay/link-lifecycle.ts` models the successful durable-unlink path, lost receipts and orphaned unused secrets. It does not model network faults/crashes or rollback of external work; wire tests cover live socket closure, offline/pending cleanup and restart persistence.
- Remaining inventory items include direct native AI/computer CLI, local stop/model/command parity, message-free continuation, interactive terminal attachment, completions, app upgrade and full schema discovery. They are not stubbed successful commands.

## Motivation

People should be able to list and drive Sessions, pair a machine, inspect a terminal or restart their daemon from a shell:

```sh
axo session list
axo session create --folder .
axo session prompt --sid <session-id> --message "Run the tests and summarize failures"
axo daemon restart
axo relay link ABCD-1234
```

Agents should get predictable JSON, real errors, explicit targets and the same safety boundaries as other clients. Contributors should add a capability once, not separately maintain the daemon API, CLI flags, schemas, help and shell completions.

## Current surfaces

The source has several catalogs, not one complete discovery API:

| Surface | Current inventory | Important distinction |
|---|---|---|
| Local protocol negotiation | 43 advertised methods; negotiation itself is a 44th ordinary local method | Four advertised methods require a particular signed caller; one has caller-dependent modes. Advertising is not authorization. |
| Remote Session/terminal extension | 15 `axo.remote.*` methods | Registered beside local handlers, but accept only the relay's caller and validate host ID/generation. A CLI cannot call them directly over the local socket. |
| Connection upgrades | `axo.session.events.stream`, `axo.mcp.open` | First request changes ownership of a dedicated connection; not ordinary request/response calls. |
| PTY attachment | Separate Unix socket | Replay, live terminal bytes and file-descriptor passing; not JSON-RPC. |
| Relay jobs/status | AI, bash, computer, computer status, sign-in, cancellation | Separately dispatched by the authenticated relay, not ordinary local RPCs. |
| Session MCP server | 18 tool entrypoints | Session-scoped adapters, including two computer-tool entrypoints and runtime account discovery. |
| Computer tools | 24 allowlisted driver tools plus `request_input` on macOS | Available through the gated MCP/relay routes; never expose the raw driver as an unguarded CLI shortcut. |
| Native inference | 7 operations, 4 run tasks | Native service exists; today the public route is account codemode through `axo.apps.ai`, not a general local AI RPC. |
| App/OS lifecycle | LaunchAgent registration/restart, app upgrade, permission settings | Not daemon methods and cannot be generated by splitting an RPC name on dots. |

Sources: [local names/types](../../crates/axo-protocol/src/rpc.rs), [local handlers](../../crates/axo-server/src/handlers.rs), [remote handlers](../../crates/axo-server/src/remote.rs), [assembly/upgrades](../../crates/axo-server/src/lib.rs), [extension ownership](../../crates/axo-ipc/src/extension.rs), [relay dispatch](../../crates/axo-relay/src/relay/session.rs), [MCP](../../crates/axo-mcp/src/lib.rs), [computer allowlist](../../crates/axo-computer/src/lib.rs), [inference requests](../../crates/axod-infer/src/api.rs).

### How to read the command inventory

Every spelling is a **candidate CLI**, not a claim that the command already exists.

- **L** — ordinary local RPC already exists; a thin CLI adapter is feasible.
- **R** — capability exists through a relay/peer path, but a corresponding ordinary local RPC is absent where noted.
- **M** — existing Session MCP path, not an ordinary local RPC.
- **A** — app/OS/library operation exists; CLI orchestration or app integration is still needed.
- **D** — derived convenience over existing capabilities, not a backend method.
- **G** — actual capability/API gap; do not generate a pretend working command.
- **Internal** — transport machinery or a privileged operation, not automatically a public command.

## Capability inventory

### Daemon, protocol and diagnostics

Sources: [daemon entrypoint](../../crates/axod/src/main.rs), [daemon health](../../crates/axo-server/src/lib.rs), [service controller](../../apple/AxoDaemonManager/Sources/AxoDaemonManager/DaemonController.swift), [LaunchAgent](../../apple/AxoMac/Resources/dev.leostera.axo.axod.plist).

| Candidate command | Backend today | Contract / missing CLI work |
|---|---|---|
| `axo version` | A: bundle/release metadata; `axo.daemon.health` for running daemon | Show CLI, installed app and running daemon separately. They may differ. |
| `axo daemon status` | L: `axo.daemon.health`; A: launchd job state | Report running/readiness/version/build; distinguish disabled, unregistered and unreachable. |
| `axo daemon wait` | D: health plus startup/event readiness | Bounded wait; never restart a merely slow daemon automatically. |
| `axo daemon start` | A: registered LaunchAgent can be started | Not an RPC. Registration/approval may require the app. Do not spawn a competing unmanaged daemon. |
| `axo daemon restart` | A: `DaemonController.restartDaemon`, launchctl kickstart with existing recovery logic | Explicit disruptive operation: shells restart; Pi recovery follows existing daemon behavior. Wait for readiness/build afterward. |
| `axo daemon enable` | A: `SMAppService` registration from Axo.app | App-owned registration and Login Items approval need a deliberate CLI integration. |
| `axo daemon disable` | A/G: service-manager operation, no public local RPC | Decide app/service ownership; do not edit a database to simulate it. |
| `axo daemon stop` | A/G: lifecycle operation | A SIGTERM alone is not a durable stop: the LaunchAgent has `KeepAlive`. Define stop versus disable first. |
| `axo daemon logs` | A: daemon stdout/stderr logs | File read/follow must work while daemon is down. Redact diagnostics; no transcript or credential dumps. |
| `axo doctor` | D: health, service state, sockets, relay state and permission probes | A read-only report, not silent repair or a destructive reset. |
| `axo rpc methods` | L: `axo.protocol.negotiate` | Current result is names only; include caller and transport metadata before claiming completeness. |
| `axo rpc call <method> --params @-` | L: generic local transport | Debug escape hatch, still subject to exactly the same server-side caller checks. |
| `axo rpc schema <method>` | G: complete discoverable descriptors absent | A generator/discovery deliverable, not something negotiation provides today. |

The existing `axod` executable is a daemon launcher with socket/server-dir/credential-store/relay flags and an `mcp` subcommand. It is **not** the proposed user CLI. A terminal-attach transport exists in the libraries, but the current `axod` command enum does not expose an attach command. Historical design docs are not evidence of a shipped subcommand.

### Pairing, account link and connectivity

Sources: [relay methods](../../crates/axo-server/src/lib.rs), [pairing client](../../crates/axo-relay/src/pairing.rs), [pairing schema](../../schemas/axo.leostera.dev/v1/pairing.schema.json).

| Candidate command | Backend today | Contract / missing CLI work |
|---|---|---|
| `axo relay link <code>` | L: `axo.relay.link {code}` | Redeem an already-issued pairing code, store the host link through the existing credential path, request connection. No tokens in output/logs. |
| `axo relay status` | L: `axo.relay.status` | State, connected time, host label/kind and last error. |
| Internal app retry | L: `axo.relay.connect` | Existing wire compatibility only; no CLI connect/disconnect. Linked hosts reconnect automatically. |
| `axo relay pairing-code create` | R/G: account-side pairing creation exists, not local RPC | Requires a signed-in account route. Do not confuse creating a code with redeeming one. |
| `axo account status` | D: relay link/status, account app discovery | Need a defined non-secret account identity view; never print stored host credentials. |
| `axo account login` | A/R: existing browser/app sign-in flows | No general daemon login RPC; CLI browser callback/token ownership needs design. |
| `axo relay unlink` | G at inventory baseline; L in 0.64: `axo.relay.unlink` | Clear local pairing and pending redemption, close admission and remove unused secrets. Account-client logout/cloud revocation are separate concerns. |

### Sessions and their agents

Sources: [local handlers](../../crates/axo-server/src/handlers.rs), [parameter/result types](../../crates/axo-protocol/src/rpc.rs), [shared operations](../../crates/axo-server/src/ops.rs), [remote handlers](../../crates/axo-server/src/remote.rs), [brief](../../crates/axo-server/src/brief.rs).

| Candidate command | Backend today | Contract / missing CLI work |
|---|---|---|
| `axo session list` | L: prefer `axo.session.catalog`, render open Sessions | **Do not use `axo.session.list` for a passive list:** it takes pending resume-focus state. |
| `axo session catalog` | L: `axo.session.catalog` | Open and archived Sessions, folders, panes and transcript paths. No focus side effect. |
| `axo session show --sid …` | D: select one record from catalog | No separate local `session.get` RPC. Missing ID must fail, not select another Session. |
| `axo session whoami` | D/M: Session environment plus catalog; MCP `whoami` | Convenience context, not authenticated caller identity. Fail outside a Session unless explicitly targeted. |
| `axo session create --folder .` | L: `axo.session.create {folder}` | CLI resolves a relative path; daemon requires an absolute existing directory. |
| `axo session create --like <sid>` | L: same method, `{like}` | Mutually exclusive with `--folder`; neither means home. Returns the created Session. |
| `axo session close --sid …` | L: `axo.session.close` | Archives the Session and closes panes; it is not transcript deletion. |
| `axo session reopen` | L: `axo.session.reopen` | Reopens the most recently closed Session; **not** an arbitrary archived ID. |
| `axo session rename --sid … --name …` | L: `axo.session.rename` | Return the authoritative saved result. |
| `axo session prompt --sid … --message …` | L: `axo.session.prompt {sessionId,text,delivery?,fromSessionId?}` | `--message` is a CLI projection of `text`. Also support stdin/file input without shell interpolation. |
| `axo session prompt --sid … --delivery …` | L: same method | Local modes: `followUp` (default), `steer`, `turn`, `interrupt`. Remote shape/modes differ; do not blindly reuse flags. |
| `axo session prompt --host … --sid … --attachment …` | R: `axo.remote.session.prompt` | Remote attachment fetching and optional command IDs exist. Local prompt RPC does not carry these fields. Needs explicit route/parity work. |
| `axo session stop --sid …` | R: `axo.remote.session.stop`; shared `ops::stop_turn` | No ordinary local stop RPC. Stop identifies the turn/seen entry/own command IDs, not “whatever happens to run.” |
| `axo session restart --sid …` | R: `axo.remote.session.restart`; shared `ops::restart_for_client` | Restarts the agent on its conversation, potentially stopping a turn. Needs local method if default-local CLI supports it. |
| `axo session recover --sid … --shell …` | L: `axo.session.pi.restart.auto.v1` / `.force.v2` | Both current local handlers call `restart_unavailable`; the word “force” is not a license to invent healthy-agent kill semantics. |
| `axo session key --sid … --key escape\|enter` | R: `axo.remote.session.key` | No ordinary local key RPC; remote path wakes a dormant Pi. Do not emulate via unrelated terminal bytes without defining equivalence. |
| `axo session commands --sid …` | R: `axo.remote.session.commands` | Runtime slash-command discovery; local shared operation exists, local RPC does not. |
| `axo session models --sid …` | R: `axo.remote.session.models` | Pi/provider model catalog, **not** the native inference model cache. Local RPC gap. |
| `axo session model set --sid … --provider … --model …` | R: `axo.remote.session.model.set` | Existing model choice is provider + ID. Provider authentication failure remains actionable. |
| `axo session thinking set --sid … --level …` | R: same model-set method, thinking-only payload | Independent of model choice; preserve supported levels, not a hard-coded provider list. |
| `axo session thinking get --sid …` | D/R: Pi runtime in session metadata | Decide a consistent local runtime read. Do not claim `session.models` is itself the selected-model API. |
| `axo session brief --sid …` | L: `axo.session.brief` | Agent-facing description of reachable capabilities; can depend on the account. |
| `axo session history --sid …` | D: catalog's `piSessionFile`, or R: peer watch | Local transcript file exists; there is no ordinary local paged-history RPC. Safe tailing/partial-line/format handling needs an adapter. |
| `axo session watch --sid …` | L/upgrade: `axo.session.events.stream` | Dedicated event connection; Session filters and terminal-output inclusion are explicit. Lag requires resubscription/relisting, not pretending nothing was lost. |
| `axo session share --snapshot @file` | L: `axo.session.share {snapshot}` | Publishes a supplied redacted snapshot. `--sid` convenience additionally needs the existing share/redaction workflow; never publish raw history by default. |

Local prompts currently lack the remote prompt's `commandId`. A CLI must not claim identical deduplication or automatically retry an uncertain write. A prompt receipt is also not a completed assistant turn; a future `--wait` needs streaming completion semantics and a timeout.

### Shells, terminals and layouts

Sources: [handlers](../../crates/axo-server/src/handlers.rs), [PTY attachment server](../../crates/axo-server/src/attachments.rs), [attachment protocol](../../crates/axo-pty/src/attach.rs).

| Candidate command | Backend today | Contract / missing CLI work |
|---|---|---|
| `axo shell list --sid …` | D: catalog's Session shells | Includes shell ID, role and availability. |
| `axo shell create --sid …` | L: `axo.shell.create` | New terminal pane, not a separate Session or arbitrary host command. |
| `axo shell close --sid … --shell …` | L: `axo.shell.close` | May terminate a running command; require explicit destructive intent. |
| `axo shell busy --sid … --shell …` | L: `axo.shell.busy` | Use existing busy-state query, not process-name guessing. |
| `axo terminal write --sid … --shell … --text …` | L: `axo.terminal.write` | Keyboard text; `\r` submits and control characters are keys. No shell quoting or extra newline injected silently. |
| `axo terminal input --sid … --shell … --sequence … --data …` | L: `axo.terminal.input` | Low-level base64 bytes and per-shell sequence contract, not the same command as text write. |
| `axo terminal screen --sid … --shell … --lines …` | L: `axo.terminal.screen` | Plain screen/scrollback; default 200, maximum 10,000 lines. |
| `axo terminal resize --sid … --shell … --rows … --columns …` | L: `axo.terminal.resize` | Dimension validation; remote sizing can also wake a Pi. |
| `axo terminal attach --shell …` | A: PTY attachment protocol | Separate transport; implement raw TTY restoration, replay/live transition, resize and detach. Not a JSON flag generator feature. |
| `axo layout get --sid …` | D: catalog's layout | Existing data, no separate get method. |
| `axo layout set --sid … --file layout.json` | L: `axo.session.layout.set` | Layout must contain each open shell exactly once, within structural limits. |
| `axo client viewport set --file viewport.json` | L: `axo.client.viewport.set` | Low-level client geometry affects pane sizing. Probably advanced/internal rather than a common CLI action. |

### Settings

Sources: [config keys](../../crates/axo-protocol/src/model.rs), [settings parser](../../crates/axo-server/src/settings.rs).

| Candidate command | Backend today | Contract / missing CLI work |
|---|---|---|
| `axo config get <key>` | L: `axo.config.get` | Valid keys: `agent.command`, `shell.command`, `sessions.idleMinutes`, `sessions.idleLimit`. |
| `axo config set <key> <value>` | L: `axo.config.set` | Wire value is a string parsed according to the key; preserve server validation and saved canonical value. |
| `axo config list` | D: enumerate known keys and read each | No wildcard/list RPC. Command defaults must not be invented by the CLI. |

A generic `config reset`, arbitrary preferences store, or editing all app settings is not implied. Browser appearance/grouping and native UI preferences are not these four daemon settings.

### Other hosts and remote Sessions

Sources: [peer methods](../../crates/axo-server/src/handlers.rs), [peer service](../../crates/axo-server/src/peers.rs), [account client protocol](../../packages/axo-api/src/session-sync.ts).

| Candidate command | Backend today | Contract / missing CLI work |
|---|---|---|
| `axo host list` | L: `axo.peer.sessions.list`; account `codemode.hosts.list()` for richer status | Local peer view can be cached/offline; account host list includes capabilities. Declare which is returned. |
| `axo session list --host …` | L: `axo.peer.sessions.list` | One account's remote Sessions, connection state and host labels. Paths may refer to local transcript copies. |
| `axo peer open --host … --sid …` | L: `axo.peer.session.open` | Opens a local remote pane; this is not Session migration. |
| `axo peer close --host … --sid …` | L: `axo.peer.session.close` | Closes the local peer view, not the remote Session. |
| `axo peer watch --host … --sid …` | L: `axo.peer.session.watch` | Epoch/cursor/version, reset/more, live progress; waits up to 20 seconds per call. |
| `axo host call --host … --method … --params @-` | L: `axo.peer.command` | Generic forwarding of remote methods with host targeting; preserve relay authorization/redacted views. |
| `axo host rename …` | R: account client host rename | Account operation, no advertised ordinary local rename RPC. |
| `axo host status …` | R/D: account host/computer capabilities | Online is not the same as unlocked, screen recording granted, accessibility granted or inference support. |

The 15 relay-only operations are create/close/rename Session; create/close shell; set layout; input/resize terminal; prompt/commands/models/model-set/restart/stop/key Session. Their Rust registrations and TypeScript request schemas are separate today. Local `--folder` creation, absolute paths and local-only methods must never leak into remote requests.

### Apps, tools and cloud codemode

Sources: [local forwarding](../../crates/axo-apps/src/lib.rs), [apps schemas](../../packages/axo-api/src/apps.ts), [MCP adapters](../../crates/axo-mcp/src/lib.rs), [run limits](RFD0050-codemode-run-limits.md).

| Candidate command | Backend today | Contract / missing CLI work |
|---|---|---|
| `axo apps list --sid …` | L: `axo.apps.list` | Runtime apps, connected accounts, hosts and remote MCP servers. |
| `axo apps search <query> --sid …` | L: `axo.apps.search` | Discover tools and their schemas; query/function modes need explicit input forms. |
| `axo apps run --sid … --file script.js` | L: `axo.apps.run` | Cloud JavaScript, not local Node; preserve per-run limits, logs, cancellation and uncertain outcomes. |
| `axo apps log --sid …` | L: `axo.apps.log` | Recent call records, not permission to expose credential contents. |
| `axo apps add --sid … --name … --url …` | L: `axo.apps.add` | Adds remote MCP server; sign-in may still be needed. Print actionable sign-in URL. |
| `axo apps remove --sid … --name …` | L: `axo.apps.remove` | Removes the account's connection; explicit effect, not deleting a local config file. |
| `axo tools list/search/call …` | D/R: runtime tool catalog and apps execution | Candidate generic front end, not three currently existing local RPC names. |
| `axo bash run --host … --command …` | R: codemode bash, host `axo.apps.bash` | Runs a bounded host command without creating or typing into a terminal pane. No ordinary local bash RPC. |
| `axo apps signin …` | R: account sign-in flows, host `axo.apps.signIn` where needed | Browser/device flow; not a credential-taking local daemon method. |

Provider tools are a **runtime catalog**, not a finite static list to bake into Axo.app. The same shell could reach Gmail, Calendar, Drive, GitHub, linked messaging/finance/infra apps and arbitrary added MCP servers, with different accounts and tools tomorrow. The CLI can generate a runtime projection from their schemas or expose a generic tool call. It must not require a new binary for every newly connected service, flatten account selection away, or treat third-party annotations as authorization.

### Native inference

Sources: [native request parser](../../crates/axod-infer/src/api.rs), [native service](../../crates/axod-infer/src/service.rs), [account API](../../packages/axo-api/src/ai.ts), [host boundary](../../crates/axo-server/src/ai.rs).

| Candidate command | Existing operation | Route / semantics |
|---|---|---|
| `axo ai capabilities` | `capabilities` | Actual available backends, formats, tasks and limits. |
| `axo ai list` | `list` | Installed/cache inventory, not every HF model or Pi provider model. |
| `axo ai info <model>` | `info` | Resolve/inspect compatibility before downloading weights. |
| `axo ai install <model>` | `install` | Resolve, download and verify a supported selection. |
| `axo ai load <model> --task …` | `load` | Residency; Core ML prediction exposes feature schemas. |
| `axo ai unload <model>` | `unload` | Runtime residency, **not** deletion of cached weights. |
| `axo ai run <model> --task … --input @file` | `run` | Tasks: `generate`, `classify`, `embed`, `predict`; task-specific typed inputs and complete bounded outputs. |

All seven exist as native service operations behind account codemode and authenticated relay `axo.apps.ai`. **There is no ordinary local `axo.ai.*` RPC today.** Local-first CLI needs a designed public method or another approved route; do not spawn a second model runtime or steal the daemon's worker files. MLX requires Apple Silicon; Core ML requires macOS; backend/model compatibility and task support are not universal. Model deletion is a separate unimplemented operation.

### Computer use

Sources: [driver allowlist](../../crates/axo-computer/src/lib.rs), [gated service](../../crates/axo-computer-use/src/lib.rs), [MCP tools](../../crates/axo-mcp/src/lib.rs).

These are candidate generated subcommands under `axo computer`, using the existing gated MCP or authenticated account route. Snake-case names below are actual tool identifiers; kebab-case CLI projections need explicit metadata.

| Candidate suffix | Existing tool | Effect |
|---|---|---|
| `permissions` | `check_permissions` | Read permission state; not grant permissions. |
| `apps list` | `list_apps` | Enumerate apps. |
| `windows list` | `list_windows` | Enumerate windows. |
| `app launch` | `launch_app` | Launch an app. |
| `window focus` | `bring_to_front` | Explicit foreground action. |
| `tree` | `get_accessibility_tree` | Accessibility structure. |
| `window state` | `get_window_state` | Elements and window screenshot. |
| `screenshot` | `screenshot` | Desktop screenshot. |
| `screen size` | `get_screen_size` | Display geometry. |
| `cursor` | `get_cursor_position` | Cursor position. |
| `click` | `click` | Gated action. |
| `double-click` | `double_click` | Gated action. |
| `right-click` | `right_click` | Gated action. |
| `scroll` | `scroll` | Gated action. |
| `drag` | `drag` | Gated action. |
| `type` | `type_text` | Gated text input, not a password channel. |
| `key` | `press_key` | Gated keypress. |
| `hotkey` | `hotkey` | Gated key combination. |
| `value set` | `set_value` | Gated accessibility value. |
| `menu invoke` | `invoke_menu` | Gated menu action. |
| `window frame set` | `set_window_frame` | Gated window geometry. |
| `steps --file …` | `run_steps` | Bounded batch. |
| `script --file …` | `run_script` | Existing driver scripting, not arbitrary bypass of the gate. |
| `guide` | `get_guide` | Driver usage guidance. |
| `input request` | `request_input` | Person fills protected fields on their device; values are not echoed through CLI args/stdout. |

MCP exposes `computer_tools` for definitions and `computer` for calls, rather than registering 25 ordinary local RPCs. A CLI can reuse the Session MCP path or a deliberately added gated API. Its own signature must not be treated as `axod` or Axo.app. Availability, locked-screen rules, human approval, redactions and the independent safety judge remain in force. OS permission denial must produce an actionable error, not a fallback to an unguarded driver.

### Questions and assets

Sources: [questions](../../crates/axo-questions/src/lib.rs), [assets](../../crates/axo-assets/src/lib.rs), [caller verification](../../crates/axo-ipc/src/peer.rs).

| Candidate command | Backend today | Contract / missing CLI work |
|---|---|---|
| `axo question list` | L: `axo.elicitation.list` | Pending questions, oldest first. |
| `axo question ask --sid … --message …` | L/M: `axo.elicitation.request` | Ordinary local caller asks as agent; only axod's own tool can claim the tool role. Connection ownership withdraws abandoned questions. |
| `axo question answer …` | Internal: `axo.elicitation.resolve` | **Not automatically a public CLI command.** Local answer requires Axo.app's signature; remote answers require the signed-device path. `--yes` does not turn an agent into the person. |
| `axo asset fetch …` | Internal: `axo.assets.fetch` | Restricted to axod's own signed binary. Existing MCP result handling fetches verified returned files. Public CLI route needs deliberate integration. |
| `axo asset read …` | R: account asset range reads through codemode | Not an ordinary local RPC. Preserve account ownership, hash, MIME and size checks. |
| `axo asset upload …` | R: client/account attachment path | Not an advertised local RPC; requires account authorization and a CLI adapter. |

`axo.computer.input` and `axo.computer.redactions` are also signed-axod-only local methods. Redaction internals, credential files and sealing keys are not user-facing commands just because their method names exist.

### App operations and CLI installation

Sources: [app upgrade model](../../apple/AxoMac/Sources/AxoMac/App/AppUpgradeModel.swift), [verified installer](../../apple/AxoDaemonManager/Sources/AxoDaemonManager/AppUpgrade.swift), [launch handover](../../apple/AxoMac/Sources/AxoMac/App/AppLaunchHandover.swift), [packaging/signing](../../bazel/apple/sign_mac_app.sh).

| Candidate command | Backend today | Contract / missing CLI work |
|---|---|---|
| `axo open` | A: launch/open Axo.app | Works independently of daemon RPC. |
| `axo session focus --sid …` | A/G: app-owned selection and focus | No ordinary local focus command for arbitrary client; design explicit app routing. |
| `axo upgrade --check` | A: published-release fetch/selection | Distinguish latest published from installed and running versions. |
| `axo upgrade` | A: verified install plus app handover | Capture immutable archive identity; verify signature and metadata. Daemon-build change is disruptive and must stay explicit. |
| `axo permissions` | D/A: health, computer probes, OS settings links | Reports real grants; cannot grant TCC via generated flags. |
| `axo cli install` / `axo cli uninstall` | G: packaging/PATH integration | Ship a signed helper and link it into a user-selected bin directory; do not overwrite another executable or silently edit shell profiles. |
| `axo completion <shell>` | D: generated command descriptors | Build from the same definitions as parsing/help, including runtime discovery where appropriate. |
| `axo capabilities --json` | G: proposed unified discovery | Must distinguish available, unsupported, offline and caller-restricted capabilities. |

Package the executable as **`Axo.app/Contents/Helpers/axo`**, not beside `Contents/MacOS/Axo`: `Axo` and `axo` collide on common case-insensitive macOS filesystems. Sign the helper explicitly before the outer bundle, validate it in package tests and point PATH integration at the stable app location so upgrades replace it together with the app. This is a proposed packaging contract, not implemented here.

## Gaps deliberately not disguised as existing commands

- **Message-free continuation** (`axo session continue --sid …`): the earlier request to trigger a new turn without injecting a synthetic user message remains unimplemented. It is not an empty prompt or an alias for process restart.
- **Explicit local wake:** shared wake behavior exists, including remote input/resize, but no ordinary local wake RPC. Do not invent fake input or geometry changes to wake an agent.
- **Arbitrary archived Session reopen by ID**, Session deletion, transcript compaction/edit/fork/export policy, and moving a Session to another host need their own contracts.
- **Local/remote parity:** stop, key, commands, models, thinking and full agent restart need deliberate local adapters/APIs. Prompts have differing fields, deduplication and delivery modes.
- **Local native inference API**, public asset fetch/upload and account login/unpair need explicit supported CLI routes.
- **Daemon/app lifecycle is not a generic RPC** and includes platform service ownership, app registration, user approval and terminal interruption.
- **Human approval cannot be generated away** by shipping a signed binary, adding `--yes`, or exposing private computer/form methods.

## Generation findings and direction

### Existing catalogs are insufficient

1. `rpc::method::ADVERTISED` has method names, not schemas, caller policies or stream modes. Some names are privileged.
2. `axo_ipc::Methods` already knows which extension owns a method, but that ownership is not exported as a complete descriptor catalog.
3. `local-rpc.schema.json` has only 19 `axo.*` string literals, including an event notification and stream upgrade. **27 of the 43 advertised method names are absent from that file.** Even including `apps.schema.json`, **21 advertised names remain absent**. Presence of a name is not proof that its schema is complete/correct; these counts are a source audit, not schema conformance certification.
4. Rust request types, JSON schemas, TypeScript validators and MCP tool properties are separate representations today. Semantic constraints also live in parsers/handlers: exclusive create options, byte limits, valid stop targets, layout membership, per-key config parsing and caller identity.
5. AXP schemas exist, but axod has not moved to that wire. Do not generate a CLI for planned AXP methods and call it the current daemon client.
6. App/MCP tool catalogs are runtime data; one static binary's command list cannot exhaust every connected account and third-party server.
7. The existing MCP `Tool` type already has descriptions, input properties/required fields, optional output schemas, and read-only/destructive annotations. Reuse that work when consolidating descriptors; it covers 18 adapters, not the whole daemon, and effect annotations are not caller authorization.

### Proposed descriptor boundary

A descriptor should identify the operation, its owner, request/result schema, allowed callers, supported routes/platforms, unary/stream/attach behavior, limits/timeouts, mutability and idempotency semantics, secret-bearing inputs, and its optional CLI projection. Register the descriptor with the handler so a method cannot quietly exist without one. A restricted/internal operation can explicitly have **no public CLI projection**.

Generate parsing, help, JSON discovery, completion and reference docs from these definitions. Keep a small deliberate projection for `sessionId → --sid`, `text → --message`, `relay.link → relay link`, local/remote selection and human-friendly enum spelling. Keep lifecycle, interactive PTY attachment, redacted sharing and multi-step waits as explicit adapters. Do not make regex source scraping the production generator.

### Proposed CLI behavior

- Local daemon by default; `--host` is explicit remote selection. No silent fallback to another host, Session or offline mutation queue.
- Resolve `--sid self` only from a valid Session context; it grants no extra authority. Never guess “the last Session.”
- Human-readable bounded output in a TTY, stable `--json` for scripts and NDJSON for streams. Progress/errors go to stderr; stdout stays machine-readable.
- Structured input from stdin/files for prompts, scripts, layouts, AI tasks and JSON params. No passwords/tokens in arguments or echoed form values.
- Generate constraints but preserve authoritative server validation. The CLI may resolve `--folder .` to an absolute path; it cannot relax limits.
- Explicit confirmation for disruptive local operations; noninteractive invocation must be explicit. This does not authorize answering a human approval or bypassing computer-use safety.
- No automatic retries of side-effecting requests with uncertain outcomes. Closing a CLI connection is not proof a dispatched action was rolled back.
- Bounded deadlines, Ctrl-C cleanup and stream/attach reconnection semantics are part of each adapter, not just a generic HTTP timeout.

## Smallest useful first slice

After the inventory is accepted: a signed packaged client, local connection/version negotiation, generated discovery/help/JSON output, read-only `session list/show`, `session create/rename/prompt`, `relay link <code>`, relay status and daemon health. Add explicit daemon restart through the correct lifecycle path, with tests that never target the developer's running service.

Before adding new CLI nouns, close the catalog and caller/transport metadata gaps. Existing features that lack public local routes should get deliberate boundaries, not a CLI exception to authentication. The first slice is now implemented; the remainder still requires explicit design and implementation rather than expanding the CLI around private methods.

## Validation plan

- Compare every registered handler and connection upgrade against descriptors, including explicit internal exclusions; fail on missing or duplicate ownership.
- Assert generated CLI coverage for every operation that opts in, and a reason for each non-public operation.
- Round-trip CLI flags into the exact typed request; test JSON schema plus semantic boundaries, unknown flags, byte limits and exclusive inputs.
- Test the examples against an isolated real daemon and fake Pi/relay, including offline behavior, stale host generations, interrupted requests and non-retried uncertain writes.
- Test privileged calls are still refused to a CLI, even when its helper is signed by the app's team.
- PTY tests cover replay, SIGWINCH, raw-mode restoration, detach and daemon exit. Lifecycle tests use fixture service labels and never restart the person's daemon.
- Download a signed release, verify its CLI helper and bundle metadata, run `--help` and read-only discovery, and verify PATH links survive app replacement.

## Drawbacks and alternatives

- A complete descriptor registry is real work: structural schema derivation alone will not recover semantics or caller identity from Rust types.
- Runtime tool schemas can be large, change while offline and come from third parties. Cache them as untrusted account-scoped descriptions, not execution authority.
- **Handwritten session-only CLI:** fastest first prototype, but risks another drifting API. A thin annotated slice is reasonable only if it establishes the common descriptor path.
- **Raw RPC client only:** useful debug escape hatch, but exposes wire names, hides limits/caller policy and does not solve restart, attach or good help.
- **Reuse `axod` as the CLI:** possible packaging alternative, but mixes daemon startup/logging with user commands. Prefer distinct `axo` client and `axod` service responsibilities.
- **Generate from current JSON schemas only:** incomplete coverage, missing caller/transport semantics and app operations; rejected as the sole source.
- **Wait for full AXP migration:** would delay useful CLI work for an unrelated wire migration. Descriptors can serve today's protocol and later evolve.
- **Do nothing:** people and agents keep using ad hoc socket scripts, app UI and MCP adapters.

## Unresolved questions

- **Before implementation:** should the first slice be local-only with later `--host`, or include existing peer routing from day one? Recommendation: local-first descriptors that explicitly model routes, without pretending full local/remote parity.
- **During implementation:** schema derivation/custom validators, PATH install UX, app lifecycle control channel, stable error/exit-code taxonomy and runtime provider command projections.
- **Out of scope:** implementing the CLI in this inventory, a new agent runtime, message-free continuation, Session migration, changing human approval, or migrating axod to AXP.
