---
name: axo-development
description: Apply Axo's project-specific development workflow and vanilla Pi integration boundaries. Use when implementing, reviewing, or delivering changes in the Axo repository.
---

# Axo development

## Durable project guidance

Keep Axo-specific workflows and operational knowledge in `.agents/skills/axo-*`. Improve an existing relevant skill or add a focused skill as repeatable practices emerge. Do not put these project notes in the personal memory repository. Skills should describe how to work, not accumulate transient test logs, process IDs, backup paths, or a second conversation history. For native Mac scenes, windows, sidebar/detail UI, settings, and AppKit boundaries, follow [axo-macos-native-apps](../axo-macos-native-apps/SKILL.md); for delivery, also follow the sibling packaging skill.

Resolve paths relative to the Axo root, three parents above this skill's directory. Inspect git status before editing and preserve unrelated local work, including draft RFDs.

## Integration boundary

Axo extends **vanilla Pi through installable extensions and public APIs**. Pi owns execution, queues, transcript persistence, and active conversation/branch. Do not patch Pi, use private runtime APIs, invent transcript records, or infer execution/steering identities from terminal text or timestamps. State observations and notifications are not an execution broker.

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

For packed-package consumer tests, create an explicit fixture `package.json` and assert `npm prefix` resolves to that fixture **before** any install. An empty temporary cwd can make npm walk to an unrelated ancestor project. Keep package tarballs, credentials and daemon state in owned disposable fixtures; never use live app state or deployment credentials for isolated tests.

## Validation and delivery

- Make frequent, coherent, validated Conventional Commits and push proactively.
- Follow the sibling [axo-macos-packaging skill](../axo-macos-packaging/SKILL.md) whenever a change affects the Mac app or its Pi bridge. **Always deliver an updated `dist/Axo.app`**, not only a DerivedData build.
- Packaging is not permission to restart the live Mac/Pi processes or install/relaunch the physical phone. Ask separately and preserve ongoing work.
- Never bypass denied Accessibility permissions. Synthetic isolated tests are useful but do not prove live UI, macOS notification-banner/click, or physical-device acceptance.
- Report source/build/package/live status accurately. Document public API gaps rather than disguising partial coverage as complete behavior.
