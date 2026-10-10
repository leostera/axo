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
- Request IDs are correlation only; durable start `CommandId`/normalized launch receipts retain their existing conflict/reconciliation semantics. Reconnect repeats protocol negotiation/registration, never prompts, input or launch requests.
- Response source generation is current, but historical runtime references are not rewritten. Reading/reconciling a completed receipt after reboot does not create another process.
- Cloud expiry/disconnect cannot stop local children. Relay WebSocket messages/buffers/writes are bounded; connection liveness is not Pi admission or proof of descendant cleanup. Local JSON-RPC remains usable independently. The Unix listener and legacy envelope are removed.

**Residual limits:** local OS-user authorization, admitted Pi/session APIs, production backoff/rotation policy and bounded DNS resolution remain unfinished. Access is the current cloud edge gate, not a new application account/auth platform. This adapter is not a Mac/phone ownership cutover or production availability guarantee.

## Launch intent and persistence

- `Manager::start` serializes reconciliation, admission, durable intent, and process registration under the terminal-catalog mutex. Shutdown fences new admission before capturing owned terminals.
- A command receipt binds the original target, launch fingerprint, and runtime. `Journal::prepare` itself rejects conflicting reassignment; identical direct retries leave the receipt/disposition unchanged. Manager reconciliation must precede any new spawn.
- Child exec inherits only standard descriptors: known daemon resources have CLOEXEC, and the fork child additionally closes the inherited nonstandard table, including library-created descriptors. The Darwin kernel allocation ceiling is captured before fork and bounded to 1,048,576; unsupported bounds reject before fork, unexpected close failures exit before exec. Kernel limits are not changed by this daemon. Only prepared memory and libc operations are used after fork.
- Starting intent is durably committed before `forkpty`. After spawn, the daemon retains the terminal and starts drain/reaper workers even when its Running commit fails. Receipt reconciliation does not launch another child.
- Journal updates require the exact runtime and a legal transition. Completed records cannot be resurrected or have their exit status rewritten. A conservative recovery record can become a proven exit only through the same live runtime's completion path.
- Failed rename/fsync has an uncertain on-disk outcome. The journal fences subsequent mutations, not just that write. Completion persistence records failure explicitly rather than silently treating an ignored error as success.
- Version 2 requires the current completion contract. Version 1 is refused without rewriting its claims. This is a private daemon journal, not the existing Mac workspace registry.

## Child and terminal completion

- `ChildPid` validates positive kernel PID values; it does **not** prove ownership. Nonzero signals and `waitpid` operate only on live terminal state under the same state mutex. A reaped PID cannot receive a later termination/escalation signal.
- `TerminalSize` validates both dimensions once at the resize boundary before the PTY operation. The native helper never receives an unchecked size.
- Reaping a child and reaching terminal EOF are independent events. Neither alone proves clean completion. `OutputState` distinguishes normal closure from failure; `CompletionPersistence` distinguishes pending, recorded, and failed persistence.
- Clean completion requires reaping, normal terminal closure, and an absent initial process group. Signal 0 is an existence/permission probe, not a delivered signal. Unknown/present groups remain recovery-required; numeric group reuse can cause conservative rejection, never kill/adoption.
- macOS may hang up terminal I/O when its session leader exits while descendants remain alive. EOF must not erase the group-membership check.
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
- Local connections include pending handshakes in the 16-worker cap. Upgrade headers have an absolute two-second deadline/8-KiB bound; messages, batches, call rate, reply credits and writes are bounded. Failed credit admission precedes dispatch; oversized post-dispatch replies remain outcome-unknown.

**Residual limits:** mutex poisoning and worker-thread creation failure still need an explicit operational failure policy; signal-handler registration/lifetime and socket-startup cleanup need further hardening. These are not proven safe by happy-path tests or by stronger identity types.

## Evidence boundary

Rust tests validate constructors, state/receipt boundaries, completion orderings, persistence failures, and frame/cache limits. Python integration tests exercise isolated real daemon/PTY processes, including a surviving descendant. The isolated API suite additionally runs a library-backed dummy network client through a real Worker/workerd to two actual daemon/PTY owners, with duplicate receipts, cold restart and post-cloud-loss progress. Hibernation tests inspect SQLite correlation and restore healthy sockets; full service restart verifies persisted registration without phantom routes. This establishes the standalone relay slice, not current application relay ownership, vanilla Pi admission, terminal-state reconstruction, Ghostty fidelity, native app/physical-phone acceptance or live-hostname deployment.
