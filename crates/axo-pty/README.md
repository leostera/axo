# axo-pty

Pseudo-terminals for axod: launching programs on a PTY, the permanent output pump that fans a PTY's output out to any number of subscribers, and attach protocol v2.

| Module | Owns |
| --- | --- |
| `process` | `PtyProcess`: opening a PTY (retrying the kernel's `EREDRIVEOPEN` race), launching a session leader on it, resizing, input, `stop_all` |
| `output` | `TerminalOutput`: the one pump per shell that feeds every byte to its headless terminal (`axo-vt`), publishes it, and fans it out |
| `attach` | Attach protocol v2, both ends: replay length, the PTY master over `SCM_RIGHTS`, then replay and live bytes |
| `command` | Configured command lines (`shell.command`, `agent.command`) and finding their executables |

## Rules

- Only the pump reads a PTY master; attached clients get the descriptor for input, resizing and termios queries only.
- The pump never blocks on a client. A subscriber more than its backlog behind is disconnected and reattaches from a replay.
- Subscribing is atomic with recording: replay plus live chunks equals the whole stream, with no gap and no duplicate.
- Every descriptor axod creates is close-on-exec; a child inherits only its PTY and what `SpawnOptions::inherit` lists.

## Build and test

```sh
bazel build //crates/axo-pty
bazel test //crates/axo-pty:axo_pty_tests
```
