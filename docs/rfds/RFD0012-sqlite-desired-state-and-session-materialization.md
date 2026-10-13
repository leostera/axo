# RFD0012 - Axo: Central session management in axod

- Feature Name: `axo-central-session-management-in-axod`
- Status: Accepted
- Start Date: 2026-10-12
- Updated: 2026-10-12
- Document Type: Proposal

## Summary

I want Axod to centrally own workspace, session, and pane state and their complete execution lifecycle. I propose a SQLite-backed desired-state store as the persistence mechanism, not as the architectural goal. On startup, Axod reads that desired graph, reconciles original operations and execution ownership, and materializes every effectively open session and pane. It then continuously reconciles desired state with actual PTY lifecycle, without depending on an attached client. Creating a workspace is one backend operation that initializes its session and panes, not a frontend sequence of catalog creation, shell creation, and Pi startup. Make `Axo.app` as thin as possible: macOS daemon management, presentation, and user input, including voice capture/transcription and an in-memory editing buffer. I keep unsent drafts only in volatile client editing buffers; I do not persist or restore them. Axod owns original submission captures once input is submitted. The app neither owns a competing catalog nor decides how to launch, restart, resume, or recover execution. SQLite owns Axo metadata, not Pi's canonical history or kernel resources. This is an accepted design, not a description of the current implementation or a claim of deployment, crash survival, or terminal-screen recovery. I start over with a fresh central store; I do not import the legacy catalogs, pane layouts, Pi bindings, operation receipts, or frontend drafts. Old data remains untouched and outside the new authority. Writing it authorizes no live service handoff, activation, or deletion of old data.

## Motivation

When using Axo, pressing ⌘T should immediately show a new session, and creating a workspace should immediately show Pi and zsh side by side. I want Axod to own the complete session lifecycle so those experiences do not depend on frontend orchestration.

If persisted state contains three open workspaces with four sessions each and three panes per session, I want Axod to materialize all twelve sessions and thirty-six panes without frontend selection or follow-up startup requests.

The current split between catalog creation and frontend startup makes the client more than a client. A durable session can be selected while its shell is absent or its Pi start remains prepared. Reopening a window does not reliably repair that gap, and hiding a recovery banner does not restore a PTY. Adding frontend restart heuristics would further entangle selection, process ownership, command uncertainty, and history preservation.

A daemon-owned desired-state model provides one place to decide what must exist, one materializer to make it exist, and one runtime owner to observe what actually exists. SQLite allows graph changes and their original operation records to commit together instead of coordinating several independently replaced JSON files.

### Current behavior and evidence boundary

The committed baseline is `5c895107d6c21711b2808ca607f1f5c817787642`. Relevant boundaries are:

- [`work.rs`](../../axod/src/work.rs) and [`work/deletion.rs`](../../axod/src/work/deletion.rs): private work records, revisions, original mutation receipts, and completion-proven deletion tombstones. The catalog is backed by `work-records.json`; there is no general workspace/session desired-open versus archived model.
- [`panes/store.rs`](../../axod/src/panes/store.rs) and [`panes/rpc.rs`](../../axod/src/panes/rpc.rs): separate shell-pane identities and add/remove receipts in `pane-state.json`.
- [`managed/store.rs`](../../axod/src/managed/store.rs) and [`managed/mod.rs`](../../axod/src/managed/mod.rs): separate Pi receipts and canonical bindings in `pi-state.json`. Native launch precedes public Pi admission and binding commit; an intervening failure can leave the original start prepared.
- [`journal.rs`](../../axod/src/journal.rs) and [`runtime.rs`](../../axod/src/runtime.rs): exclusive root ownership, runtime receipts in `runtime-state.json`, actual native PTY ownership, and completion evidence. Earlier nonterminal records become recovery-required in a new daemon epoch; saved PIDs do not restore ownership.
- [`AxodWorkbenchCoordinator.swift`](../../apple/AxoMacAxod/AxodWorkbenchCoordinator.swift): catalog requests followed by client-orchestrated initial shell and Pi startup, plus selection, connection, and reconciliation state.
- [`AxodPaneLayouts.swift`](../../apple/AxoMacAxod/AxodPaneLayouts.swift): client-side saved split geometry and pane identities.
- [`Cargo.toml`](../../axod/Cargo.toml): no SQLite dependency at the committed baseline.

Uncommitted work preceding this proposal experiments with daemon keep-alive loops, live-pane projection, and read-only completion observations. Those experiments are not this architecture: they still use the existing stores, do not define complete desired-state materialization or archival, and are not the central-store cutover. In particular, keeping one backing shell alive is not the same as materializing every desired pane.

### Relationship to existing RFDs

- [RFD0007](RFD0007-mac-session-manager.md) establishes independent host/client lifetimes and native PTY ownership. This proposal replaces its metadata-only cold-start and explicit-restart policy with reconciliation of persisted desired-live intent. It retains the prohibition on replaying user commands and on inventing orphan ownership.
- [RFD0010](RFD0010-macos-daemon-lifecycle-and-recovery.md) retains authority over launchd supervision, service registration, readiness, stop/update handoffs, and ownership safety. This proposal changes the session materialization policy, not the production launcher. Transparent crash survival and authoritative VT recovery remain separate guarantees.
- [RFD0011](RFD0011-menu-bar-residency-and-first-launch-setup.md) retains one resident frontend, an optional workbench, independently opt-in frontend login startup, and quit that leaves Axod alone. I supersede its earlier draft-save barrier: unsent text is discarded when the frontend exits.
- [RFD0008](RFD0008-private-multi-machine-control-plane.md) and [RFD0009](RFD0009-protocol-capability-parity.md) retain addressed local/remote RPC, role checks, bounded observation, and separate work/chat/runtime authority. Local and phone clients must converge on the same backend operations rather than forwarding orchestration to the Mac UI.

If accepted, conflicting startup and restart clauses in those proposals are superseded by this RFD. Their historical checkpoints do not become current implementation claims.

## Goals

- One durable desired graph and one daemon-owned materialization policy.
- Every effectively open session has its desired panes materialized, subject to explicit readiness, capacity, dependency, and ownership conditions.
- Automatic safe restoration on daemon startup and replacement after completion-proven runtime exit.
- Stable workspace/session/pane identities across runtime replacement and client reconnect.
- Backend-complete workspace/session/pane creation with no client startup choreography.
- A thin Mac client limited to platform daemon management, presentation, and user input, with bounded in-memory editing buffers and no durable draft storage.
- Preserve new-store original operations and canonical histories, plus existing security/resource bounds. Leave legacy data, credentials and unrelated configuration untouched; do not import legacy session state.

## Non-goals

- Importing legacy JSON catalogs, pane layouts, Pi bindings, operation receipts, or frontend draft archives into the central store.
- Deleting old histories, drafts, credentials, archives, or unrelated workspace data as a side effect of starting fresh.
- Putting Pi transcripts, terminal output, voice recordings, secrets, or arbitrary shell-command history into SQLite.
- Replaying prompts, tool calls, shell input, or unfinished model turns to simulate continuity.
- Treating persisted runtime rows as restored processes, or promising uninterrupted execution after coordinator/OS termination.
- Adding tmux, screen, Zellij, a repository Pi fallback, private Pi APIs, or automatic Pi installation/upgrades.
- Moving native rendering, focus, IME, voice capture, or macOS service consent into Axod.
- Cloud execution, cross-host database replication, new authentication machinery, or physical-device/cloud deployment.
- Solving authoritative VT screen reconstruction through a larger raw backlog or transcript rendering.
- Adding an implementation checklist or recording mutable work progress in this document.

## Guide-level explanation

### Mental model

**The database describes what the user wants. Axod makes it real. Clients show it and collect input.**

```text
Axo.app / phone client
  user action -> addressed backend operation
  observation <- desired graph + current availability
  terminal presentation <- exact attachment metadata

launchd -> Axod
  SQLite desired state + original operation records
       -> reconciler / materializer
       -> native PTYs -> account shells and ambient interactive vanilla Pi
       <- runtime completion and public Pi admission observations

Pi -> canonical JSONL history
```

There are two distinct facts:

- **Desired open:** the user wants the resource to exist and remain live.
- **Observed live:** the current daemon owns the actual backing PTY and, for Pi readiness, has admitted the public control/history binding.

An exit changes observed state to restarting; it does not archive the session or remove the desired pane. Missing dependencies or uncertain prior ownership can temporarily prevent materialization. The daemon must expose that honestly instead of calling a database row a running terminal.

### Example: daemon startup

1. Acquire exclusive state-root ownership and open the existing database safely. Never replace an unreadable database with an empty one.
2. Apply supported transactional schema upgrades for the central database before allowing new effects. On the initial cutover, initialize a dedicated fresh private root; do not read or import the legacy stores. Reject a mixed legacy root rather than overwriting it or treating it as an empty central store.
3. Read the complete desired graph and original pending operations. Reconcile earlier runtime ownership and completion before considering replacement.
4. Materialize all effectively open workspaces, sessions, and panes—not only the last selected session. Start independent shells without waiting for unrelated Pi admission.
5. Publish bounded, revisioned observations. Continue supervising without any frontend connection.

For the example of three workspaces, four sessions each, and three panes per session, there are twelve session identities and thirty-six pane identities. If each session contains one Pi and two shells, Axod owns twelve Pi runtimes and twenty-four shell runtimes when fully ready. A frontend need not render all thirty-six panes; renderer limits remain independent of execution limits.

### Example: create a workspace

The client submits one captured create-workspace intent with approved directory authority, command identity, and expected revision. Axod transactionally creates the workspace, initial session, desired panes, and the materialization operation. It initializes their backing resources and returns a complete graph with explicit readiness and attachment metadata.

A successful **ready** result means all required initial panes are initialized, including Pi admission where required. If the request deadline expires first, Axod returns the same accepted operation and its materializing/blocked state. It continues independently; the client observes that original operation instead of issuing `add shell` or `start Pi` follow-ups.

A live shell may be presented while Pi initializes. Partial readiness must never be mislabeled as complete creation or cause another create operation.

### Example: a pane exits

Axod observes the exact runtime's exit, drain, reap, and original process-group completion. The desired pane remains present. It reserves a distinct replacement attempt linked to that completed runtime, starts a new backing PTY for the **same pane ID**, and publishes a new runtime generation.

An ordinary shell restarts using its persisted approved launch specification; old shell input is not replayed. Pi resumes only its exact recorded canonical conversation binding. Selection, focus, viewport creation, and client reconnection do not participate in this decision.

### Example: archive and reopen

Archiving withdraws desired-live intent. Axod stops only resources it currently owns, retains history and original operations, and records actual completion separately. An archived session is not rematerialized at daemon startup.

An explicit reopen restores desired-live intent. Axod rematerializes the stored graph, retaining session/pane identities and exact Pi history bindings. Reopening the **workbench window** is presentation-only and is not this operation.

If stopping is uncertain, the desired state can already be archived while observed execution remains stopping or ownership-unknown. Archival must not falsely claim that the original writer has stopped or authorize a replacement writer.

## Reference-level explanation

### Ownership and the thin Mac client

| Owner | Responsibilities |
| --- | --- |
| Axod | Desired graph, shared pane topology, approvals, revisions, command deduplication, materialization, PTYs, Pi admission/bindings, restart/resume, archival, execution recovery, backend capacity, runtime observations and original input-submission captures |
| Pi | Agent execution, model/tools, conversation/branch state, and canonical JSONL history through public vanilla Pi APIs |
| Axo.app | `SMAppService` setup/status and separately authorized service operations; AppKit/Ghostty presentation; selection, focus, sizing, scrolling, accessibility and IME; keyboard/paste/voice input and in-memory editing buffers; submitting typed user intent through RPC |
| Phone client | Its presentation/input and permitted addressed backend operations; no dependence on Mac frontend orchestration |
| Relay/API | Existing authenticated routing and role enforcement; no competing desired-state store or materializer |

I allow the frontend to persist view preferences, but unsent input lives only in its bounded in-memory editing buffers. I do not provide durable draft files, daemon draft tables/APIs, draft-save barriers or draft restoration. Attachment selections are volatile too; file transfer may use a fresh private temporary staging directory, never a restorable archive. Quitting or crashing the client discards unsent text without stopping Axod; hide/reflow preserves the live buffer. Acknowledgement clears only the exact unchanged editing revision. Voice transcription produces user input for a captured destination; it does not select a global session, launch an agent, or replay an uncertain submission. Axod's original submission capture and command deduplication remain separate from unsent drafts: removing draft persistence never authorizes replay of an uncertain send. Legacy draft archives and pending submissions are not restored, attached to new identities, or replayed; their old files remain untouched and unread.

The client can own UI validation and confirmation, not backend authority. Axod must independently validate target, revision, approval, capacity, and lifecycle even if a menu item was enabled. No create/start/recovery fallback invokes Pi or a shell from the Mac app.

Shared desired pane membership and topology belong to Axod. Window-specific focus, sidebar expansion, zoom, temporary reflow, viewport ownership, and current attachment size remain presentation state. A view hiding or collapsing a pane does not remove it from the desired graph.

### Desired graph and archival semantics

Use explicit domain states rather than deriving intent from a runtime's last exit:

- Workspace desired lifecycle: `open` or `archived`.
- Session desired lifecycle: `open` or `archived`, with optional workspace membership for standalone sessions.
- Pane desired lifecycle: `present` or `removed`, with a closed role/specification: one managed Pi pane per session and zero or more independently addressed shells, subject to the accepted minimum/default pane policy.
- Each mutable desired entity has a configuration revision. The catalog has a monotonic, wire-safe revision.

A pane is effectively live-desired when it is present and its session and, if applicable, workspace are open. Archiving a workspace suppresses materialization of its descendants without erasing their individual desired states. Reopening it reactivates only descendants that remain individually open/present. An individually archived session must not become open because its parent was reopened.

Archive, pane removal, and retained-history deletion/tombstoning are explicit backend intents. Do not silently rename the existing Delete contract into Archive. Existing completion-proven deletion receipts retain their original atomicity and meaning. A future permanent history deletion needs its own explicit retention/consent contract.

The default new session remains a managed Pi pane plus an independent account-shell pane. Removing the final required backing pane must be rejected or expressed as an explicit session archive; a successful operation cannot leave an effectively open session with an empty desired backing specification.

### SQLite authority and conceptual schema

Use one private SQLite database within the owned Axod state root. Table names below are conceptual, not frozen APIs:

| Data | Required meaning |
| --- | --- |
| Storage metadata | Schema version, machine identity, catalog revision, central-store generation and authority provenance |
| Workspaces | Stable ID, name, approved canonical directory reference, desired lifecycle and configuration revision |
| Sessions | Stable ID, workspace membership, naming protection, desired lifecycle and configuration revision |
| Panes / topology | Stable IDs, session membership, desired presence, role, validated execution specification/reference, shared topology and configuration revision |
| Pi bindings | Exact chat identity, canonical file/location, approved working directory, branch/source facts as required, and binding provenance |
| Operations | Original command ID, captured source/target/revision, normalized intent, protected preparation fingerprint, immutable acceptance/result records, and unresolved phase |
| Runtime attempts | Attempt ID, pane/configuration revision, owner epoch, runtime generation, predecessor attempt, launch/admission phase and proven completion facts |

Use foreign keys, uniqueness constraints, checked domain values, and transactional mutation logic to preserve graph invariants. Reject cycles, cross-session topology leaves, orphan membership, duplicate pane identities, unsupported launch roles, and conflicting command reuse at the boundary.

Mutable projections may advance; original captures and terminal receipts remain immutable. Runtime observations are last-known facts tied to an owner epoch, not persistent kernel handles. PIDs can be diagnostic facts but cannot authorize adoption, signaling, or replacement.

Keep SQLite operations behind the daemon's storage owner. Clients receive typed RPC; they never open the database or submit SQL. Use short transactions and bounded queries. No transaction or storage mutex spans dependency probing, process launch, Pi handshake, network I/O, or a stop-completion wait.

For the initial single-writer design, use SQLite transactions in a bounded in-memory database and atomically publish the complete SQLite image through Rust's pinned private-directory file descriptors. The durable commit boundary is successful file fsync, exclusive publication/exchange, and directory fsync—not the preceding SQLite memory commit. Clients and SQLite never open the disk image directly. This avoids uncontrolled SQLite sidecar opens while enforcing no-follow, ownership, single-link and mode checks at actual I/O. A publication error fences the owner without exposing new spawn authority. This deliberately trades full-image write amplification for a simple, bounded private-storage boundary. An on-disk VFS/WAL replacement requires equivalent privacy, commit, backup and interruption acceptance.

The database is not a second transcript store. Preserve canonical files, locations and ownership within the central store, and leave legacy histories untouched and unbound; keep original submission evidence at a dedicated daemon-owned input-storage boundary. I do not store unsent drafts there or treat a client editing buffer as canonical Pi history or a replay queue. Do not persist arbitrary argv, environment values, prompts, terminal output, audio or credentials as operation payloads. Persist approved specification references and fingerprints instead.

### Materializer and runtime lifecycle

Implement one policy owner, with separate scheduling for slow Pi admission and independent shell lifecycle. The reconciler compares effective desired state with current owned resources and immutable operation evidence.

```text
read desired graph + original operations
  -> reconcile ownership / completion
  -> reserve missing or replacement attempt
  -> materialize native PTY
  -> admit Pi and exact binding when applicable
  -> publish actual availability
  -> observe exit or desired-state change
  -> reconcile again
```

Each pane has at most one active materialization attempt and at most one owned backing runtime. Replacement preserves the pane ID but changes runtime generation. A retry cannot mint another attempt while the original spawn/admission outcome is unknown.

Persist attempt identity, target, desired configuration revision and predecessor before effects. Revalidate effective desired state and configuration before launch and after asynchronous boundaries. If archive/removal races with an accepted launch, retain ownership of that newly created child and stop it under the original operation lineage. Do not lose the child or falsely report that no effect occurred.

Distinguish at least desired state, materialization phase, native ownership, Pi readiness, and presentation. Conceptual observed phases are `materializing`, `live`, `restarting`, `stopping`, `stopped`, and `blocked`; bounded reason codes distinguish dependency, capacity, storage and ownership failures. A session is fully ready only when all its required desired panes satisfy their role-specific readiness.

Restart scheduling uses bounded backoff and concurrency. Repeated short-lived launches must not spin or consume unlimited operation history. Existing per-session/global execution, transport, control, history, in-memory editing and presentation limits remain enforced. Reserve capacity for the complete requested graph before accepting a new graph that cannot fit. Never evict unrelated live work or silently materialize fewer panes to claim readiness.

A runtime's exit does not update desired lifecycle to archived. Only explicit user intent changes that policy. A user intentionally leaving a shell must archive/remove the corresponding desired resource rather than rely on exiting its current process to permanently suppress keep-alive.

### Pi continuity and unfinished admission

Pi is ambient interactive vanilla Pi on a daemon-owned native PTY, with the installed public Axo extension. SQLite does not become an agent harness.

- A ready owned runtime is reused; no second Pi is launched for another client or viewport.
- A completion-proven stopped runtime resumes only the exact recorded canonical binding, under the existing writer-exclusion and path checks.
- A never-materialized new desired Pi pane may allocate its first conversation under the original creation/materialization intent.
- An incomplete original start is reconciled through its exact attempt, native resources, public control state, and canonical binding evidence. Missing binding is not permission to create a replacement fresh conversation.
- An unresolved writer or storage outcome remains blocked. Preserve the original evidence and expose a metadata-only diagnostic; do not discard it to satisfy a keep-alive predicate.
- Restoring a conversation loads its history; it never resubmits a prompt, replays a tool call, or restarts the last model turn implicitly.

I use a read-only, source-fenced Pi observation to discover the committed binding for an exact workspace/session scope. Its closed alternatives are not admitted, live with bounded public control metadata, and stopped with exact completion proof. Not admitted includes unfinished admission; it is not a new-chat or replacement capability. A live observation requires the same durable binding and attempt, current native ownership and exact control identity. An observation gap is unavailable, never an idle snapshot or stopped-writer proof. The result is bounded to 48 KiB and carries no canonical path, PID, launch specification or terminal data. I bound question titles to 2,000 UTF-16 units, option labels to 500 and options to 2–8 distinct IDs; a question must match the active interaction. History, snapshot resynchronization and actions remain separate exact-binding operations, not side effects of observation.

New workspace histories remain under `<workspace>/.axo/sessions/<work-session UUID>/`. Bindings created by the central store keep their original locations. Legacy bindings are not imported or resumed. Pi alone writes JSONL; the fresh start neither copies nor rewrites old canonical histories.

### Startup, crash and shutdown boundaries

Database initialization means safely creating the initial central database in a dedicated fresh root, or opening and upgrading a supported existing central database. Starting fresh is an explicit architecture cutover, not a corruption-recovery policy. Integrity failures, unsupported versions, unsafe files, mixed legacy state, or disk failure fence effects; they never trigger an empty-database fallback.

A daemon epoch change invalidates old live observations and input authority. SQLite cannot restore a PTY descriptor or prove that an old writer died. Materialization after restart therefore begins with ownership reconciliation:

| Previous evidence | Allowed action |
| --- | --- |
| Current owned runtime and valid binding | Reuse; expose fresh attachment metadata |
| Exact previous completion proven | Reserve replacement; restart shell or resume exact Pi binding |
| Durable attempt with outcome unknown | Reconcile original only; no second spawn |
| Historical runtime without ownership/completion proof | Preserve desired intent, mark blocked, refuse replacement writer |

This RFD selects durable desired-state reconstruction and safe eventual materialization, not transparent process checkpointing or unconditional recovery from every coordinator crash. A stronger unattended crash-restoration promise requires an accepted execution-owner/worker or completion-fencing protocol and real acceptance. Do not infer such a protocol from SQLite locks, PID absence, refused sockets, or a restarted launchd job.

An explicit service stop/update freezes new materialization and stops only exactly owned runtimes under RFD0010's authority. It does not archive user sessions as a side effect. When the service is legitimately enabled again, the desired graph remains available for reconciliation. Frontend quit, hide, crash, login-only launch, or reconnect neither freezes nor restarts the daemon's executions.

Service startup on an empty database does not invent user work. An explicit create/default-workspace intent, including any separately specified create-if-empty first-opening action, goes through the same backend transaction, revision, original-operation and input-safety fences. The frontend must not decide authoritative emptiness from cached lists.

### Client contract and readiness

Keep addressed, versioned RPC and terminal attachment separation. Every state-bearing result identifies machine, host epoch, resource identities, applicable revision, and original operation identity. Method spelling is resolved in the shared protocol during implementation; no illustrative name here creates an alias or accepted compatibility layer.

Required logical operations are:

- Read bounded desired graph and current availability; subscribe/reconcile observation gaps.
- Create workspace with its initial session/panes; create a session with its panes; add/remove a desired pane.
- Rename and change shared topology/configuration with captured revision.
- Archive/reopen workspace or session through explicit lifecycle intent.
- Observe the original accepted creation/materialization/archive operation without replay.
- Attach an exact live pane runtime and route authorized input/resize or public Pi actions.

Creation transactionally reserves the entire initial graph and original intent before external effects. A repeated command ID with the same normalized intent observes the original operation; conflicting reuse fails. A late or lost response cannot create another workspace, session, pane, or writer.

A ready creation reply includes initialized session/pane metadata and current attachment identities. A bounded pending/blocked reply includes the same graph and original operation, with explicit partial readiness. Neither reply asks the client to materialize resources. Client timeout or disposal does not cancel accepted backend intent.

Negotiate the backend-complete creation/lifecycle capability explicitly. An incompatible helper blocks new creation with a concise update requirement; the frontend must not fall back to the obsolete catalog-plus-shell-plus-Pi sequence. Reconnect remains read-only and never installs, upgrades, repairs, or directly launches a production helper to obtain that capability.

Terminal views are instantiated only from validated current live runtime metadata. Non-live desired panes can have a concise materializing/unavailable presentation, but must not be shown as dead interactive terminals. Technical diagnostics remain outside normal workbench notices. The existing native AppKit outline, selection/range behavior, Ghostty ownership, cache bounds, and viewport leases remain intact.

Output gaps and unavailable authoritative VT state are presentation problems when the owned runtime is still live. They never authorize a replacement runtime, hidden redraw input, partial-ANSI replay, or transcript-based fake terminal recovery.

### Security and privacy

Retain exclusive per-user root ownership and private storage. The database, journal/sidecars, backups, and any temporary SQLite files must satisfy owned-directory and regular single-link private-file requirements. Enforce no-follow opening and identity checks at the actual I/O boundary; preflight path checks alone do not protect later SQLite/VFS opens. SQLite integration cannot ship until those guarantees are demonstrated, including failure/collision cases. Do not chmod old histories or weaken permissions to complete the cutover.

Use a reviewed Rust SQLite dependency/VFS configuration, foreign-key enforcement, explicit transactions, bounded busy handling, and private bounded backup/compaction behavior. Preserve the current exclusive owner lock in addition to SQLite transaction locks. Missing database locks or corruption are not recovery permission.

Retain approved directory/launch authority and current local/remote role checks. Database-backed configuration must not become arbitrary remote argv/path execution. SQLite is persistence, not a new authentication or sandbox boundary. Respect macOS ServiceManagement, signing, TCC and automation denials.

Diagnostics include only bounded operation/lifecycle categories, revision/epoch, and failure facts. Never log SQL parameter values, prompt/terminal/audio content, secrets, argv, arbitrary RPC bodies, or sensitive paths. Support export is separately explicit and metadata-only.

### Fresh start and clean cutover

I replace the legacy session-state model with a fresh central store, not a data importer. The initial catalog, pane graph, shared topology and submission records are empty; client editing buffers start empty and are never restored. New explicit creation intents allocate new workspace/session/pane identities. Legacy catalog entries, history bindings, tombstones, pending operations, layout hints and drafts do not seed the new store or appear as recovered central sessions.

Use a dedicated fresh private root. Leave the old roots, canonical histories, draft archives, opaque originals, attachments, credentials, service-operation originals, unrelated preferences and untracked workspace `.axo` data untouched. No old file becomes a fallback authority. Ordinary central-database schema upgrades remain supported; they are not legacy import.

The service handoff still obeys RFD0010: freeze old admission and reconcile exactly owned work before an authorized helper replacement. A fresh catalog does not prove old writers have stopped, permit historical PID signaling, authorize orphan adoption, or repair registrations. Unknown old execution remains separately fenced; it is never attached to newly allocated identities.

Move all session-state callers directly to the central operations and remove obsolete catalog/start choreography and frontend durable-storage paths. Negotiate the central capability and store generation so old cached revisions, pane selections, pending commands and input destinations cannot become new-store input authority. Legacy pending submissions are never replayed. An old helper cannot serve the new store; incompatible clients/helpers block rather than reopen the old catalog or run a compatibility importer.

The fresh start is not permission to delete old data, reset background items, stop unrelated work, or activate a packaged app. Those remain separately scoped operations.

### Validation and acceptance

These are contract gates, not an implementation progress ledger:

| Scenario | Required result |
| --- | --- |
| Fresh and existing database startup | Safe fresh-root initialization/schema upgrade or complete central-store read; no empty fallback on failure; no frontend needed for existing desired work |
| Three open workspaces × four sessions × three panes | The complete graph materializes within admitted capacity; stable identities; no selection-dependent launches |
| Workspace creation, session creation and pane addition | Backend-owned graph reservation and initialization; ready/pending truth; zero follow-up client starts |
| Lost replies, retries and concurrent clients | Original operation reconciliation; no duplicate graph, PTY, Pi writer or prompt |
| Shell/Pi exit with clean completion | Same desired pane ID, new runtime generation; exact Pi resume, no shell-input or prompt replay |
| Slow/missing Pi, bad directory, capacity or disk failure | Independent shells progress where safe; bounded retries and truthful partial/blocked state |
| Archive/remove races with materialization | Intent persists before effects; owned late child reconciled/stopped; no resurrection after withdrawal |
| Workspace archive/reopen | Descendant effective intent follows the documented hierarchy; individually archived sessions stay archived |
| Frontend quit/crash/hide/reflow, phone-only use | Daemon policy unchanged; actual runtime continuity; original-submission fences and viewport ownership preserved; unsent text intentionally lost on frontend exit |
| Coordinator crash before/after reservation, spawn, Pi admission and completion commit | Old epoch invalidated; exact original evidence retained; no unsupported adoption or duplicate writer |
| Fresh cutover with legacy data, stale clients, unsafe files and attempted downgrade | New empty authority without import; old bytes untouched; old captures never retargeted/replayed; mixed roots and incompatible helpers fenced |
| Reattachment beyond raw backlog and repeated runtime replacement | Real VT/attachment gate distinguished; completion-authorized surface release; no eviction or fake screen recovery |

Rust owns disposable process/filesystem/model assertions. Native UI testing uses actual authorized XCTest actions and refuses another same-bundle frontend. SQLite unit tests alone do not establish real Pi readiness, launchd acceptance, crash ownership, terminal fidelity, or installed-user cutover.

Delivery requires the exact committed source, packaged `dist/Axo.app`, matching app/helper team and strict/deep signatures, and the applicable native/protocol/storage lanes. Packaging is not activation; normal-profile cutover, service handoff, cloud changes, and physical-device installation retain their separate consent and evidence boundaries.

## Drawbacks

- SQLite adds dependency, schema migration, VFS/privacy, backup and corruption-handling work. Transactions do not make process launch atomic.
- Keeping every desired pane live consumes resources even without clients. Capacity admission and archive semantics become essential product behavior.
- Moving shared topology and creation policy out of the Mac coordinator requires a real frontend cutover, not a new database behind the same choreography.
- Desired and observed state are necessarily different during startup, failure and shutdown; the API must expose that without bloated UI.
- Old runtime ownership and unfinished admission remain difficult. A desired-state database cannot guarantee unattended recovery of every old writer.
- Starting fresh deliberately excludes old sessions, layouts and drafts from the new workbench. Their retained files are not automatic recovery or fallback authority.

## Rationale and alternatives

### SQLite-backed desired state and daemon materialization

Selected proposal because the user wants durable open workspace/session/pane intent, complete backend creation, and a thin client. One transactional graph plus original operation records is a clearer authority than coordinating separate catalog and runtime stores through frontend callbacks.

### Keep JSON and add restart loops

A simpler local solution can restart known-stopped backing resources and improve availability. It does not by itself define complete desired pane topology, archival hierarchy, atomic multi-entity creation or client removal. The current experiments are useful characterization, not the selected final architecture. JSON could encode desired state, but retaining the same fragmented model would not satisfy this decision.

### SQLite as an observed-process catalog only

Changing storage format while continuing to let the frontend launch resources leaves the important ownership defect intact. The selected database stores user intent and original operations; actual PTYs remain daemon-owned resources.

### Thin frontend over an external multiplexer

An existing terminal server provides a useful owner/client pattern, but delegating execution ownership to tmux/screen/Zellij is not the selected Axo direction and does not supply exact Pi binding, operation or fresh-cutover contracts automatically.

### Introduce independently surviving execution workers now

Potentially enables stronger coordinator-crash continuity, but adds worker admission, leases, PTY/output ownership, reaping, signing, upgrade and reconciliation protocols. Do not smuggle it into the SQLite change. Require a separate accepted design if transparent crash continuity becomes a release requirement.

### Do nothing

Keep the existing frontend startup sequence and manual recovery. This preserves current behavior but fails the user's desired backend model; packaging it would not implement the agreed ownership change.

## Prior art

- Tmux's server/client separation is the useful analogy: the server owns sessions/windows/panes and PTYs, while clients attach and send input. This proposal does **not** assert that tmux stores desired state in SQLite or automatically reconstructs live sessions after server death. See the [tmux manual/source](https://github.com/tmux/tmux/blob/master/tmux.1).
- Declarative reconciliation distinguishes intended resources from current observed availability. Applying that model locally does not import a distributed control plane, remote scheduler or cloud dependency.
- SQLite's [atomic commit description](https://www.sqlite.org/atomiccommit.html), [locking and rollback-journal model](https://www.sqlite.org/lockingv3.html), and [synchronous setting](https://www.sqlite.org/pragma.html#pragma_synchronous) explain storage guarantees and their limits. None establishes atomic PTY spawn, Pi admission or process recovery.
- Axod's existing root lock, captured operations, exact runtime generations, writer exclusion and completion proofs remain valuable invariants. Consolidating persistence must preserve them, not replace evidence with a `running` database flag.

## Unresolved questions

### Accepted policy

- Start with an empty central session store. Do not import legacy catalogs, layouts, bindings, receipts or drafts; leave old data untouched and unreferenced.
- Archive is explicit desired-state intent, distinct from the existing Delete/tombstone contract. Parent archive/reopen preserves child choices.
- A new open session has Pi plus an independent account shell. Reject removing its final required shell rather than implicitly archiving the session.
- Safe eventual materialization with blocked unknown ownership is the initial contract; transparent coordinator-crash survival requires a separately accepted execution-owner design.
- Shared pane topology and original submission captures belong in Axod. Per-window presentation and bounded volatile input editing remain client-owned. I do not persist unsent drafts in either process.

### During implementation

- Exact SQLite dependency/version, private VFS/open policy, rollback-journal configuration, physical database budgets and backup/compaction limits.
- Central schema and operation-phase encoding, with no legacy-state import.
- Exact bounded creation/observation API and negotiated capabilities; readiness deadlines and scheduling fairness.
- Fresh-root placement, store-generation negotiation and incompatible-helper exclusion without stale-catalog fallback.
- Exact original admission reconciliation for conversations created by the central store.

### Out of scope

Distributed catalogs, cloud execution, OS process checkpointing, authoritative VT design, permanent history erasure, new service-registration repair, and physical-device/cloud rollout.

## Future possibilities

A separately accepted stable execution-owner design may allow Axod coordination to restart while existing PTYs remain owned. A separately accepted terminal-state design may make detach/reopen faithfully reconstruct the viewport. Both can use this desired graph and operation lineage without moving lifecycle policy back into clients or making SQLite authoritative for Pi history.
