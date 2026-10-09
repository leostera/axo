---
name: axo-pi-title-and-attention
description: Implement or troubleshoot Axo conversation naming, sidebar agent-state icons, and macOS attention notifications using public vanilla Pi APIs.
---

# Axo Pi titles and attention

Read the sibling [development](../axo-development/SKILL.md) and [packaging](../axo-macos-packaging/SKILL.md) skills when changing this integration. Resolve paths from the Axo root, three parents above this directory.

## Naming

- `bridge/session-title.ts` registers the model-callable `axo_set_title` tool. Do not reinstate the superseded separate naming agent, provider selection, or hidden startup user message.
- Add first-request naming guidance to a named **structured section** of `before_agent_start.systemPromptOptions`. Do not replace the whole system prompt or fabricate user/history entries. `AXO_AUTO_TITLE=0` disables automatic guidance, not explicit tool access. If the tool is not selected, do not instruct the model to call it.
- Pi owns the persisted conversation name through public `pi.setSessionName`; `axo.title_set` is only a durable naming marker. Normal tool calls/results remain in Pi's authoritative transcript. A normal tool-follow-up model request is not a separate naming instance.
- Bind calls by Pi's stable tool-call ID, captured conversation/file identity, and lifecycle generation. Bound the pending-call map and revalidate after approval waits. Switch/fork/tree/reload/shutdown or abort must reject stale callbacks.
- Validate nonempty single-line titles of at most 120 UTF-8 bytes, with no control characters. A repeat of the current title is a no-op. Replacing another title requires `replace=true` plus actual user approval; cancellation and newer manual names win.
- Native manually named Axo session labels are separate from the Pi conversation name and remain protected. Do not silently turn an agent suggestion into a manual workspace/session rename.
- Use `tests/session-title.test.ts` including its real vanilla Pi CLI/local-provider fixture. It must show no startup model request, one real user message, a normal naming tool result, and no helper model. Explicit `--tools` CLI selections must include `axo_set_title`; `--no-tools` excludes it.

## Observations and sidebar

- `bridge/mac-session-state.ts` is read-only local telemetry, **not a command broker or transcript replica**. Publish only public lifecycle facts and Axo-owned UI waits; never guess state from terminal text.
- Start the heartbeat from `session_start`, not extension discovery, and release it idempotently at shutdown. Atomic private frames are bounded to 4 KiB and paired with explicit Axo session, pane, runtime generation, and expected Pi file. The native observation lease is 30 seconds.
- Validate the conversation against its Pi header before admitting observations or notifying. Missing, expired, malformed, or detached observations are unavailable—not proof of idle/working state.
- Each session row has **one leading icon**: hammer for working, small green dot for open/idle, alert for attention, unknown/stopped indicators as appropriate. Project headers retain folders. Standalone playground leaves reclaim their disclosure gutter; project children retain hierarchy indentation. Flat, non-selectable **Workspaces** and **Sessions** group headings distinguish the populated sections without introducing another tree level.
- Settled results/failures become idle after viewing; pending questions remain alert until answered. Attention episode IDs deduplicate polling without suppressing genuinely new episodes.
- Pi currently has no public global observer for arbitrary other extensions' permission/dialog waits. Document incomplete coverage; do not patch Pi or claim global attention parity.

## macOS notification acceptance

- `MacSessionNotifications.swift` uses native UserNotifications with permission-gated, generic text, no prompts/replies/paths, and opaque session/pane/runtime/conversation destinations. Coalesce attention notifications per session and suppress them while actually viewing that session.
- Notification clicks must validate a fresh admitted live runtime/conversation before selecting its session/pane. Stale notifications must not retarget or restart old work. Never submit a prompt from a notification.
- Settings exposes permission status, the macOS settings link, and **Send Test Notification** for a captured selected live Pi binding. It is explicitly labeled as a test, may show while the app is foreground, and does not fabricate an agent attention event or submit work. Bound tests to one replaceable notification per session.
- Repackage first. Ask before a live-app restart; never kill the Pi hosting the current assistant turn. Let the user perform a safe restart after the turn if necessary.
- Live acceptance requires the user to allow notifications, see the banner/Notification Center item, click it, and verify the correct session/pane opens. Also check foreground suppression and a real background settled reply/Axo question. Synthetic native smoke tests and successful `center.add` completion alone do not prove these outcomes. Focus/banners/sound preferences can suppress delivery even when permission is allowed.
