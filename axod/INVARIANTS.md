# axod ownership boundaries

The architectural contract is [RFD0012](../docs/rfds/RFD0012-sqlite-desired-state-and-session-materialization.md). These boundaries describe central authority and the native execution seam, not installed-service or UI acceptance.

## One session authority

- The central store owns workspace/session/pane intent, immutable original operations, configuration revisions, runtime attempts and canonical bindings. Unsent drafts are bounded volatile client buffers, never persisted/restored by either process; removing draft storage does not remove original command receipts. Neither the runtime journal nor a frontend is a competing catalog.
- The service claims the top-level helper lease without reading legacy catalogs, then opens its dedicated central directory. Old bytes remain unimported. Unsafe/mixed roots fail closed; supported central schema upgrades are separate from legacy migration.
- Machine, host, store, session, pane, runtime, attachment and command identities have distinct meanings. Central addresses capture store generation as well as machine/boot identity. Session addresses include explicit parent membership.
- Publication of the complete graph/original precedes effects. A reserved attempt has an exact runtime and captures pane/session/workspace revisions individually. Unknown reservations or admission cannot be issued as another spawn.
- Every effectively open pane is independently materialized without attached clients. Parent archive/reopen preserves child choices. Exit changes availability, not desired-open intent. An old live runtime cannot claim readiness for a newer configuration.
- Completion-proven successors keep the desired pane identity. Missing original completion is blocked, not permission to adopt a process, signal a historical PID or replace a Pi writer.

## Native launch and completion

- Native launch fingerprints bind exact target, argv/directory and ordinary/control-channel mode. Reconciliation precedes new spawn. The native journal stores execution and completion evidence only.
- Durable launch intent precedes `forkpty`. Drain/reaper ownership is retained even if Running publication fails. Fenced persistence is an unknown outcome, never a no-effect claim.
- Only a still-owned live terminal may signal or reap its child/group. A valid numeric PID is not ownership. Reaping, normal output closure, initial-group absence and durable completion are independent prerequisites for a completion witness.
- Visible exit, EOF alone, failed terminal I/O, uncertain group membership or failed completion persistence cannot authorize replacement. Interim recovery records cannot overwrite final completion.
- Admission freezes before service teardown. Disconnect, frontend exit and presentation changes never stop work or mutate intent. Escaped/job-control descendants, host crash and authoritative VT recovery remain distinct limits; a backlog or process absence proves none of them.
- Only standard descriptors survive ordinary child exec. A controlled Pi launch additionally owns its paired anonymous fd 3. Parent resources use CLOEXEC; the fork child closes nonstandard inherited descriptors using bounded pre-fork preparation and libc-only post-fork operations.

## Canonical Pi ownership

- Ambient interactive vanilla Pi plus the installed public extension owns canonical JSONL and actual public lifecycle. No bundled engine, alternate RPC mode, transcript writer or terminal-text command injection is introduced.
- Admission binds exact runtime, chat, canonical file and captured directory. Native process-running alone is not Pi readiness.
- Resume requires an exact stored binding, completion proof for the previous writer, validated public header/tree and cooperative writer lease. Missing lazy empty-history files remain blocked; another chat identity is not a recovery substitute.
- Writer/service leases explicitly unlock before closing their descriptors so fork-inherited copies cannot prolong released ownership. Cooperative leases do not exclude arbitrary unmanaged same-user writers.
- Canonical readers reject unsafe, incomplete or changed sources and reconstruct parent-linked branches rather than flattening terminal/transcript observations. Reader access alone never proves writer completion.

## Transport and effects

- Central RPC owns intent; the separate native terminal plane owns exact attachment/input/resize/detach leases. Metadata RPC carries no terminal bytes.
- Caller-selected argv, remote filesystem paths and notifications cannot admit execution. Request IDs correlate replies; durable command IDs identify originals. Missing/unknown replies require read-only reconciliation, never automatic replay.
- The codec admits bounded finite Unicode-scalar JSON, exact safe integer semantics, closed parameters and bounded IDs/frames/batches. Credit admission precedes effects. Oversized post-dispatch replies preserve each original hop ID as outcome-unknown.
- Client/relay loss releases only the relevant lease/connection, not children. Relay reconnect repeats registration/lease establishment, never execution. Credentials, prompts, audio, terminal bodies and sensitive paths do not enter diagnostics.
- Loopback Host/path/Origin guards are browser/rebinding protection, not hardened OS-user authentication. Routing UUIDs and private discovery are not credentials.

See [the test boundary](tests/README.md) for the scope of disposable process/filesystem evidence. Native clients and their durable-input contracts require a clean central cutover; deleted JSON authorities and legacy startup fixtures are not compatibility or acceptance paths.
