# Axo D CLI (`axod`)

`axod` is the daemon's command-line entrypoint. It uses `clap` for argument parsing and delegates server startup to `axo-server`; it does not implement daemon behavior or JSON-RPC itself.

```sh
axod [--socket <absolute-path>] [--server-dir <absolute-path>]
axod --version
```

Without `--socket`, the server uses `~/Library/Application Support/Axo/run/axod.sock`. Without `--server-dir`, it stores `axo.pid`, `stdout.log`, and `stderr.log` under `~/.axo/server/`. The directory is private to the user; logs include timestamps, levels, and stable lifecycle event names, append across launches, and rotate to one `.log.1` backup on startup when larger than 10 MiB. `--server-dir` is useful for isolated tests and local runs.

The PID file is diagnostic metadata, not a process-control mechanism: launchd remains the source of truth for service lifetime, and a forced kill may leave a stale PID file until the next successful start replaces it. On macOS, `SMAppService` registers the bundled executable as a per-user LaunchAgent; launchd owns its process lifetime.
