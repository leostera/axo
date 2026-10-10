---
name: axo-development
description: Apply Axo's project-specific development workflow and vanilla Pi integration boundaries. Use when implementing, reviewing, or delivering changes in the Axo repository.
---

# Axo development

## Durable project guidance

Keep Axo-specific workflows and operational knowledge in `.agents/skills/axo-*`. Improve an existing relevant skill or add a focused skill as repeatable practices emerge. Do not put these project notes in the personal memory repository. Skills should describe how to work, not accumulate transient test logs, process IDs, backup paths, or a second conversation history. For native Mac scenes, windows, sidebar/detail UI, settings, and AppKit boundaries, follow [axo-macos-native-apps](../axo-macos-native-apps/SKILL.md); for delivery, also follow the sibling packaging skill.

Resolve paths relative to the Axo root, three parents above this skill's directory. Inspect git status before editing and preserve unrelated local work, including draft RFDs.

## Integration boundary

Axo extends **the user's ambient vanilla Pi through installable extensions and public APIs**. Pi is a runtime dependency, not an Axo-vendored/bundled engine. Resolve a captured normal PATH launcher or explicit operator-selected executable; ignore npm-injected project `node_modules/.bin` and never silently fall back to the repo's Pi devDependency, auto-install or auto-upgrade. Validate supported public capabilities/readiness and report missing/unsupported installations clearly. Development Pi type declarations are not the execution origin; real integration tests must exercise the ambient CLI. The product path is Axo public RPC → Rust daemon → daemon-owned native PTY → ambient Pi's interactive TUI with an installed Axo control extension, using public Pi APIs in that same process. Do not add a separate `pi --mode rpc` execution path without an explicit product use case. The Rust CLI must exercise the same addressed Axo RPC path as the Mac/cloud clients, not talk directly to a different Pi mode. No attached Mac window is required for a TUI to keep running in its daemon-owned PTY. `axod/pi/README.md` records this boundary; `npm run test:pi-discovery` checks dependency discovery only, not execution/admission acceptance. Pi owns execution, queues, transcript persistence, and active conversation/branch. Do not patch Pi, use private runtime APIs, invent transcript records, or infer execution/steering identities from terminal text or timestamps. State observations and notifications are not an execution broker.

Capture explicit session, conversation, pane, and generation destinations before asynchronous operations. Revalidate them before applying a result; never fall back to the globally selected session. Restoring terminals must not replay prompts or shell commands. Read-only history/catalog operations must not execute work.

Reuse the pinned upstream Ghostty split implementation and preserve its MIT provenance. Do not modify ignored vendor sources or introduce a competing split geometry engine.

Use the current RFDs and repository tests for detailed contracts, especially `docs/rfds/RFD0003-workspaces-sessions-and-search.md`. Keep honest distinctions between implemented local features and unfinished addressed phone routing/broker work; search remains deferred until the foundation is complete.

## Parallel daemon and application lanes

The standalone Rust daemon is `axod/`. Implement and harden it there, not in new POCs. Its private runtime journal is not a second writer to the existing Mac workspace registry. Keep its processes/state isolated from the live application while developing it.

The current Mac app/bridge/relay/iOS compatibility work is an independent lane. It retains its existing process ownership until a later explicitly coordinated refactor. Do not prematurely wire `axod` into the Mac app, its broker, packaging, startup, or live storage. Completing a daemon slice is not permission for cutover, migration, login registration, or live process restart.

Use neutral relationship terminology: **host/child endpoints** for PTYs, **controller/worker** or **leader/follower** where appropriate. Preserve upstream API names only where required for compatibility.

## Private API and protocol development

Keep the next private control-plane iteration in `sites/api.axo.leostera.dev/` and shared contracts in the proper `@axo/protocol` package under `protocol/`. JavaScript consumers import its compiled package exports, not sibling TypeScript source. Preserve the current `service/` lane and its file/relay authority until a separately coordinated migration.

Install/build/test the protocol package independently before the new API. Follow their READMEs for `cf` build/type generation, isolated Node/Miniflare tests and the real-`axod` network suite. Use the same supported workerd compatibility target; Miniflare v5 persistence uses `resourcePersistencePath`, and cold-runtime/hibernation tests must establish actual storage/socket recovery. Library request correlation is not durable command execution identity or DO recovery state.

`axod serve` now uses loopback JSON-RPC and private `local-endpoint.json` discovery, not Unix IPC. Local credentials were explicitly deferred: native Host/path/no-Origin guards are browser restrictions, not OS-user authorization. Keep Access as the existing cloud edge gate without introducing application accounts, enrollment or user-management scaffolding. Use the shared dispatcher/profile policy for local/remote parity; do not add a native-side legacy-envelope shim or assume terminal data/Pi APIs are exposed by the metadata/approved-profile/work-record slices.

The private daemon work store is `work-records.json`, opened under the same owner lock as its runtime journal. It is not permission to import or mutate live Mac work records. Metadata create/rename/read must not launch or invent Pi chats; generic runtime observations remain distinct from admission. Preserve shared execution/work command admission, immutable receipts, source/revision/filter-bound cursors and cross-domain persistence fencing.

For daemon hardening, run `npm --prefix protocol run test:properties` alongside Rust and real-route tests; see `axod/tests/README.md`. Differential oracles must call production codec/admission code and explicitly forbid mutations, not fake Pi execution. Retain seed/path replay and minimal synthetic regressions without logging payload bodies. Inject persistence faults at commit boundaries and distinguish memory fencing, same-kernel reopen and actual power-loss durability. Parallel PTY forks can briefly inherit other test roots' CLOEXEC locks: bounded waiting is allowed only for disposable fixture ownership, never commands/corruption or production replay. A passing generated suite is not production-hardening evidence.

For packed-package consumer tests, create an explicit fixture `package.json` and assert `npm prefix` resolves to that fixture **before** any install. An empty temporary cwd can make npm walk to an unrelated ancestor project. Keep package tarballs, credentials and daemon state in owned disposable fixtures; never use live app state or deployment credentials for isolated tests.

## AxoPhone sidebar design contract

When refining the compact iPhone Sessions menu, use the supplied ChatGPT sidebar screenshot as a proportional reference:

- Keep the Sessions list underneath the chat surface. Reveal it by translating the foreground chat right; use a width-derived reveal distance of about 79% of the available compact viewport, capped near 360 pt, and make the exposed sidebar the same width.
- Align sidebar content to shared rails: roughly 32 pt leading and 24 pt trailing. Keep search and Settings on the trailing rail.
- Use text-only session rows, grouped by workspace. Inset the selected-row background about 10 pt from each edge; use a roughly 44 pt row with a 38 pt selected pill, and inset the label so its leading edge aligns with the 32 pt content rail. Reserve symbols for actions, not session identity.
- Keep the header compact, use 44 pt controls, and align the bottom New Session and Settings actions to the same rails.
- Extend a secondary-system-surface backplate behind the foreground chat through the status-bar and home-indicator safe areas. At full reveal, a tertiary-system-surface overlay near 0.64 opacity over chat content lands near the reference's `#1b1b1b` background while muting bright content to roughly `#78`; keep that overlay confined to the shifted chat, never the sidebar. Do not snap the color change only after the gesture ends. Let corner rounding (about 42 pt on the supplied phone) and shadow track the same progress.
- Keep workspace creation out of the scrolling session list; expose it alongside New Session in the footer action menu so the list remains visually focused on sessions.
- While the menu is open, dim and disable the foreground chat, including scroll and accessibility interaction, while keeping the exposed sidebar interactive. Preserve a reverse-swipe close path that can begin on the visible chat surface as well as the sidebar.
- These are reference starting measurements, not device-wide constants. Derive the reveal from available geometry and verify Dynamic Type, landscape, and narrow layouts. User-facing terminology is **Sessions**, never “Playground”; retain that spelling only in compatibility code when required by stored data.

## Validation and delivery

- Make frequent, coherent, validated Conventional Commits and push proactively.
- Follow the sibling [axo-macos-packaging skill](../axo-macos-packaging/SKILL.md) whenever a change affects the Mac app or its Pi bridge. **Always deliver an updated `dist/Axo.app`**, not only a DerivedData build.
- Packaging is not permission to restart the live Mac/Pi processes or install/relaunch the physical phone. Ask separately and preserve ongoing work.
- Never bypass denied Accessibility permissions. Synthetic isolated tests are useful but do not prove live UI, macOS notification-banner/click, or physical-device acceptance.
- Report source/build/package/live status accurately. Document public API gaps rather than disguising partial coverage as complete behavior.
