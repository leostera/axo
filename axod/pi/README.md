# Ambient Pi dependency and intended integration

Axo depends on the **user's ambient `pi` installation**. It does not bundle, vendor, fork or patch Pi, and never uses the repository's Pi npm devDependency as a runtime fallback. There is no download, auto-update or installation behavior.

## Intended product path — not implemented yet

```text
Mac / Rust CLI / iOS
        │ Axo public JSON-RPC (local WebSocket or cloud forwarding)
        ▼
       axod ───── managed extension control channel ────┐
        │                                             │
        │ owns native PTY per pane                    ▼
        └────────────────────────────────── ambient Pi TUI
                                             + Axo extension
                                             + public Pi APIs
```

The extension runs inside **that same PTY-hosted Pi process**. Terminal keyboard/output bytes use a separate local data plane; they are neither control messages nor a source of canonical execution identity. Pi owns execution, tools/models, queues, active branch and canonical history. No Mac view owns the managed PTY/process, and closing/detaching a view must not stop accepted work.

A work session contains its managed Pi pane and can contain additional shell panes with their own PTYs. Metadata creation does not launch; the UI explicitly composes create/start/attach. Splitting does not implicitly create another Pi writer. Ghostty attachment to a daemon-owned terminal remains a feasibility gate; its pinned surface API cannot simply be assumed to accept an external PTY descriptor.

The Rust CLI integration tests must exercise **this public Axo RPC → daemon → native PTY → ambient Pi TUI + extension path**, including actual admission, canonical persistence, messages, steering, cancellation, exact resume, real tool effects and independent sessions. A Mac window is not needed to run those tests, but Pi must still run interactively in its PTY.

## Dependency discovery only

`AmbientPi.find()` captures the normal absolute launcher from PATH or an explicit operator-selected executable. It ignores npm-injected `node_modules/.bin` entries, refuses repository-local runtime paths, preserves ordinary user/package-manager launcher symlinks, bounds version probes and sanitizes dependency errors.

Version is metadata, **not a capability/readiness claim**. TUI-extension capability and exact chat/persistence/runtime admission checks remain required before execution integration is usable. No headless-RPC version baseline is imposed.

Run the six discovery policy tests from the repository root:

```sh
npm run test:pi-discovery
```

These owned probe fixtures verify lookup/version/error policy only. They are **not positive Pi execution, PTY, Rust-daemon, public-route or native acceptance evidence**.

## Removed detour

The `--mode rpc` controller and its subprocess/provider/lifecycle fixtures introduced in `c8f72f9` have been removed. There is no identified product need for a separate headless Pi RPC mode. That path bypassed the daemon-owned interactive PTY and managed extension, so it could not establish product end-to-end coverage.

The old RPC-mode findings about idle steering queues, abort retaining queued input and remotely answerable RPC dialogs are **mode-specific characterization**, not proof of TUI-extension behavior. Revalidate queue/race/cancel/question semantics using the public APIs actually exposed by the interactive extension; do not copy unsupported APIs or approval claims from the discarded controller. Historical evidence remains in Git, not as a second supported product path.

No live registry, file authority, startup, deployment or app/process ownership has changed. Implementing the above path remains the RFD0009 critical work, not a completed feature.
