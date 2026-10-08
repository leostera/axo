# First slice: one Pi, two clients

This is the deliberately smaller implementation selected after reviewing [RFD0001](rfds/RFD0001-axo-continuous-agent-workspaces.md). The RFD remains the longer-term product proposal.

## Scope

- One native macOS window, one libghostty terminal, Pi started automatically.
- One fixed playground and one persistent Pi conversation.
- One native iPhone conversation screen with text/keyboard dictation and choice buttons.
- One Cloudflare relay channel, protected by Cloudflare Access rather than Axo-owned accounts.
- No session/workspace navigation, GitHub login implementation, offline command queue, E2EE, independent background host, push notifications, or additional machines.

The relay's one-channel design is intentional for this single-user prototype; it is not the multi-user partitioning strategy for the full product.

## Integration decision

Use a Pi **extension in interactive mode**, not an RPC subprocess on the desktop. The extension receives remote prompts through its own authenticated WebSocket and calls Pi's `sendUserMessage`. It observes completed messages and `agent_settled`, publishing a bounded projection of the active conversation branch.

The `axo_ask` tool races a local Pi select dialog against a remote response. The first answer resolves it; the other path is cancelled. Stale question IDs are rejected. Arbitrary existing TUI dialogs are not intercepted or monkey-patched.

This keeps the stock Pi TUI intact. The bridge's real-TUI integration test runs Pi on a PTY, drives it through a local TLS WebSocket, and uses a deterministic local model to prove prompt → question → phone answer → result without spending model credits.

## Wire protocol

JSON text frames, maximum 256 KiB, over authenticated WebSockets:

| Direction | Type | Meaning |
| --- | --- | --- |
| Phone → Mac | `sync` | Request current projection |
| Phone → Mac | `prompt` | Command ID, explicit Pi session ID, bounded text |
| Phone → Mac | `answer` | Command ID, session ID, question ID, offered choice |
| Mac → phone | `snapshot` | Session identity, agent state, bounded messages, pending question |
| Mac → phone | `ack` | Command was submitted to Pi; not proof of execution |
| Either bridge/relay → phone | `error` | Rejection or failure; correlated by command ID where possible |
| Relay → phone | `presence` | Whether a currently authorized Mac connection exists |

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

1. Install/select full Xcode and its Metal toolchain; provide Zig 0.16.0 and XcodeGen.
2. Link/run the pinned full Ghostty framework; validate terminal input, IME, rendering, clipboard, and window hiding.
3. Build/sign/run the iPhone app and verify the configured Access identity provider works in its login sheet.
4. Confirm the Cloudflare account and hostname, create the Access guard and Mac service identity, configure the relay, and deploy.
5. Perform the phone → actual Mac terminal loop outside the local network.

The repository's automated tests do not claim those physical-device/deployment gates have passed. See the root [README](../README.md) for commands and current validation status.
