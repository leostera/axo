# RFD0033 - Axo: Session Controls for Clients

- Feature Name: `axo-session-controls-for-clients`
- Status: Implemented (accepted 2026-11-07; Send interrupts, 2026-11-08; see As built)
- Author: leostera
- Start Date: 2026-11-07
- Updated: 2026-11-10
- Document Type: Proposal
- Amends: [RFD0024](RFD0024-remote-sessions-in-pi.md)

## Summary

I propose four controls that the web app and the phone get over a Session's Pi, each through one new piece of the client protocol:

- **What Pi runs.** pi-axo publishes the Session's model and thinking level. Axod puts them in the Session's snapshot, so the message box can show "Opus 4.1 · High" as the new design asks. Tapping it picks another model or thinking level, through `axo.remote.session.models` and `axo.remote.session.model.set`.
- **Slash commands.** Typing `/` in the box lists the commands that this Session's Pi can run when a client sends them: prompt templates, skills and extension commands such as `/axo-share`. The list comes from Pi itself, through `axo.remote.session.commands`.
- **Restart.** `axo.remote.session.restart` restarts the Session's Pi, whether it is running or has died. It keeps the conversation and stops a turn that is running.
- **Interrupt, steer or follow-up.** A client's prompt says how it should be delivered if Pi is busy: tapping Send interrupts (Decisions, 2026-11-08), holding it offers Steer or Follow-up. Every accepted prompt is written to the Session's log before the client is told it was accepted, so reloading the web app or killing the phone app can never lose it.

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

- The message box shows the Session's model and thinking level, and picking either changes it for this Session.
- `/` lists exactly what this Session's Pi would run if sent, and narrows as you type. Arrow keys and Enter work on the web, and tapping works on the phone.
- Restart works on a running, stuck or dead Pi. It asks first, and shows "Restarting…" until Pi is ready.
- A prompt sent while Pi works can be a follow-up (the default, as today) or a steer.
- **Durability:** once a client shows a prompt as sent, it is in the Session's log. It reaches Pi exactly once, whatever happens to the client, the relay or Pi.

## Non-goals

- Changing the model a new Session starts with. Picking a model changes this Session only, as `/model` in Pi does.
- Pi's built-in commands that only make sense in its terminal (`/model`, `/tree`, `/login`). `pi.sendUserMessage` cannot run them, so they are not listed.

## Guide-level explanation

**The box.** Under the words, on the right, a dimmed "Opus 4.1 · High" names the Session's model and thinking level. It changes when someone switches the model in the Session's Pi on the Mac, because pi-axo publishes the change and the snapshot carries it. Tapping it opens a menu: the models this Pi has credentials for, grouped by provider, and the thinking levels the chosen model supports. Choosing one changes it for this Session at once, also on the Mac.

**Slash commands.** Typing `/` at the start of the box opens a list above it: `/axo-share` (Share this conversation), `/review` (a prompt template), `/hivemind` (a skill), and so on, each with its description. Typing narrows it, and choosing one puts `/review ` in the box, ready for arguments. Sending it goes through `pi.sendUserMessage` with `expandPromptTemplates`, exactly as typing it into Pi does. The client fetches the list when it opens it (Reference-level explanation).

**Restart.** The info pane has "Restart Pi". It asks "Restart Pi? A reply it is writing stops. The conversation is kept." While Pi restarts, the pane and the conversation header say "Restarting…". When the Session is `ready` again, the box opens.

**Follow-up or steer.** *As first proposed; superseded for the tap by Decisions, 2026-11-08: tapping Send interrupts.* Tapping Send works as today. Holding it (long-press on the phone; press-and-hold or the chevron beside it on the web) offers **Follow-up**, delivered after the current turn, and **Steer**, delivered at the next step of the running turn. The message then shows in the conversation as "Queued" or "Steering". It stays there after a reload, because it is in the log.

## Reference-level explanation

### Pi state in the snapshot

pi-axo publishes `pi.state` on `session_start` and whenever the model, the thinking level or the commands change:

```json
{ "model": { "provider": "anthropic", "id": "claude-opus-4-1", "name": "Opus 4.1" },
  "thinkingLevel": "high" }
```

`model` is `null` while Pi has no model (no credentials anywhere). An early draft also carried a `commandsVersion`; it was dropped, because clients ask for the commands whenever they open the list.

Axod keeps the latest for each Session and adds it to the Session's snapshot (local and remote) as an optional `pi: {model, thinkingLevel}` field. Old clients ignore it, and old pi-axos simply never send it.

The commands and models are not in the snapshot: there can be dozens of skills and models, and the snapshot is broadcast on every change. pi-axo publishes them as bridge events (`pi.commands` and `pi.models`) on `session_start` and whenever they change, axod keeps the latest, and clients ask for them:

- `axo.remote.session.commands {target, sessionId}` returns `{commands: [{name, description, source: "extension" | "prompt" | "skill"}]}` (`pi.getCommands()`).
- `axo.remote.session.models {target, sessionId}` returns `{models: [{provider, id, name, thinkingLevels}]}`: the models Pi has credentials for (`modelRegistry.getAvailable()`), each with the thinking levels it supports.
- `axo.remote.session.model.set {target, sessionId, model?: {provider, id}, thinkingLevel?}` sets either or both through the bridge's new `setModel` action (`pi.setModel`, `pi.setThinkingLevel`). Pi answers `invalid` for a model it doesn't have and `unavailable` for one without credentials; the new state reaches every client through the snapshot.

A client asks again when it opens the `/` list or the model menu, so neither needs a version.

### Restart

`axo.remote.session.restart {target, sessionId}` replaces the `Planned` rows for `SESSION_PI_RESTART_FORCE` and `SESSION_PI_RESTART_AUTO` in `parity.rs`: a person away from the Mac has one Restart. Axod handles it as follows (as amended by [RFD0041](RFD0041-axod-session-tasks.md), which replaced the Session manager with a task per Session; `restart_for_client` in `crates/axo-server/src/session/pi.rs`):

1. If the Pi is running, the Session's task sends the bridge's `shutdown` action. pi-axo aborts a running turn and exits.
2. After a 10 s grace (`EXIT_GRACE`), the task kills that Pi if it is still the one running, and starts it again on the same transcript. There is no takeover.
3. A Pi that is dormant or unavailable is started at once. One that is still launching is left to finish.

The first draft waited for the pane to become unavailable and then called `restart_unavailable_pi(…)`; that function went with the Session manager.

Status goes `starting` → `ready` through the usual snapshots, which is how clients know when the restart has finished. Held prompts survive it, because they are in the log (next section).

### Delivery, and why it is durable

`axo.remote.session.prompt` gains `delivery?: "followUp" | "steer"`, which defaults to `followUp`. The `commandId` stays the idempotency key (RFD0024).

pi-axo accepts a prompt that it cannot hand to Pi straight away like this:

1. It appends `axo.command.queued {commandId, delivery, text, attachments}` to the log. Attachments are kept as asset references, not bytes.
2. Only then does it answer `accepted`. The client shows the prompt as sent only after that answer.
   - A Pi that is still starting cannot write anything yet. Axod does not hold a client's prompt for it in memory: the request waits, as a future, up to 4 s (`CLIENT_PROMPT_START_WAIT` in `crates/axo-server/src/sessions.rs`) for Pi to bind its bridge, so that with Pi's own answer it stays inside the cloud's 10 s command deadline. A Pi slower than that is answered as still starting. The client keeps the prompt as unsent and retries with the same `commandId`. (The first draft answered from a relay thread after up to 30 s.)
3. **Follow-up:** when the turn ends, pi-axo writes the `axo.command` receipt and prompts Pi, as today.
4. **Steer:** in its `turn_end` handler, which Pi's loop awaits right before it reads its steering queue, pi-axo writes the receipt and hands the prompt to Pi with `deliverAs: "steer"`. Pi takes it at once, so the receipt is still the entry just before the user message, as clients expect.
   - A turn that ended because it was stopped or failed takes no steer: a stop can move Pi's steering queue into its editor (RFD0024, problem 1).
   - On `settled`, a steer handed to Pi whose user message never came is delivered again, as the next turn.
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

## Decisions

Leo, 2026-11-07:

- Queued prompts are kept in the log.
- Restarting a working Pi stops its turn.
- The model is pickable from clients, not only shown.

Leo, 2026-11-08:

- **Send interrupts.** A message sent from a client is answered now: tapping Send stops the reply Pi is writing and starts the next run with the message, ahead of follow-ups already waiting (`delivery: "interrupt"`). Holding Send offers Steer (at the next step) and Follow-up (after the reply). pi-axo writes the interrupt to the log as `axo.command.queued`, aborts the run, and delivers it when the run settles, so it is as durable as the others. Clients fall back to a follow-up against a Mac that refuses `interrupt`.

## As built

What the code does as of 0.49, checked against it:

- **Snapshot and catalogs.** pi-axo publishes `pi.state`, `pi.commands` and `pi.models` on the bridge (`packages/pi-axo/src/extension.ts`, `pi-state.ts`), and sends them again to an axod that connects later. `SessionRecord.pi` and `RemoteSessionSnapshot.pi` carry `{model, thinkingLevel}` (`crates/axo-protocol/src/model.rs`). Commands and models are answered from the latest bridge events by `axo.remote.session.commands` and `axo.remote.session.models`. `axo.remote.session.model.set` goes to the bridge's `setModel` action. All three are `REMOTE_ONLY` in `crates/axo-protocol/src/parity.rs`.
- **Restart.** `axo.remote.session.restart` is the remote call for both local restart methods in `parity.rs`. No `Planned` row remains for it.
- **Delivery.** `delivery` is `followUp`, `steer` or `interrupt`. Web and phone send `interrupt` on a tap, offer Steer and Follow-up on hold, and resend as a follow-up when an older Mac refuses `interrupt` with invalid params (`packages/axo-web-app/src/chat/workbench.ts`, `apple/AxoPhone/Sources/AxoPhoneModel/HostWorkbenchModel.swift`). pi-axo's queue (`packages/pi-axo/src/remote-commands.ts`) writes `axo.command.queued` before it accepts, restores unreceipted entries in log order, hands steers over at `turn_end`, re-delivers a steer the run never took on `settled`, and puts interrupts ahead of waiting follow-ups. A client prompt with no `commandId` gets one from axod, so it is still queued in the log.
- **Clients.** The `/` list and the model picker are in the web composer (`packages/axo-web-app/src/chat/composer-controls.tsx`, `pi-controls.ts`) and the phone's (`apple/AxoPhone/Sources/AxoPhone/ChatComposer.swift`). Restart, with its confirmation and "Restarting…", is in the web's info pane (`chat-app.tsx`) and the phone's (`SessionInfoPanel.swift`). Queued entries render from the log as queued, steering or interrupting on both.
- **Tests.** `packages/pi-axo/test/remote-commands.test.ts` covers accepted-before-answer, restore, steers stopped by a stop, interrupts and retried `commandId`s. The web's `test/browser.test.mjs` checks that a queued prompt survives a reload from the log alone. `apple/AxoPhone/UITests/AxoPhoneSessionControlsTests.swift` and `Tests/AxoPhoneModelTests/SessionControlsTests.swift` cover the phone's controls. `crates/axod/tests/conformance/relay.rs` covers the remote calls. No end-to-end test kills a client mid-send against a real Worker and axod, which the Tests section above proposed.
