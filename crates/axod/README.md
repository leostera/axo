# axod CLI (`axod`)

`axod` is the daemon's command-line entrypoint. It uses `clap` for argument parsing and delegates server startup to `axo-server`; it does not implement daemon behavior or JSON-RPC itself.

```sh
axod [--socket <absolute-path>] [--server-dir <absolute-path>]
axod --version
```

Without `--socket`, the server uses `~/Library/Application Support/Axo/run/axod.sock`. Without `--server-dir`, it stores `axo.pid`, `stdout.log`, and `stderr.log` under `~/.axo/server/`. It uses `HOME` when absolute and falls back to the current account's home directory when LaunchAgent environments omit it. The directory is private to the user; logs include timestamps, levels, and stable lifecycle event names, append across launches, and rotate to one `.log.1` backup on startup when larger than 10 MiB. `--server-dir` is useful for isolated tests and local runs.

The PID file is diagnostic metadata, not a process-control mechanism: launchd remains the source of truth for service lifetime, and a forced kill may leave a stale PID file until the next successful start replaces it. On macOS, `SMAppService` registers the bundled executable as a per-user LaunchAgent; launchd owns its process lifetime.

## Cloudflare host relay

The packaged LaunchAgent supplies the Axo API URL. Axod attempts to connect automatically when it starts and retries with backoff; **Axo.app → Settings → Remote Access** reports the actual relay connection state and lets you request an immediate retry. The host name is read from existing local host metadata (or the system hostname on first setup), and the platform is reported as macOS. There is no API URL or editable host-name setup in the app.

The daemon derives its stable host ID from its private session database and rotates the host generation at each daemon-process start. It connects to `/v1/hosts/<host-id>/daemon` over TLS, registers terminal-free session metadata, sends periodic heartbeats, and streams activity/output events without retaining them in Cloudflare storage. Local PTYs remain owned by `axod`; closing the Axo.app UI detaches the terminal view but does not stop the LaunchAgent or its PTYs. Restarting the daemon itself does stop those processes, after which Axod restores session records by starting replacement shells.

A failed Pi recovery is isolated to its pane: Axod stays available, retains the session and transcript, and reports the pane as unavailable. **Settings → Agent → Automatically restart unavailable Pi sessions** retries recovery for each affected pane. Automatic retries are safe-only: Axod starts a replacement when the transcript lock is free, or asks the exact authenticated Pi bridge to shut down only if Pi reports idle. Busy or unresponsive Pi processes are never force-stopped automatically; their panes remain unavailable and Axo keeps retrying while the option is enabled. The pane's **Restart Pi** action remains an explicit, pane-scoped recovery: it first authenticates to the Pi bridge and requests shutdown. If that bridge is unavailable, the explicit restart may identify the exclusive transcript-lock owner, but only when the lock is held by one process group owned by the current user and led by `pi`. Axod then sends SIGTERM and, if necessary, SIGKILL only to that verified group. Axod acquires the original transcript lock before starting any replacement; it never overwrites the conversation history.

For isolated loopback tests only, the relay supports `allowInsecureLoopback: true` with a `ws://localhost`/loopback URL and `access: { "kind": "accessAssertion", "assertion": "<fixture JWT>" }`; never use that test mode on a non-loopback endpoint.
