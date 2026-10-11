---
name: axo-development
description: Apply Axo's project-specific development workflow and vanilla Pi integration boundaries. Use when implementing, reviewing, or delivering changes in the Axo repository.
---

# Axo development

Resolve repository paths from `../../..` relative to this directory. Inspect Git status before edits and preserve unrelated work. Use the sibling [native Mac](../axo-macos-native-apps/SKILL.md), [packaging](../axo-macos-packaging/SKILL.md), and [Pi titles](../axo-pi-title-and-attention/SKILL.md) skills for those areas.

## Current architecture

```text
Axo Mac / axo CLI → addressed public RPC → Rust axod → daemon-owned native PTY
                                                   → ambient interactive Pi + Axo extension
```

- `axod/` owns daemon implementation, accepted work, PTYs, persistence, CLI and process fixtures. `pi-axo/` is the installed TypeScript extension, using public vanilla Pi APIs. Node may host an owned Worker/model fixture, not orchestrate daemon/Pi processes.
- Pi is an ambient runtime dependency. Resolve its launcher from captured normal PATH or explicit operator configuration; exclude npm-injected project launchers. Do not bundle Pi, execute the repository devDependency, auto-install/upgrade, patch Pi, or use private APIs. The product uses interactive TUI Pi, not a parallel `pi --mode rpc` engine.
- The Mac app uses `AxoProtocol`/`AxoCore` and its bundled `Contents/Helpers/axod`. Its state is `~/Library/Application Support/Axo/Axod`. Multiple app processes share that daemon/state. Normal frontend exit does not stop daemon-owned work.
- The per-user service uses `SMAppService`; `serve-user` captures the OS account's configured login shell. Axo also registers as a login item. Registration, actual running version and operational readiness are separate facts.
- Local RPC uses loopback WebSocket JSON-RPC and private `local-endpoint.json` discovery. Host/path/no-Origin restrictions are browser defenses, not OS-user authentication.
- Shared contracts live in `protocol/`; JavaScript consumers import compiled `@axo/protocol` exports. The addressed cloud API lives in `sites/api.axo.leostera.dev/` and uses Cloudflare Access. Local Mac changes do not authorize changes to phone routing, deployed services, credentials or file authority.
- Keep the pinned Ghostty renderer and split implementation, including upstream licenses. Do not edit ignored vendor sources or build another split geometry engine.

## Authorities and invariants

| Authority | Responsibility |
| --- | --- |
| `work-records.json` | Workspace/session metadata, committed directories, revisions and immutable work receipts |
| Runtime journal / Manager | Accepted processes, exact runtime identity, resource ownership and durable completion |
| `pane-state.json` | Shell-pane intents, original receipts and tombstones |
| `pi-state.json` | Managed Pi bindings and intent/disposition fingerprints, not prompt/history bodies |
| Vanilla Pi JSONL | Canonical conversation, branch, tool history and conversation name; Pi is the sole writer |
| Native draft archive | Bounded local text and durable original dispatch tickets, not execution authority |

- Metadata create/rename/read does not itself admit Pi or execute work. Observations, catalog restoration, terminal text, timestamps and PIDs are not launch/replay/completion authority.
- Capture machine, session, pane, conversation, host/runtime generation, endpoint and operation before awaits. Revalidate before dispatch/application. Never retarget to global selection.
- Persist original intent before effects. Keep receipts immutable. Prepared, null, opaque, mismatched, lost or unknown results permit exact reconciliation only, never automatic replay.
- Stop/remove only the exact owned runtime with Manager completion/resource proof. Missing process groups, socket refusal or cached readiness are not proof. Signal only owned unreaped process handles with applicable authority.
- Private roots are owner-only `0700`; files are no-follow, regular, single-link `0600`. Preserve unsafe/opaque bytes rather than repairing, truncating or resetting them. Explicitly unlock flock before closing descriptors.
- Preserve live records, histories, drafts, credentials and accepted work. Build/test/package is not consent to stop/restart the live app, daemon or Pi, deploy remotely, or install on a device.
- Never log prompts, terminal/transcript/audio bodies, tokens, environment values, clipboard content or full private configuration. Diagnostics use bounded allowlisted facts.

## Sessions and workspace storage

- New Session is one direct action with immediate committed selection and inline startup/failure/unknown state. Command-T inherits the active workspace; nil workspace means standalone.
- Each created session has Pi left and an independently usable login shell right. Admit the default shell before awaiting Pi readiness. Standalone cwd is daemon-captured HOME; workspace cwd is the locally approved committed directory.
- Workspace creation uses the native folder picker and local-only `axo.workspace.createLocal`. Parse selection into `LocalDirectoryPath`, not profile IDs. Commit the first workspace/session atomically; do not add selected paths to generic cloud launch profiles. Reconciliation preserves original directory receipts.
- Automatic empty startup uses `axo.session.createIfEmpty`. Require authoritative complete empty work/runtime catalogs and pending/draft/admission fences. Consume launch authority once per app launch; reconnect and restoration remain read-only.
- Fresh workspace Pi bindings use `<workspace>/.axo/sessions/<work-session UUID>/`. Prepare private directories after durable admission reservation with descriptor traversal, `mkdirat`/`openat` and no-follow checks. Reject unsafe paths without repair. Validate workspace-local roots on resume.
- A binding's saved history location remains authoritative. Do not relocate histories, rewrite existing bindings or restart writers as part of creation. Standalone bindings use the configured private session root.
- Pi persists JSONL lazily. Directory creation alone is not a saved conversation; operational storage acceptance requires an actual Pi turn and its canonical history in the exact UUID folder.
- Session Delete is local-only `axo.session.delete`, with an addressed source, expected work revision, original command and 1–32 unique workspace/session addresses. `work-records.json` retains deletion intents/captured runtimes and catalog tombstones alongside immutable records/receipts; advance revision once for the completed batch. Prepare before stopping, fence target admission and metadata mutation while pending, and finish only with exact Manager completion. `axo.command.get` may settle that original metadata commit from durable proofs, never repeat signals. Boot validates the captured runtime set/completion against the runtime journal. Keep canonical histories/drafts; refuse uncertain ownership. See `axod/SESSION_DELETION.md`.
- Managed Pi children use `umask(077)` before exec so their new files, including canonical history, are private. Do not chmod existing histories or change parent/default-shell umask.
- Manual native labels and Pi conversation names are distinct. Protect manual labels; `manualName == nil` means unavailable peer capability, not permission to infer protection.

## Shells and terminal ownership

- Shell add/remove uses local-only `axo.session.pane.add/remove`. Null/omitted `profileId` selects the captured user login shell; a string selects matching approved argv. Preserve distinct parsed `ShellSource` intents and original receipts.
- `serve-user` uses account shell identity. General `serve` respects explicit environment selection and rejects invalid present values. Export the captured shell to PTYs and login-PATH probing without mutating global environment.
- Failed executable/directory selection does not permit fallback or replay. Catalog reads do not add shells. Renderer detach, viewport reflow, frontend quit/crash and reconnect do not stop or duplicate PTYs.
- Shell removal requires exact captured runtime termination and proof-gated tombstoning. Pi close policy is not inferred from shell removal.
- Terminal surface caches use exact machine/host/session/pane/runtime keys, bounded capacity and one interactive viewport owner. Never evict accepted work or create another process to render another window.
- Preserve bounded terminal delivery/control pacing. Coalesce only contiguous output for one exact attachment; do not widen queues or replay uncertain input. See `axod/TERMINALS.md` and `axod/PANES.md`.

## Protocol and persistence work

- Deserialize owned protocols into closed enums/structs and route exhaustively. Use semantic identity types and request-specific result validation. Opaque Pi/plugin documents cannot become execution/routing authority.
- Preserve addressed targets, revision/filter/source-bound cursors, shared command admission and cross-domain storage fencing. `localMethods` and cloud `remoteMethods` remain separate.
- Managed Pi configuration is explicitly validated private `--pi-config`: approved directory/profile, session root, installed extension and ambient launcher. Callers do not supply arbitrary cwd/argv/history paths.
- Test commit-boundary faults, bounded single/batch reply bytes, correlation and completion models without payload diagnostics. Model/property tests, same-kernel reopen and power-loss acceptance are distinct. Use bounded `PROPTEST_CASES`/`PROPTEST_RNG_SEED` campaigns; retain synthetic regressions and replay seeds.
- Packed npm consumer fixtures require their own `package.json`; assert `npm prefix` before installation so npm cannot select an ancestor project. Keep tarballs/state/credentials disposable and private.

## Validation and delivery

- Start with affected tests, then full Rust/Swift/TypeScript and actual route/UI lanes. `npm run test:pi-discovery` proves dependency discovery; `npm run test:pi-interactive` and `axod/tests/managed_public.rs` exercise actual ambient Pi and owned PTYs/public routes.
- For protocol/cloud changes, follow their READMEs and run property suites under `protocol/` and `sites/api.axo.leostera.dev/`. Use actual isolated Worker/daemon tests for network claims.
- Use private disposable owned roots, never live-state resets. Do not bypass denied Accessibility or filesystem permissions. Distinguish pure tests, native components, Xcode UI, packaged launch and normal-service acceptance.
- Commit coherent validated Conventional Commits and push proactively. After Mac-affecting changes, deliver a signed, exact-source `dist/Axo.app` through the packaging skill. Shared AxoCore changes also require an AxoPhone build.
- Keep current operational guidance in `.agents/skills/axo-*`, not personal memory. Put evidence, implementation inventories and decision history in project documentation, not skill narratives. Report source/build/package/live status accurately.
