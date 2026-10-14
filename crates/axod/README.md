# Axo D CLI (`axod`)

`axod` is the daemon's command-line entrypoint. It uses `clap` for argument parsing and delegates server startup to `axo-server`; it does not implement daemon behavior or JSON-RPC itself.

```sh
axod [--socket <absolute-path>]
axod --version
```

Without `--socket`, the server uses `~/Library/Application Support/Axo/run/axod.sock`. On macOS, `SMAppService` registers the bundled executable as a per-user LaunchAgent; launchd owns its process lifetime.
