# Axod Pi recovery hardening

## Scope

This pass removes Pi takeover waits from the shared Session catalog mutex. It does not change Axod's PTY ownership, Pi's canonical transcript ownership, the pinned Ghostty revision, or automatic-recovery consent policy. UI verification is deferred at the user's request.

## Transition and ownership

1. Under the catalog mutex, verify the unavailable pane and its unique persisted history owner, capture owned launch inputs, and reserve a daemon-local recovery identity.
2. Outside that mutex, validate the existing history and authenticate/request the allowed shutdown, acquiring the original exclusive writer lock before proceeding. Connect/read deadlines do not restart on partial bytes or unrelated events. Polls observe reservation invalidation.
3. Revalidate history device/inode, then briefly reacquire the catalog mutex to validate the reservation and rotate the bridge credential. Spawn outside the mutex.
4. Commit only if that exact reservation is still current. Otherwise terminate/reap the newly owned child outside the mutex while retaining its writer lock. A failed attempt releases its reservation and leaves the unavailable pane represented.

Close/removal/shutdown invalidates reservations. Force-signal dispatch and invalidation are serialized by short guarded syscalls, not by holding the mutex during child waits. Already dispatched graceful shutdown requests cannot be recalled. Automatic recovery remains idle-only and non-forcing.

Startup restoration and archived-session resume register unavailable panes before dropping the mutex and use the same recovery path. Existing runtimes are not replaced by another restore call. Target availability and requester archival during `/resume` are checked in one catalog transition.

Recovery rejects missing, ambiguously owned, leaf-symlinked, outside-directory, or replaced history rather than creating a new transcript at the old path. Writer-lock opens reject symlinks/nonregular files and do not truncate existing contents.

## Verification

Executed against isolated fixture catalogs/processes, not the normal database or Pi histories:

```sh
cargo test -p axo-server -p axod --locked
cargo test -p axo-server --lib session::tests
cargo clippy -p axo-server -p axod --all-targets -- \
  -D warnings \
  -A clippy::too_many_arguments \
  -A clippy::manual_is_multiple_of \
  -A clippy::chunks_exact_to_as_chunks
cargo fmt --all -- --check
git diff --check
```

- Full Cargo lane: **63 server tests, 7 helper unit tests, 7 daemon/RPC tests passed**.
- Session/lifecycle lane: **39 tests passed on three consecutive additional runs**.
- Clippy passed with only the three pre-existing lint categories explicitly allowed above. This is not a claim of an unqualified strict Clippy pass.
- Sixteen new regressions cover stalled takeover with responsive sibling catalog/PTY operations; duplicate recovery; close/cancellation under both policies without force escalation; shutdown fencing; failed exec and retry; late-launch cleanup; missing/ambiguous/symlinked/outside/replaced history; lock symlinks; restore isolation/idempotence; stale lease release; safe resume gating; full socket queues; dribbling records; and endless unrelated events.
- Lifecycle fixtures now seed an owned shell wrapper before opening their private database, avoiding account login-profile and history initialization in those tests. Initial concurrent-run failures exposed fixture timing assumptions; final evidence above uses bounded lock-release checks and deterministic fixture startup.

Packaging and packaged-helper RPC results are reported with the delivered bundle/build/source stamp, rather than inferred from these source tests. Building/replacing the bundle does not upgrade running processes.

## Remaining boundaries

This pass is not proof that every lifecycle operation is nonblocking or that a daemon restart is transparent:

- New Session admission still performs local filesystem work and process creation under the catalog mutex, but never performs takeover of an existing writer there.
- Bootstrap recovery remains sequential before daemon startup completes. Releasing the catalog mutex does not itself provide parallel boot admission or a startup-wide deadline.
- Explicit bridge-unavailable fallback still invokes system process-inspection utilities (`lsof`/`ps`). Those subprocesses are outside the catalog mutex but do not yet have their own cancellation/output/deadline contract.
- Shutdown fences recovery commits; an in-flight exec may still finish before its caller cleans up the rejected launch. This is not a durable completion receipt for arbitrary process crashes/power loss.
- External filesystem mutation after the final history check is outside Axod's cooperating-writer lock protocol. Device/inode revalidation detects replacement during takeover, not arbitrary hostile changes at every subsequent instruction.
- Packaged UI/physical input acceptance and normal live-service handoff remain separate. No real frontend/service was stopped or restarted during this pass.
