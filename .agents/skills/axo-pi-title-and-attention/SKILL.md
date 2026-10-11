---
name: axo-pi-title-and-attention
description: Implement or troubleshoot Axo conversation naming, sidebar status, and macOS attention coverage using public vanilla Pi APIs.
---

# Axo Pi titles and attention

Resolve paths from the Axo root (`../../..`). Follow [development](../axo-development/SKILL.md), [native Mac](../axo-macos-native-apps/SKILL.md) and [packaging](../axo-macos-packaging/SKILL.md). The active integration is `pi-axo/` inside daemon-owned ambient interactive Pi.

## Conversation naming

- `pi-axo/title.ts` registers `axo_set_title`. It calls public `pi.setSessionName`; Pi alone persists canonical conversation metadata. The tool/result belongs to the real user turn, not a second naming model or fabricated history entry.
- Titles are nonempty, trimmed, at most 80 JavaScript string code units, with no control characters. Keep validation consistent with the extension snapshot and shared protocol. The current tool accepts `title`; it does not have a replacement/approval flag.
- `before_agent_start.systemPromptOptions.sections.axo_session_title` supplies guidance only when `selectedTools` includes `axo_set_title`. Preserve the system prompt's other structured sections; do not fabricate a startup user message or model request.
- `changed()` publishes canonical title through the managed control snapshot. Native manual workspace/session labels are separate; `WorkSessionRecord.displayName` respects manual protection. A Pi title is not a manual work rename. Unknown `manualName` capability disables unsupported editing rather than inventing protection.
- Capture exact runtime/conversation/source identities around asynchronous work. A title observation must not rebind another conversation or reconstruct a canonical record from terminal text.

## Current status transport and sidebar

- `pi-axo/index.ts` activates managed control only for the explicit inherited fd-3 launch. It uses public Pi events/context/session-manager APIs and has no separate listener or RPC-mode engine.
- Snapshots include exact chat/file/leaf/cwd/runtime identity, title, busy/pending state, Axo-owned question/UI waits, active tools and recovery. `pi-axo/questions.ts` owns supported question interactions; arbitrary extensions' permission/dialog waits are not globally observable through current public Pi APIs.
- Axod validates bindings and exposes addressed public snapshots. Keep generic runtime existence separate from admitted Pi readiness. Missing, malformed, disconnected, stale or recovery state is unavailable/uncertain, not confirmed idle or replay permission.
- The current native outline renders folder workspace rows and session title/running-status rows. It does not implement full working/attention episode presentation or agent-attention notification delivery. Do not describe those as operational based on available control fields.
- Metadata/title refresh preserves row identity/order, native selection/range anchor, displayed session, field editor and unchanged terminal/chat bindings. Use Sessions terminology; standalone means no workspace.

## Current notification coverage

`AxodWorkbenchCoordinator.notificationPreferenceChanged` requests UserNotifications authorization; `openNotificationSettings` opens the app's system notification settings. These settings hooks are not agent-attention delivery, notification-click routing or delivery acceptance.

When implementing notification delivery:

- Derive supported attention facts from exact admitted snapshots/public events, not terminal text or timestamps. Document unsupported external extension waits.
- Use generic permission-gated text and opaque captured session/pane/runtime/conversation destinations, with no prompts, replies or private paths.
- Coalesce episodes, suppress when actually viewing the target, and validate current admitted binding on click. Notification interaction is selection only: never submit work, restart a runtime or retarget stale destinations.
- Test actual permission, banner/Notification Center delivery, correct click destination, foreground suppression and supported background reply/question episodes. Successful `center.add` or synthetic component tests alone are not delivery proof.

## Validation

- `npm run test:pi-interactive` exercises ambient interactive Pi and the installed extension in owned Rust PTYs. `axod/tests/managed_public.rs` exercises public managed routes, canonical title/history and exact binding behavior.
- `scripts/check-mac-workbench.sh` chat mode covers real tools/title/history through production native coordination. `scripts/check-mac-ui.sh` covers actual native row rename/selection and a UI-typed Pi turn with its real viewport response/canonical file.
- Keep model counts explicit: loading/observing/naming guidance does not itself issue a model request; a tool follow-up belongs to the normal turn.
- Package Mac-affecting changes, preserve all live histories/work, and obtain consent separately for live restart or notification acceptance requiring user interaction. Never stop the Pi hosting an active assistant turn.
