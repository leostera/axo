# axod

Axo's standalone per-user Rust session-manager daemon. Active implementation and hardening happen here, not in new POCs. `axod` directly owns terminal children and PTYs; no tmux, screen, or Zellij backend is used.

**Current boundary:** newly built Mac app bundles now run an Axod-only shell with this bundled daemon and a private state directory at `~/Library/Application Support/Axo/Axod` (no versioned directory suffix). The app reads daemon work/runtime metadata; it does not attach Ghostty, admit Pi sessions, or import the legacy workspace registry/history. Unsupported Mac features are intentionally absent until Axod capabilities replace them. This does not migrate, stop, adopt, or rewrite existing work in an already-running app. The iOS and legacy service/file lanes remain separate.

On first app launch, Axo registers the main app as a user-level macOS login item using `SMAppService`. At login, macOS opens Axo, which starts the bundled daemon. `axod` is not independently registered as a LaunchAgent or LaunchDaemon; approval may be required in System Settings. Direct daemon startup independent of Axo remains a separate future decision.

## Build and validate

Currently macOS-only; tested using Rust 1.99.0. Run from this directory:

```sh
cargo build --locked
cargo fmt --check
cargo test --locked --offline
cargo clippy --locked --offline --all-targets -- -D warnings
# Dedicated real-daemon RPC/process and local/cloud parity tests:
npm --prefix ../sites/api.axo.leostera.dev run test:axod
# Full API/JWT/hibernation suite:
npm --prefix ../sites/api.axo.leostera.dev test
```

The [coverage guide](tests/README.md) separates domain/process tests, exposed-RPC coverage and remaining RFD gates. `tests/managed_public.rs` now joins actual `axo`/`axod serve` to ambient Pi TUI/tools/history on local RPC and an actual isolated Worker cloud route. See [managed Pi setup and limits](MANAGED_PI.md). `npm run test:pi-interactive` separately exercises 24 real TUI/native-PTY cases through a transitional fixture adapter, without a visual terminal. Offline commands require cached dependencies. Rust lifecycle tests use owned, disposable real Python terminal children in private temporary directories; these generic fixtures are not Pi transcripts or native application acceptance.

## Run explicitly

```sh
state="$(mktemp -d /tmp/axod-local.XXXXXX)"
chmod 700 "$state"
cargo run --locked -- serve "$state"
```

`serve` runs in the foreground and publishes `local-endpoint.json`, `machine-id.json` and `owner.lock`; mutations also create `runtime-state.json`. The absolute state directory must already exist, belong to this OS user, and deny group/other access. Discovery is atomically published as an owned single-linked mode-0600 regular file (at most 4 KiB). It contains only version, protocolVersion, endpoint, machineId and hostGeneration—**no local credentials**.

The local endpoint is `ws://127.0.0.1:<ephemeral-port>/v1/rpc`. Native clients read private discovery, connect with no authentication header, negotiate profile 1 and acknowledge consumed replies. Exact Host/path checks and rejection of every Origin header prevent browser/rebinding access; they are **not application authentication or an OS-user authorization boundary**. Routing UUIDs are not credentials. This intentionally credential-free development transport was explicitly requested; do not expose it on a public interface or claim hardened multi-user isolation. The Unix listener and legacy command envelope have been removed. Native Ghostty attachment is not implemented.

SIGINT/SIGTERM stop accepting launches, request termination of owned child process groups, escalate after one second, and wait boundedly for child reaping/journal completion. Disconnecting a client never requests process termination. **General shell job-control/descendant cleanup is not complete:** a shell's additional process groups or deliberately detached descendants are not covered by the initial group signal. Do not use this slice for production workloads or assume host/OS crash survival.

A duplicate live daemon cannot acquire the directory lock. A new boot under that lock can replace an old private discovery file; corrupt machine identity or unsafe discovery metadata fails closed. Controlled cleanup removes discovery only if its inode still belongs to this publication. After an abrupt host crash, inspect surviving work; never restart uncertain children or signal historical PIDs. Process IDs alone cannot prove ownership across daemon generations.

The private runtime journal is now **version 2**: version 1 could record an exit before terminal/process-group completion was established, so it is rejected rather than silently trusting or migrating those claims. This changes no Mac workspace-registry format. Do not remove a journal to bypass recovery while old work may still survive.

## Opt-in private relay

```sh
cargo run --locked -- serve /absolute/private/state-directory \
  --relay-config /absolute/private/relay.json
```

Configuration must be an absolute, owned, single-linked regular mode-0600 file, with no symlink and at most 64 KiB. Do not put credentials in argv/environment or print them. Example shape (placeholders, not configured credentials):

```json
{
  "relay_url": "wss://api.axo.leostera.dev/",
  "label": "Development machine",
  "credentials": {
    "kind": "service_token",
    "client_id": "OPERATOR_CONFIGURED_ACCESS_CLIENT_ID",
    "client_secret": "OPERATOR_CONFIGURED_ACCESS_CLIENT_SECRET"
  },
  "profiles": {
    "approved": {
      "directory": "/absolute/approved/workspace",
      "argv": ["/absolute/approved/program"]
    }
  }
}
```

This creates a stable private `machine-id.json` before cloud registration; corruption fails closed instead of regenerating another identity. The daemon opens outbound authenticated WSS, negotiates [shared JSON-RPC profile 1](../protocol/README.md), registers itself automatically, and heartbeats its fresh connection lease. Reconnect repeats **registration only**, never execution calls. Cloud/network/Access loss leaves local processes and local JSON-RPC usable. The API now has a separately approved private Cloudflare canary; see its README for the live acceptance checkpoint.

The cloud can request bounded runtime metadata and launch only an operator-configured named profile. It cannot supply argv/cwd, attach a terminal, transport raw terminal bytes or signal historical PIDs. The explicit Pi policy below also permits addressed managed chat controls and canonical reads through the same owner. Both adapters use the same `Manager` and durable launch receipts. A current response source generation does not rewrite historical terminal references, and receipt reconciliation can return a previously exited runtime without spawning again.

For isolated tests only, a numeric-loopback `ws://127.0.0.1:PORT/` or IPv6 loopback base URL requires `allow_insecure_loopback: true`. An ephemeral `credentials: {kind: "access_assertion", assertion: "..."}` is also supported for bounded test/tool sessions; it does not auto-refresh. Real provisioning should use Access service-token credentials. URL userinfo/query/fragment, redirects, non-loopback plaintext and invalid credential headers are rejected.

The Rust adapter uses `tungstenite` with native-root-validated Rustls and an explicitly selected AWS-LC crypto provider (including P-521 certificate signatures), bounded frames/write buffers and timeouts. The live Access-protected route passed supervised registration, metadata/list, approved fixture launch, receipt reconciliation, client reconnect and cold-restart fencing on 2026-10-10; see the [deployed evidence](../sites/api.axo.leostera.dev/README.md#deployed-connectivity-evidence--2026-10-10). DNS resolution and fixed retry/backoff/credential rotation remain operational hardening work; this is not a production startup/availability guarantee. Configuration remains local and is not stored in the runtime journal or passed into children.

The [API test suite](../sites/api.axo.leostera.dev/README.md) runs the dummy network client through a real Worker/workerd to two actual daemon processes and PTYs, including restart/receipt/cloud-loss checks. No live Mac state, existing relay deployment or Pi transcript is involved.

## Local JSON-RPC and profiles

Local and cloud calls use the same [`@axo/protocol` profile](../protocol/README.md), `rpc::dispatch`, approved launch profiles, `Manager` and journal. Local discovery supplies the explicit machine/host target. `axo.protocol.negotiate` must succeed before `axo.runtime.list` or `axo.runtime.startApproved`; `axo.transport.ack` is a notification acknowledging consumed reply frames. Machine registration/discovery remains a cloud service operation, not a local RPC method.

For local-only approved launches:

```sh
axod serve /absolute/private/state-directory --profiles-config /absolute/private/profiles.json
```

The owned mode-0600 bounded configuration shape is `{ "profiles": { "approved": { "directory": "/absolute/workspace", "argv": ["/absolute/program"] } } }`. Without configuration, listing is available but no profile may launch. Relay configuration can supply the shared profiles instead. If both files supply nonempty policies, they must agree; no silent local/cloud override is permitted. The caller supplies a profile ID, never arbitrary executable/argv/cwd.

A JSON-RPC ID is correlation only; `commandId` is the durable mutation identity. Same intent reconciles the original runtime, including historical completion after reboot. Conflicts fail closed, and unknown outcomes never trigger replay. Notifications do not launch work. A reply that exceeds the encoded bound after dispatch becomes bounded `-32004` outcome-unknown.

Limits: 16 connections including pending upgrades; 8 KiB upgrade headers under an absolute two-second deadline; 64 KiB text messages; batches of at most eight calls; 30 logical calls/control frames per second per connection; 32 outstanding reply frames/128 KiB and 500 ms writes. Binary messages and invalid acknowledgements close the connection. Delivery credit is checked before admitting a response-bearing mutation; client disconnect never stops work.

Internal terminal attachment/input/resize/stop operations and bounded raw output remain transport-independent manager capabilities with real PTY regressions. They are **not exposed by this JSON-RPC profile**. No terminal bytes travel through either RPC route; native terminal data-channel/rendering work remains separate.

## Private workspace/session records

The daemon opens `work-records.json` under the same exclusive state-directory lock as its runtime journal. It is a private version-1 record store, **not an importer/writer for the live Mac registry or Pi history**. `axo.workspace.list/create/rename`, `axo.session.list/get/create/rename` and read-only `axo.command.get` share this store on local and cloud RPC routes; see [the shared contracts](../protocol/README.md#implemented-methods) and [RFD0009](../docs/rfds/RFD0009-protocol-capability-parity.md#isolated-work-record-contracts).

Creation commits stable metadata only. `workspace.create` takes a `directoryId` selecting a configured profile's approved directory, never arbitrary argv/cwd; it creates no initial session and executes no program. A created session has a fresh work ID and managed Pi-pane ID, but no invented canonical Pi chat. Names are manual Axo labels, separate from Pi titles. `session.get` reports exact runtime facts independently of the actual nullable Pi chat binding and ready/stopped/failed/recovery admission state.

A global revision fences mutations and pages. Cursors also fence source, domain and workspace filter. Immutable metadata receipts and records commit together through private atomic rename/fsync. Reconciliation returns the original commit rather than a new record. `command.get` never mutates or executes; null is not rejection or replay permission, and historical runtime references stay historical. Execution/work command admission is serialized and cross-journal reuse rejects. If work/runtime/managed-Pi persistence is uncertain, all mutation domains fence further admission; accepted children still drain/run.

Caps: 128 workspaces, 1000 sessions, 2000 work receipts and 4 MiB private mode-0600 storage. Startup rejects unsafe metadata, invalid versions/bounds, inconsistent record/receipt revisions, unreceipted edits and cross-journal identity collisions. There is no implicit import, offline cache, registry cutover or native adoption. Explicit [managed Pi policy](MANAGED_PI.md) now enables nine additional session/chat methods and a private metadata-only `pi-state.json`; Pi alone remains the canonical history writer. The [implementation checklist](../docs/rfds/RFD0009-implementation-checklist.md) tracks those remaining gates.

## Local independent shell panes

[`axo.session.pane.add/remove`](PANES.md) now expose explicit create-and-launch and terminate-and-remove on the **local** RPC route only. Add creates a fresh owned shell PTY; remove captures the exact runtime and commits a tombstone only after proven native completion. `session.get/list` expose `shellPanes`; original `command.get` receipts never replay effects. The private bounded `pane-state.json` participates in shared command/storage admission. Right/down split geometry remains Mac-local; Cmd+W is explicit removal, not renderer detach. Current Mac shortcut wiring, external-PTY/Ghostty attachment and the public terminal data plane remain separate gates.

## Ownership, persistence, and bounds

- `src/model.rs`: typed UUID/client identities, validated positive child PIDs and terminal sizes, and distinct process states. `Running` means a spawned child not yet observed exited, **not admitted/ready Pi**.
- `src/pty.rs`: native `forkpty`, host-side **controller** handle, child-side exec, nonblocking I/O, resize; no Rust allocation/logging/locking in the post-fork child. Inherited `AXO_*` configuration is removed so an active parent turn cannot retarget a child.
- `src/pty.rs`: native PTY launch and sizing. The fork child closes all nonstandard descriptors before exec, including library-owned non-CLOEXEC descriptors; Darwin's kernel descriptor allocation ceiling is captured before fork and must be at most 1,048,576. Unsupported bounds fail before fork, and unexpected close failures exit without executing the profile. No post-fork Rust allocator/locking/logging is used.
- `src/runtime.rs`: terminal ownership, leases, continuous headless output drain, byte offsets/backlog, reaping, and generation checks. Reaped/fully drained terminals release their controller descriptors. PTYs still draining and uncertain process groups count against capacity even after their initial child exits. Clean completion requires the child to be reaped, terminal I/O to close normally, and the initial process group to be absent; failed I/O or uncertain group membership remains recovery-required.
- `src/work.rs` / `src/work_rpc.rs`: private daemon work records, addressed metadata mutation/read projection, bounded source/revision/filter cursors and durable metadata receipts. No writes to live Mac storage or Pi history.
- `src/panes/`: closed local shell-pane requests, durable original add/remove receipts and tombstones, shared collision/fencing and proof-gated exact-runtime completion. No layout or terminal bytes in RPC.
- `src/managed/`: validated Pi operator policy, durable intents/dispositions/bindings, approved fresh/exact-resume admission, bounded canonical projections/live/stopped reads and addressed chat controls. Cooperative managed writer leases are not unmanaged-writer exclusion.
- `src/journal.rs`: exclusive OS lock, bounded private versioned JSON, atomic rename/fsync, immutable launch receipts, checked lifecycle transitions, fail-closed uncertain persistence. Stores identities/process dispositions and launch fingerprints, **not argv, prompts, output, or Pi history**. This runtime journal is not a second writer to the Mac workspace registry.
- `src/server.rs`: one owner/bootstrap, shared execution policy, signal handling and controlled shutdown.
- `src/local.rs` / `src/bootstrap.rs`: native loopback JSON-RPC, bounded upgrade/reply handling, private boot-fenced discovery and inode-owned cleanup.
- `src/profiles.rs` / `src/private_file.rs`: shared operator policy and bounded owned-file validation.
- `src/rpc.rs`: bounded JSON-RPC codec and explicit remote method policy; domain/caller targets reach the same runtime manager, never ambient UI selection.
- `src/relay.rs`: private stable machine identity/configuration, authenticated outbound WebSocket, profile negotiation/registration, lease heartbeat and non-replaying reconnect.

Limits: 128 live terminal resources, 1000 terminal records, 2000 durable start receipts, 4 MiB journal, 16 client readers, 32 queued frames/client, 1 KiB output chunks, 8 KiB raw backlog/terminal, and 500 ms socket writes. Slow consumers lose their connection/lease, not the child or headless drain. Receipt exhaustion fails closed; eviction/retention is not silently introduced.

The internal attachment snapshot discloses `start_offset`, `next_offset`, and whether the raw backlog is `truncated`. Snapshot/backlog and live-output handoff are serialized with terminal output. Exit events follow the final drained output.

**Raw bytes are not reconstructed terminal state.** This slice does not claim alternate-screen, cursor/modes, scrollback, feature-query, graphics/image, Unicode/IME, paste, or Ghostty reconnection fidelity. Terminal bytes remain local; they must never be placed in phone relay frames.

## Review and invariants

The Leo readability/types/invariants pass established focused launch/reconciliation, RPC dispatch, local upgrade/discovery, and output/completion operations. Named outcomes replace dispatch tuples and signal booleans. See [INVARIANTS.md](INVARIANTS.md) for enforcement boundaries and residual limitations.

Regression coverage includes direct journal receipt conflicts, forbidden state transitions, failed persistence, both reaper/EOF orderings, failed terminal I/O, RPC/upgrade bounds, delivery credits, local/cloud receipt parity, and a real descendant surviving its initial terminal child. The process-group existence probe uses signal **0** (no signal is delivered); numeric reuse can only cause conservative recovery. It cannot discover descendants that escaped into another group or session, and it never authorizes signaling a reaped PID.

## Remaining implementation/hardening

1. Terminal-state ownership/snapshot/replay and headless terminal feature negotiation.
2. Harden the now-implemented managed Pi launch/chat/read path: crash windows, unmanaged writers, larger histories, observation epochs/gaps, attachments and full canonical projections; no Pi patches or transcript fabrication.
3. Complete shell job-control, descendant shutdown, unexpected I/O/reaper failures, and orphan/recovery operations, including crash drills.
4. Daemon-owned workspace/session registry compatibility and one-writer cutover/rollback; explicit launch profiles and broker/relay ownership. Do not write the current live Mac registry during standalone development.
5. Complete remaining RFD domains beyond the implemented work/Pi controls; retain simple local bootstrap and improve production backoff handling and bounded lifecycle/retention policies. Access remains the current cloud edge gate; no account/user-management system is introduced.
6. Continue the coordinated Mac attachment/client refactor and evaluate daemon startup ownership (app login item versus a registered per-user LaunchAgent) before packaging and operational acceptance. These are distinct lifecycle choices; registration must be explicit and avoid duplicate daemon owners.

See [RFD0007](../docs/rfds/RFD0007-mac-session-manager.md). Its startup/availability/persistence policy proposals are not silently accepted by this initial implementation.
