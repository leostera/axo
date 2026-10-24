---
name: axo-pi-title-and-attention
description: Implement or troubleshoot Axo conversation naming, sidebar status, and macOS attention coverage using public vanilla Pi APIs.
---

# Axo Pi titles and attention

Resolve paths from the Axo root (`../../..`). Follow the [native app](../axo-macos-native-apps/SKILL.md) and [packaging](../axo-macos-packaging/SKILL.md) skills. The integration is the `packages/pi-axo` extension, loaded by daemon-owned vanilla interactive Pi from the app bundle (`Contents/Resources/AxoPi/`).

## Extension (`packages/pi-axo/src`)

- `extension.ts` is the entry: it starts an authenticated per-Session bridge server (`bridge-server.ts`) on the socket and token Axod passes in, then forwards public Pi events (`session_*`, `message_*`, `turn_*`, `agent_*`, `tool_execution_*`, `session_info_changed`, `ui_prompt_start/end`) to Axod and accepts Axod's commands. `protocol.ts` defines the bridge messages; `index.ts` exports the extension.
- `title.ts` registers the `axo_set_title` tool with `title` (1–80 chars, no control characters) and `emoji` (exactly one pictographic grapheme). It calls public `pi.setSessionName` and records the emoji as an `axo_session_appearance` custom entry; Pi alone persists canonical metadata.
- Naming guidance is injected in `before_agent_start` as `systemPromptOptions.sections.axo_session_title`, only when `axo_set_title` is among the selected tools: first-request naming when untitled, otherwise "rename only on material focus change". Never fabricate user messages or make a separate naming model request.
- Manual names (`axo.session.rename`, `manualName`) are separate from Pi titles and take precedence in `TerminalSession.displayName`.

## Status and attention

- Axod derives Session status from bridge activity (`crates/axo-server/src/session.rs`, `PiRuntimeActivity::status`): disconnected → `unavailable`, pending UI prompts → `needsAttention`, an active agent → `working`, otherwise `ready`; before the bridge connects, `starting`.
- The app receives status in `session.snapshot` events through `TerminalCatalogSync` and renders it in the sidebar (`Workbench/TerminalWorkbenchView.swift`). Unseen terminal bells mark a Session `needsAttention` locally (`GhosttyRuntime.attentionShellIDs`, cleared when the pane is focused).
- Desktop notifications today come only from Ghostty terminal events (OSC desktop notifications and command-finished policy in `Terminal/TerminalAttention.swift`), gated by Ghostty config. There is no Pi agent-attention notification delivery or notification-click routing yet; do not describe status fields as notifications.
- Missing, malformed or disconnected bridge state is unavailable/uncertain, never confirmed idle.

## Validation

- `npm --prefix packages/pi-axo test` covers the extension: title validation, guidance injection, bridge protocol and config.
- `bazel test //crates/axod:rpc_tests` and `cargo test -p axo-server --lib` cover bridge activity, status derivation and session events with the inert Pi fixtures.
- `bazel test //apple/AxoMac:AxoMacTests` covers catalog event application; the visual UI suite covers real sidebar rename and a Pi Session surviving app relaunch.
- Package after extension changes (`build-mac.sh` rebuilds and embeds it). Never stop a Pi hosting an active assistant turn, and get the user's consent before live restarts or notification acceptance that needs interaction.
