# Ambient Pi dependency and intended integration

Axo depends on the **user's ambient `pi` installation**. It does not bundle, vendor, fork or patch Pi, and never uses the repository's Pi npm devDependency as a runtime fallback. There is no download, auto-update or installation behavior.

## Selected product path — initial public RPC wiring implemented

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

`tests/managed_public.rs` now exercises **this public Axo RPC → daemon → native PTY → ambient Pi TUI + extension path**, including actual admission, canonical persistence, messages, steering, cancellation, exact resume and real tool effects. A Rust-owned peer through the real isolated Worker also admits an independent actual Pi and verifies its tool effect. See [managed setup/contracts/remaining gates](../MANAGED_PI.md). A Mac window is not needed to run those tests, but Pi must still run interactively in its PTY.

## Real interactive PTY battery

```sh
npm run test:pi-interactive
```

This builds `axod/examples/interactive-pi-fixture.rs`, a **test-only process adapter around the production Rust `Manager`, journal, supervision and native `forkpty`**. It is not an installed endpoint, public RPC implementation, product CLI or substitute Pi agent harness. The adapter starts the user's ambient CLI with terminal stdin/stdout; tests assert public `ctx.mode === "tui"`, both `isTTY` flags and Pi PID equality with the Rust-owned child. It does not select print, JSON or RPC mode.

`Manager::start_with_control` returns an anonymous socket endpoint only to its execution owner. The explicit managed child gets its paired endpoint at fd 3; all other nonstandard inherited descriptors still close before exec. The channel is a distinct immutable launch intent in the journal fingerprint, not a terminal-view attachment or a reconnectable registration URL. Generic launches inherit no such descriptor. [`pi-axo/index.ts`](../../pi-axo/index.ts) activates only with the explicit managed flag during `session_start`; it binds the captured runtime reference to actual public Pi chat state. Public `sendUserMessage`, steering, abort, lifecycle, UI-wait and read-only session APIs operate **inside that same interactive process**. No listener, local credentials, private Pi APIs, transcript writer or replacement execution loop is added.

The 24 actual interactive tests pass after relocation to `pi-axo/`; the preceding 23-case battery also passed two full consecutive runs. They cover:

- TUI/TTY/process proof, real readiness, idle reads without model calls.
- Extension messages, Unicode canonical entries, real bash side effects, terminal input reaching the same chat, explicit steering and normal/busy rejection.
- Stream and real-tool cancellation, sibling isolation, real interactive selectors, cancellation never approving and actual terminal-key selection (not a fabricated remote answer API).
- Resize, terminal detach/reconnect while work completes, no-view output draining, bounded backlog, stop, Pi-initiated shutdown and terminal EOF/reaping.
- Exact resume preserving IDs/file/tree without replay, invalid bindings/symlinks preserving originals, independent cwd/history and same-pane duplicate writer rejection.
- Stale destinations, concurrent dispatch, malformed/capacity rejection, provider error after dispatch, a real input hook consuming a void send without fabricated execution/replay, and control-fd exclusion in real tool children.

Models use a controlled loopback-only provider installed through public Pi APIs. Tools, TUI, agent loop, queues, events and persistence are real Pi. Private HOME/settings/session roots keep actual user credentials and live history out of fixtures. Terminal output drains through the real manager and is only counted/discarded, **never parsed for readiness, identity or outcomes**. Canonical history is read on explicit demand. Test failure diagnostics do not dump terminal/transcript bodies; teardown stops only owned handles/groups and removes owned roots.

**Observed mode difference:** interactive `ctx.abort()` removes queued steering from execution; the regression verifies it is not delivered after a subsequent explicit normal send. The discarded headless RPC behavior was not interchangeable. Dispatch acknowledges only `dispatched` because public extension send/abort APIs return void; lifecycle/canonical evidence establishes execution/settlement separately.

**Limits:** these tests reach the production Rust PTY manager and actual TUI extension directly through fixture-owned framing. This 24-case battery itself does **not** route Pi controls through public WebSockets/CLI; the new `tests/managed_public.rs` proves the initial production local/cloud path separately. Full observation/history/operational parity remains open. The example's resume prechecks are fixture policy, not production admission. Per-pane writer exclusion is not proof against arbitrary different-pane/unmanaged writers opening one file. Ghostty rendering, crash/spawn/fsync windows, escaped descendants, client/cloud failure recovery and production supervision still have separate gates.

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

The old RPC-mode findings about idle steering queues, abort retaining queued input and remotely answerable RPC dialogs are **mode-specific characterization**, not proof of TUI-extension behavior. The interactive battery above now verifies the selected public APIs and has already demonstrated different cancellation behavior. Do not copy unsupported APIs or generic remote-approval claims from the discarded controller. Historical evidence remains in Git, not as a second supported product path.

No live registry, file authority, startup, deployment or app/process ownership has changed. The initial path is implemented and isolated acceptance passes; remaining RFD0009 observation, attachment, namespace/data-plane, writer/crash and operational gates still block completion/Mac handoff.
