# Ambient Pi integration seam

Axo depends on the **user's ambient `pi` installation**. This directory does not bundle, vendor, fork or patch Pi, and does not use the repository's Pi npm devDependency as a runtime fallback. There is no download/auto-update/install behavior.

`AmbientPi.find()` captures the normal absolute `pi` launcher from PATH or an explicit operator-selected executable. npm's injected `node_modules/.bin` entries and repository-local runtime paths are refused. Normal user/package-manager symlinks remain launch paths. The current public-RPC baseline is Pi 1.1.0 or newer, not an exact package pin. Missing/unsupported dependencies fail clearly; admission additionally checks actual state/canonical-entry RPC shapes. Version alone is not readiness or evidence of completed work.

`ManagedPi` is an **isolated headless control seam**, not yet a shipped `axo.session.start` implementation. It invokes ambient Pi's documented `--mode rpc` through anonymous owned stdin/stdout pipes. Pi owns model/tool execution, queues, public lifecycle events, canonical IDs and JSONL. Axo writes only its disposable ownership lease, not transcript records. No Unix listener, public runtime-registration endpoint, private Pi API or replacement agent loop is introduced.

## Validated behavior

Run from the repository root:

```sh
npm run test:pi
```

Real execution tests run the **ambient CLI**, including under npm (which otherwise prepends the repository's Pi executable to PATH). They load a controlled loopback-only provider/custom tool into vanilla Pi, with private HOME/settings/session roots and no paid credentials. The Pi npm devDependency supplies development type declarations for the test extension only; the production seam imports no Pi SDK/runtime package.

Positive tests cover fresh start/readiness without model work, canonical messages/entry IDs/tool results, actual bash side effects in the captured directory, Unicode stream framing, exact resume without prompt replay, busy normal-input rejection, explicit steering, cancel/queue cleanup/settlement, sibling isolation, supported RPC UI choices, handled input versus model work, provider failure after acceptance, concurrency and captured targets during awaits.

Negative tests cover missing/wrong/cross-context/legacy/symlink/truncated/corrupt persistence, duplicate/unclean ownership, startup-profile prompt/credential/persistence injection, byte limits, stopped controls and successor-safe lease cleanup. Separate Node transport fixtures test invalid/oversized/miscorrelated records, EOF/unknown outcome and pending capacity. Those fake transport records **are not Pi execution evidence**. Discovery fixtures likewise test version/PATH policy only.

Two real-Pi characterization findings are regression-tested: raw `steer` accepts idle input into a latent queue; raw `abort` retains queued steering. Axo requires the captured active interaction, never adds normal-send streaming behavior, clears captured-interaction queues before abort, and quarantines idle pending input instead of admitting another normal interaction. An accepted steering disposition is not delivery/completion, and external Pi races are not claimed to be atomic.

## Ownership and limits

- Start captures approved executable/resources/context/persistence before awaits. This is an internal typed seam, not permission for clients to provide argv, cwd, session paths or environment.
- Each dedicated managed session directory has one exclusive `.writer` lease. Unclean leases require explicit recovery; no historical PID adoption/signaling or automatic restart. This excludes cooperating managed writers, not arbitrary same-user programs ignoring the lease.
- Exact resume validates owned, regular, single-linked, bounded current-version persistence before launching Pi; it refuses legacy auto-migration and never changes original bytes itself. It then binds readiness to Pi's actual ID/file. Missing unmaterialized history cannot silently become a new session.
- Private Pi JSONL uses LF byte framing, not Node `readline`. Records are bounded to 4 MiB, commands to 64 KiB, pending calls to 16, writes to 128 KiB and responses to ten seconds. A gap/timeout fences controls with unknown outcome while stdout continues draining; no automatic replay or unsolicited history upload.
- Stop signals only the created child handle. Escaped-descendant containment, crash/durability evidence, supervision, credential lifecycle and production teardown still require the daemon operational gate.
- Generic RPC dialogs are characterized only in this headless mode. This does not prove arbitrary TUI/custom-component approval parity or expand the proposed public answer policy beyond its separately selected scope.

**Still required before operational use:** connect this tested seam to the Rust manager's single execution owner/admission/journals; durable start/message/cancel disposition and reconciliation across crash windows; full machine/workspace/session/pane/runtime destinations; shared `axo.session.start` and `axo.chat.*` contracts and local/cloud route evidence; bounded branch/history/event projections; the TUI/Ghostty strategy and native acceptance. Never mount RPC stdout as a terminal or disguise it as a VT screen. No live app/registry/file/deployment/startup cutover is authorized by these tests.
