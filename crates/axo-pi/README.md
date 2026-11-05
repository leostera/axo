# axo-pi

Pi processes for axod: launching Pi for a Session, the transcript writer lock that proves whether one is alive, its bridge socket, the bridge protocol and transport, and taking a transcript over from a running Pi. It knows nothing of the catalog; callers decide which Pi to launch and what its events mean.

| Module | Owns |
| --- | --- |
| `launch`, `command` | Launching Pi on a PTY for a Session, from the configured `agent.command`; `STOP_GRACE` |
| `lock` | `WriterLock`: the exclusive `flock` on `<transcript>.jsonl.lock` every Pi holds. Holding it proves no Pi for the Session is alive |
| `socket` | `BridgeSocketPath`: where a Pi's bridge listens, and cleaning up after a Pi that died |
| `protocol` | The bridge protocol shared with `packages/pi-axo/src/protocol.ts` |
| `bridge`, `connection` | The bridge transport, and the connection as a state machine: authenticate, bind to the exact pane, then one ordered event stream |
| `worker` | Following one running Pi for as long as it is its pane's current process; `CommandSender` |
| `takeover`, `process_inspection` | Taking a transcript from a Pi that holds it: ask over the bridge, and on explicit restart signal only the verified Pi process group |
| `history`, `activity` | Recognising the transcript Axo created, and what a Pi is doing |

## Rules

- Only the intended Pi inherits its writer lock across exec; every other descriptor stays close-on-exec.
- Takeover never signals a process it has not verified: one process group, owned by this user, led by `pi`, holding the lock. Inspection is bounded in time and output and never logs tool output.

## Build and test

```sh
bazel build //crates/axo-pi
bazel test //crates/axo-pi:axo_pi_tests
```
