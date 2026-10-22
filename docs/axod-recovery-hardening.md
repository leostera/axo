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

## Initial recovery-pass verification (`9ae1ebaf`)

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

## Bounded owner-inspection follow-up

The explicit bridge-unavailable fallback now runs `lsof` and all subsequent `ps` calls with a **single two-second inspection deadline**, cancellation checks between nonblocking reads/waits, a **16 KiB stdout cap per tool**, and at most **32 unique owner PIDs**. Stderr is discarded; tool output and command arguments are not logged. `lsof` avoids hostname/port-name lookups. Rejected inspections report only Session ID, elapsed time, and error kind, and never authorize force termination from partial results.

Inspection utilities start in their own owned process groups. Error cleanup confirms retained child/wait ownership with `waitid(WNOWAIT)`, stops only that inspection group, and uses a separate bounded two-second reap budget. A leader is not reaped while descendants retain stdout, preserving the group identity needed for cleanup. Lost wait ownership or unconfirmed cleanup is logged and is not permission to signal an adopted/reused PID. This runner is for the fixed metadata tools, not a general supervisor for arbitrary daemons or descendants that escape their group.

Owner-list parsing rejects reserved/self/out-of-range PIDs, invalid encoding, excessive owners, malformed UID/group/command records, and multi-process `ps` responses. Existing exact-user/one-Pi-process-group checks remain mandatory. Automatic recovery never enters this explicit-only fallback.

Follow-up verification:

- `cargo test -p axo-server -p axod --locked`: **74 server tests, 7 helper tests, 7 daemon/RPC tests passed**.
- The entire **74-test server suite passed three additional consecutive runs**.
- Both `//crates/axo-server:axo_server_tests` and `//crates/axod:rpc_tests` passed with cache disabled in Bazel's default and optimized configurations.
- Eleven new tests cover exact output limits/floods; hung tools with open or closed stdout; cancellation; pre-spawn expiry/cancellation; one deadline across sequential tools; exited-leader/descendant-pipe cleanup; lost wait ownership; bounded PID/owner parsing; and cancellation through the real lock-inspection entrypoint.
- Clippy passed with the same three pre-existing lint categories allowed above. Formatting and diff checks passed.

The first Bazel attempt exposed an undeclared local Pi-extension dependency in existing launch fixtures. Tests now declare an inert extension runfile, and daemon RPC fixtures use an explicitly owned inert Pi executable rather than loading ambient account Pi configuration. These fixtures verify catalog/PTY/lifecycle behavior, **not real Pi extension or model behavior**. Extension resource paths are made absolute before crossing from Axod's cwd into a Workspace child.

## Remaining boundaries

This pass is not proof that every lifecycle operation is nonblocking or that a daemon restart is transparent:

- New Session admission still performs local filesystem work and process creation under the catalog mutex, but never performs takeover of an existing writer there.
- Bootstrap recovery remains sequential before daemon startup completes. Releasing the catalog mutex does not itself provide parallel boot admission or a startup-wide deadline.
- Metadata inspection now has bounded running-tool/output/cancellation behavior, but kernel/filesystem process creation via `Command::spawn` cannot itself be preempted by this userspace deadline. Cleanup has a separate reap budget and reports uncertainty rather than claiming success when ownership or termination cannot be proved.
- Shutdown fences recovery commits; an in-flight exec may still finish before its caller cleans up the rejected launch. This is not a durable completion receipt for arbitrary process crashes/power loss.
- External filesystem mutation after the final history check is outside Axod's cooperating-writer lock protocol. Device/inode revalidation detects replacement during takeover, not arbitrary hostile changes at every subsequent instruction.
- Packaged UI/physical input acceptance and normal live-service handoff remain separate. No real frontend/service was stopped or restarted during this pass.
