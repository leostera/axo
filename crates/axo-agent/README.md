# axo-agent

Everything axod knows about running a coding agent for a Session. The goal is one crate that launches, supervises and steers any agent (Pi, Codex, Claude Code, OpenCode) and turns its session into ATXF records, so nothing above it knows which agent runs; see RFD0072 and AXP's `agent` extension (`axp/extensions/agent.md`). Pi is the only adapter so far.

Today it holds Pi processes for axod: launching Pi for a Session, the transcript writer lock that proves whether one is alive, its bridge socket, the bridge protocol and its async link, and the lifeline that ends a Pi when axod does (RFD0041). It knows nothing of the catalog; callers decide which Pi to launch and what its events mean.

| Module | Owns |
| --- | --- |
| `kind` | `AgentKind` (`pi`, `codex`, `opencode`, `claude-code`, as ATXF names them) and the `Capabilities` each declares |
| `runtime` | The one shape every running agent presents to its Session: `AgentCommands` in, `CommandResult` back, `AgentEvent` out, in the event vocabulary pi-axo defined |
| `command` | The configured `agent.command` |
| `lock` | `WriterLock`: the exclusive `flock` on `<transcript>.jsonl.lock`. axod takes it and the agent inherits it, so holding it proves no agent for the Session is alive |
| `lifeline` | Re-exports `axo_pty::lifeline`: the pipe every agent inherits (`AXO_LIFELINE_FD`), whose read end reaches end of file when axod exits, however it exits |
| `process` | `ProcessIdentity`: a pid and its start time, stored per Session so axod can kill, at boot, an agent a previous axod left behind, and never a reused pid |
| `history`, `activity` | Recognising the transcript Axo created, and a Session's status from what its agent reports |
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
