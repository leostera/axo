# RFD0033 - Axo: Session Controls for Clients

- Feature Name: `axo-session-controls-for-clients`
- Status: Draft
- Author: leostera
- Start Date: 2026-11-07
- Updated: 2026-11-07
- Document Type: Proposal
- Amends: [RFD0024](RFD0024-remote-sessions-in-pi.md)

## Summary

I propose four controls that the web app and the phone get over a Session's Pi, each through one new piece of the client protocol:

- **What Pi runs.** pi-axo publishes the Session's model and thinking level. Axod puts them in the Session's remote snapshot, so the message box can show "Opus 4.1 · High" as the new design asks.
- **Slash commands.** Typing `/` in the box lists the commands that this Session's Pi can run when a client sends them: prompt templates, skills and extension commands such as `/axo-share`. The list comes from Pi itself, through `axo.remote.session.commands`.
- **Restart.** `axo.remote.session.restart` restarts the Session's Pi, whether it is running or has died. It keeps the conversation and stops a turn that is running.
- **Follow-up or steer.** A client's prompt says how it should be delivered if Pi is busy. Every accepted prompt is written to the Session's log before the client is told it was accepted, so reloading the web app or killing the phone app can never lose it.

## Motivation

Leo asked for all four in one batch (relayed through the "outbox" Session, 2026-11-06):

5. A `/` menu in the message box, with commands from the Session itself rather than a hard-coded list.
6. A Restart button in the Session info pane.
7. Holding Send to choose Follow-up or Steer. Delivery must be durable: "nothing may be queued only on the client", and it must happen exactly once.

The new composer design (Leo's screenshots, 2026-11-06) also shows the model and effort next to Send. None of this can be built in the clients alone today:

- The remote snapshot (`RemoteSessionSnapshot` in `crates/axo-protocol/src/model.rs`) has a Session's name, status and times, but nothing about its Pi.
- `axo.remote.session.prompt` has no delivery. pi-axo holds every client prompt that arrives during a turn and sends it as the next turn (`packages/pi-axo/src/remote-commands.ts`), which is a follow-up.
- Held prompts live only in pi-axo's memory. A Pi that exits before sending them loses them, even though its client was told they were accepted. Clients cannot see them either: a reloaded web app has no record of a prompt waiting behind the reply.
- `axo.session.pi.restart.force.v2` can only revive a Pi that has died (`restart_unavailable_pi` refuses a running one). Its remote counterpart is `Planned` in `crates/axo-protocol/src/parity.rs`.

## Goals

- The message box shows the Session's model and thinking level.
- `/` lists exactly what this Session's Pi would run if sent, and narrows as you type. Arrow keys and Enter work on the web, and tapping works on the phone.
- Restart works on a running, stuck or dead Pi. It asks first, and shows "Restarting…" until Pi is ready.
- A prompt sent while Pi works can be a follow-up (the default, as today) or a steer.
- **Durability:** once a client shows a prompt as sent, it is in the Session's log. It reaches Pi exactly once, whatever happens to the client, the relay or Pi.

## Non-goals

- Changing the model from a client. Showing it comes first; a picker needs Pi's list of available models and a set-model call, and is a follow-up RFD.
- Pi's built-in commands that only make sense in its terminal (`/model`, `/tree`, `/login`). `pi.sendUserMessage` cannot run them, so they are not listed.

## Guide-level explanation

**The box.** Under the words, on the right, a dimmed "Opus 4.1 · High" names the Session's model and thinking level. It changes when someone switches the model in the Session's Pi on the Mac, because pi-axo publishes the change and the snapshot carries it.

**Slash commands.** Typing `/` at the start of the box opens a list above it: `/axo-share` (Share this conversation), `/review` (a prompt template), `/hivemind` (a skill), and so on, each with its description. Typing narrows it, and choosing one puts `/review ` in the box, ready for arguments. Sending it goes through `pi.sendUserMessage` with `expandPromptTemplates`, exactly as typing it into Pi does. The client fetches the list once per Session and fetches it again when the snapshot's `commandsVersion` changes.

**Restart.** The info pane has "Restart Pi". It asks "Restart Pi? A reply it is writing stops. The conversation is kept." While Pi restarts, the pane and the conversation header say "Restarting…". When the Session is `ready` again, the box opens.

**Follow-up or steer.** Tapping Send works as today. Holding it (long-press on the phone; press-and-hold or the chevron beside it on the web) offers **Follow-up**, delivered after the current turn, and **Steer**, delivered at the next step of the running turn. The message then shows in the conversation as "Queued" or "Steering". It stays there after a reload, because it is in the log.

## Reference-level explanation

### Pi state in the snapshot

pi-axo publishes `pi.state` on `session_start` and whenever the model, the thinking level or the commands change:

```json
{ "model": { "provider": "anthropic", "id": "claude-opus-4-1", "name": "Opus 4.1" },
  "thinkingLevel": "high",
  "commandsVersion": "sha256:…" }
```

Axod keeps the latest for each Session and adds it to `RemoteSessionSnapshot` as an optional `pi` field. Old clients ignore it, and old pi-axos simply never send it.

The commands themselves are not in the snapshot: there can be dozens of skills, and the snapshot is broadcast on every change. They come from:

- `axo.remote.session.commands {target, sessionId}`, which returns `{commands: [{name, description, source: "extension" | "prompt" | "skill"}], commandsVersion}`. Axod gets the list from pi-axo over the bridge (`pi.getCommands()`).

### Restart

`axo.remote.session.restart {target, sessionId}` replaces the `Planned` row for `SESSION_PI_RESTART_FORCE` in `parity.rs`. Axod handles it as follows:

1. If the Pi is running, axod sends the bridge's existing `shutdown` action. pi-axo aborts a running turn and exits.
2. Axod waits up to 10 s for the pane to become unavailable. If it does not, axod kills the process.
3. Axod calls `restart_unavailable_pi(…, ExplicitUserRestart)`, as the Mac's own restart does.

Status goes `starting` → `ready` through the usual snapshots, which is how clients know when the restart has finished. Held prompts survive it, because they are in the log (next section).

### Delivery, and why it is durable

`axo.remote.session.prompt` gains `delivery?: "followUp" | "steer"`, which defaults to `followUp`. The `commandId` stays the idempotency key (RFD0024).

pi-axo accepts a prompt that it cannot hand to Pi straight away like this:

1. It appends `axo.command.queued {commandId, delivery, text, attachments}` to the log. Attachments are kept as asset references, not bytes.
2. Only then does it answer `accepted`. The client shows the prompt as sent only after that answer.
3. **Follow-up:** when the turn ends, pi-axo writes the `axo.command` receipt and prompts Pi, as today.
4. **Steer:** after the next tool result, before the next model call, pi-axo writes the receipt and hands the prompt to Pi with `deliverAs: "steer"`.
   - A stop can move Pi's steering queue into its editor (RFD0024, problem 1).
   - So on `settled`, a steer whose receipt is in the log but whose user message is not is delivered again, as the next turn.
5. On `restore()`, when Pi starts or restarts, every queued entry without a receipt is held again, in log order. A Pi that exited, crashed or was restarted therefore still delivers what it had accepted.

Clients render `axo.command.queued` entries without a receipt as "Queued" or "Steering". A reloaded web app or a relaunched phone shows them from the log alone, so nothing is queued only on the client. A client that never got an answer retries with the same `commandId`. pi-axo finds that id among its queued entries and receipts and answers `taken`, so there is no duplicate.

### Tests

- **pi-axo:**
  - Accepted means the entry is written before the answer.
  - A restore re-holds queued entries without a receipt.
  - A steer interrupted by a stop is delivered once as the next turn.
  - A retried `commandId` is never delivered twice.
- **End to end** (Worker with axod, `AxoPhoneEndToEndTests` and the web's browser fixture):
  - Send, then reload or kill the client at once. The message is delivered exactly once, and shows as queued after the reload.
- **Clients:**
  - The `/` list filters and inserts.
  - Restart asks first and shows "Restarting…".
  - Holding Send offers both deliveries.

## Drawbacks

- Queued prompts become log entries. That lengthens the log a little, and shares and exports must skip `axo.command.queued` as they already skip receipts.
- Restarting a working Pi stops its turn. The confirmation says so.

## Alternatives

- **A queue in axod's database instead of the log.** It would be durable on the Mac, but clients would need a new way to see it, and a second store would have to agree with the log. The log is already the one thing every client reads.
- **Keeping queued prompts on the client until Pi is idle.** This is what Leo ruled out: a reload or a killed app loses them.
- **Commands in the snapshot.** Simpler, but every status change would rebroadcast dozens of skills to every client.

## Open questions

- Is a queued prompt kept in the log (as proposed) or in axod's database?
- Should restarting a working Pi stop its turn (as proposed), or should Restart be refused while Pi works?
- Should a client be able to change the model in this round, or only see it (as proposed)?
