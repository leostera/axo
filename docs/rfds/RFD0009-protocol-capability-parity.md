# RFD0009 - Axo: protocol capability parity and native adoption

- Feature Name: `axo-protocol-capability-parity`
- Status: Proposal
- Start Date: 2026-10-10
- Updated: 2026-10-10
- Document Type: Proposal

## Summary

Define the application capabilities needed before shared JSON-RPC can replace Axo's existing Mac/bridge/iOS protocol. Preserve useful behavior and ownership guarantees, not the old wire format. [RFD0008](RFD0008-private-multi-machine-control-plane.md) supplies the implemented multi-machine transport foundation; this RFD supplies a source-grounded capability matrix, domain contracts, implementation order and per-capability cutover gates. `axod` owns managed local work, vanilla Pi owns execution and canonical history, and the cloud routes calls without becoming an executor. This proposal does not authorize native ownership migration, file-authority changes, startup registration or restarting live sessions.

## Motivation

A working local/cloud transport is necessary but insufficient for using the new route as the application's protocol. Runtime metadata and an approved-profile launch cannot replace session catalogs, conversation history, addressed prompts, questions, streaming state or attachments. Migrating clients before these capabilities exist would lose behavior or recreate execution authority inside the frontend.

Use one parity map to answer: what exists, who owns it, which clients require it, what remains missing, and what evidence permits replacement. A capability may use shared control RPC, a local terminal data channel, an existing HTTP/file route, or no network protocol at all. Uniform JSON-RPC does not mean putting terminal bytes, files or audio into control frames.

## Scope and evidence

This is an application-contract proposal with an implementation snapshot, not a claim that every legacy feature has passed native/device acceptance. The 2026-10-10 transport baseline is commit `576a1ea`; subsequent native work must be assessed independently.

Source inventory:

- [`shared/protocol.ts`](../../shared/protocol.ts): legacy `sync`, catalog paging/subscription, create/rename, prompt/answer/cancel, history/tool-output requests, snapshots and acknowledgements.
- [`bridge/extension.ts`](../../bridge/extension.ts), [`bridge/delivery.ts`](../../bridge/delivery.ts) and [`bridge/host-broker.ts`](../../bridge/host-broker.ts): public Pi bindings, branch/history projections, prompt delivery, Axo-owned questions and addressed routing. Busy prompts currently use steering; this is not a general durable follow-up queue.
- [`WorkspaceStore.swift`](../../apple/AxoCore/Sources/AxoCore/WorkspaceStore.swift) and [`WorkspaceController.swift`](../../apple/AxoMac/WorkspaceController.swift): current native registry, create/rename/archive/duplicate, pane launch/resume and window selection. Some capabilities are Mac-only, not old phone protocol methods.
- [`service/src/files.ts`](../../service/src/files.ts) and [RFD0002](RFD0002-shared-session-files.md): existing file HTTP lifecycle and immutable-file authority, separate from conversational control.
- [`protocol/`](../../protocol/README.md), [`axod`](../../axod/README.md) and the [API](../../sites/api.axo.leostera.dev/README.md): implemented shared machine/runtime contracts and bounded local/cloud adapters.
- [`AxoJSONRPCClient.swift`](../../apple/AxoCore/Sources/AxoCore/AxoJSONRPCClient.swift): reusable native client source exists; this is not proof of full native migration or physical-phone parity.

Status vocabulary below applies to the **new daemon route**, not to the existence of a legacy implementation:

- **Implemented:** shared contract/daemon/service capability exists with isolated evidence; native acceptance remains separately gated.
- **Partial:** a lower-level capability exists but does not satisfy the application contract.
- **Missing:** application capability is not exposed by the new route.
- **Retained:** deliberately remains in its current authority or client lane until a separate gate passes.

## Capability matrix

| Capability / consumers | Legacy or current behavior | Required authority / boundary | New-route status | Replacement gate |
| --- | --- | --- | --- | --- |
| Transport, negotiation and machine discovery / Mac, iOS | Legacy single-workbench relay; no equivalent multi-machine directory | API owns directory/leases; daemon owns execution; explicit local/remote destination | **Implemented:** local bootstrap, negotiation, registration/heartbeat, machine list and fenced relay | Native readers validate discovery and method results; wrong machine/source/lease never crosses routes; no mutation replay |
| Runtime metadata and approved launch / Mac, structured clients | Native pane launch; former daemon control commands | One daemon manager/journal; operator-approved launch policy | **Implemented:** `axo.runtime.list`, `axo.runtime.startApproved`; **not Pi readiness** | Preserve durable receipt, unknown outcome and historical generation semantics on both routes |
| Workspace/session catalog and selection / Mac, iOS | `catalog_page`, `subscribe`, `sync`; native registry and window-local selection | Daemon-owned work records/projection; selection remains client-local | **Missing:** runtime pages are not a workspace/session catalog | Machine/source/revision-bound cursors, stopped records, gap reconciliation and no launch from reading/selecting/restoring |
| Create and rename workspaces/sessions / Mac, iOS | `create_workspace`, `create_session`, `rename_workspace`, `rename_session` | Exactly one registry writer; approved directory intents; preserve manual-title protection | **Missing** | Durable create receipts, revision conflicts and explicit launch intent; no remote arbitrary cwd/argv; compatible existing identities |
| Archive and duplicate / Mac; remote exposure separately decided | Native archive/duplicate; not old phone methods | Registry authority; Pi/file authority stays intact | **Missing** | Archive preserves originals; duplicate uses fresh work/conversation identities; define stopped/live behavior without copying a live writer |
| Explicit Pi session start and exact resume / Mac, iOS | Native Ghostty launch/resume and extension admission | Daemon resolves work target and managed Pi persistence; public Pi launch/registration | **Partial:** PTY spawn/receipts only | Real vanilla Pi binding to actual session ID/file; spawned versus ready; no ambient continue, duplicate writer or automatic restart |
| Conversation snapshot, active branch and history / Mac, iOS | `sync`/`snapshot`, `history`; branch/view identity and bounded pages | Pi owns canonical JSONL and active branch; daemon/extension projects observations | **Missing** | Tree/compaction-aware projection, branch-bound cursors, stopped-history policy, encoded-byte bounds and no second transcript writer |
| Live assistant/thinking/tool state and detailed tool output / iOS, structured Mac views | Snapshot/live text, activities/events and paged `tool_output` | Public Pi events and canonical entries; bounded daemon observation | **Missing** | Correlated tool identities, source/subscription sequence, dropped-event disclosure, demand-driven detail and snapshot reconciliation after gaps |
| Addressed prompt submission and busy-turn delivery / Mac, iOS | `prompt`, submitted/steering acknowledgements and command metadata through public Pi APIs | Admitted Pi binding; daemon reconciles logical command identity | **Missing** | Explicit destination/branch policy, durable evidence of disposition, actual public-API delivery and no replay after timeout/disconnect; preserve draft on known rejection |
| Axo questions and answers / Mac, iOS | Pending question in snapshot; `answer` validates question/options | Public Axo extension owns question; answer bound to admitted runtime/question | **Missing** | Reconnect recovers the pending question; stale/duplicate answers rejected; cancellation never means approval; no-client wait policy explicit |
| Cancel a Pi run versus stop a runtime/host / Mac, iOS where permitted | `cancel` with agent-run identity; native lifecycle controls; internal daemon stop | Pi owns run cancellation; daemon owns process shutdown; host stop is separate intent | **Partial:** internal manager stop exists, no exposed stop/cancel RPC | Confirmed target after waits; cancel acknowledgement is not completion; real lifecycle observations and sibling isolation; no historical PID signaling |
| Model controls and follow-up policy / Pi TUI; structured UI if selected | Pi TUI/public APIs; no equivalent legacy phone method for general controls | Pi remains model/tool/queue authority | **Retained:** not automatically a phone-parity requirement | Decide structured scope before defining methods; do not invent a competing queue or infer readiness/queue identity from terminal text |
| Presence, readiness, attention and viewing state / Mac, iOS | Host presence, snapshot run/question state, native status/title/notification behavior | API reachability; daemon lifecycle; Pi activity; clients' expiring viewing state | **Partial:** machine presence/process states only | Reachable, spawned, ready, busy, waiting, detached and recovery-required stay distinct; notifications retain privacy and destination fencing; public observer gaps disclosed |
| Subscriptions and reconnect synchronization / Mac, iOS | `subscribe`, `sync`, bounded catalog/history views | Daemon projection with explicit destination; service routes only | **Missing:** transport ACKs are delivery credit, not application subscriptions | Subscribe/unsubscribe scope, baseline revision/sequence, byte/count budgets, lease cleanup and deterministic resync without event/execution replay |
| Shared files and prompt attachments / Mac, iOS | Existing HTTP reserve/authorize/complete/list/download/delete; prompt attachment references and file updates | Existing FileIndex/R2/deletion authority and Pi-owned conversation references | **Retained:** no file route on new API | One file authority, machine/conversation authorization, immutable originals, consent, direct transfer, deletion races and existing-reference compatibility |
| Terminal attach/input/resize/rendering and shell panes / Mac only | Ghostty-owned PTYs; daemon has internal attachment leases/backlog | Daemon owns process/PTY; native renderer owns presentation; local data plane | **Partial:** manager behavior tested; no RPC/data-channel or Ghostty adoption | Headless drain, real TUI/IME/images/resize and detach/reconnect during work; honest screen recovery; byte backlog is not VT state; never forward raw terminal to iOS |
| Local voice, drafts, layout and UI selection / native clients | Local speech and draft/send flow; window layout/focus and per-session drafts | Client-local; resulting text uses addressed prompt submission | **Retained:** not daemon/cloud features | Preserve stop-to-draft/send-one-attempt behavior and captured destination; no audio upload or ambient-selection retargeting |
| Recovery, supervision and native ownership handoff / Mac operations | App-owned lifetime; daemon journal fails closed on uncertain prior work | One daemon writer; explicit operational/user consent | **Partial:** standalone receipts/recovery fences, no production ownership migration | No-window real Pi operation, orphan/upgrade/rollback drills, signed packaging, explicit shutdown and separate opt-in startup; client quit/cloud logout never stops daemon work |

Parity does not require exposing every Mac-only operation to the phone. Each new method must declare **shared**, **local-only**, or **service-only** availability. Search/FFF/palette remain deferred; accounts, enrollment, offline execution queues, cloud executors and raw phone terminals remain out of scope.

## Guide-level explanation

### A session is not a process, and transport is not readiness

A session record may exist while stopped. An explicit start binds that record and pane to a daemon runtime and an actual vanilla Pi conversation. A spawned PTY is not ready Pi. Only validated public extension/API registration establishes readiness; clients can browse metadata/history without starting anything.

A Mac or phone captures the destination, submits one explicit intent, and observes its disposition and subsequent state. Switching views while it waits cannot move that intent. If the connection is lost after dispatch, the UI retains an unknown outcome and reconciles the same logical command; it never fabricates a rejection or resubmits as new work.

### Replace capabilities, not all endpoints at once

A native client may use the new machine/runtime browser while retaining legacy chat and file paths. When a capability passes its gate, deliberately move that client's call path without enabling a second mutating owner. A working chat migration still does not authorize moving file storage or adopting the Ghostty renderer. The coexistence boundary must be explicit, not a silent fallback to legacy execution when the daemon is offline.

## Reference-level contracts

### Proposed canonical naming catalogue

This catalogue is the naming proposal for review, not a claim that the methods are available or that their schemas are frozen. **Existing** names are implemented contracts and remain unchanged. **Proposed** names identify the intended application surface; acceptance and schemas follow the owning capability gate. Native clients must not translate the old type-tagged envelope into an alternate naming scheme.

Every Axo JSON-RPC method and event notification must begin with `axo.`; there are no unprefixed methods, legacy-name aliases or `rpc.*` application methods. Use `axo.<resource>[.<subresource>].<operation>` with singular domain/resource names and camelCase for compound operations, consistent with the existing `startApproved`. Nested scope is intentional, for example `axo.session.turn.cancel`. `protocol`, `transport` and `observe` are infrastructure namespaces. `list` is bounded paging, `get` reads one explicitly addressed resource/projection, and verbs describe intent rather than transport (`sync`, `send`, `execute` and a generic `action` are not application methods). A read never starts work. Do not expose UI selection as daemon execution authority.

Route vocabulary: **shared** means the same daemon semantics locally or through the API, subject to advertised support/caller policy; **service** means client-to-API; **registration** means daemon-to-API; **local** means not forwarded through the cloud. Scope does not imply current implementation or permission.

| Canonical method | Light capability specification | Route | Status |
| --- | --- | --- | --- |
| `axo.protocol.negotiate` | Negotiate the application profile before domain calls; supported-method/limit advertisement needs its own compatible schema | Local and service connections | Existing |
| `axo.machine.list` | Page registered machines and observed reachability; never launch or publish histories | Service | Existing |
| `axo.machine.register` | Bind the approved machine identity/source to an admitted service route, not account enrollment | Registration | Existing |
| `axo.machine.heartbeat` | Renew the current route's bounded liveness lease | Registration | Existing |
| `axo.transport.ack` | Notification returning consumed reply-frame credit; not execution acknowledgement | Local and service connections | Existing |
| `axo.machine.catalog.publish` | Publish approved bounded catalog metadata under the admitted machine/source/revision; partial publication must never become an active mixed replica | Daemon to service | Proposed; projection gate |
| `axo.machine.catalog.list` | Page the service's bounded published workspace/session replica, including when the daemon is offline; disclose source/revision/freshness | Service | Proposed; legacy offline-catalog parity |
| `axo.workspace.list` | Page authoritative daemon workspace records, including stopped work; disclose only allowed metadata | Shared | Proposed |
| `axo.workspace.create` | Commit a workspace from an approved directory intent and return stable IDs; do not launch Pi | Shared | Proposed |
| `axo.workspace.rename` | Update the captured workspace's name under revision checks | Shared | Proposed |
| `axo.workspace.archive` | Archive work records while preserving originals; live-work policy must be decided first | Daemon; remote exposure undecided | Proposed |
| `axo.workspace.duplicate` | Create independent records with fresh identities, not a copy of a live writer | Daemon; remote exposure undecided | Proposed |
| `axo.session.list` | Page session records, optionally within a captured workspace; separate presence from Pi readiness | Shared | Proposed |
| `axo.session.get` | Read one session's work/pane metadata, persistence binding and observed lifecycle/readiness; not its transcript | Shared | Proposed |
| `axo.session.create` | Commit a stopped session record with fresh identity in an approved workspace; no implicit launch | Shared | Proposed |
| `axo.session.rename` | Update the captured session's name, preserving manual-title protection and revision checks | Shared | Proposed |
| `axo.session.archive` | Archive the session record without deleting its original history/files; live-work policy is a separate gate | Daemon; remote exposure undecided | Proposed |
| `axo.session.duplicate` | Commit a fresh independent session/conversation identity; history-copy semantics need an explicit decision | Daemon; remote exposure undecided | Proposed |
| `axo.session.start` | Explicitly start the session's managed Pi pane from an approved fresh/resume persistence intent; report spawn separately from readiness | Shared | Proposed |
| `axo.session.prompt` | Submit text/authorized attachment references to the captured admitted Pi binding, with explicit busy-delivery policy and truthful disposition | Shared | Proposed |
| `axo.session.turn.cancel` | Request cancellation of the captured active interaction/run within that session, which may span multiple internal Pi turns; do not kill its process or siblings | Shared | Proposed |
| `axo.session.question.answer` | Resolve the captured pending Axo question with a validated offered choice; never infer approval | Shared | Proposed |
| `axo.session.conversation.get` | Read a bounded active-view snapshot: messages/live state, active run and pending question, with conversation/branch identity | Shared | Proposed |
| `axo.session.conversation.history` | Page canonical-history projections under an explicit conversation/view cursor; not a flat JSONL dump | Shared | Proposed |
| `axo.session.conversation.toolOutput` | Page detail for a captured tool-call identity and output offset; never invoke a tool | Shared | Proposed |
| `axo.observe.subscribe` | Establish bounded observation of an explicit scope with baseline/source/sequence and gap semantics; identify daemon versus service-projection producer | Daemon or service projection | Proposed |
| `axo.observe.unsubscribe` | Release the captured subscription at its owning producer only; do not cancel work | Daemon or service projection | Proposed |
| `axo.session.observe.setViewing` | Report an expiring, explicitly scoped client viewing lease for attention policy; a subscription alone does not prove viewing | Shared | Proposed |
| `axo.observe.event` | Server notification for a subscribed structured change; includes producer/subscription/source/sequence, not an execution receipt | Daemon or service to client | Proposed |
| `axo.command.get` | Read the known receipt/disposition of a logical command within its captured machine/work scope; missing/unknown never means safe to replay | Shared | Proposed |
| `axo.runtime.register` | Admit a public Pi extension's actual conversation/persistence binding against an already-owned expected session/pane/runtime; not process spawn or cloud registration | Managed runtime to daemon only | Proposed; internal admission gate |
| `axo.runtime.list` | Page process/runtime metadata, preserving historical runtime generations | Shared | Existing |
| `axo.runtime.startApproved` | Start an operator-approved generic profile with a durable receipt; not the application session-create/start API | Shared | Existing |
| `axo.runtime.stop` | Request termination of one exact owned runtime; completion must be observed separately | Shared, subject to stop policy | Proposed |
| `axo.session.pane.create` | Commit an approved shell-pane record in the captured session; layout/focus remain client-owned and creation does not launch | Local | Proposed; native pane parity |
| `axo.session.pane.start` | Explicitly start that pane's approved shell/runtime without arbitrary remote argv/cwd; Pi admission remains `session.start` | Local | Proposed; native pane parity |
| `axo.session.pane.remove` | Remove a stopped pane record after ownership/revision checks; not terminal detach, process-stop shorthand or history deletion | Local | Proposed; native pane parity |
| `axo.runtime.terminal.attach` | Acquire a local interactive lease and negotiate a separate local data-channel/rendering contract | Local | Proposed; terminal feasibility gate |
| `axo.runtime.terminal.detach` | Release that attachment lease only, leaving managed work running | Local | Proposed; terminal feasibility gate |
| `axo.runtime.terminal.resize` | Resize under the captured current attachment/input-owner lease | Local | Proposed; terminal feasibility gate |
| `axo.runtime.daemon.stop` | Explicitly stop the daemon and its owned work under confirmation/shutdown policy; not machine power-off or client logout | Local | Proposed; operational gate |

Naming choices to agree before schemas:

- **Create versus start:** `axo.session.create` creates records; `axo.session.start` starts Pi for an existing record. A UI can deliberately compose them using distinct commands, but creating/listing/selecting/restoring never implicitly executes. Fresh versus exact resume is explicit persistence intent on `start`, not a separate `resume`/`restart` shortcut or ambient continue. Existing live-runtime handling must reject or report that binding without creating another writer.
- **Domain hierarchy:** `axo` is the root namespace. Workspace records belong under `axo.workspace.*`; session interactions, conversation views, questions and pane records under `axo.session.*`; live process/admission/terminal/daemon lifecycle under `axo.runtime.*`; cloud machine/catalog routing under `axo.machine.*`. Only truly cross-cutting protocol, transport, observation streams and receipt lookup retain their own infrastructure namespaces. Nesting is not limited to three segments.
- **Catalog:** source inspection distinguishes authoritative daemon reads (`axo.workspace.list`, `axo.session.list`) from offline-capable service replica reads (`axo.machine.catalog.list`), published through `axo.machine.catalog.publish`. The latter is not an alias or second writer. Published pages disclose machine/source/revision/freshness; subscriptions distinguish the producer, and clients never merge incompatible pages. Stale catalog availability cannot authorize offline execution or unsolicited history publication.
- **Session versus conversation:** `axo.session.get` is the work/lifecycle projection; `axo.session.conversation.get` is the bounded chat snapshot. History and tool detail stay under `axo.session.conversation.*`. Branch mutation/fork APIs are not selected by this naming pass.
- **Session turn versus internal Pi turn versus stop:** the selected name is `axo.session.turn.cancel`. Here a session turn means the captured active user interaction/agent run, not one provider/tool iteration identified by Pi's internal `turnIndex`. The legacy `runId` starts at public `agent_start` and ends at `agent_settled`; cancellation uses public Pi abort under that binding. Preserve this scope while adopting the selected session-nested name. `axo.runtime.stop` terminates one owned runtime; `axo.runtime.daemon.stop` is daemon shutdown. There is no ambiguous `axo.session.cancel` or session-wide kill method. Multi-pane stop orchestration needs a separate contract if required.
- **Admission and panes:** `runtime.register` is the managed extension's internal admission seam, not a native control-client ability to claim Pi readiness. Preserve expected owner/binding checks without blindly importing the old Unix/capability-secret machinery. `axo.session.pane.create/start/remove` preserve Mac shell-pane behavior; a UI composes stop-and-remove only after explicit intent and observed lifecycle, while `axo.runtime.terminal.detach` merely releases presentation.
- **Reconciliation versus replay:** `command.get` is read-only lookup, not a retry/recovery executor. Existing same-intent start reconciliation remains valid; a receipt lookup does not authorize a new command or replay of an uncertain prompt. Work mutations require durable command identity; connection maintenance and observation leases use their scoped ephemeral identities, not another execution journal.
- **Events:** use one `observe.event` notification with a typed change kind, not a separate RPC method for every Pi callback. Candidate kinds include `machine.changed`, `catalog.changed`, `session.changed`, `conversation.changed`, `run.changed`, `turn.changed`, `toolCall.changed`, `question.changed` and `file.changed`; payloads/coalescing and file-event sourcing remain undecided. Preserve the legacy session/lifecycle/turn/assistant/tool/input/model/provider observation categories where appropriate; observing an event does not imply an RPC to perform that action. Raw terminal, audio and file bodies are not event payloads.
- **Other planes:** no `axo.runtime.terminal.input`/`axo.runtime.terminal.output` control RPC is selected; raw bytes belong to the separately gated local data channel. File reserve/authorize/complete/list/download/delete remain existing HTTP capabilities, not new `axo.file.*` aliases. Model/follow-up controls remain with Pi until their structured scope is accepted; voice, layout and drafts remain client-local.

A lightweight intended flow is: `axo.workspace.list` → `axo.session.create` → explicit `axo.session.start` → `axo.session.get`/scoped observation of Pi readiness → `axo.session.conversation.get` → `axo.session.prompt`. Reads and readiness observations do not execute. An uncertain mutation goes to `axo.command.get`, not an automatic resend. Exact schemas, cursor fields, error variants and public Pi admission evidence are the next contract pass.

### Legacy source audit — 2026-10-10

Source inspection at `6befdaa` covered every `bridge/*.ts` module, the legacy service entrypoint/catalog/file lifecycle, shared schemas, native command/event decoding and relevant native registry/client operations. This is a source inventory; test sources were inspected but no legacy runtime/device acceptance was rerun during this pass.

#### Public client commands and their replacements

The legacy phone schema contains exactly these twelve commands. Preserve their useful semantics, not their spelling or subscription-as-selection coupling.

| Legacy command | Proposed replacement | Behavior that must survive |
| --- | --- | --- |
| `sync` | `axo.machine.catalog.list` + `axo.session.conversation.get`, with scoped observation/resync | Refresh catalog and selected conversation; reconnect never executes work |
| `catalog_page` | `axo.machine.catalog.list`; authoritative `axo.workspace.list` / `axo.session.list` when explicitly requested | Bounded workspace/session pages and offline cached visibility; invalidation must be explicit rather than silently mixing revisions |
| `subscribe` with session/null | `axo.observe.subscribe` / `axo.observe.unsubscribe` | Subscribe/unsubscribe and receive a baseline; explicit work target is not ambient UI selection |
| `create_workspace` | `axo.workspace.create` | Durable created IDs; legacy creation also returns an initial session record, so decide that result/initial-record policy explicitly |
| `create_session` | `axo.session.create` | Stable stopped record in captured workspace; explicit launch is separate |
| `rename_workspace` | `axo.workspace.rename` | Name validation and expected catalog revision conflict |
| `rename_session` | `axo.session.rename` | Manual Axo name protection and revision conflict; not Pi conversation-title mutation |
| `prompt` | `axo.session.prompt` | Text or attachment-only submission; busy steering, pending-question rejection, durable command association and no automatic replay |
| `answer` | `axo.session.question.answer` | Exact current Axo question/options, sibling local-dialog resolution and no cancellation-as-approval |
| `cancel` | `axo.session.turn.cancel` | Exact active interaction/run identity within the captured session and public Pi abort, followed by real settlement observation |
| `history` | `axo.session.conversation.history` | Both before/after paging, active-view fence and earlier/later continuation state |
| `tool_output` | `axo.session.conversation.toolOutput` | Recorded tool-call lookup, UTF-8 byte offsets and retained Pi bash spool detail; no caller-supplied host path |

The native decoder consumes nine relay response/event kinds: `catalog_page`, `subscription`, `snapshot`, `history`, `tool_output`, `presence`, `files_changed`, `ack`, `error`. These become typed method results/errors plus `observe.event`, not nine extra callable methods. Host `catalog` publication is an internal projection write. `catalog_request`, `session_sync`, `runtime_register`/`runtime_registered`, `mac_command`/`mac_reply`, status/fatal messages and transport ping are internal coordination; managed runtime admission becomes `axo.runtime.register`, and host catalog publication becomes `axo.machine.catalog.publish`. These are producer-only boundaries, not general native client operations. Do not expose broker plumbing as general client RPCs.

#### File and extension surfaces are separate planes

Under `/files/sessions/{id}`, the public HTTP surface is `POST uploads` (reserve), `POST uploads/{fileId}/authorize`, `POST uploads/{fileId}/complete`, `GET files` (paged inventory), `GET files/{fileId}` (metadata/status), `GET files/{fileId}/content` (download), and `DELETE files/{fileId}`. Signed conditional PUT goes directly to R2. `uploadContent` in the service is an internal test-fixture path, not an eighth public upload-body endpoint. Preserve reservation reconciliation, checksums, immutable originals, pending/ready/deleting/deleted states, quotas and deletion fencing; do not move them into control frames.

Despite the HTTP path/field name `sessionId`, this file namespace currently names the **Pi conversation**, not the Axo work-session ID. `files_changed` also uses that conversation namespace. Migration must explicitly map machine/work-session/conversation identities without rewriting existing file ownership or keys.

`axo_ask`, `axo_share_file`, `/axo-share` and `axo_set_title` are installed Pi tools/commands, not existing relay RPCs. Sharing entails consent/staging/verification and canonical attachment references; photo conversion and custom renderers are presentation. Pi title changes use public Pi naming/persistence and replacement confirmation, while native `session.rename` protects the separate Axo label. Observe title changes and retain these extension behaviors; do not invent `tool.execute`, arbitrary `file.publish(path)` or a second Pi-title writer to achieve apparent parity.

#### Gaps and legacy quirks not to copy

- The old service stores catalog pages durably and serves them with `hostOnline: false`; live daemon reads alone lose that offline browser capability. New published replicas remain bounded, consentful and explicitly stale when appropriate.
- The old relay requires commands to match a socket's selected subscription and rejects pending ID collisions across phone sockets. The new contract uses captured explicit targets and per-hop correlation; subscription state is not execution authority.
- The extension emits eight observation categories and coalesces snapshots with bounded recent/pending events. Provider/model changes, compaction/tree/switch events, UI waits and tool progress need typed observation coverage, not an automatic command for each callback. Live snapshots and canonical history are distinct.
- The projection uses timestamp-derived assistant/streaming display keys and a synthetic in-memory streaming overlay. Do not adopt those as canonical history or execution identity. New projections need persisted entry/block identity and explicitly ephemeral public-event-bound stream identity; no fabricated JSONL records.
- Rename `ack` supports `updated` in the TypeScript host schema but the inspected Swift decoder accepts only created/submitted/cancelled. Typed method results and cross-language fixtures must resolve this schema mismatch; source presence is not evidence that these paths currently work.
- Some legacy limits are character-based or exceed the new 64-KiB encoded budget (history projection allows up to 72,000 encoded bytes). Rebudget every snapshot/history/tool/event result; do not mechanically reuse legacy constants.
- Native shell-pane create/close and Pi title/attention observation exist outside the phone schema. Pane work records move behind daemon ownership; split geometry/focus and notification rendering remain native. Model selection/thinking-level events are observations, not old phone control RPCs.

### Common destination and outcome rules

- **Work target:** explicit machine/host source plus workspace/session/pane where applicable. Registry mutations validate existence and expected revision; observation cursors bind source/revision. Never use a global selected session as authority.
- **Pi target:** add admitted runtime generation, actual Pi conversation and active view/branch identity where required. Define whether branch changes reject or invalidate each operation; they cannot silently redirect it.
- **Interactive target:** add attachment identity for terminal input/resize, pending question identity for answers, and authoritative agent-run identity for cancel. No IDs derived from terminal output, timing or guessed model activity.
- **Mutation identity:** RPC ID is hop correlation; stable `commandId` identifies normalized intent. Conflicting reuse rejects. A receipt distinguishes known disposition from uncertain external effects; a pre-dispatch marker alone cannot prove Pi received a prompt.
- **Observation identity:** subscription, source and sequence/revision identify events. Delivery credit ACKs do not acknowledge Pi execution. Lost live events trigger read-only resynchronization, not command replay.
- **Asynchronous boundary:** capture target before awaiting and revalidate before dispatching/applying results, including attachment preparation, confirmations, history loads and notification clicks.

### Capability-specific result and reconnect semantics

| Operation family | Required request / result / observations | Reconnect and failure contract |
| --- | --- | --- |
| Registry/catalog | Named intent, expected revision and command identity; committed IDs/revision; bounded catalog pages/changes | Reconcile committed intent; invalidate stale cursors explicitly; never recreate or launch from a page |
| Session start/resume | Approved work/persistence intent; durable runtime disposition; separate Pi-ready/failed/recovery observations | Inspect/reconcile same receipt; exact canonical persistence binding; no automatic launch after restart or uncertain old writer |
| History/tool detail | Conversation/view-bound cursor or tool identity/offset; bounded pages with continuation/truncation | Rebaseline on branch/source mismatch; canonical Pi tree remains authoritative; define stopped versus live read behavior |
| Prompt | Captured admitted target, logical command, text/authorized attachment references and explicit busy-delivery policy; submitted/steering/rejected/unknown disposition; subsequent public Pi observations | No automatic replay; define reconciliation evidence and before/after-dispatch crash windows; follow-up requires a separately specified public Pi queue contract |
| Question/answer | Pending question/options and identity; response-bearing answer intent and disposition; pending/resolved observation | Recover only the same valid question; late answers cannot resolve another runtime/question; no fabricated approvals |
| Run cancel / runtime stop | Authoritative run/runtime target and command identity; request disposition followed by actual terminal/Pi lifecycle facts | Timeout is not completion; stale targets fail; never signal historical PIDs or stop a sibling/host through implicit selection |
| Subscription/presence | Explicit scope, baseline and bounded updates; source/sequence, gap marker, expiry and unsubscribe disposition | Release client resources on quit; refresh observations after gaps/expiry; do not stop already accepted work |
| File references | Authorized machine/session/conversation and immutable file IDs; existing transfer/deletion dispositions | Preserve existing authority and tombstones; revalidate after preparation; do not duplicate uploads or submit a prompt with deleted references |

### Authority and compatibility

Choose the daemon-owned registry seam before enabling registry mutation: either port the compatible operations/format with fixtures or supervise a narrow native adapter. These are alternatives, not two concurrent writers. Preserve existing work IDs, manual names, archive originals, private permissions and canonical Pi paths. Window selection/layout remain frontend state.

Pi alone writes its JSONL. Reading JSONL is not a substitute for public live events or knowing the current branch; a flattened history dump is not canonical conversation state. Public extension APIs may persist Axo metadata through Pi, but Axo must not manufacture transcript records or replace the agent loop.

The cloud owns routes, leases and bounded projections only. Registration does not upload full histories. History/tool detail is demand-driven; catalog publication and retention require explicit policy. Access remains the existing cloud-edge gate. Local WebSocket remains intentionally credential-free with browser guards, not OS-user authentication. This RFD adds no credentials, account/user-management or refresh framework.

### Bounds, capabilities and errors

Retain the shared 64-KiB encoded control-frame limit rather than copying the legacy 256-KiB envelope allowance. History, Unicode, tool detail, attachment metadata and event batches need encoded-byte tests as well as record counts. Set subscription count/byte budgets, snapshot truncation and resync rules before shipping events; never rely on an unbounded producer/cache.

Capabilities must distinguish daemon support, route availability and admitted runtime readiness. A protocol version or online host cannot imply prompt/history support. Define unsupported, stale destination/view, conflict, capacity, storage, recovery-required, known rejection and unknown outcome distinctly. Keep metadata-only diagnostics; do not log payloads, transcripts, terminal bytes, tokens or signed URLs.

The inspected public SDK exposes `ui_prompt_start`/`ui_prompt_end` lifecycle events, and the legacy extension already observes them. They identify kind/title, not a remotely answerable question with choices or a general approval API. Only Axo-owned `axo_ask` questions currently have the actionable remote-answer contract. Do not repeat the stale claim that no public UI-wait observation exists, or infer complete permission parity from these hooks. Decide and test headless behavior before claiming ready/no-window support; no private APIs or terminal-text workaround is permitted.

## Implementation order and acceptance

These are dependency gates, not a commitment to implement every row in one release. Terminal feasibility and registry characterization can proceed independently, but cutover waits for their relevant gates.

1. **Specify the Pi binding and registry seam.** Define explicit start/resume targets, canonical persistence ownership, readiness registration, single-writer exclusion and receipt/recovery schemas. Use isolated state; no live registry migration.
2. **Prove real session start/admission.** One actual vanilla Pi under `axod`, then two distinct addressed sessions. Verify spawned versus ready, public registration, exact history binding, headless behavior, stale generation rejection and no duplicate writer/replay after disconnect/restart.
3. **Deliver read-only catalog/history and bounded observation.** Establish machine/source/revision and branch semantics, stopped records, tool detail, event gaps, subscription budgets and demand-driven disclosure before native chat depends on them.
4. **Deliver addressed prompt/question/cancel semantics.** Exercise actual public Pi delivery, busy steering, attachments' preparation boundary, durable reconciliation, late answer/cancel rejection and unknown-outcome crash drills. Keep file transfers on their existing authority initially.
5. **Move native capabilities deliberately.** Use the shared Swift client/models with method validation. Browse first; replace chat only after its required rows pass. Independently prove Ghostty attachment, compatible registry handoff and file authorization/cutover. Never fallback to another execution owner on failure.
6. **Validate operations and delivery.** Real Mac/iOS scenarios, no-window work, workbench quit/reopen, cloud outage/expiry, orphan recovery, upgrade/rollback and signed packaging. Startup/live migration/phone installation require separate consent.

Every shared daemon capability must have the same semantic test on local and relayed routes; only caller policy may differ. Include malformed requests, notifications that cannot mutate, stale/cross-machine targets, colliding RPC IDs, conflicting command IDs, encoded limits, slow/disconnected consumers, and failures immediately before/after dispatch. Test sibling isolation and target changes during awaits. Source/unit/fixture success does not establish native or physical-device acceptance.

Update the matrix when a contract or evidence changes, citing the implementation and its acceptance boundary. Keep detailed PR/task/test-run tracking outside the RFD; this document owns the rationale, parity requirements and gates.

## Drawbacks and alternatives

- Inventory and cross-language fixtures require maintenance; stale status is worse than an explicitly missing feature.
- Capability-by-capability coexistence requires clear call-path and ownership boundaries, but is safer than a big-bang replacement.
- Copying the old protocol verbatim is cheaper initially but carries implicit selection, transport correlation and legacy bounds into the new design. Preserve behavior instead.
- Implementing only the next method without this map is fast locally but risks reaching native migration with missing questions, tool pages, files or recovery semantics.
- Keeping the legacy protocol indefinitely is a valid fallback release strategy, but does not provide daemon-owned application parity or independent workbench lifetime.

## Unresolved decisions

Before each owning slice, resolve:

- Registry compatibility seam and the minimum isolated work-record model for explicit Pi start; create versus start must remain distinct intents.
- Public Pi readiness/registration protocol, canonical persistence binding and ownership exclusion, including external unmanaged writers.
- Acceptance of the proposed canonical catalogue/scopes above, followed by exact schemas and compatible capability advertisement; proposed names do not imply availability.
- Prompt receipt evidence across crash windows; authoritative run identity and supported busy-delivery policy.
- Active branch/view epochs, stopped-history access, event/snapshot schema, sequence gaps and exact observation budgets.
- Headless extension UI behavior and which missing public observations require truthful unsupported/unknown state.
- Remote exposure of archive/duplicate/model controls; these are not automatically old phone requirements.
- File machine scoping, catalog disclosure/retention and independent native terminal/file/registry handoff criteria.

No unresolved item authorizes private Pi APIs, transcript fabrication, a second file/registry authority, new auth machinery or automatic execution replay.
