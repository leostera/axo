# Default user-shell policy checkpoint

**Component evidence only; no supported-workflow acceptance gate is closed.**
Exact committed implementation/package versions are recorded after packaging.

## Contract

Local `axo.session.pane.add` accepts null/omitted `profileId` for the boot-captured
user login shell with `-l`, or an approved profile string for configured argv.
Rust parses these into distinct `ShellSource` values before effects. Existing
string intents/receipts keep their JSON representation; default intents serialize
as null and cannot collide with configured-profile receipts.

The daemon captures SHELL when present, consulting the account shell only when it
is absent. Relative, missing, non-executable and replaced executable identities
fail without fallback. Cwd comes from the original work record: captured HOME for
standalone, approved canonical folder for project work. Configured-workspace
approval still requires its current matching profile. No caller path/argv is
accepted, and the default policy is not exposed as a generic cloud launch profile.

Original receipt reconciliation precedes current executable/directory checks and
never starts work again. Add/remove retain intent-before-effect, cross-domain
fences, exact runtime binding and completion-gated tombstones.

## Evidence

- Actual Rust-owned `axo`/`axod serve` fixture with **empty profiles and no Pi
  policy/admission**: standalone and locally selected project sessions each get
  one regular native shell PTY. Addressed terminal input verifies exact cwd and
  actual TTY effects. Repeated command returns the original receipt without a new
  pane; changing its source to a profile rejects. Detach preserves the running
  shell; removal completes against its captured runtime; original add receipt
  remains readable afterward.
- Captured-executable unit test rejects relative, directory, non-executable and
  replaced program identities. Source parsing rejects malformed types/path IDs.
- Pane store reopens nullable default receipts, rejects default/configured
  collisions, and existing string receipt/store tests remain passing.
- Serial locked/offline Rust: **95 library**, interactive Pi 1, local sessions 2,
  managed public 1, public CLI 7, relay config 4; no ignored/skipped cases.
- Clippy all targets with warnings denied; fmt/diff checks pass.
- Published protocol/schema tests: **24 passes, no skips**; schemas regenerated
  and checked. Protocol properties 4 / API properties 2 pass.
- Swift protocol: **34 tests, 1 existing relay-environment skip**, zero failures.
  Nullable shell metadata is parsed strictly; missing/invalid profiles reject.
  The skipped actual relay contract is not passing evidence.
- Both Mac and iOS targets compile with the existing macOS26/iOS18/Swift5 baseline.

## Remaining work

The Mac creation path does not yet dispatch the default right-pane add. Independent
shell availability while Pi starts/fails/waits, immediate complete native layout,
authoritative-empty automatic startup, native pane commands and full recovery
remain open. CLI/daemon cwd/TTY facts do not establish A03 native acceptance.

No live app/daemon restart, uncertain replay, credentials/deployment change or
physical device installation occurred. Protocol changes are not a claim that the
historical deployed API or installed phone has been updated.

Temporary logs (not acceptance archives):
`/tmp/axo-default-shell-{unit,cli,rust,clippy,protocol-build,protocol-tests,protocol-properties,api-properties,swift,mac,ios}.log`.
