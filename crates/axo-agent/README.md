# axo-agent

Everything axod knows about running a coding agent for a Session. Pi is the only agent today. The goal is one crate that launches, supervises and steers any agent (Pi, Codex, Claude Code, OpenCode) and turns its session into ATXF records, so nothing above it knows which agent runs; see AXP's `agent` extension (`axp/extensions/agent.md`).

Today it holds Pi processes for axod: launching Pi for a Session, the transcript writer lock that proves whether one is alive, its bridge socket, the bridge protocol and transport, and taking a transcript over from a running Pi. It knows nothing of the catalog; callers decide which Pi to launch and what its events mean.

| Module | Owns |
| --- | --- |
| `command` | The configured `agent.command` |
| `lock` | `WriterLock`: the exclusive `flock` on `<transcript>.jsonl.lock`. axod takes it and the agent inherits it, so holding it proves no agent for the Session is alive |
| `takeover`, `process_inspection` | Taking a transcript from an agent that holds it: ask it to shut down, and on explicit restart signal only the verified process group. Asking still goes through Pi's bridge |
| `history`, `activity` | Recognising the transcript Axo created, and a Session's status from what its agent reports |
| `pi` | Pi itself: `launch` (Pi on a PTY with the pi-axo extension; `STOP_GRACE`), `socket` (`BridgeSocketPath`), `protocol` (shared with `packages/pi-axo/src/protocol.ts`), `bridge` and `connection` (the transport, and the connection as a state machine), `worker` (following one running Pi; `CommandSender`), `pi3` (record identity and hashing for Pi files, the upload's wire format, shared with `packages/axo-api/src/pi3.ts`) and `TranscriptFile` (a Session's Pi file read and hashed for upload; `transcript_chain`) |

Code outside `pi` is meant to serve any agent; a second agent gets a module beside `pi`. There is no `Agent` trait yet: it will be drawn from what Pi and the second agent share.

## Rules

- Only the intended Pi inherits its writer lock across exec; every other descriptor stays close-on-exec.
- Takeover never signals a process it has not verified: one process group, owned by this user, led by `pi`, holding the lock. Inspection is bounded in time and output and never logs tool output.

## Build and test

```sh
bazel build //crates/axo-agent
bazel test //crates/axo-agent:axo_agent_tests
```
