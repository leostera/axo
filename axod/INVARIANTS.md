# axod ownership invariants

This is an enforcement map, not a claim that the daemon is production-ready. The Mac app remains an independent lane; no live registry, broker, or packaging cutover is authorized here.

## Identity and admission

- Every mutation carries an explicit target/runtime/attachment. Distinct UUID types prevent mixing session, pane, host, runtime, attachment, and command identities in Rust. Socket decoding rejects malformed UUIDs and unknown fields; there is no ambient selected-session target.
- Host/runtime generations are checked before accessing a live terminal. A connection-owned attachment gates input, resize, and detach. A stale reference cannot be retargeted to the pane's successor.
- `ClientId` is an internal terminal consumer identity, not a Pi conversation or user capability. The local RPC listener is intentionally credential-free at the user's request. Numeric loopback/exact Host/path/no-Origin guards block browsers, not other local processes/users. Private discovery and UUIDs are not authentication. No hardened OS-user isolation is claimed.
- Read-only metadata and restart loading never spawn, execute, adopt, or replay work. A fresh boot treats unfinished records as recovery-required.

## Outbound relay boundary

- Stable `MachineId` is persisted privately before registration, distinct from fresh host/runtime generations. Invalid identity state fails closed; no automatic replacement UUID or historic-PID adoption occurs.
- Relay configuration is an owned, single-linked bounded mode-0600 regular file. Credential values stay outside argv/environment/logs; non-loopback plaintext, credential-bearing URLs and redirects are refused. Native-root TLS verification is retained; the explicitly selected Rustls AWS-LC provider supports P-521 CA signatures. Configuration/provider and certificate-algorithm support are regression-tested before any network credentials are used.
- Remote calls carry explicit machine/host/session/pane targets. `src/rpc.rs` checks them at the daemon boundary and invokes the same `Manager`, not a second executor or journal writer. The local WebSocket uses the identical dispatcher and approved-profile policy.
- Only a named operator-approved launch profile can start remotely. Remote argv/cwd/terminal attachment/input are not admitted. Execution notifications never run.
- Local/cloud JSON parsing agrees on a finite, Unicode-scalar domain with at most 127 nested containers. IDs/methods use UTF-16 bounds, frames use UTF-8 bytes, fractional hop IDs preserve IEEE-754 identity, integral parameter spellings are equivalent, and UUID text is strict case-insensitive RFC/nil/max form. Prototype-like dictionary keys must not silently disappear during validation. Differential/property tests enforce these boundaries.
- Relay reply groups are bounded by actual encoded single/batch wire shape, not their SQL array wrapper. Capacity reduction preserves every original hop ID as an unknown/reconcile outcome without replay or unnecessary client disconnect. Partial groups remain bounded through serialization/hibernation.
- Request IDs are correlation only; durable start `CommandId`/normalized launch receipts retain their existing conflict/reconciliation semantics. Reconnect repeats protocol negotiation/registration, never prompts, input or launch requests.
- Response source generation is current, but historical runtime references are not rewritten. Reading/reconciling a completed receipt after reboot does not create another process.
- Cloud expiry/disconnect cannot stop local children. Relay WebSocket messages/buffers/writes are bounded; connection liveness is not Pi admission or proof of descendant cleanup. Local JSON-RPC remains usable independently. The Unix listener and legacy envelope are removed.

**Residual limits:** local OS-user authorization, full Pi/session observation/attachment/operational parity, production backoff/rotation policy and bounded DNS resolution remain unfinished. Access is the current cloud edge gate, not a new application account/auth platform. This adapter is not a Mac/phone ownership cutover or production availability guarantee.

## Launch intent and persistence

- `Manager::start` serializes reconciliation, admission, durable intent, and process registration under shared command admission and the terminal-catalog mutex. Shutdown fences new admission before capturing owned terminals.
- A command receipt binds the original target, launch fingerprint, and runtime. `Journal::prepare` itself rejects conflicting reassignment; identical direct retries leave the receipt/disposition unchanged. Manager reconciliation must precede any new spawn.
- Ordinary child exec inherits only standard descriptors. An explicit `start_with_control` additionally passes its anonymous paired socket at fd 3; its parent endpoint stays CLOEXEC. Controlled/uncontrolled intent has a distinct receipt fingerprint; reconciliation cannot fabricate a replacement channel. Known daemon resources have CLOEXEC, and the fork child additionally closes the other inherited nonstandard table, including library-created descriptors. The Darwin kernel allocation ceiling is captured before fork and bounded to 1,048,576; unsupported bounds reject before fork, unexpected close failures exit before exec. Kernel limits are not changed by this daemon. Only prepared memory and libc operations are used after fork.
- Starting intent is durably committed before `forkpty`. After spawn, the daemon retains the terminal and starts drain/reaper workers even when its Running commit fails. Receipt reconciliation does not launch another child.
- Journal updates require the exact runtime and a legal transition. Completed records cannot be resurrected or have their exit status rewritten. A conservative recovery record can become a proven exit only through the same live runtime's completion path.
- Failed rename/fsync has an uncertain on-disk outcome. The journal fences subsequent mutations, not just that write. Completion persistence records failure explicitly rather than silently treating an ignored error as success.
- Version 2 requires the current completion contract. Version 1 is refused without rewriting its claims. This is a private daemon journal, not the existing Mac workspace registry.

## Work-record authority and shared command admission

- `Journal::open` acquires the exclusive directory lock before opening the private work store. Its records/receipts use a separate versioned file, not the live Mac registry or a Pi transcript. Create/rename/read cannot launch a process or invent a canonical chat identity.
- Approved `directoryId` resolves a configured directory only; no RPC accepts caller cwd/argv. Resolved canonical paths stay private. Manual names are bounded/validated independently of Pi titles; immutable session/pane/parent bindings cannot be retargeted by rename.
- One admission mutex serializes execution/work commands, with consistent admission → catalog/journal/work locking. Cross-journal command identity reuse rejects before side effects; boot also rejects persisted collisions. Work reads release their store guard before inspecting runtimes.
- Work records and their immutable normalized-intent receipt commit together. Loading validates bounded records, unique pane identities, receipt revision continuity and exact metadata reconstruction. Record edits without matching receipts fail closed.
- Failed work persistence is outcome-unknown because rename/fsync may already have committed. A fenced work or runtime store blocks new mutations in both domains; it does not stop accepted children or turn missing receipt knowledge into safe replay.
- Page cursors bind machine/boot source, global revision, domain and workspace filter. Changing any invalidates the cursor, never silently mixes pages or redirects a call. Results expose generic runtime facts separately from Pi admission.
- `command.get` reads existing work/runtime receipt evidence, never calls `start`. Original runtime references remain historical; no matching snapshot means missing observation, not new execution or completion proof.

**Residual limits:** unmanaged-writer/crash/operational Pi admission hardening, archive/duplicate/panes, live registry migration, cache/subscriptions and Swift/native work-record adoption remain separate gates. Current prototype internal names have not yet moved to `axo._.*`; prefix spelling itself will not establish caller provenance.

## Child and terminal completion

- `ChildPid` validates positive kernel PID values; it does **not** prove ownership. Nonzero signals and `waitpid` operate only on live terminal state under the same state mutex. A reaped PID cannot receive a later termination/escalation signal.
- `TerminalSize` validates both dimensions once at the resize boundary before the PTY operation. The native helper never receives an unchecked size.
- Reaping a child and reaching terminal EOF are independent events. Neither alone proves clean completion. `OutputState` distinguishes normal closure from failure; `CompletionPersistence` distinguishes pending, recorded, and failed persistence.
- Clean completion requires reaping, normal terminal closure, and an absent initial process group. Signal 0 is an existence/permission probe, not a delivered signal. Unknown/present groups remain recovery-required; numeric group reuse can cause conservative rejection, never kill/adoption.
- macOS may hang up terminal I/O when its session leader exits while descendants remain alive. EOF must not erase the group-membership check.
- Managed stopped reads, exact resume, stopped/failed admission and shell removal all require the exact Manager completion proof: durable completed disposition plus absence of owned resources. Visible exit or cached Pi readiness cannot bypass draining, persistence or group uncertainty. Cooperative writer leases explicitly unlock before FD closure; transient duplicated descriptors cannot prolong released ownership.
- Completion writers are serialized. An interim recovery record cannot overwrite a later final record; its persistence outcome describes the record actually committed, not a subsequently changed in-memory state.
- Terminal resources remain reserved while output/persistence is pending or group ownership is uncertain. Descriptor release does not imply all descendants stopped.

**Residual limit:** escaped process groups/sessions, deliberately detached descendants, and comprehensive orphan cleanup are not covered. The existence probe cannot establish their absence. A bounded service shutdown is not confirmation that all descendants died. Automatic adoption/restart remains forbidden; full job-control/recovery work is required before production use.

## Locking and asynchronous work

- Catalog admission may inspect journal or terminal state. Journal reads release their guard before acquiring terminal state. No completion writer holds terminal state while committing the journal.
- Terminal operations acquire state before the optional controller handle. The drain worker owns a separate `Arc<File>` and never holds the controller mutex while reading/polling.
- The completion-writer mutex orders journal dispositions; it takes state briefly, releases it before journal I/O, then publishes the outcome. No catalog lookup occurs from that path.
- Output and attachment/backlog publication share the state mutex, preserving contiguous offsets at the backlog/live boundary. Offset overflow fails I/O rather than wrapping.
- Client queues, reply-credit budgets, frame sizes, terminal backlog, live resources, and persistent records have explicit bounds. Repeated stop requests schedule only the first escalation worker. Slow consumers lose their lease/connection, not the terminal child.
- JSON-RPC IDs are correlation only. Exposed mutations reconcile durable command receipts, not transport acceptance. Terminal input is not exposed by this profile; future input transport must not authorize replay or retry a partial PTY write implicitly.
- Oversized or unserializable post-dispatch replies preserve every request ID and batch shape in bounded outcome-unknown errors; a null-ID replacement must not lose reconciliation identity.
- Local connections include pending handshakes in the 16-worker cap. Upgrade headers have an absolute two-second deadline/8-KiB bound; messages, batches, call rate, reply credits and writes are bounded. Failed credit admission precedes dispatch; oversized post-dispatch replies remain outcome-unknown.

**Residual limits:** mutex poisoning and worker-thread creation failure still need an explicit operational failure policy; signal-handler registration/lifetime and socket-startup cleanup need further hardening. These are not proven safe by happy-path tests or by stronger identity types.

## Interactive Pi seam

- The managed fd-3 extension activates only in an explicit interactive TUI launch, reads actual public Pi chat identity and binds controls to its captured runtime/chat. It refuses retargeting/stale contexts and blocks normal sends during execution/submission/questions; steering requires the captured active interaction. It does not start an SDK agent or parse/inject terminal text for structured controls.
- Public void send/abort APIs acknowledge dispatch, not completed execution. Lifecycle/canonical observations remain separate. Canonical files and queues belong to Pi; the extension does not synthesize transcript entries or invent a public queue-clear/remote-answer API.
- Initial public local/cloud RPC now reaches this seam with captured full destinations, approved fresh/exact-resume policy, metadata-only durable dispositions and bounded live/stopped branch projections. The private channel itself is not a capability catalogue or live-owner cutover.

## Managed public admission and chat receipts

- Validated private Pi policy separately approves work directory, session root, installed extension, captured ambient launcher and closed operator flags. Caller cwd/argv/file paths/modes are not accepted. Actual extension admission binds chat/file/cwd/TTY/model and the same native child; process-running is not readiness.
- Durable normalized preparation/intent precedes native spawn or public Pi dispatch. `pi-state.json` stores hashes/identities/original dispositions, not message or transcript bodies. Work/runtime/Pi/pane stores share admission/collision/storage fences. Accepted ownership survives uncertainty; command reconciliation never reexecutes or reinterprets changed policy.
- Current `hostGeneration` fences the request; `runtimeHostGeneration` retains the original runtime's birth identity. Fresh cannot replace an existing canonical binding. Exact resume requires that binding, a proven stopped original writer, validated public header/tree and cooperative lease; no unmanaged adoption or historical PID signal.
- Start binding and disposition commit together. Startup validates machine/work/pane membership, hashes, intent/runtime/disposition relationships, unique managed files/chats and receipt/binding reconstruction. Prepared unknown outcomes remain unknown; missing receipts do not authorize replay.
- Normal sends require ready/idle state. Steering/cancel/answer capture the active interaction and revalidate at extension dispatch. Questions block sends. Known delivery rejection differs from uncertain dispatch; a consumed void send fences recovery rather than fabricating a canonical message or retry.
- Only the public Axo-owned `axo_ask` shares offered IDs between local selector and remote answer. Remote resolution closes the sibling local selector; cancellation/abort/invalid/stale choices never grant approval. Generic public Pi UI waits are not remotely answerable permissions.
- Explicit stopped reads require proven ownership completion and reconstruct the persisted Pi resume branch by parent links, not a flattened event stream or last UI selection guess. Unsafe/missing/incomplete/changed source rejects. Bounded history/tool projections retain canonical IDs, UTF-8 byte offsets and source/mode/branch-bound cursors; no transcript writer, image/file body copy, caller filesystem path or spool-file read.
- Expiring viewing leases are bounded ephemeral metadata; original receipt reconciliation does not renew an expired lease. Client/control/cloud loss never stops accepted Pi.

**Residual limits:** managed writer leases are cooperative, not exclusion of arbitrary same-user unmanaged writers. Empty Pi sessions may not yet persist their lazy file; missing exact-resume files reject. Full compaction/plugin/spool/bidirectional/observation/attachment parity, histories beyond current file bounds, abrupt crash/power-loss/escaped descendants, retention and operational recovery remain open. Initial isolated acceptance is not Mac readiness.

## Explicit local shell-pane lifecycle

- `pane.add` is explicit create-and-launch; `pane.remove` is explicit Cmd+W terminate-and-remove, not renderer detach. Split direction/focus remain Mac-local. These are local-only methods; neither the cloud allowlist nor Rust relay dispatcher admits them.
- `pane-state.json` stores bounded pane identities, tombstones, profile IDs and original operation dispositions, not argv/geometry/bytes. Shared admission prevents work/runtime/Pi/pane command reuse; every domain checks pane storage fencing. Generic launch cannot replace a managed or tombstoned shell pane.
- The approved profile's canonical directory must match the captured work directory; launch uses that captured canonical path. Native intent precedes launch. Removal reserves exact runtime/closing intent before signals and cannot retarget the Pi pane or a sibling.
- Final removal requires a non-deserializable Manager completion witness for the exact runtime: owned resource drain/reap/group absence and recorded completion. Already-completed historical runtimes can be tombstoned without signals. Unknown completion remains prepared/closing/recovery; original reconciliation cannot repeat signals or launch effects.
- Active session panes are bounded to 32; retained identities/receipts to 1,000/2,000 and storage to 4 MiB. Session-list projections shorten with a source-bound continuation to stay within 48 KiB. Work revision is not a pane/live-process observation epoch.

**Residual limits:** original-group ownership does not prove absence of escaped/job-control descendants; deadline/uncertain prepared operations require recovery rather than fake removal. No automatic shell restoration, live Mac adoption, terminal data-plane, Ghostty rendering or abrupt crash/power-loss/retention guarantee is added. See `PANES.md`.

## Evidence boundary

`npm run test:pi-interactive` runs 24 combined tests against the ambient interactive CLI in the production Rust manager's native PTYs, with an installed public extension and controlled loopback provider. Actual tools, agent lifecycle, TUI questions, canonical history, exact resume, detach/resize, cancellation, independent sessions and fd exclusion are verified; see `pi/README.md` for scope. The 24-case run passes after relocation to `pi-axo/`; the preceding 23-case battery passed twice consecutively. That transitional battery is not public-path acceptance. Separately, `tests/managed_public.rs` now verifies actual CLI/local public admission/tools/canonical reads, questions/steering/cancel, clean restart/stopped reads/exact resume, stale/uncertain/fenced mutations, plus real isolated cloud admission/tool execution and cloud/client loss; see `MANAGED_PI.md`.

Rust tests validate constructors, state/receipt boundaries, completion orderings, persistence failures, and frame/cache limits. Property/differential tests and synthetic edge corpora compare the actual Rust codec/read admission to shared schemas; real-route regressions cover selected findings. Test-only commit-window faults, generated receipt state machines and exhaustive synthetic-store truncation establish fencing/atomic reopen evidence, not power-loss durability; see `tests/README.md`. Rust lifecycle tests exercise isolated real PTYs with Python child fixtures, including a surviving descendant; the removed Unix-envelope daemon harness is not a current validation path. The isolated API suite additionally runs a library-backed dummy network client through a real Worker/workerd to two actual daemon/PTY owners, with duplicate receipts, cold restart and post-cloud-loss progress. Hibernation tests inspect SQLite correlation and restore healthy sockets; full service restart verifies persisted registration without phantom routes. This establishes the standalone relay slice, not current application relay ownership, complete Pi failure/observation/operational parity, terminal-state reconstruction, Ghostty fidelity, native app/physical-phone acceptance or live-hostname deployment.
