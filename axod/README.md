# axod

Axo's per-user Rust daemon owns durable session intent and native PTYs. The architectural contract is [RFD0012: Central session management in axod](../docs/rfds/RFD0012-sqlite-desired-state-and-session-materialization.md).

## Authority and startup

The bundled LaunchAgent uses `axod serve-user [--instance-id safe-id]`. Launchd alone supervises the production helper; opening a client never registers, repairs, upgrades or directly launches it.

The service claims the existing private top-level `owner.lock`, preserves the stable machine identity and opens a dedicated `CentralSessions` directory. Its private SQLite image contains the desired workspace/session/pane graph, original operations, configuration captures, runtime attempts and Pi bindings. Unsent drafts are volatile client editing buffers, never daemon storage; existing retired draft data stays unread and untouched. The auxiliary `CentralSessions/Runtime` journal holds native execution/completion evidence only: it does not open a second catalog.

This is a fresh authority, not a legacy importer. Old work catalogs, bindings, receipts, layouts, drafts and canonical histories are left untouched and unbound. Mixed storage fails closed. Supported central database schema upgrades are not legacy migration. A database cannot restore a PTY, prove an unknown writer's completion or authorize historical PID signaling.

Materialization runs independently of attached clients. Creation commits a complete Pi-and-account-shell graph before effects; each pane keeps its stable identity across completion-proven runtime successors. Archive preserves child choices. Missing policy, uncertain reservations/admission and missing canonical histories are blocked, not permissions to replay work or create another writer.

Ambient interactive vanilla Pi and the installed `pi-axo` extension use an anonymous daemon-owned control channel. There is no bundled Pi engine, `pi --mode rpc`, private Pi API, automatic installation or replacement chat identity. Pi alone writes canonical JSONL; the daemon validates exact resume bindings and holds cooperative writer leases.

## Addressed RPC

The local endpoint is `ws://127.0.0.1:<ephemeral-port>/v1/rpc`. Its bounded private discovery file contains machine and boot identity, not credentials. Host/path/Origin guards prevent browser/rebinding access; this development transport is not a hardened multi-user authorization boundary. Routing UUIDs are not credentials.

After protocol negotiation, `axo.state.get` returns the central store generation. Every subsequent central address captures machine, host and store generation. Session addresses additionally capture the explicit nullable workspace and session identity. Original command IDs, safe revisions and source-qualified cursors fence mutation and observation. Notifications never admit mutations; uncertain outcomes require read-only original reconciliation, not replay.

Central methods cover workspace/session observation and creation, lifecycle intent, shell addition/removal, original operation lookup and exact runtime completion. Results separate immutable accepted graphs from current ready/materializing/blocked/stopped observations. Local folder authority cannot become remote argv or an arbitrary execution directory. The daemon's old workspace/session/chat-start RPCs and JSON receipt stores have been removed; clients must use the central contracts, with no compatibility fallback.

The terminal plane remains separate from metadata RPC. Attachment, input, resize, acknowledgements and detach use exact runtime/attachment identities and bounded credits. Disconnect, reflow and frontend quit never change desired intent or stop daemon-owned execution. General authoritative VT recovery and host-crash survival are not established by an output backlog.

## Explicit owned PTY harness

`axod serve /absolute/private/root --profiles-config /absolute/private/profiles.json` without Pi policy is an explicit native PTY/operator harness, not session-management authority. It exposes bounded native runtime observation and operator-approved profile launch, never a workspace catalog or frontend Pi startup. It cannot reopen a central service root or a directory containing legacy catalogs.

With `--pi-config`, foreground `serve` uses the central controller. Policy files are bounded, private, owned regular files; Pi policy approves the installed extension and ambient launcher settings. Neither local nor relay clients supply argv. The production `serve-user` policy captures the account login shell/PATH and installed extension itself.

Optional relay configuration is local and credential-bearing; it must never enter argv, diagnostics or child environments. Relay reconnect repeats registration/lease establishment only, never execution. Packaging, configuration and private fixtures do not authorize deployment, installed-service changes or physical-device installation.

## Validation

From the repository root:

```sh
cargo test --manifest-path axod/Cargo.toml --locked --offline
cargo clippy --manifest-path axod/Cargo.toml --locked --offline --all-targets -- -D warnings
npm --prefix protocol test
```

See [the coverage boundary](tests/README.md). Tests use disposable owned roots, exact unreaped child handles and isolated model peers; never live user state or historical process IDs. Source validation is not packaged Mac, installed launchd, cloud-deployment, physical-input or crash-survival acceptance.
