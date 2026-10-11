# Separate native client draft exit/crash recovery — build146

## Exact versions and boundary

Owning source **`4dd8fd7e7e1dcb403caeb35993eaa30ad3b846d9`**, `dist/Axo.app` **build146**, helper **`0.1.0 (4dd8fd7e)`**, matching `AxoBuildCommit`; deep strict signature verification passes. Production persistence remains the [build144 integration/fences](durable-chat-drafts.md). This change adds Rust-owned process acceptance fixtures and documentation, not a new production execution path or draft policy. No live app/helper restart, service handoff, API deployment, physical-device installation or live-data mutation occurred.

**M13/A10 and all full gates remain incomplete.** This is actual exit/forced crash/recovery of separate owned native fixture clients using production coordinator/draft storage and a retained actual daemon/Pi/shell. It is not exit/crash of the packaged `Axo.app`, Finder/ServiceManagement, actual composer/OS keyboard/IME, lost dispatched reply, active-Pi-turn crash handling, device/cloud or power-loss acceptance.

## Process drill

`AXO_NATIVE_WORKBENCH_MODE=all|chat|drafts` is a closed bounded campaign selector. Default `all` now runs eight scenarios. Each `drafts` scenario owns one private daemon/HOME and **three separately spawned native processes**:

1. **Normal native process exit.** Production New Session creates/selects one standalone session, actual Pi-left/shell-right surfaces, independent shell input and the existing reselect/reconnect checks. Through the captured shell surface's public input/Return path, the fixture intentionally starts a bounded foreground job in the same runtime (`exec /bin/sh`, no detached job group). It appends at most 800 synthetic bytes to a private file. A fresh coordinator within this first process edits a synthetic Unicode/multiline draft, runs the production cache quit freeze/flush barrier and exits normally. This exercises the cache barrier, **not** the packaged application delegate or real Cmd+Q/field-editor commit.
2. **Fresh client, durable pre-hint crash.** Another native process reads the saved text and original existing Pi binding, without creating/resuming work. It edits text, captures an original normal-message ticket and waits for its archive commit. It never calls mutation RPC or creates a preference hint. Only then does a same-directory private static `ready` marker appear. Rust verifies that its exact child is still running/unreaped, sends SIGKILL through that owned child handle and waits for the actual signal9 result. The daemon, Pi and shell are not signaled; inventory PIDs are not authority.
3. **Fresh recovery client.** A third native process loads the exact original target/operation/command/text ticket from disk with an empty new preference suite. Matching runtime identities remain unchanged, one session/two runtimes remain, and no start is dispatched. Capturing another message is refused. Actual original-command lookup returns null and leaves text/ticket unresolved; no preference hint or replacement command is created.

After the owned client has been reaped, Rust captures the current shell-effect count and waits for a later increase. This proves accepted shell work progresses **after** client death, rather than merely observing a running PID or a write that happened before the kill. Runtime references are non-null objects and compared exactly before/after crash and recovery. The retained loopback provider records **zero model requests** for this scenario. The Pi is idle; active-turn crash acceptance is not claimed. Only the exact synthetic crashed-client preference suite is cleaned by recovery. Private marker/effect files contain no user text, credentials or IDs and never grant dispatch authority.

The intentionally never-sent ticket proves the archive-before-hint boundary, not loss of an accepted mutation reply. Known/uncertain post-dispatch recovery remains open. Same-kernel fsync/rename plus SIGKILL is not power-loss or disk-controller durability proof.

## Passing campaign

Final exact-source package: **two full rounds/eight scenarios =16 fresh-root scenarios**, **48 component-owner PASS lines**. Each `drafts` root spans three native processes; existing seven-scenario creation/terminal/split/chat/storage checks continue passing. Chat scenarios still assert **eight actual model calls** and tool/title/question/cancel/steer effects; draft-crash scenarios assert zero. Original work/runtime counts survive all presentation/client disposal.

Exact helper public CLI **8 passed**, exact helper AxoCore **81 passed/no skips**, async cache/late-return fence checks pass, and deep strict signature passes. The owning campaign also passed three focused fresh-root process drills, full serial Rust **104 library + interactive1/local2/managed-public1/CLI8/relay4**, all-target strict Clippy/fmt, Swift protocol **41 executed/one existing real-daemon E2E skip**, and draft preflight/cache checks. No TS/API/iOS/device/deployment lane is newly claimed; production/shared schemas were unchanged.

A retained compile failure attempted a nonexistent `TerminalView.sendText` helper. The fixture now uses the existing public `insertText` plus a synthetic Return key event, just like its other owned native shell checks; the failed log is retained and is not OS-input acceptance. No runtime/process assertion failure occurred in the completed owning campaign. Existing MacAppearance concurrency/linker/AppIntents warnings remain nonfatal.

Logs: `/tmp/axo-native-draft-process-{initial,progress,progress-rerun,clippy,clippy-final,campaign,rust,protocol,cache,preflight,package-exact}.log`; final exact `/tmp/axo-native-draft-process-146-{native,cli,core,cache}.log`. `progress.log` is the retained compiler failure; initial focused checks predate the final shell-progress assertion.

## Remaining supported-workflow work

Continue actual rendered composer/source-selection/field-editor/IME/capacity acceptance, packaged-app ordinary quit/delegate and forced crash, concurrent app-process editing, rejected/unknown/post-dispatch lost-reply reconciliation and storage faults. Branch-authoritative draft identity/policy, bounded history/tool/reading/navigation and binding transfer remain separate missing capabilities. Live service/handoff, VT reconstruction, deployed API/phone and the rest of the 49-workflow/25-gate inventory remain open. This checkpoint approves no scope reduction, live stop, uncertain replay or automatic migration.
