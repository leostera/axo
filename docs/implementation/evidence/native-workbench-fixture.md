# Owned production-native workbench checkpoint

**Component evidence only. No complete A02/A03/A07 or other supported-workflow gate is closed.**

## Exact versions

- Production fixes and initial fixture: `e4cffa553d75da223795a12017ec0db1c5bc2067`.
- Body-free fixture failure classification: `1b4465b505e0aec34183f880078dc9b266926256`.
- Delivered `dist/Axo.app` **build128**, `AxoBuildCommit` exactly `1b4465b505e0aec34183f880078dc9b266926256`; bundled helper **`0.1.0 (1b4465b5)`**. Deep strict signature verification passes. Atomic packaging retains the previous signed bundle.
- Ambient vanilla Pi **1.1.0**, resolved from the operator's launcher. The packaged-helper checks load the packaged Axo adapter, not a bundled engine or repository Pi fallback.
- This did not launch/restart the live app/helper, deploy the API, install a phone build, reconcile old work or alter live preferences/history. The last read-only live observation remains helper `0.1.0 (23be4c99)`, five recovery-required runtimes and eleven not-admitted standalone sessions. Those records still lack safe handoff proof. Historical deployment/device evidence is unchanged.

## Bugs found by joining the actual components

1. The Pi-start observer validated its local negotiation reply with the cloud negotiation validator. It silently exited, preventing early PTY observation. It now uses `localNegotiation`; attachment is still read-only and never Pi admission or start/replay authority.
2. Swift session-list parsing validated a pane-aware record and then required the old exact six-field shape, rejecting `shellPanes`. Catalogs now use the same closed record parser as session-get. The regression covers absent/empty/populated panes, nullable default-shell profiles and standalone workspace, and continued rejection of extra authority fields, wrong ownership and duplicate pane identities.

## Owned native path

`bash scripts/check-mac-workbench.sh` compiles the production coordinator, workbench views and full Ghostty terminal code with `AXO_NATIVE_FIXTURE`. Compile-only seams choose an already-private fixture root/helper, skip ServiceManagement and avoid live voice history. They are absent from the shipped app. Production connection/protocol, creation, preference-hint, selection, observer and terminal paths are used. The automatic-connection decision was extracted without replacing the daemon's admission-time fence.

Rust owns disposable private HOME/agent/session/daemon directories, actual daemon and native children, and teardown of their original child handles. The native child hosts `AxodWorkbenchView` in an owned offscreen AppKit window with an isolated preference suite. It uses the actual New Session action or automatic empty-launch path. The default captured `/bin/sh -l` produces a synthetic login-output marker; the native fixture observes that output before sending one intentional command, then verifies its private file effect. No input is retried after a missing outcome. Synthetic screen predicates are bounded and never printed or used as Pi binding/readiness.

The public Pi extension registers synthetic provider metadata without requesting a model and delays public `session_start` for three seconds. Four fresh-root modes check:

- **Delayed:** committed work selected without modal; distinct Pi-left/shell-right full surfaces hosted; the read-only observer sees the exact Pi PTY attached while admission is pending; native shell input completes before admission becomes ready.
- **Unavailable:** missing Pi executable is rejected inline, while the independent shell remains usable and the committed session is retained.
- **Automatic:** genuinely-empty startup creates one two-pane session through the existing atomic startup method; reconnect does not create/start again.
- **Pending:** an opaque machine-scoped saved shell hint blocks empty-startup without dispatch, deletion or modal; reconnect preserves the hint and empty namespace.

The first three modes check retained surface identity on selection/refresh/reconnect, original pane/runtime identity and metadata restoration by a fresh launch coordinator. Explicit presentation disposal leaves accepted daemon work running. Rust independently reads the actual catalog/runtime pages: exactly one session and two runtimes (one for unavailable Pi), or zero work/runtimes for the pending case. No second Pi writer/view is launched for restoration.

## Validation

- Rust: **99 library** cases, interactive Pi 1, local sessions 2, managed-public 1, public CLI 8, relay-config 4; no failures/ignored cases, serial process tests. All-target clippy `-D warnings`, fmt and diff checks pass.
- Swift protocol: **41 cases, one existing relay-environment skip**, no failures. The skip is missing acceptance evidence, not a pass.
- Mac and iOS compile. Pinned split suite: **50 cases**. Protocol TS: **25 passes/no skips**; protocol/API property suites pass. Owned client-hint/sidebar/owner-lease/voice checks pass.
- Initial AxoCore lane: 81 cases with one missing-helper skip. **Exact build128 helper:** public CLI **8**, AxoCore **81/no skips**, full Ghostty component fixture and two complete four-mode native-workbench runs pass.
- Three fresh-root debug-helper runs passed after adding observed shell-output readiness. Eight consecutive build127 four-mode runs subsequently passed, including overlap with four serial public-CLI batteries in separate roots. These are bounded runs, not soak or exhaustive correctness.
- Existing Swift-6-mode `MacAppearance` actor-conformance warning remains; deployment is still Swift5/macOS26/iOS18.

## Subsequent correction

[Build131 bounded-delivery evidence](bounded-terminal-delivery.md) subsequently
reproduces presentation close, corrects per-read queue fragmentation with bounded
coalescing and adds precise first-loss reasons. Its exact packaged-helper
20-round/80-scenario campaign passes. [Build133 captured pane/control evidence](native-pane-splits.md) subsequently adds a fifth mode for right/down fresh shells, exact saved geometry, bounded control-burst dispatch and observed queued cancellation, with five rounds/25 fresh-root scenarios. It still closes no full workflow gate. The old aggregate disconnected flag was not
sufficient to attribute every historical failure exclusively to capacity; the
failed evidence below remains historical, and full actual-surface robustness is
still open.

## Historical intermittent observation

Do not erase failed evidence: an early fixture timed out waiting for the shell effect; its cause was not established. After adding observed output readiness, the first build127 packaged-helper campaign also failed its unavailable-Pi mode: the native frontend had exited and command echo was present, but the shell effect was missing. No input was resent; only owned fixture children/roots were torn down. Later passing runs do **not** establish the failure's cause or prove it cannot recur. The fixture now reports only frontend/input flags, byte count and allowlisted static error classes, never terminal bodies. Native input/presentation robustness remains an open acceptance item requiring failure-class capture and a concrete fix if reproduced.

## Subsequent actual chat-action checkpoint

[Build138 native chat actions](native-chat-actions.md) adds a sixth mode with the public provider extension and Rust-owned loopback model. Actual local Pi tools/title/history, a waiting question with usable native shell, offered/stale answer, cancellation/steering, original draft revisions and exact request/runtime counts pass through production coordinator actions. Failed visibility/timing predicates remain preserved; test-only public-Pi progress is not authority or renderer recovery. Real OS composer/IME/Finder/live/deployed/phone gates remain open.

## Remaining actual-surface acceptance

These runs do not launch the Finder bundle or exercise SMAppService, actual project picker, real keyboard/IME/focus/scale/paste/drop, question-waiting Pi, multiwindow, complete visible VT state/graphics/scrollback recovery, live recovery reconciliation, helper handoff or phone/deployed routes. Retained surfaces are not VT reconstruction. The current live namespace is not genuinely empty and must not be reset to manufacture acceptance. No full supported workflow is complete.

Logs: `/tmp/axo-workbench-{swift,mac,ios,rust,clippy,core,splits,ts,protocol-properties,api-properties,client,sidebar,owner,voice,package}.log`; `/tmp/axo-native-workbench-fixture-{1,2,3}.log`; `/tmp/axo-workbench-packaged-workbench{,-1,-2,-3,-4,-5,-6,-7,-8}.log`; `/tmp/axo-workbench-128-{native-1,native-2,terminal,cli,core}.log`. The failed logs are retained alongside passing evidence.
