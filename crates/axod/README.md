# axod CLI (`axod`)

`axod` is the daemon's command-line entrypoint. It uses `clap` for argument parsing and delegates server startup to `axo-server`; it does not implement daemon behavior or JSON-RPC itself.

```sh
axod [--socket <absolute-path>] [--server-dir <absolute-path>]
axod --version
```

Without `--socket`, the server uses `~/Library/Application Support/Axo/run/axod.sock`. Without `--server-dir`, it stores `axo.pid`, `stdout.log`, and `stderr.log` under `~/.axo/server/`. It uses `HOME` when absolute and falls back to the current account's home directory when LaunchAgent environments omit it. The directory is private to the user; logs include timestamps, levels, and stable lifecycle event names, append across launches, and rotate to one `.log.1` backup on startup when larger than 10 MiB. `--server-dir` is useful for isolated tests and local runs.

The PID file is diagnostic metadata, not a process-control mechanism: launchd remains the source of truth for service lifetime, and a forced kill may leave a stale PID file until the next successful start replaces it. On macOS, `SMAppService` registers the bundled executable as a per-user LaunchAgent; launchd owns its process lifetime.

## Runtime and attachment invariants

- A durable pane ID is not a process identity. Each launch gets a daemon-local runtime ID; attachment output/detachment, Pi bridge metadata/activity, and resume requests are checked against that runtime. Late callbacks from a replaced process cannot modify its replacement.
- Accepted terminal sockets explicitly use bounded blocking I/O, including on macOS where accepted sockets can inherit the listener's nonblocking mode. Stalled replay writes release their attachment lease; idle attachments observe shutdown and runtime replacement.
- Child wait failures are reported once per runtime and isolated from other children. An uncertain child remains represented; Axod does not infer completion or signal a possibly reused PID after losing wait ownership.
- Shutdown drains runtime ownership before slow child cleanup, without holding the catalog mutex while waiting for processes. Cleanup is idempotent, avoids joining its own worker, and retains cleanup responsibility if a background cleanup thread cannot start.
- Only the intended Pi child inherits its transcript writer lock across exec. The parent keeps close-on-exec set throughout launch so unrelated child processes cannot accidentally retain that lock. No transcript content is rewritten by these lifecycle operations.
- Pi recovery reserves only the unavailable pane, snapshots its launch inputs, then releases the catalog mutex before connecting, waiting for writer ownership, or executing the replacement. Duplicate recovery returns a retryable error. Startup restore and archived-session resume use this same path; restoring an already represented pane never replaces its runtime.
- Close/removal and shutdown invalidate recovery reservations. Waits poll cancellation, force-signal dispatch is ordered with cancellation under a short catalog guard, and a launch completing after invalidation is cleaned up outside the mutex rather than resurrecting its pane. A previously dispatched graceful shutdown cannot be recalled. Failed recovery releases its reservation without removing the unavailable pane.
- Recovery requires a unique persisted owner and an existing regular history file inside Axo's private history directory; leaf symlinks, missing history, and history inode/device changes while takeover waits are rejected. Writer-lock opens reject symlinks and nonregular files. Credentials rotate only after exclusive writer ownership and history revalidation.
- Pi takeover connect/read phases share an absolute two-second deadline, including partial records and unrelated events; writes have independent bounded timeouts. Bridge-worker connects are also bounded and cancellation-aware, including a full listener accept queue. `/resume` validates target availability and archives its requester in one catalog transition.

See [recovery hardening evidence and remaining boundaries](../../docs/axod-recovery-hardening.md) for verification and follow-up scope.

These guarantees do not make a daemon restart transparent: restarting Axod still replaces its PTYs/processes. Automatic Pi recovery remains idle-only and non-forcing, and restoration can leave a pane unavailable when the original transcript or safe writer ownership is unavailable.

## Cloudflare host relay

The packaged LaunchAgent supplies the Axo API URL. Axod attempts to connect automatically when it starts and retries with backoff; **Axo.app → Settings → Remote Access** reports the actual relay connection state and lets you request an immediate retry. The host name is read from existing local host metadata (or the system hostname on first setup), and the platform is reported as macOS. There is no API URL or editable host-name setup in the app.

The daemon derives its stable host ID from its private session database and rotates the host generation at each daemon-process start. It connects to `/v1/hosts/<host-id>/daemon` over TLS, registers terminal-free session metadata, sends periodic heartbeats, and streams activity/output events without retaining them in Cloudflare storage. Local PTYs remain owned by `axod`; closing the Axo.app UI detaches the terminal view but does not stop the LaunchAgent or its PTYs. Restarting the daemon itself does stop those processes, after which Axod restores session records by starting replacement shells.

A failed Pi recovery is isolated to its pane: Axod stays available, retains the open Session and transcript, and reports the pane as unavailable. An unexpected Pi process exit also leaves the Session and Pi pane open-but-unavailable; it does not archive the Session or its sibling panes. **Settings → Agent → Automatically restart unavailable Pi sessions** retries recovery for each affected pane. Automatic retries are safe-only: Axod starts a replacement when the transcript lock is free, or asks the exact authenticated Pi bridge to shut down only if Pi reports idle. Busy or unresponsive Pi processes are never force-stopped automatically; their panes remain unavailable and Axo keeps retrying while the option is enabled. The pane's **Restart Pi** action remains an explicit, pane-scoped recovery: it first authenticates to the Pi bridge and requests shutdown. If that bridge is unavailable, the explicit restart may identify the exclusive transcript-lock owner, but only when the lock is held by one process group owned by the current user and led by `pi`. Axod then sends SIGTERM and, if necessary, SIGKILL only to that verified group. Axod acquires the original transcript lock before starting any replacement; it never overwrites the conversation history.

For isolated loopback tests only, the relay supports `allowInsecureLoopback: true` with a `ws://localhost`/loopback URL and `access: { "kind": "accessAssertion", "assertion": "<fixture JWT>" }`; never use that test mode on a non-loopback endpoint.
