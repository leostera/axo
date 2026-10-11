# Admission-fenced empty startup checkpoint

**Source + owned daemon/CLI/client-state evidence, not actual packaged-app A02/A03/A07 acceptance.**
Exact committed/package versions will be recorded after packaging.

## Authority and behavior

The local-only `axo.session.createIfEmpty` commits standalone session metadata in
the daemon-captured HOME only when the daemon's namespace is genuinely empty at
admission. It accepts captured machine/host, command ID, name and expected work
revision—not a path, profile, workspace or argv. Cloud calls return -32601.
Creation itself does not start a PTY/Pi. The native explicit creation pipeline
then starts the right shell and independent left Pi through their original
captured commands, as described in [the sequencing checkpoint](native-two-pane-creation.md).

A distinct immutable `CreateStartupSession` intent preserves this predicate in
receipts; it is not an alias for unrestricted creation. Under the same admission
mutex as metadata/generic runtime/Pi/pane operations, the daemon rejects fresh
startup creation if workspaces/sessions, managed/pane receipt hints or **any
retained runtime record** exist, or storage is fenced/stopping. "Empty" does not
mean no running PID, apparently idle, a completed historical process, or safe
helper-replacement permission. The work-store transition also checks empty work
and validates startup chronology when recovering persisted receipts.

Repeated original commands reconcile the original receipt before applying the
empty predicate, including after reboot or loss of current HOME policy. Changed
public intent does not match it. No creation result invents a Pi binding.

Native automatic authority is consumed once per app-launch coordinator, not on
ordinary reconnect, catalog reload or restoration. Eligibility requires connected,
complete empty work/runtime pages and no pending preference hint for that exact
machine. Even unreadable work/Pi/chat/shell/upgrade hints block automation and are
preserved. A second pre-dispatch check prevents a newly saved local hint from
slipping in. The daemon's atomic predicate, rather than those observations, is
the race fence. Known rejection/unknown/blocked startup stays inline, without a
modal, a second Open Session action, hint cleanup or automatic retry.

## Evidence

- Rust: **99 library cases**, interactive Pi 1, local sessions 2, managed-public 1,
  actual CLI 8, relay-config 4; zero failures/ignored cases in serial execution.
  Four new unit cases cover original/reboot/HOME-loss receipt, concurrent creates,
  retained runtime/nonempty work and cloud/path/argv/workspace rejection.
- Actual `axo` -> production local WebSocket -> owned `axod serve` fixture races
  two startup requests: one session commits, matching-revision nonempty creation
  fails, no runtime starts, and owned daemon reboot returns the original metadata
  receipt without execution. This is not a native app-click fixture.
- First retained-runtime assertion incorrectly assumed child exec failure meant
  process admission failed. Corrected to observe the accepted PTY/runtime record;
  dispatch is not readiness/completion. No terminal bytes were logged.
- Clippy all-targets -D warnings, fmt and diff checks pass.
- TS protocol **25 passes/no skips**, schema regeneration/check, protocol/API
  properties pass. Swift protocol **40 cases/1 existing relay-environment skip**,
  zero failures; skip remains missing route acceptance.
- Mac/iOS compile and client-state hint checks pass. Native hint checks preserve
  an opaque machine-scoped hint without dispatch or deletion; unrelated machine
  hints do not grant or remove authority on this machine.

## Open acceptance

Actual packaged Mac genuinely-empty launch, later empty launches, simultaneous
native clients, restored/stopped records, pending hints, Pi delay/failure/questions,
real two-pane usability and service startup/handoff remain open. These fixtures
close no complete workflow gate. Full VT recovery and other inventory gaps remain.
No live app/helper restart, credentials/deployment mutation or device install was
performed. Owned fixture restart never signals historical/unowned PIDs.

Logs: `/tmp/axo-empty-start-{unit,cli,rust,clippy,ts-build,schema,protocol-ts,protocol-properties,api-properties,swift,mac,ios,client}.log`.
