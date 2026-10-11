# Terminal frontend component checkpoint — 517b011

## Exact versions and boundary

Implementation source: **`517b01150c1499e1f356b071e059e59d27779c64`**, committed/pushed to `origin/main`. Packaged `dist/Axo.app` is **build116**, with that `AxoBuildCommit` and bundled helper **`0.1.0 (517b0115)`**. Strict deep signature verification passed. Packaging did not launch/upgrade the live app/service or replay work. No API deployment, device installation, credential change or live-process signaling occurred.

The helper now has a typed local terminal consumer and `terminal-attach` mode. That mode is a **transport-only frontend child**: captured machine/runtime IDs; frontend raw TTY and bounded writes; exact output/receipt/credit validation; one pending input and resize; no execution commands, uncertain-input replay or automatic reconnect. It closes presentation, not managed work. See [contract](../../../axod/TERMINALS.md).

**Native Ghostty integration and truthful VT recovery remain missing.** The helper's raw replay is not a restored screen. It refuses truncated backlog while preserving work; non-truncated raw bytes also do not prove correct historical geometry/parser/graphics state. This checkpoint closes no supported workflow gate or goal task.

## Validation

| Scenario / command | Passing evidence and limits |
| --- | --- |
| Locked/offline serial full Rust suite | **92 library cases**, interactive Pi **1**, local sessions **2**, managed public **1**, public CLI **6**, relay config **4**, no ignored/skipped cases. Tests ran on the exact source content subsequently committed as 517b011; development binaries preceded the release package. |
| Typed terminal consumer | Three pure state cases enforce exact offsets, byte/delivery bounds, attachment ownership, matching pending input/resize receipts, deadline uncertainty and duplicate-exit rejection. A sixth production-listener fixture consumes real synthetic PTY output, rejects a second pending input, applies resize and releases only its lease through detach/drop. No raw data is logged. |
| Actual frontend-child positive case | Actual `axod terminal-attach` binary runs inside a distinct Rust-owned frontend PTY and uses the actual daemon's terminal listener. Unicode input reaches the managed shell; resizing the frontend reaches the inner PTY (`42×91` observed by the synthetic worker). Terminating the frontend releases its attachment while the original single managed runtime remains running. This is **not a Ghostty surface or actual Pi-window acceptance**. |
| Actual frontend-child failure case | A synthetic runtime produces more than the bounded raw ring. The helper refuses truncated replay and exits unsuccessfully; the original single runtime stays running and unattached. No fake screen, new worker or destructive recovery occurs. |
| Rust fmt, Clippy all-targets `-D warnings`, diff check | Passed. |
| Protocol property/differential suite | **4** passed; schema/codec/admission models, not UI acceptance. |
| API property/framing suite | **2** passed; isolated framing/durable-group models, not deployment evidence. |
| Mac packaging | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-mac.sh` passed and atomically delivered build116; previous bundle retained. |
| `codesign --verify --deep --strict dist/Axo.app` | Passed. Not live-helper handoff or notarization evidence. |
| Packaged-helper AxoCore suite | `AXO_LOCAL_DAEMON_BINARY="$PWD/dist/Axo.app/Contents/Helpers/axod" swift test --package-path apple/AxoCore`: **81**, zero skips/failures. The bundled 517b0115 helper ran only in the owned integration fixture's private state root. No GUI surface was launched. |

Temporary pointers (not durable acceptance archives): `/tmp/axo-terminal-frontend-{rust,package,core,protocol-properties,api-properties}.log`. The earlier Swift protocol relay case remains unaccepted; this change did not provide its owned/deployed relay fixture environment.

## Next gate

Wire the pinned Ghostty native surface to the bundled transport child, validate actual surface input/output/resize/focus/disposal, and implement independent default HOME/project shells plus direct/automatic-empty two-pane creation. Full visible-state recovery, headless feature queries, IME/images, native pane/window lifecycle and every affected actual-surface acceptance procedure remain open. Preserve accepted/uncertain live work; any risky handoff still needs scoped consent.
