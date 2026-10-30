# @axo/pi-axo

A first-party Pi extension for an Axod-owned interactive Pi process. Axod creates the PTY, chooses the exact Pi session-file path, and owns cloud/API relay. This extension provides a local structured event/control channel; it never connects to the API or writes Pi's JSONL session file.

## Load from Axod

Axod passes these environment variables when launching Pi and explicitly loads this extension:

- `AXO_PI_BRIDGE_SOCKET`: absolute path to a per-session Unix-domain socket.
- `AXO_SESSION_ID`: Axo Session UUID.
- `AXO_PANE_ID`: required Pi pane UUID.
- `AXO_PI_SESSION_FILE`: exact absolute Pi session-file path for this Axo Session.

Axod persists the chosen socket path in the session record and passes that same absolute path as `AXO_PI_BRIDGE_SOCKET` on launch and recovery; neither side independently picks a port or re-derives the address. It uses `~/.axo/server/pi-sessions/<session-uuid>.sock`, falling back to `/tmp/axo-pi-<session-uuid>.sock` when the scoped path would exceed 100 UTF-8 bytes. The 100-byte limit is shared with Axod and intentionally leaves room below macOS's Unix-domain socket limit. Axod creates the socket's parent directory and session-file parent directory with mode `0700`. The extension creates the socket with mode `0600`; it does not remove a pre-existing socket path. Axod owns stale-socket cleanup and uses a distinct path for each Pi session. Pi may leave a new session file absent until meaningful interaction; Axod must not pre-create or write it.

```sh
npm ci --prefix /path/to/packages/pi-axo
npm --prefix /path/to/packages/pi-axo run build
pi \
  --session "$AXO_PI_SESSION_FILE" \
  --extension /path/to/packages/pi-axo/dist/index.js
```

The extension starts listening during extension initialization, then binds only after Pi reports `session_start`. It verifies that Pi opened the exact session-file path Axod supplied. Once bound, it reports the Axo Session/Pane IDs, Pi session ID, actual file path, working directory, and process ID. Axod must independently validate this binding before relaying anything. The path and working directory are local Axod metadata; the extension does not send them to Cloudflare.

## Axo MCP server

When Axod also passes `AXOD` (its executable) and `AXO_SOCKET` (its local socket), the extension registers `axod mcp` for this Session as the `axo` MCP server with `codemode` exposure (`src/mcp.ts`). Its tools are not declared to the model; codemode scripts call them as `tools.mcp__axo__<tool>(...)` and read their instructions with `describeNamespace("mcp__axo")`. See RFD0015. The registration is independent of the bridge, and nothing is registered outside Axo.

## Local bridge v1

Records are UTF-8 JSON objects terminated by LF. Each direction is full-duplex. The server accepts one Axod connection at a time and can accept a replacement connection after disconnect.

Pi-to-Axod records:

- `hello`: protocol version and local Pi/Axo identity.
- `event`: monotonically sequenced Pi lifecycle, message, turn, and tool events.
- `commandResult`: the result for a control command.
- `protocolError`: a bounded framing/validation error without session content.

Axod-to-Pi records use `type: "command"`, a request ID, and the matching Axo Session ID. V1 supports `send` (normal, steer, or follow-up delivery) and `cancel`. Commands for a different Session are rejected. Duplicate request IDs return the cached result while this Pi process remains alive; after an ambiguous disconnect, Axod must not blindly replay a command.

The extension forwards structured Pi events to Axod only. Its `/resume` request includes a selected transcript path but is consumed locally by Axod and is never relayed. `/axo-import <path.jsonl>` asks Axod to copy that Pi transcript into a new Session in the current Workspace, then focus the new Session; the source and current Session remain unchanged. Axod validates the Pi session header and copies it into its private history directory with the Workspace's working directory. If Axod is disconnected, live events are not buffered in memory; Axod must reconcile from Pi's durable local session history. Terminal bytes never enter this channel. Pi remains the sole writer of its session file.

## Sharing a conversation

`/axo-share` publishes a read-only copy of the current branch at `https://axo.leostera.dev/s/<share-id>/<slug>`; `/axo-share --dry-run` stops before uploading. Everything happens on this Mac (`src/share.ts`, `src/share-command.ts`):

1. **Snapshot.** User and assistant words and the tools that ran (name, command or path, status, output cut to 4,000 characters). Reasoning and images are never included.
2. **Scrub.** Known secret shapes (private keys, cloud and Git tokens, JWTs, bearer headers, URL credentials, `*_TOKEN=…`-style assignments, email addresses) and home-directory user names are replaced by `[redacted:<category>]` before any model sees the text.
3. **Triage with Clef.** Each field goes to the cheapest available Clef classifier (Clef Flash, then Clef); fields with at least a 15% chance of holding sensitive information go on. Without a Clef with working credentials (Workers AI or OpenRouter), every field goes on.
4. **Redact with Haiku.** A Haiku model (the current provider's first, newest first) names the exact sensitive substrings; they are replaced in every field, so a secret seen once is removed everywhere. The model never rewrites text.
5. **Review and publish.** The redacted snapshot is written to `~/.axo/shares/<share-id>.json` (mode `0600`) and uploaded only after confirmation, with `wrangler r2 object put` to the `axo-public-sessions` bucket. The share is recorded as an `axo_session_share` custom entry.

Triage and redaction send the scrubbed text to those model providers. Any model error or malformed answer stops the share; nothing half-checked is uploaded. Model redaction is best effort: review the file before confirming. `AXO_SHARE_CLASSIFIER` and `AXO_SHARE_REDACTOR` (`provider/model-id`), `AXO_SHARE_BUCKET`, and `CLOUDFLARE_ACCOUNT_ID` override the defaults. Publishing never touches Axo's API or its stored session history.

## Session title, emoji, and activity

On the first user turn of an unnamed conversation, the extension adds a structured prompt section asking Pi to call `axo_set_title` in that same turn with a concise title and one representative emoji. The tool remains available to update both when the conversation's focus materially changes; the prompt discourages renaming on routine turns. Titles are persisted through Pi's public `setSessionName()` API, and the current emoji is saved as a Pi custom entry that does not enter model context. Axod receives only validated title/emoji metadata through the exact bound bridge and stores the sidebar projection locally.

The extension also forwards Pi's public agent-settled and blocking-UI-prompt lifecycle events. Axod derives sidebar status as ready, working, or needs attention from those events. A starting/disconnected Pi binding is not presented as ready. The attention indicator means Pi is currently waiting in a blocking UI prompt; arbitrary terminal output is never inspected to infer status.

## Session ownership

The extension prevents Pi from switching or forking a transcript behind Axod. `/resume` is forwarded as a local resume request; Axod accepts only an exact transcript path already owned by an Axo Session, reopens its archived Session record, and starts Pi against that same file. When the target is ready, Axod archives the Session that issued `/resume` and the Mac app switches to the resumed Session; if the target cannot be safely opened, the current Session remains open. The Pi switch itself remains canceled so Axod keeps sole ownership. Unknown or missing files are not adopted. `/new` and `/fork` remain blocked and must be initiated through Axo. Branch navigation within the current Pi file remains Pi-owned.

The Unix socket is local to the host. Axod must place it in a private per-session directory and verify the `hello` identity against its stored Pane/Session binding. Mode `0600` excludes other local user accounts, but does not authenticate a different process running as the same user; v1 has no challenge/capability handshake, so the first local peer must be treated as trusted. Do not expose or forward this socket to remote clients, and do not relay Pi event content to server-side storage until Axod implements the host/session authorization and the event retention/sharing policy.
