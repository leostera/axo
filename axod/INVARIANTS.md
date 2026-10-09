# axod ownership invariants

This is an enforcement map, not a claim that the daemon is production-ready. The Mac app remains an independent lane; no live registry, broker, or packaging cutover is authorized here.

## Identity and admission

- Every mutation carries an explicit target/runtime/attachment. Distinct UUID types prevent mixing session, pane, host, runtime, attachment, and command identities in Rust. Socket decoding rejects malformed UUIDs and unknown fields; there is no ambient selected-session target.
- Host/runtime generations are checked before accessing a live terminal. A connection-owned attachment gates input, resize, and detach. A stale reference cannot be retargeted to the pane's successor.
- `ClientId` is a local connection identity, not a Pi conversation or user capability. The private socket admits the same OS user; this is not a sandbox against that user's code.
- Read-only metadata and restart loading never spawn, execute, adopt, or replay work. A fresh boot treats unfinished records as recovery-required.

## Launch intent and persistence

- `Manager::start` serializes reconciliation, admission, durable intent, and process registration under the terminal-catalog mutex. Shutdown fences new admission before capturing owned terminals.
- A command receipt binds the original target, launch fingerprint, and runtime. `Journal::prepare` itself rejects conflicting reassignment; identical direct retries leave the receipt/disposition unchanged. Manager reconciliation must precede any new spawn.
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
- Client queues, reply caches, frame sizes, terminal backlog, live resources, and persistent records have explicit bounds. Repeated stop requests schedule only the first escalation worker. Slow consumers lose their lease/connection, not the terminal child.
- Per-connection request retries reconcile a cached response. Conflicting/evicted IDs never execute again. This does not authorize input replay after reconnect or retrying a partial PTY write implicitly.

**Residual limits:** mutex poisoning and worker-thread creation failure still need an explicit operational failure policy; signal-handler registration/lifetime and socket-startup cleanup need further hardening. These are not proven safe by happy-path tests or by stronger identity types.

## Evidence boundary

Rust tests validate constructors, state/receipt boundaries, completion orderings, persistence failures, and frame/cache limits. Python integration tests exercise isolated real daemon/PTY processes, including a surviving descendant. Neither establishes vanilla Pi admission, terminal-state reconstruction, Ghostty fidelity, relay ownership, or native app acceptance.
