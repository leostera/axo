# Native creation sequencing checkpoint

**Implemented source and client-state fixtures, not full native A02/A03 acceptance.**

## Exact versions

- Implementation source **`141b3f88edce19b3441fe2c19dfdb7587ce99979`**, committed
  and pushed on `main`.
- Delivered **`dist/Axo.app` build122**, `AxoBuildCommit` exactly that source;
  bundled helper **`0.1.0 (141b3f88)`**. Strict deep signature verification passes.
- Atomic packaging retains the prior signed bundle. Documentation-only version
  recording afterward does not change bundled code or the running app/helper.

## Change

After explicit workspace/session metadata commits, the Mac selects that committed
session immediately, without a naming/progress modal or second Open Session step.
It captures and saves the default-shell add ID, dispatches that local operation,
and assigns its returned shell PTY before waiting for Pi admission. Shell failure
or uncertainty does not cancel the committed session or its independent Pi intent.
The shell's data plane remains independent while the Pi control request waits.

A separate read-only WebSocket observes the exact captured Pi session/pane/current
host runtime during startup. It cannot execute/admit work, alter canonical Pi
binding, infer readiness from a snapshot or replay a start. Bounded runtime pages
are checked after awaits against the original control connection/operation and
private endpoint. The left viewport may render that captured PTY before admission
completes; canonical conversation operations still require the admitted binding.

`AxodShellCreation` owns per-machine/session hint states. Missing/unreadable hints
are not discarded. Known rejection may clear the exact captured ID; transport,
validation or source uncertainty preserves it. Restoration only reads hints.
Explicit reconciliation calls `axo.command.get`, supports historical original
pane receipts with a current envelope, and never resends add. Null/prepared/wrong
receipts remain unresolved. Inline shell messages and reconciliation are available.

Swift now has typed pane mutation intents/receipts/dispositions and validates
captured target, command, source, pane/runtime identity and closed fields. These
are not renderer input receipts or a new executor.

## Validation and limits

- Swift protocol: **38 cases, 1 existing relay-environment skip**, zero failures;
  the skipped actual relay test is not passing evidence. Four new cases cover
  captured default add, wrong source/command/unknown fields, historical receipt
  reads and prepared/null uncertainty.
- `scripts/check-mac-shell-creation.sh` checks saved ID before transport, validation
  failure before dispatch, unreadable hint preservation, unknown/no-resend,
  fresh-object restoration and historical read-only rejection reconciliation.
  Injected transport closures are client-state tests, not daemon/native acceptance.
- Mac and iOS targets compile; protocol TS 24 cases and protocol/API properties
  pass. Owned sidebar, owner lease and voice keybinding checks pass.
- AxoCore 81 cases pass against the preceding build120 helper in owned roots.
  Exact new-package checks follow below.
- Build122 actual bundled-helper AxoCore lane: **81 tests, zero skips/failures**,
  in owned private fixture roots. Packaged-helper Ghostty component checks also
  pass for actual full-surface Unicode/PTY geometry and non-destructive disposal.
  These validate the preserved attachment seam, not a fresh packaged-app
  New Session click or actual Pi startup UX.
- Client hint/no-replay checks were rerun after packaging and pass.

**Still open:** actual fresh New Session through the packaged Mac, immediate visible
Pi-left/shell-right usability through delayed/failed/question-waiting Pi startup,
real input/focus/resize/lifecycle, complete VT recovery and authoritative-empty
automatic startup. The latter needs safe pending/uncertain reconciliation and an
authoritative admission-time empty-state fence; an empty cached catalog or ordinary
reconnect is not launch permission. No workflow gate is closed by compilation or
client-state fixtures.

No live app/helper restart, uncertain replay, credentials/deployment change or
physical phone installation occurred. Temporary logs are
`/tmp/axo-two-pane-{protocol,mac,ios,core,client,sidebar,owner,voice,protocol-ts,protocol-properties,api-properties,package,packaged-core,packaged-native}.log`.
