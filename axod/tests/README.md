# axod test coverage

Tests use owned disposable directories/processes, not live Mac state or deployment credentials. Public Pi RPC admission now has isolated positive evidence; native rendering, crash/operational readiness and physical-device acceptance remain separate gates.

## Real interactive Pi in native PTYs

From the repository root:

```sh
npm run test:pi-interactive
npm run test:pi-discovery
```

The interactive command builds the fixture adapter against the **production Rust Manager/journal/forkpty**, then starts the user's ambient Pi CLI and installed managed extension in an actual interactive TUI. No print/JSON/RPC mode, SDK-created agent, bundled runtime or visual terminal is used. A controlled loopback model provider makes failures/races reproducible while actual Pi owns its agent loop, tools, queues, dialogs and canonical persistence. Private HOME/settings/session roots exclude live user credentials/history.

**24 combined tests pass** after moving the extension to `pi-axo/` (the earlier 23-case battery also passed two consecutive full runs): TUI/TTY/PID proof, public message and terminal input convergence, Unicode history/real bash, steering/normal intent, streamed and tool cancellation, real dialogs, sibling/session isolation, detach/resize/backlog, exact resume, bad bindings, concurrent/stale/invalid controls, same-pane writer exclusion, provider failure, a real input hook consuming a void dispatch without execution/replay, real tool fd isolation, owned stop and Pi-initiated shutdown. Terminal bytes are drained/count-discarded, never interpreted as structured control or readiness. Fixtures clean only their owned roots/groups/handles and do not print transcript/terminal bodies.

Actual interactive abort removes queued steering from execution; a regression verifies subsequent normal input does not deliver it. This differs from the removed headless controller's findings. Public API dispatch is not execution completion.

**Scope:** the test adapter reaches the real manager and TUI extension through private fixture framing, not `axod serve`'s public local/cloud WebSockets or a product CLI. It does not prove production session admission, cross-pane/unmanaged canonical-file writer exclusivity, durable chat receipts, remotely answerable generic questions, crash durability or Ghostty rendering. Resume prechecks are fixture policy. See [Pi seam details](../pi/README.md) for architecture and residual gates. The six discovery cases are dependency policy only, not extra Pi execution tests.

## Rust CLI and typed Pi transport checkpoints

`cargo test --locked --offline` now includes `tests/public_cli.rs` (actual `axo` -> public local WebSocket -> `axod serve`, generic PTY/work metadata/receipts/stale targets) and `tests/interactive_pi.rs` (Rust-owned ambient TUI, typed extension IPC, real bash/canonical history). Those earlier tests are separate paths; the new joined checkpoint below adds public Pi-control acceptance. No TypeScript orchestration is used by these Rust tests; Pi-side provider/tools remain TypeScript under `pi-axo/`.

The owned control codec uses closed serde `Record`/`Response`/`Request` types, distinct chat/interaction/request IDs, request-specific reply matching and native operations. Unknown tags/fields, malformed payloads and wrong response kinds fail closed. Arbitrary canonical Pi document payloads remain explicit opaque `RawValue` wrappers rather than dynamic routing envelopes.

## Joined actual public CLI/cloud/Pi checkpoint

```sh
cargo test --manifest-path axod/Cargo.toml --locked --offline --test managed_public -- --test-threads=1
```

`tests/managed_public.rs` owns the actual binaries, ambient interactive Pi, private work/HOME/session roots, Rust HTTP model and actual isolated Worker/Access fixture. Rust orchestrates daemon/Pi/model/processes; Node hosts only Worker/workerd. It builds the installed shared protocol from source without installing packages, keeps synthetic assertions in bounded private files, and cleans compiler/Worker groups while holding their original unreaped leader. npm dependencies and ambient Pi must already be available; no runtime fallback/upgrade is performed.

Positive local evidence: metadata-only creation, actual admission, real bash/canonical history/tool paging, original message/start receipts, Axo-owned question/answer/no replay, viewing expiry/no renewal, active steering/cancel/late rejection and queued-steering exclusion. Clean daemon restart preserves machine/chat, permits explicit stopped branch reads and exact resume without provider calls. Positive cloud evidence: the real Worker forwards start/message/history into an independent actual Pi, whose bash effect is verified; cloud/client loss leaves accepted Pi admitted. Stale targets, consumed input-hook uncertainty and injected `pi-state.json` failure verify no fabricated execution/replay, preserved receipts and three-domain fencing without killing accepted Pi.

Six managed unit tests separately prove normalized fingerprints/no persisted prompt text, immutable dispositions, every-byte synthetic truncation/corruption, persistence fencing, cooperative lease/private-path checks, active-tree reconstruction and cross-domain collisions. These are not extra Pi execution cases. Full compaction/plugin/spool projection, unmanaged-writer exclusion, abrupt crash/power-loss, scalable history, observation subscriptions and remaining RFD domains are still open. See [managed setup/contracts/limits](../MANAGED_PI.md).

## Local shell-pane add/remove checkpoint

`tests/public_cli.rs` now adds two actual independent shell PTYs through `axo`/public local RPC/`axod serve`, verifies real TTY effects/no duplicate launch, stale scope/generic replacement rejection, removal of only the captured shell, durable tombstones/receipts, restart without replay and historical stopped removal. `tests/managed_public.rs` separately verifies shell removal does not stop/replay a sibling actual Pi and Pi storage failure fences new pane admission.

Five synthetic pane store/admission tests cover original dispositions, tombstones, wrong runtime, missing completion witness, duplicate removal, exhaustive truncation/unreceipted edits and global command/storage fencing. The real route matrix checks malformed/stale/idless local requests and cloud refusal of these local-only methods. No terminal bytes/geometry, Ghostty/shortcut adoption or full escaped-process/crash/operational acceptance is claimed. See [pane contracts and limits](../PANES.md).

## Rust domain and process tests

From `axod/`:

```sh
cargo test --locked --offline
cargo clippy --locked --offline --all-targets -- -D warnings
```

These cover typed boundaries, runtime/work receipts, corruption/persistence fencing, private files, real PTYs, attachment/input/resize, slow readers, final output, descendants and stopped/recovery states. The `tests/fixtures/` programs are process fixtures, **not fake Pi sessions**. Explicit controlled launches additionally verify fd-3 socket/TTY preservation, unrelated fd closure, CLOEXEC and immutable controlled-versus-ordinary intent; dropping/reconciling the channel cannot create another writer or stop work.

## Property/fuzz and commit-window hardening

```sh
npm --prefix protocol run test:properties
```

The normal protocol and Rust test commands also include these tests. `fast-check` runs three replayable seeds (4282447, 20261011, 12648430): 6,000 malformed/structured codec cases, 1,500 read-admission cases, and generated notification/oversized-response batches. The development-only `axod/examples/rpc-oracle.rs` calls the actual Rust decoder and dispatcher, with an explicit read-only method allowlist, private disposable state, bounded input and owned-child teardown. It is not an installed daemon endpoint, surrogate Pi harness or execution test.

Replay a reported seed/path for one property from `protocol/`:

```sh
npm run build
AXO_PROPERTY_SEED=4282447 AXO_PROPERTY_PATH=0:1 \
  ./node_modules/.bin/tsx --test --test-name-pattern='seeded malformed-input' tests/property.test.ts
```

Diagnostics report seed/path and mismatch location, not generated payload bodies. Shrinking is enabled. The synthetic edge corpus covers UTF-16 IDs/methods, UTF-8 frame bytes, lone surrogates, non-finite JSON numbers, nesting, prototype-like dictionary keys, strict case-insensitive RFC UUIDs, cursor domains and numeric spellings such as `1.0`/`1e0`. Selected regressions also run through both real WebSocket routes.

Rust `proptest` exercises bounded UTF-8 input, exact IEEE-754 round trips, encoded-byte and post-dispatch reply bounds. A real filesystem state machine generates create/rename/reconcile/conflict/restart sequences and checks revision continuity, immutable original receipts, reconstruction and absence of runtime launch records. It runs 96 sequences of up to 39 actions per invocation; generated identities/state remain fixture-owned.

Test-only, thread-local hooks inject failures before file sync, before atomic rename and immediately after rename. The store must fence memory, retain known receipt reads and reject further mutations; reopening observes only the old or new atomic record/receipt pair. Exhaustive byte truncation of a synthetic store and individual receipt-invariant corruption must reject startup, never regenerate empty state. Ownership contention is distinguished from corruption; only disposable test roots may briefly wait for inherited CLOEXEC locks during parallel PTY forks. Production ownership acquisition remains fail-closed, with no command retry.

**Evidence limits:** injected post-rename failure and same-kernel reopen do not prove power-loss durability or actual directory-fsync recovery. This is bounded generated testing, not coverage-guided libFuzzer, exhaustive correctness, production hardening, orphan containment or a fix for every compiler/Worker contention stall. Abrupt death at process/spawn/fsync boundaries, escaped descendants, soak/resource-exhaustion campaigns and native admission and the broader public-Pi crash/operational gates remain open.

### Completion and relay framing campaigns

Managed exact resume, stopped canonical reads and stopped admission require `Manager::runtime_completed`: the exact durable completed runtime and absence of owned live resources. An observed exit, EOF alone, an in-memory completion flag or failed persistence is insufficient. Synthetic tests cover drain/group/storage uncertainty and explicit cooperative lease release despite a duplicated open-file description; they never launch or signal their fixture PID.

The completion state machine generates up to 23 observation/output/persistence/fault events, with independently varied output success and group certainty. Every step checks completion evidence, stopped admission and stale-runtime refusal. Three fixed-seed campaigns passed **1,536 sequences** (512 per seed). Repeat from Axo root:

```sh
for seed in 4282447 20261011 12648430; do
  PROPTEST_CASES=512 PROPTEST_RNG_SEED="$seed" \
    cargo test --manifest-path axod/Cargo.toml --locked --offline \
    --lib completion_evidence_state_machine -- --test-threads=1 || exit 1
done
npm --prefix sites/api.axo.leostera.dev run test:properties
```

The relay campaign runs **12,000 cases** across the same three seeds: encoded bytes/JSON escaping/Unicode and numeric/null IDs, single-versus-batch wire shape, incremental partial-group serialization and repeated capacity reductions. Oversized results become correlated `-32004` outcomes, never replay permission; the real Worker test proves client/daemon routes remain usable and correlations are released. Mutation deadline/late-success tests verify no correlation resurrection or automatic resend. Those API endpoints are protocol fixtures, not execution evidence.

Replay one relay property with `AXO_PROPERTY_SEED` and optional `AXO_PROPERTY_PATH`, using `tsx --test --test-name-pattern='seeded relay framing' tests/replies.property.test.ts` from the API directory. Failure diagnostics retain seed/path/shrinking but omit payload bodies. Rust completion counterexamples contain only synthetic event enums/booleans; normal proptest regression persistence and `PROPTEST_RNG_SEED` remain available. These bounded model/property campaigns are not coverage-guided fuzzing, real crash/power-loss drills or exhaustive correctness.

## Actual daemon RPC tests

From the repository root:

```sh
npm --prefix sites/api.axo.leostera.dev run test:axod
```

This builds the compiled `@axo/protocol` package, checks schema drift and runs:

- `tests/axod.test.ts`: two real daemon owners behind an Access-validating isolated Worker; process launch/reconciliation, independent machines, disconnect/cloud loss, restart and Swift wire fixtures.
- `tests/local.test.ts`: real local discovery/WebSocket admission, negotiation, codec/credits/bounds, launch receipts, paging and recovery.
- `tests/work.test.ts`: positive paths for every implemented workspace/session/receipt RPC on both actual local/cloud routes, stable records, manual names, cursor/source fencing and restart durability.
- `tests/daemon-rpc.test.ts`: an exhaustive method-input matrix for every shared exposed daemon RPC. Typechecking requires a case whenever `RemoteMethod` grows. Each method exercises positional/missing/extra/malformed input, stale machine/source and non-executing notifications on both routes.

The method suite also checks concurrent command/hop-ID collisions, revision winners/losers, original receipt reconciliation, per-route uncertain persistence and global mutation fencing, absent-versus-null paging semantics, legitimate nullable cursor scopes, explicit null request IDs and maximum Unicode pages within encoded-byte budgets.

The RFD catalogue is used to exercise **explicit unsupported errors** for methods not implemented yet. This is not positive Pi/chat/terminal coverage. Adding a real capability requires both a typed matrix case and actual positive/failure/lifecycle evidence; do not replace it with a fake handler or invented transcript.

Local and cloud transport policies may differ; shared domain semantics must not. For example, optional paging fields may be omitted but not explicitly null unless their schema is nullable. A missing command receipt means unknown knowledge, never safe replay or confirmed rejection.

The dedicated command serializes test files to bound compiler/Worker fixture contention; its concurrent-client cases still send real simultaneous requests. The complete API suite remains available with `npm --prefix sites/api.axo.leostera.dev test`; it additionally tests service JWT roles, directory admission, hibernation/deadlines and relay recovery. Tests deliberately respect ingress/credit limits rather than disabling guards, and cleanup signals only owned child handles.

## Native local terminal plane (component evidence)

`cargo test --manifest-path axod/Cargo.toml --locked --offline --lib terminal_transport -- --test-threads=1` exercises both production local listeners with owned real synthetic PTYs. Six listener tests and three typed-consumer state tests cover the versioned terminal wire boundary, browser/cross-plane rejection, attachment/input/resize, stale/second-owner rejection, non-destructive detach/reconnect, output/EOF, slow-reader loss with continued process/control availability, private discovery and delivery-credit bounds. These are not fake Pi sessions or native Ghostty acceptance. See [terminal contract](../TERMINALS.md) and [versioned checkpoint](../../docs/implementation/evidence/terminal-plane-a6765aa.md).

`cargo test --manifest-path axod/Cargo.toml --locked --offline --test public_cli frontend -- --test-threads=1` runs two actual-binary frontend-child cases. A distinct Rust-owned frontend PTY launches `axod terminal-attach` against the actual daemon: Unicode input/inner resize and frontend quit preserve one managed runtime; truncated-backlog refusal also preserves work. This is stream-seam evidence, not native Ghostty or screen-recovery acceptance.

`bash scripts/check-mac-chat-drafts.sh` compiles the production bounded in-process draft cache and closed Pi mutation preflight. It checks logical conversation scope/exact runtime resume, original receipt target/command matching, unknown/no-clear/no-replay, edited/ABA revision retention, UTF-8/aggregate/slot capacity refusal and encoded RPC-frame bounds including escaping. These are client-state checks, not actual Pi execution, durable draft recovery or native/phone chat acceptance.

`bash scripts/check-mac-draft-storage.sh` checks the bounded archive/pinned owner-only storage primitive: private fresh-store reads, original pending revisions/closed send-steer operations, UTF-8, opaque/older-format/corrupt/unsafe preservation, stale byte-checkpoint CAS, validated transaction writer leases and pre/post-rename write fences. Production `AxodDraftPersistence` now owns this store off the main actor. `bash scripts/check-mac-draft-persistence.sh` covers asynchronous required-load/edit/save behavior, coalesced latest rows, fresh-cache logical resume/original tickets, rejected/unknown/ABA settlement, conditional durable clearing, competing stale stores/lease failures and the ordinary-quit freeze/flush state. File/encoding work stays off typing; at most one save is active and one latest snapshot queued. These checks are not actual composer/IME, app-exit/crash/power-loss or competing application-process acceptance, and do not establish branch identity; fault injection is compile-only.

`bash scripts/check-mac-workbench.sh` compiles production native coordinator/views/terminal code with compile-only root/helper/voice isolation, then launches it through Rust-owned private daemon/HOME/session roots and actual ambient Pi. Build the Mac target and helper first; `AXO_LOCAL_DAEMON_BINARY` selects an exact packaged helper and its adapter. A public Pi fixture extension registers a synthetic model without requesting it and delays public `session_start` by three seconds. Seven modes cover direct New Session with delayed admission, unavailable Pi with usable shell, genuinely-empty automatic creation, opaque machine pending-hint blocking, explicit captured right/down shell splits, actual controlled-provider structured-chat actions and opaque draft-storage preservation/blocking of automatic startup while explicit creation still supplies usable terminals. The `chat` mode additionally loads the existing public provider extension against the Rust-owned loopback model fixture: normal tool/title/history, original draft revision, offered/stale question answer with independent shell input, captured cancellation, steering with a distinct real tool effect, exact runtime survival and eight model calls. Fresh production coordinators also restore text and an exact captured unresolved archive ticket without a preference hint; real original-command lookup returns null and leaves the ticket/text untouched, never issuing a replacement message or additional model call. This is an intentionally never-sent owned ticket, not proof of a lost mutation reply or process crash. A test-only public-Pi `message_update` observer recognizes only two closed synthetic stream progress markers; it never writes canonical history, exposes bodies or supplies run/binding authority. Typed snapshots remain authoritative; terminal-visible text is not a reliable provider-start barrier. Native fixtures invoke production coordinator actions, not real OS composer/IME or deployed/phone surfaces. Use `AXO_NATIVE_WORKBENCH_MODE=all|chat` for a closed focused reproducer; full campaigns default to all modes. The `panes` mode checks three distinct shell PTYs, positive native geometry/input, unchanged Pi, retained surfaces and exact saved geometry after fresh-coordinator restoration. A production Swift-client 24-read burst respects the unchanged local request/ack rate window; observed queued metadata cancellation cannot dispatch later. `bash scripts/check-mac-pane-layout.sh` separately checks the bounded closed preferences format, opaque hint preservation, original command/no-replay and stale/ABA resize guards. Native input writes one synthetic shell marker; captured Pi/shell surfaces and left/right geometry, pending Pi attachment, retained reselect/reconnect/later-launch, exact runtime counts and non-destructive disposal are checked. Set `AXO_NATIVE_WORKBENCH_REPETITIONS=1..20` for a bounded fresh-root campaign (default 1). Compile-only frontend stderr capture and the Rust-owned daemon stderr file are private; native failure reports select only known static classes from bounded reads, never raw error/terminal bodies. The production delivery queue also has deterministic one-byte-fragment, byte/offset/identity/control-boundary, exact-capacity/no-partial-insertion and receiver/sender-loss regressions. No terminal/transcript bodies or credentials are printed. This does not prove Finder/service startup or question-wait interaction, live handoff, project picker, real OS IME, multiwindow or VT recovery; it closes no full workflow gate.

`bash scripts/check-ghostty-vt-snapshot.sh` characterizes the clean pinned public VT C API against an existing local dylib using synthetic bytes only. Snapshot continuation/text restoration and malformed-data rejection are tested; total decoder allocation bounds, complete styled replay, graphics, headless query behavior, native surface attachment and actual workbench acceptance remain open.
