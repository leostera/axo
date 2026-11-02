# AXP extension: `pi`

```text
Identifier: pi
Version:    0.1
Status:     Draft
Requires:   core only
Roles:      host, client
```

Steering a [Pi](https://github.com/earendil-works/pi) agent: prompts, stops, answers to its questions and restarts, plus how a Pi Session becomes an AXP log.

## 1. Logs

A Pi Session's log is the ATXF conversion of Pi's session file, as described in ATXF's [Pi mapping](https://atxf.leostera.dev/mappings/#pi-pipiagentsessionsjsonl):

- The header's `source.agent` is `pi` and its `id` is the Session's `sessionId`.
- The host converts each Pi entry as Pi appends it, and MUST carry it in `native` (with `native.raw` when re-serializing would not reproduce it), so that `fidelity.native` is `all`. A client that draws Pi's own interface recovers Pi's entries from `native` in order, byte for byte.
- ATXF record ids are Pi entry ids (`fidelity.ids: "stable"`).
- The user message a `pi.prompt` produces carries `ext.axp.commandId` (SPEC §10.2). A host that cannot attach it to the user message itself, because Pi writes that entry, writes a Pi custom entry of type `axp.command` with `{ "commandId" }` immediately before it, and the converter moves the id onto the next user message.

## 2. Commands

Every method is routed (SPEC §10.1) and a command (SPEC §10.2). All take `hostId`, `sessionId` and `commandId`.

| Method | Further params | Effect |
| --- | --- | --- |
| `pi.prompt` | `text`, `images`? | A user message. |
| `pi.stop` | `turn` | Stops the turn, if it is still running. |
| `pi.answer` | `question`, `answer` | Answers a question Pi asked. |
| `pi.restart` | `mode`: `auto` or `force` | Restarts the Pi process of the Session. |

### 2.1 `pi.prompt`

- `text` is 1 to 100,000 characters. `images` is up to 8 objects `{ "mediaType", "data" }`, `data` being base64url of at most 5 MiB each.
- When Pi is idle the prompt starts a turn. When a turn is running the host holds the prompt and starts the next turn with it when the running one ends. Held prompts are not steering: a stop does not drop them.
- A host holds at most 32 prompts per Session and refuses more with `-32220` (`busy`).

### 2.2 `pi.stop`

`turn` is the `id` of a user message record in the turn the client saw running. The host stops the running turn only if that record belongs to it, and otherwise answers `{ "receipt": "accepted", "stopped": false }`. A stop never ends a turn the client has not seen.

### 2.3 `pi.answer`

`question` is the `id` from the `question` slot (§3). `answer` is `{ "option": <id> }` or `{ "text": <string> }`. A question that is no longer open is answered `-32221` (`noQuestion`).

### 2.4 `pi.restart`

`auto` restarts Pi between turns, after the running turn ends. `force` restarts it now and ends the running turn. The Session's status is `starting` until Pi is running again.

## 3. Slots

| Slot | Value |
| --- | --- |
| `reply` | The assistant message being written, as an ATXF `message` record without `hash`. |
| `tool:<callId>` | Progress of a running tool call: `{ "status", "output"? }`, `output` being the latest partial output, at most 64 KiB. |
| `question` | The question Pi is waiting on: `{ "id", "title", "options": [{ "id", "label" }] }`. |

The Session's status is `needsAttention` while `question` is set.

## 4. Errors

| Code | Name | `retry` | Meaning |
| --- | --- | --- | --- |
| -32220 | `busy` | `safe` | Too many held prompts. |
| -32221 | `noQuestion` | `never` | The question is no longer open. |
| -32222 | `agentNotRunning` | `safe` | Pi is not running for this Session; it may be restarting. |
