# axo-agent

Everything axod knows about running a coding agent for a Session. The goal is one crate that launches, supervises and steers any agent (Pi, Codex, Claude Code, OpenCode) and turns its session into ATXF records, so nothing above it knows which agent runs; see RFD0072 and AXP's `agent` extension (`axp/extensions/agent.md`). Pi, Codex, OpenCode and Claude Code all have adapters.

Today it holds Pi processes for axod: launching Pi for a Session, the transcript writer lock that proves whether one is alive, its bridge socket, the bridge protocol and its async link, and the lifeline that ends a Pi when axod does (RFD0041). It knows nothing of the catalog; callers decide which Pi to launch and what its events mean.

| Module | Owns |
| --- | --- |
| (re-exported) | `AgentKind` (`pi`, `codex`, `opencode`, `claude-code`, as ATXF names them) and the `Capabilities` each declares, from `axo_protocol::agent`: clients name the agent when they create a Session |
| `runtime` | The one shape every running agent presents to its Session: `AgentCommands` in, `CommandResult` back, `AgentEvent` out, in the event vocabulary pi-axo defined |
| `command` | The configured `agent.command` |
| `discovery` | Finding each agent's executable without relying on `PATH` (launchd gives axod almost none): an override variable, the configured command, `PATH`, the installers' directories, then the system's; each checked with `--version` against the oldest version its adapter supports |
| `lock` | `WriterLock`: the exclusive `flock` on `<transcript>.jsonl.lock`. axod takes it and the agent inherits it, so holding it proves no agent for the Session is alive |
| `lifeline` | Re-exports `axo_pty::lifeline`: the pipe every agent inherits (`AXO_LIFELINE_FD`), whose read end reaches end of file when axod exits, however it exits |
| `process` | `ProcessIdentity`: a pid and its start time, stored per Session so axod can kill, at boot, an agent a previous axod left behind, and never a reused pid |
| `history`, `activity` | Recognising the transcript Axo created, and a Session's status from what its agent reports |
| `codex` | Codex: `rpc` (the app-server's JSON-RPC frames), `thread` (the thread's state and Codex's items as Axo events, pure), `launch` (the app-server under the lifeline guard holding `<agents>/<session>.jsonl.lock`, then the TUI with `--remote`), `link` (the WebSocket client over the app-server's Unix socket that follows the thread beside the TUI; `create_thread` for a new Session) |
| `channel` | The command channel shared by every adapter other than Pi's, and `ServerProcess`, the guarded server a link owns |
| `opencode` | OpenCode: `client` (the v2 HTTP API with the server's password), `sse` (the event stream's framing), `session` (the session's state and OpenCode's events as Axo events, pure), `launch` (`opencode serve` under the lifeline guard, then the TUI with `--server`), `link` (follows `/api/event`, keeps the export for the transcript) |
| `claude` | Claude Code: `hooks` (the loopback listener for its HTTP hooks and the `--settings` that points them at it), `session` (hooks as Axo events and what to type, pure), `launch` (the TUI holding the lock, new or `--resume`), `link` (receives hooks, types prompts as bracketed pastes) |
| `transcript`, `axo_mcp` | Other agents' conversations as Pi lines through ATXF; Axo's MCP server in each agent's configuration format |
| `pi` | Pi itself: `launch` (Pi on a PTY with the pi-axo extension; `STOP_GRACE`), `socket` (`BridgeSocketPath`), `protocol` (shared with `packages/pi-axo/src/protocol.ts`), `connection` (the connection as a state machine), `link` (the async bridge link for one running Pi: events out, `LinkCommands` in), `pi3` (record identity and hashing for Pi files, the upload's wire format, shared with `packages/axo-api/src/pi3.ts`) and `TranscriptFile` (a Session's Pi file read and hashed for upload; `transcript_chain`) |

Code outside `pi` serves any agent; each agent's adapter is a module beside `pi`, and `AgentCommands` is an enum over their links: the set of agents is closed, so every command's handling for every agent stays in one `match`.

## Rules

- Only the intended Pi inherits its writer lock across exec; every other descriptor stays close-on-exec.
- axod signals only an agent whose pid and start time match the identity it stored when it launched it; a lock held by anything else leaves the pane unavailable.

## Build and test

```sh
bazel build //crates/axo-agent
bazel test //crates/axo-agent:axo_agent_tests
```
