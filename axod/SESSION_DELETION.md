# Session deletion

`axo.session.delete` is a local-only addressed operation. Parameters are a machine/host target, command ID, expected work revision and 1–32 unique `{workspaceId, sessionId}` addresses. Missing scope, duplicates, extra execution fields, stale revisions and unknown records are rejected. Cloud callers cannot invoke it.

The native row menu freezes the clicked session outside selection or the selected set inside it. The native confirmation explains that Pi/all shells and running commands stop, sessions disappear from Axo, and canonical histories/drafts remain on disk. Cancel dispatches nothing. Confirmation rechecks source, operation and catalog revision. It is not live-helper restart or uncertain-process adoption consent.

## Durable lifecycle

1. Serialize against Pi/shell admissions in the supported lock order; under the shared admission fence, capture every exact runtime in the selected sessions.
2. Refuse prepared/uncertain starts or an incomplete runtime from another birth epoch before issuing any signal.
3. Persist the immutable deletion intent and captured runtime set in `work-records.json`, with null receipt revision. Fence starts into those sessions and metadata mutations until settlement. Captured pane IDs remain reserved.
4. Stop only the captured owned runtimes through Manager; await its exact durable completion/resource proofs.
5. Persist one work revision and atomically tombstone the entire selected batch. Retain underlying session/directory records, work/Pi/pane receipts and canonical files. Active catalogs/get/admission omit or reject tombstoned sessions; retained records are used only to validate stored receipts.

A completed receipt has `revision == expectedRevision + 1`; null means prepared/unknown. Original command replay returns original state and never repeats stop effects. `axo.command.get` may finish the original catalog commit when all exact completion proofs exist, without signals, history writes or a new command. A partial stop leaves the entire catalog batch pending and visible; reconciliation does not signal the remaining runtimes. Incomplete evidence remains pending. Boot validates captured runtime sets against the journal, including durable completion for committed deletions; forged/omitted evidence fails closed without rewriting files.

Pending native hints preserve the original typed addresses/revision/command. Missing, malformed, mismatched or unavailable outcomes are not retry authority. Reconciliation checks the original intent and private endpoint before clearing matching hints. Opaque hints remain fenced. Draft text/tickets and history paths are not deleted. Confirmed deletion releases presentation-only cached surfaces and completed managed-control leases; it does not erase receipts or alter unrelated runtime/viewport state.

Deleting is catalog tombstoning, not history purge. Retained records/receipts still count toward their bounded storage capacity. No new default session is automatically launched as a side effect.

## Validation

- `session_deletion_tests` exercises exact owned child shutdown, batch atomicity, a surviving unrelated runtime, immutable receipts, restart retention, refusal of uncertain epochs, pending no-replay reconciliation, failed durable reservation and cross-journal completion validation.
- Shared TypeScript/Swift tests reject malformed scopes, duplicates, wrong revisions, extra fields and invalid receipt/runtime sets.
- `scripts/check-mac-ui.sh` uses actual packaged-app XCTest: Cancel, outside-selection clicked-row deletion while displayed Pi remains enabled, and selected cross-workspace batch deletion. Rust verifies two original committed receipts, three exact tombstones, retained unrelated records and byte-for-byte unchanged real ambient-Pi canonical history after deletion. Exactly one model request is allowed.
- Managed controlled children use private `umask(077)` before exec. Existing histories and parent/default-shell umask are untouched. The canonical history fixture requires an owned no-follow regular single-link private file before its comparison.

Normal state, accepted live work, service registration, credentials and device/deployment lanes are not part of these disposable fixtures. Move, history purge, power loss and operator recovery of uncertain runtimes are separate capabilities.
