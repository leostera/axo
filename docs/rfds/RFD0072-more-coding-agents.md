# RFD0072 - Axo: more coding agents

- Feature Name: `more-coding-agents`
- Status: Implemented (all eight slices; see As built)
- Author: leostera
- Start Date: 2026-11-18
- Updated: 2026-11-18
- Document Type: Proposal
- Amends: [RFD0041](RFD0041-axod-session-tasks.md) (a Session's agent need not be Pi), [RFD0045](RFD0045-idle-pis-sleep.md) (any agent sleeps), [RFD0058](RFD0058-message-free-restart-continuation.md) (continuation is a capability)
- Related: [RFD0015](RFD0015-sessions-as-axo-clients.md), [RFD0024](RFD0024-remote-sessions-in-pi.md), [RFD0033](RFD0033-session-controls-for-clients.md), [RFD0035](RFD0035-session-records-in-atxf.md), [RFD0043](RFD0043-axo-on-axp.md), AXP's [`agent` extension](../../axp/extensions/agent.md)

## Summary

A Session runs one of four coding agents: Pi, Codex, OpenCode or Claude Code. Each still shows its own terminal UI in the Session's pane on the Mac, and axod still steers it from beside that UI, so the Mac, the phone and the web prompt, stop and follow every agent the same way. `axo-agent` gets the domain model for it: an `AgentKind` chosen when the Session is created, the `Capabilities` each kind declares, and one runtime handle per running agent (`AgentCommands` in, `AgentEvent` out) behind which each kind has its own adapter. Codex comes first, because its terminal UI is already a client of a JSON-RPC server that axod can join as a second client. OpenCode follows with the same shape over HTTP. Claude Code comes last with fewer capabilities, because its terminal UI has no inbound control channel.

## Motivation

Today the only agent is Pi (`crates/axo-agent/README.md`: "Pi is the only agent today"). People use Codex, OpenCode and Claude Code too, and Axo's value (Sessions that survive restarts, are reachable from the phone and the web, prompt each other and reach the account's apps) has nothing to do with which agent writes the code. AXP's `agent` extension already promises that "Pi, Codex, Claude Code, OpenCode and Gemini CLI are all steered the same way"; axod does not keep that promise yet.

## What Axo needs from an agent

This is the contract, taken from how axod drives Pi today.

| Need | Pi today | Where |
| --- | --- | --- |
| Start or resume a conversation in a folder | `pi --session <file> --extension pi-axo`, cwd = the Session's folder, on a PTY | `crates/axo-agent/src/pi/launch.rs` |
| Proof of life, one agent per Session | an exclusive `flock` on `<transcript>.jsonl.lock`, inherited by Pi | `crates/axo-agent/src/lock.rs` |
| Die with axod | the lifeline descriptor (`AXO_LIFELINE_FD`); kill-at-boot by pid and start time | RFD0041, `crates/axo-agent/src/process.rs` |
| A side channel axod trusts | Unix socket, token, `hello` identity checked field by field | `crates/axo-agent/src/pi/connection.rs` |
| Prompt: turn, steer, follow-up, interrupt; attachments; a client's command id | bridge `send` | `crates/axo-server/src/session/prompts.rs` |
| Stop the turn the client saw | bridge `stop` with a `StopTarget` | RFD0024 |
| Know working, idle or waiting on the person | `agent.start`, `agent.settled`, `ui.prompt.start`/`end`, `activity.snapshot` | `crates/axo-server/src/session/controls.rs` |
| Model and thinking level, the models it could switch to, its slash commands | `pi.state`, `pi.models`, `pi.commands`; bridge `setModel` | RFD0033 |
| Titles and emoji | `session.info`, `axo.session.metadata` | `packages/pi-axo/src/title.ts` |
| Live replies and tool progress for clients | every bridge event, forwarded as `Event::PiEvent` | `session/pi.rs` `link_event` |
| The transcript, for the phone and the web | Pi's JSONL, hashed as `pi/3`, uploaded, translated to ATXF in the SessionDO | RFD0018, RFD0035 |
| Axo's MCP tools and brief | pi-axo registers `axod mcp` (codemode exposure) and adds the `<axo>` prompt section | `packages/pi-axo/src/{mcp,brief}.ts` |
| Sleep and wake | ask it to exit on the bridge, kill after a grace, dormant pane | RFD0045 |
| Restart continuation | bridge `resumeTurn`, refused by an SDK without it | RFD0058 |

## What each agent offers

From each agent's source at the installed version (Codex 0.170.0, OpenCode v2.0.20, Claude Code 2.1.327). The evidence, with file and line, is in the research note `personal/axo/coding-agent-control-surfaces` of the private research repository.

- **Codex.** `codex app-server --listen unix://PATH` serves JSON-RPC over WebSocket on a Unix socket. The TUI connects to it with `codex --remote unix://PATH resume <thread>`. A second connection that resumes a running thread joins it as a subscriber, and the server sends a thread's notifications and requests to every subscriber; the first answer to a request wins and the rest are told `serverRequest/resolved`. It has `turn/start`, `turn/steer` (with `expectedTurnId`), `turn/interrupt`, `model/list`, per-turn `model` and `effort`, and `thread/status/changed` with `waitingOnApproval` and `waitingOnUserInput`. MCP servers and developer instructions are configuration.
- **OpenCode.** `opencode serve` is an HTTP API with SSE events (each with a durable `aggregateID` and `seq`) behind basic auth. The TUI connects with `opencode --server URL --session ID`. It has `prompt` with `delivery: steer | queue`, `interrupt`, `model` and a model list, and takes its whole configuration in `OPENCODE_CONFIG_CONTENT`.
- **Claude Code.** The interactive TUI takes `--session-id`, `--settings` (hooks), `--mcp-config`, `--append-system-prompt`, `--model` and `--effort` at launch. Hooks report its lifecycle outward with each event's `transcript_path`. Nothing goes inward: stream-json input and the control protocol work only in headless `--print` mode, and channels, which push messages into a running session from an MCP server, are a research preview that needs a development flag for a custom server.
- **ACP.** A client-drives-agent protocol whose client draws the conversation. It would take the agent's own UI out of the Mac pane, so it is not the common denominator here (Alternatives).

## Guide-level explanation

### Choosing an agent

A Session picks its agent when it is created, and keeps it: `axo.session.create` takes `agent` (`pi`, `codex`, `opencode`, `claude-code`, the names ATXF uses for `source.agent`), defaulting to `pi`. `axo agents` lists the agents this Mac has, with the path and version of each and what each can do. Creating a Session with an agent that is not installed fails, naming it.

### What a person sees

On the Mac, a Codex Session's pane is Codex's own TUI, exactly as `codex` in a terminal, in the Session's folder and with its usual login and settings. The sidebar says Working while Codex runs a turn, Needs attention while it waits for an approval, and Ready otherwise. From the phone, the web or another Session's agent, `session_prompt` reaches it: a prompt when it is idle starts a turn, and while it works, a steer is added to the running turn, a follow-up waits for the next one, and Send interrupts. Stop stops the turn the client saw. The model picker lists Codex's models and its reasoning efforts.

The agent's tools include Axo's (`tools.mcp__axo__…` where the agent has codemode, the plain MCP tools otherwise), and its instructions include the `<axo>` brief.

What an agent cannot do, the clients do not offer: an agent without steering shows only Send and Follow-up, one without a model list hides the picker. The snapshot carries the Session's agent and its capabilities so clients can tell.

### Transcripts on the phone and the web

Until slice 5, only Pi Sessions upload their transcript; a Codex Session shows on the phone and the web with its status and takes prompts, but its conversation is read on the Mac. Slice 5 sends every agent's records as ATXF (Open question 1).

## Reference-level explanation

### Domain model

```text
Session ──1── AgentKind (fixed at creation)
   │
   └── Agent runtime (0..1 at a time): processes + a link
          AgentCommands  ──►  adapter  ──►  the agent's own API
          AgentEvent     ◄──  adapter  ◄──  the agent's own events
```

- **`AgentKind`**: `Pi | Codex | OpenCode | ClaudeCode`. Stored per Session (`sessions.agent`, `pi` for every existing row). It never changes: a conversation belongs to the agent that wrote it.
- **`Capabilities`**: what a kind can do, declared by the adapter, not discovered at run time: the deliveries it takes (`turn`, `steer`, `followUp`, `interrupt`), whether it stops a turn, continues one without a message, switches models and thinking levels, takes images, lists slash commands, streams replies. Axod refuses a command the agent cannot do with `InvalidInput` before reaching the agent, and clients read the same declaration.
- **`AgentConversation`**: how each kind names a conversation. Pi: the transcript file axod chose. Codex: the thread id (`thread/start`'s answer) and its rollout path. OpenCode: the session id. Claude Code: the UUID axod passes as `--session-id`. Stored with the Session (`sessions.agent_conversation`), bound the first time the agent reports it, and checked on every later bind, as Pi's `hello` identity is today.
- **`AgentCommands`**: the one handle axod's Session task holds for a running agent: `send_message(text, delivery, command_id, attachments)`, `stop_turn(StopTarget)`, `resume_turn`, `shutdown`, `set_model(model, thinking)`. Each returns the agent-neutral `CommandResult` (`Accepted`, or `Rejected(Invalid | Busy | Idle | Stale | Unavailable)`), as the Pi bridge does today.
- **`AgentEvent`**: what a link reports, in order: `Bound { agent_session_id }`, `Disconnected`, `ResumeRequested` (Pi only), `Event { stream_id, sequence, name, data }`. Event names are the vocabulary pi-axo already defined (`agent.start`, `agent.settled`, `message.start`/`end`/`update`, `tool.*`, `ui.prompt.start`/`end`, `activity.snapshot`, `session.info`, `axo.session.metadata`, `pi.state`, `pi.models`, `pi.commands`). It is Axo's vocabulary, not Pi's internals, and every adapter emits it, so the Session task, the catalog, the sidebar and every client's live view work for any agent unchanged. The names keep their `pi.` prefix and `Event::PiEvent` keeps its name until the wire moves to AXP (Open question 5).

The set of kinds is closed and small, so the handle is an enum over each kind's link, not a trait object: `match` keeps every adapter's commands visible in one place, and the compiler lists every place a new kind must be handled.

### Processes and invariants

- **One agent per Session, proven by a lock.** Every agent holds an exclusive `flock` that axod takes before launching it and the agent's processes inherit, as RFD0041 says for Pi. Pi keeps `<transcript>.jsonl.lock`. Other kinds lock `<agents>/<session>.lock` in axod's private directory, since they keep their history in their own store.
- **Every process dies with axod.** The TUI runs on the pane's PTY with the lifeline; a server (Codex's app-server, OpenCode's `serve`) runs under `Lifeline::guarded`, as `axod-infer` does. Both identities are stored, and an earlier axod's survivors are killed at boot.
- **A private server per Session.** Codex and OpenCode both default to a shared background service; Axo never uses it (Open question 3).
- **The side channel is authenticated.** Codex's socket is created by the app-server with mode 0600 in a per-uid private directory, and axod connects only to the path it chose. OpenCode's server gets a fresh random password per launch, given to the TUI in its environment.
- **The pane's exit is the agent's exit.** If the TUI exits, axod stops its server, and the pane is unavailable (or dormant, when sleep asked for it), exactly as for Pi.

### Codex

Launch, as the Session's task does on the blocking pool:

1. Take the Session's lock; start `codex app-server --listen unix://<run>/<session>.codex.sock` under the lifeline guard, with `-c mcp_servers.axo.command=<axod>`, `-c mcp_servers.axo.args=["mcp"]` and `-c mcp_servers.axo.env={AXO_SOCKET=…,AXO_SESSION_ID=…}`.
2. Connect, `initialize` (client name `axod`), and either `thread/start { cwd: folder, developerInstructions: brief }` for a new Session or `thread/resume { threadId }` for an existing one.
3. A new thread is not resumable by another client until it has been written once ("no rollout found"); axod names it with `thread/name/set`, which writes it and is what a Session's title should do anyway.
4. Start `codex --remote unix://<sock> resume <thread>` on the PTY, in the folder.

Commands:

| Axo | Codex |
| --- | --- |
| `turn` delivery, idle | `turn/start { input, clientUserMessageId: commandId }` |
| `turn` delivery, working | refused `Busy` |
| `steer`, working | `turn/steer { expectedTurnId: active }`; a stale turn id answers `Stale` |
| `followUp`, working | held in the adapter, sent as `turn/start` on `turn/completed`; a stop does not drop it (agent extension §3.1) |
| `interrupt`, working | `turn/interrupt`, then `turn/start` once `turn/completed` arrives |
| any delivery, idle | `turn/start` |
| stop | `turn/interrupt { turnId: active }` if the target names the active turn (its command id, or an item of it the client saw), else `Idle` |
| set model | the model and effort of the next `turn/start`, announced as `pi.state` |
| resume turn | refused `Unavailable`: Codex has no message-free continuation |
| shutdown | the server is stopped; the TUI exits with it |

Events: `thread/status/changed` and `turn/started`/`turn/completed` become `activity.snapshot`, `agent.start` and `agent.settled`; `waitingOnApproval` and `waitingOnUserInput` become `ui.prompt.start`/`end`; `item/completed` with a user or agent message becomes `message.end` with a Pi-shaped message (`role`, `content`) so the sidebar's last-message time and the clients' live view work; `item/agentMessage/delta` becomes `message.update`; `thread/name/updated` becomes `session.info`; `model/list` becomes `pi.models`. Every translated event goes out in one increasing sequence per connection, as the Pi bridge's do.

Approvals stay in Codex's TUI: axod sees each request but never answers it (Open question 4).

### OpenCode

`opencode serve --hostname 127.0.0.1` under the guard with `OPENCODE_SERVER_PASSWORD` and `OPENCODE_CONFIG_CONTENT` (the `axo` MCP server as a local server, the brief as instructions); axod reads the port from its `server listening on` line. axod creates the session (`POST /api/session` with the folder) or reuses the stored one, subscribes to `/api/event`, and starts `opencode --server <url> --session <id>` on the PTY with `OPENCODE_PASSWORD`. Deliveries map to `delivery: steer` and `queue`; stop is `interrupt`; models are `GET /api/model` and `POST …/model`. Events resume from the last durable `seq` after a reconnect.

### Claude Code

`claude --session-id <uuid> --settings <hooks> --mcp-config <axo> --append-system-prompt <brief>` on the PTY (`--resume <uuid>` after the first launch). The hooks are HTTP hooks posting to a loopback listener axod opens for the launch, at a path with a per-launch secret: `SessionStart` binds the conversation, `UserPromptSubmit` and `Stop` are `agent.start` and `agent.settled`, `Notification` is `ui.prompt.start`, `PreToolUse`/`PostToolUse` are tool events. The transcript is `transcript_path`, tailed as Pi's file is. A client prompt is typed into the PTY as a bracketed paste and Enter, only when Claude is idle; a follow-up waits for `Stop`; steering is not offered; stop is Escape. Its capabilities say so (Open question 2).

### Discovery

An agent's executable is found, in order, from: `AXO_<KIND>_EXECUTABLE`; the configured command for that kind (`agent.command` for Pi, as today); `PATH`; then the directories each kind's installer uses, under the user's home and the system (`~/.local/bin`, `~/.bun/bin`, `~/.opencode/bin`, `~/.npm-global/bin`, `~/.cargo/bin`, `/opt/homebrew/bin`, `/usr/local/bin`). The last step matters because axod starts from launchd with a minimal `PATH`: Claude Code's installer puts it in `~/.local/bin`. A candidate is the agent only if `<it> --version` answers within five seconds (Node-based agents start slowly on a busy Mac) with a version the adapter supports. It is checked at every launch; caching the answer until the file changes is left until a launch shows the cost.

### Storage and wire

- `sessions.agent TEXT NOT NULL DEFAULT 'pi'` and `sessions.agent_conversation TEXT`, added by a migration; every existing row is a Pi Session with its conversation in `pi_session_file`, as before.
- `CreateSession` takes an optional `agent`; `SessionRecord` and the remote snapshot carry `agent` (absent means `pi`, so older clients and older hosts agree).
- The uploader skips Sessions whose agent is not Pi until slice 5.

### As built

Where the build differs from the design above, the build wins; each point names the code.

- **One channel, three servers.** Codex, OpenCode and Claude Code links take axod's commands on one command channel (`axo_agent::channel`); `AgentCommands` is `Pi | Codex | OpenCode | ClaudeCode`. The lock takeover (kill the previous axod's process only if it still holds the Session's lock, `lock::take_server_lock`) is shared by all three.
- **The brief.** Codex gets it as `developerInstructions`; Claude Code as `--append-system-prompt`; OpenCode has no launch option for it, so `axod mcp` opens its instructions with the brief for an OpenCode Session (`axo_mcp::McpServer::instructions`, with the account's apps when the account answers).
- **Transcripts (Open question 1).** Built as (a), not (b): axod converts each agent's native conversation through ATXF (`atxf` pinned by git rev) to Pi lines with a fixed header and keeps the Session's Pi file, so the uploader, the phone and the web work unchanged (`axo_agent::transcript`, the Session's `Mirror`). Codex: the rollout file. OpenCode: the session's export (`GET /api/experimental/session/<id>/export`), saved beside the lock after every execution. Claude Code: `transcript_path` from its hooks. The path from here is agreed, in three steps: (1) every agent's conversation is kept as Pi lines, as built, since the clients work over them today; (2) the phone and the web move to reading ATXF (RFD0043); (3) axod stops storing Pi lines.
- **OpenCode.** HTTP through `reqwest` (no TLS), the event stream parsed by `opencode::sse`; the port is whatever the server prints. A session the server does not have ends the link instead of retrying. Thinking levels are not offered (OpenCode chooses reasoning by model variant). After a reconnect the link reads the session's state again rather than replaying `seq`.
- **Claude Code.** HTTP hooks, not `axod agent-hook`: Claude Code posts hooks itself, so no subcommand or socket method is needed. `PermissionRequest` (immediate) rather than `Notification` marks an approval. Claude runs no hook for a turn the person interrupts, so axod settles the turn when it sends Escape, and on `idle_prompt`. The conversation id is the Session's own id; a launch resumes it only once `<config>/projects/*/<id>.jsonl` exists (`CLAUDE_CONFIG_DIR` honoured).
- **Pickers.** `axo.agents.list` (`axo agents`) lists every agent with path, version or the reason it cannot run, and capabilities; `axo session create --agent`. `axo.remote.session.create` takes an optional `agent`, Pi when absent; the web's new-chat composer, the phone's new chat and the Mac's Terminal menu (New Session with Agent) pick it. The phone and the web offer all four: they do not yet learn which a Mac has, and a Mac without the agent refuses the Session.
- **Not built.** Approvals on the phone (Open question 4), `pi.` prefix removal (5), Claude Code channels (2b), and a launch-time cache for discovery.

### Slice order

Each slice is tested at its layer and leaves everything before it working.

1. **The cut.** `AgentKind`, `Capabilities`, `AgentCommands`, `AgentEvent` and the neutral `CommandResult` in `axo-agent`; Pi's link speaks them; `axo-server` holds the neutral types. No behaviour changes and every existing test passes.
2. **Discovery.** Finding each agent and its version, with fake executables in a temporary home.
3. **The Codex adapter**, in `axo-agent`: the JSON-RPC client over a Unix-socket WebSocket, the translation of Codex notifications to Axo events as a state machine, the command mapping, and its launch. Tested against a fake app-server that replays recorded frames; the parsers are fuzzed.
4. **Codex Sessions on the Mac.** Sessions carry an agent; a Codex Session launches, binds, shows its status and takes prompts, stops and model changes through the RPCs and MCP tools that exist. A smoke run against the real Codex is kept tiny and is not part of the suite.
5. **Transcripts as ATXF** for non-Pi agents (Open question 1).
6. **OpenCode.**
7. **Claude Code.**
8. **Pickers** on the Mac, the phone and the web, from the host's agent list.

## Drawbacks

- Four adapters to keep working as four fast-moving agents change their protocols. Each adapter pins the versions it supports, refuses others at discovery, and has recorded-frame tests that a version bump re-records.
- The Pi-named event vocabulary now carries other agents' events. It is honest about where it came from and cheap to keep; renaming it is a wire change best made with AXP.
- Codex's need to name a thread before another client can resume it is behaviour, not contract. If it changes, the adapter has to learn another way (Open questions).

## Alternatives

- **Do nothing.** Codex, OpenCode and Claude Code users keep running them in a plain terminal pane, with none of Axo's reach.
- **ACP as the one protocol.** One adapter instead of three, but ACP's client draws the conversation: the Mac pane would show an Axo chat view instead of the agent's TUI, Codex and Claude Code need third-party ACP adapters, and Pi has none. Kept as a future kind for agents with no TUI.
- **Headless agents with an Axo-drawn pane for all.** The same loss of the agent's own UI, and every agent's interactive features (approvals, pickers, its slash commands) would have to be rebuilt.
- **A trait object per agent.** Open-ended, but the set of agents is closed and small; an enum keeps every adapter visible and exhaustively matched.
- **Typing into every agent's PTY.** Works for any TUI, but mixes with what the person is typing and cannot report acceptance. Used only where nothing better exists (Claude Code).

## Open questions

1. **How do non-Pi transcripts reach the phone and the web?**
   - (a) Convert each agent's records to Pi lines in axod and keep the `pi/3` wire. Every client works unchanged, but the cloud would hold Pi lines Pi never wrote, labelled `source.agent: "pi"`.
   - (b) Convert each agent's records to ATXF in axod (ATXF's Rust converters cover all four) and upload them with format `atxf/0.x`; the SessionDO stores them as they are (its `records.format` column exists for this), and the phone and the web each gain one ATXF adapter beside their `pi/3` one.
   - (c) Upload each agent's native lines with its own format and convert in the SessionDO with ATXF's TypeScript converters.
   - Recommendation: **(b)**. It is where RFD0043 is heading anyway, it is one adapter per client instead of one per agent, and the agent's own record still rides in `native`.
2. **How does a client's prompt reach Claude Code?**
   - (a) Typed into its PTY as a bracketed paste, only when it is idle.
   - (b) Channels from Axo's MCP server, once they leave research preview.
   - (c) Headless `--print` stream-json with an Axo-drawn pane.
   - Recommendation: **(a)** now, with a capability set that says what it cannot do; **(b)** when channels are generally available.
3. **One agent server per Session, or one per Mac?**
   - (a) A private server per Session, axod's child.
   - (b) One axod-owned server per agent kind for the Mac.
   - (c) The agent's own background daemon.
   - Recommendation: **(a)**. It keeps RFD0041's lifeline and kill-at-boot, RFD0045's sleep, and one Session's crash away from the others. The cost is one more process per running Session, which sleep already bounds.
4. **Should agents' approvals reach the phone?** Codex's server requests reach axod already, and answering one resolves it for the TUI too.
   - (a) Not yet: approvals stay in the TUI, and the Session shows Needs attention.
   - (b) As Axo elicitations (RFD0029, RFD0060).
   - Recommendation: **(a)** for slice 4, **(b)** as its own RFD.
5. **When does the event vocabulary lose its `pi.` prefix?**
   - (a) Now, with a protocol bump on every client.
   - (b) With AXP's `agent` extension (RFD0043), which already names events neutrally.
   - Recommendation: **(b)**.

## Future possibilities

- Gemini CLI, which ATXF already converts.
- "Continue in another agent": seeding a new Session of one kind from another's ATXF, lossy by design.
- An ACP kind for agents with no TUI of their own.
