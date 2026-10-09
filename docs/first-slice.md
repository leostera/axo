# First slice: one Pi, two clients

This is the deliberately smaller implementation selected after reviewing [RFD0001](rfds/RFD0001-axo-continuous-agent-workspaces.md). The RFD remains the longer-term product proposal.

## Scope

- One native macOS window, one libghostty terminal, Pi started automatically.
- One fixed session working directory and one persistent Pi conversation (the original prototype).
- One native iPhone conversation screen with text, Apple's on-device English speech recognition on supported iOS 26+ devices, keyboard dictation, and choice buttons. See [voice prompting](voice-prompts.md) for Apple language-asset setup and the automatic-send flow with draft fallback.
- One Cloudflare relay channel, protected by Cloudflare Access rather than Axo-owned accounts.
- Local RFD0002 implementation: explicitly published file snapshots, native draft/gallery/preview UI, and demand-driven recent history. Production R2 storage remains disabled pending approval; see [RFD0002](rfds/RFD0002-shared-session-files.md) for release gates.
- The conversation UI requires iOS 18+; Apple's on-device voice integration remains iOS 26+.
- No session/workspace navigation, GitHub login implementation, offline command queue, E2EE, independent background host, push notifications, or additional machines.

The relay's one-channel design is intentional for this single-user prototype; it is not the multi-user partitioning strategy for the full product.

## Integration decision

Use a Pi **extension in interactive mode**, not an RPC subprocess on the desktop. The extension receives remote prompts through its own authenticated WebSocket and calls Pi's `sendUserMessage` for text or `sendMessage` for attachment-bearing custom messages whose content and metadata persist together. It observes completed messages and `agent_settled`, publishing a bounded projection of the active conversation branch.

The `axo_ask` tool races a local Pi select dialog against a remote response. The first answer resolves it; the other path is cancelled. Stale question IDs are rejected. Arbitrary existing TUI dialogs are not intercepted or monkey-patched.

This keeps the stock Pi TUI intact. The bridge's real-TUI integration test runs Pi on a PTY, drives it through a local TLS WebSocket, and uses a deterministic local model to prove prompt → question → phone answer → result without spending model credits.

## Wire protocol

JSON text frames, maximum 256 KiB, over authenticated WebSockets:

| Direction | Type | Meaning |
| --- | --- | --- |
| Phone → Mac | `sync` | Request current projection |
| Phone → Mac | `prompt` | Command ID, explicit Pi session ID, bounded text and optional shared-file IDs; never original file bytes |
| Phone → Mac | `answer` | Command ID, session ID, question ID, offered choice |
| Phone → Mac | `cancel` | Command ID, session ID, active run ID |
| Phone → Mac | `history` | Read-only before/after page with session, view, and cursor identity; demand-driven, not automatic full restoration |
| Phone → Mac | `tool_output` | Read-only output page for a saved tool call, using a byte offset |
| Mac → phone | `history` / `tool_output` | Correlated bounded pages; never execute or queue a prompt |
| Mac → phone | `snapshot` | Session identity, agent state, bounded messages, pending question |
| Mac → phone | `ack` | Command was submitted to Pi; not proof of execution |
| Either bridge/relay → phone | `error` | Rejection or failure; correlated by command ID where possible |
| Relay → phone | `presence` | Whether a currently authorized Mac connection exists |
| Relay → phone | `files_changed` | Session/revision invalidation hint, not file bytes or transcript history |

The TypeScript boundary validates frames. The native client decodes the same shapes. Snapshots are authoritative for the phone projection; the relay does not retain them for reconnects.

## Failure contract

- No Mac connection means no execution and no queue. Keep the draft on the phone.
- No acknowledgment means uncertain delivery. Do not auto-replay.
- Prompt IDs are recorded in Pi custom entries before dispatch. Repeated IDs are rejected even after reopening the same history.
- A different Pi session ID rejects an old phone command instead of sending it into the wrong conversation.
- A second active Mac connection is rejected instead of executing a prompt twice.
- Access credentials are checked on handshake and their expiry is enforced on existing sockets.
- Hiding the Mac window retains its view and process. Quitting terminates the terminal; only history is restored next time.
- Access and transport encryption do not prevent the relay from reading content. Restricted work is not part of prototype validation.

## Remaining gates to a usable device demo

Xcode 27, Metal, Zig 0.16.0, and XcodeGen are available. The pinned full Ghostty framework and Mac app link successfully; iPhone simulator and signed device builds pass, as do the fourteen shared Swift package tests. The Mac launches Pi, and the corrected iPhone app has been installed and launched on Leandro's phone. The relay is deployed at `bridge.axo.leostera.dev`, with Access and Worker checks allowing `leandro@abstractmachines.dev`.

The Mac service identity and narrowly scoped Access policy are configured, the relay is redeployed, and credentials are saved locally with mode `0600`. A live authenticated host WebSocket upgrade succeeded; the same token is rejected for phone login.

1. Validate terminal input, IME, rendering, clipboard, and window hiding beyond basic startup.
2. Complete phone login and verify the configured Access identity provider works in its WebKit sheet.
3. Restart Axo on the Mac so Pi loads its newly created credentials; verify the phone sees the Mac online.
4. Perform the phone → actual Mac terminal loop outside the local network.

Successful builds and automated tests do not claim those runtime/device gates have passed. See the root [README](../README.md) for commands and current validation status.
