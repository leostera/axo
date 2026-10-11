# Owned native structured-chat actions — build138

## Exact checkpoint and surface

Final implementation/fixture source **`79427077e9d3ef62be7550b3398681a4532425c8`**; `dist/Axo.app` **build138**, exact `AxoBuildCommit`, bundled helper **`0.1.0 (79427077)`**, deep strict signature verified. Host macOS **26.6.2**, ambient Pi **1.1.0**, unchanged packaged Axo public extension. Native controls/draft implementation remains the owning `2502b81` slice; `adf0466` adds actual chat actions and `7942707` corrects test-only progress synchronization. No live app/helper restart, state migration, API deployment or phone installation occurred. Last read-only live observation remains helper `23be4c99` with five recovery-required runtimes; packaging establishes no running upgrade/idle proof.

Rust owns private daemon/HOME/session/provider roots and original-child cleanup. The offscreen AppKit child hosts the production coordinator/workbench/full Ghostty with compile-only ServiceManagement/voice isolation. The new `chat` mode loads the existing public controlled-provider extension and a test-only public `message_update` observer into **actual ambient interactive Pi in the daemon PTY**. It invokes production coordinator actions, not a replacement engine, direct private Pi handler, real OS text-field input or a deployed phone route. Terminal bytes remain local. The observer is absent from the shipped adapter and recognizes exactly two synthetic stream-delta literals; it writes only bounded static private progress files, never JSONL/history or payload diagnostics. Typed runtime/chat/interaction snapshots remain authority.

## Passing owning scenarios

1. Baseline direct New Session still commits/selects standalone HOME without a modal, renders captured Pi-left/shell-right PTYs and executes one native shell command before delayed Pi admission.
2. Production `submitChatDraft` sends a controlled normal request through actual local RPC/axod/public Pi APIs. Real Pi bash writes the expected private marker; canonical history reports its result. `axo_set_title` in that same model/tool turn yields **Axo Workbench** in the native catalog, with no separate title-generation request. An edit made during submission survives the original acknowledgement.
3. Another normal request invokes real `axo_ask`. An unchanged acknowledged draft clears. While the offered question waits, another normal submission stays local with its text preserved, and the independent actual native shell performs a new file effect. An offered native answer settles the tool and appears in canonical history. Reusing the stale rendered answer sends nothing and leaves the local draft untouched.
4. A controlled stream is consumed by actual Pi's public observer before cancellation. Native cancellation captures its typed active interaction, acknowledges dispatch and eventually settles; a stale cancel action sends nothing. The original Pi and shell runtimes remain running.
5. A second controlled stream receives native explicit steering to its captured interaction. Subsequent real Pi bash writes a distinct steering marker. A later editor revision survives acknowledgement. The same coordinator retains that unsent draft over metadata reconnect; no restoration/receipt lookup creates work.
6. Owner-side checks see **exactly eight model requests**, one session, two original running runtimes and both expected tool effects after presentation disposal. This bounds these scenarios' duplicate/effect evidence; it does not prove arbitrary queue, crash, cancellation or escaped-descendant behavior.

## Campaigns and tests

- Before the observer correction: three rounds/six modes (**18 fresh-root scenarios**, 45 PASS lines) passed, but the following exact build137 campaign failed. That earlier campaign is not final delivery acceptance.
- After the observer correction: three focused fresh-root chat scenarios pass, then two full rounds (**12 scenarios**) pass against build137 with corrected fixture source.
- **Final exact build138:** two full rounds/six modes (**12 fresh-root scenarios**, 30 PASS lines) pass. PASS lines include owner/component results, not 30 workflow gates. Both chat scenarios have exactly eight model requests.
- Final packaged CLI **8 passed/no ignored**; AxoCore **81 passed/no skips**; local draft/preflight and pane-layout tests pass.
- Full Rust serial lane at the initial fixture checkpoint: **104 library**, interactive1/local2/managed-public1/CLI8/relay-config4, no failures/ignored. The observer correction changes only test arguments/native checks/a fixture extension, not shared Rust production or model-server behavior. Final all-target strict Clippy and fmt pass.
- Swift protocol **41 executed/one existing E2E skip**; it remains incomplete. Mac build/package/signature passes. No fresh TS/API suite or iOS/device build is claimed in this slice.

Reproducer: `AXO_LOCAL_DAEMON_BINARY="$PWD/dist/Axo.app/Contents/Helpers/axod" AXO_NATIVE_WORKBENCH_MODE=chat bash scripts/check-mac-workbench.sh`. Final campaigns omit the filter and use `AXO_NATIVE_WORKBENCH_REPETITIONS=2`; both selectors are closed/bounded (all|chat,1–20).

## Failed evidence retained

- The initial fixture assumed a title catalog refresh left a chat snapshot immediately available; it now waits for the read-only reload before another action.
- A 12-second steering wait reported **sending=false/pending=false/busy=true/recovery=false/model requests=6**. That is dispatch acknowledgement, not steering execution. Provider-start and completion synchronization were corrected within bounded fixture deadlines, without replay or production timeout/rate/queue changes.
- Exact build137 then failed to see the first stream marker in the terminal viewport, despite five model requests. Terminal-visible text is not a reliable provider-start barrier; the precise visibility cause remains uncharacterized. The test-only public Pi observer replaces that predicate, not the production renderer. This does not close TUI fidelity/recovery or explain every prior frontend loss.
- Strict Clippy initially rejected a nested diagnostic `if`; the passing rerun follows its normal let-chain form. Raw errors/bodies are excluded; diagnostics report static stage/classes/flags/counts only.

Logs include `/tmp/axo-native-chat-{initial,rerun,diagnostic,progress,campaign,rust,clippy,clippy-rerun,protocol,drafts,layout,mac,package-exact,exact,public-observer,observer-clippy,observer-all,observer-package,observer-exact}.log` and `/tmp/axo-native-chat-138-{core,cli,drafts}.log`. Failed runs were preserved alongside reruns.

## Remaining scope

**M03/M04/M12/M13/A03/A09/A10 remain incomplete.** These are owned offscreen production-action and actual-Pi evidence, not Finder/service/live handoff, actual composer button/text-field/IME/OS-keyboard input, Vim/server use, project picker/trust, physical phone/deployed controls, arbitrary concurrent/stale/lost-reply/crash races, durable/branch drafts, full reading/tool UI, independent windows or full VT recovery. Basic usage display is still missing. Pi Cmd+W policy remains unanswered and unchanged. No full workflow gate or user scope change is claimed.
