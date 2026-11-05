# AXP extension: `agent`

```text
Identifier: agent
Version:    0.1
Status:     Draft
Requires:   core only
Roles:      host, client
```

Steering the agent that runs in a Session: prompts, stops and restarts, plus how its session becomes an AXP log and what clients see while it works. The extension does not name an agent. Pi, Codex, Claude Code, OpenCode and Gemini CLI are all steered the same way; the log's ATXF header says which one it is.

## 1. Agents

An **agent** is a program that holds a conversation with a person and acts on their behalf, usually a coding agent. A host can steer an agent over AXP if the agent:

1. **takes a user message**, text with optional files, and runs a turn on it: thinking, calling tools, writing assistant messages;
2. **records the conversation** as it goes, in a form the host can convert to ATXF record by record (SPEC §9), in the order it happened;
3. **can be stopped** during a turn, ending it early;
4. **can be restarted**, ending its process (or whatever the host runs it in) and starting it again on the same session.

An agent MAY also:

- **stream** an assistant message as it writes it (the `reply` slot, §4);
- **report progress** of a running tool call (the `tool:<callId>` slots, §4);
- **take images** as input, rather than paths to them (§3.1).

The host names the agent with the `source.agent` of the log's ATXF header (for example `pi`, `codex`, `claude-code`), and advertises the agents it can run under `ext.sessions.agents` ([sessions](sessions.md)). A client steers every agent with the same commands, and draws every agent's log as ATXF.

## 2. Logs

A Session's log is the ATXF conversion of the agent's session, following the ATXF [mapping](https://atxf.leostera.dev/mappings/) for that agent:

- The header's `source.agent` names the agent and its `id` is the Session's `sessionId`.
- The host converts each record as the agent writes it. It SHOULD carry the agent's own record in `native` (with `native.raw` when re-serializing would not reproduce it), so that `fidelity.native` is `all` and a client that draws the agent's own interface can recover its records in order, byte for byte.
- When the agent gives its records ids, ATXF record ids SHOULD be those ids (`fidelity.ids: "stable"`).
- A prompt's attachments appear in its user message as content blocks that refer to the assets by URI (assets §6): image blocks for images, resource blocks for other files. The agent's own record, carried verbatim in `native`, may still hold an image inline.
- The user message an `agent.prompt` produces carries `ext.axp.commandId` (SPEC §10.2). When the agent writes that record itself, the host MUST keep the association between the prompt and the record durably, so that converting the session again produces the same records and the same hashes. §6 says how for each agent that needs it.

## 3. Commands

Every method is routed (SPEC §10.1) and a command (SPEC §10.2). All take `hostId`, `sessionId` and `commandId`.

| Method | Further params | Effect |
| --- | --- | --- |
| `agent.prompt` | `text`, `attachments`? | A user message. |
| `agent.stop` | `turn` | Stops the turn, if it is still running. |
| `agent.restart` | `mode`: `auto` or `force` | Restarts the agent of the Session. |

Questions the agent asks the person, and the person's answers, are not part of this extension; they belong to an elicitations extension that is still being designed.

### 3.1 `agent.prompt`

- `text` is up to 100,000 characters. It MAY be empty when the prompt has attachments.
- `attachments` are files from the [`assets`](assets.md) extension (assets §5), and require it to be negotiated. The host fetches and checks all of them before the agent gets the prompt, and refuses the prompt with `-32348` if any cannot be fetched. It then gives them to the agent:
  - images (`image/png`, `image/jpeg`, `image/gif`, `image/webp`) of at most 5 MiB as image input, if the agent takes images;
  - any other file, a larger image, or any image for an agent that does not take images, as a line of text naming the file, its media type, its size and the path where the host saved it, so the agent can read it with its own tools.
- When the agent is idle the prompt starts a turn. When a turn is running the host holds the prompt and starts the next turn with it when the running one ends. Held prompts are not steering: a stop does not drop them.
- A host holds at most 32 prompts per Session and refuses more with `-32220` (`busy`).

### 3.2 `agent.stop`

`turn` is the `id` of a user message record in the turn the client saw running. The host stops the running turn only if that record belongs to it, and otherwise answers `{ "receipt": "accepted", "stopped": false }`. A stop never ends a turn the client has not seen.

### 3.3 `agent.restart`

`auto` restarts the agent between turns, after the running turn ends. `force` restarts it now and ends the running turn. The Session's status is `starting` until the agent is running again.

## 4. Slots

| Slot | Value |
| --- | --- |
| `reply` | The assistant message being written, as an ATXF `message` record without `hash`. |
| `tool:<callId>` | Progress of a running tool call: `{ "status", "output"? }`, `output` being the latest partial output, at most 64 KiB. |

A host whose agent does not stream sets neither; clients see each message when its record arrives.

## 5. Errors

| Code | Name | `retry` | Meaning |
| --- | --- | --- | --- |
| -32220 | `busy` | `safe` | Too many held prompts. |
| -32221 | `agentNotRunning` | `safe` | The agent is not running for this Session; it may be restarting. |

## 6. Agent notes

What a host does for particular agents, where ATXF's mapping leaves a choice open.

### 6.1 Pi

[Pi](https://github.com/earendil-works/pi) (`source.agent: "pi"`) follows ATXF's [Pi mapping](https://atxf.leostera.dev/mappings/#pi-pipiagentsessionsjsonl). It takes images, streams replies and reports tool progress.

- Every Pi entry is carried in `native` (`fidelity.native: "all"`), and record ids are Pi entry ids.
- Pi writes the user message itself, so the host writes a Pi custom entry of type `axp.command` with `{ "commandId" }` immediately before it, and the converter moves the id onto the next user message.
