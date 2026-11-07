# RFD0024 - Axo: Remote Sessions in Pi

- Feature Name: `axo-remote-sessions-in-pi`
- Status: Draft
- Author: leostera
- Start Date: 2026-11-01
- Updated: 2026-11-07
- Document Type: Proposal
- Amends: [RFD0018](RFD0018-session-sync-and-client-delivery.md), [RFD0022](RFD0022-sessions-across-macs.md)
- Amended By: [RFD0026](RFD0026-native-remote-panes.md)

## Summary

I propose that a Session on another Mac opens in an ordinary terminal pane, with Pi's own screen, and that the Mac running the Session stays the only one that writes its log.

- **One writer.** Only the Pi on the Mac that runs a Session writes to its log. Every other Mac, like the phone and the web app, sends commands to it and sees their effect only when the log comes back.
- **Pi as a client.** A pane for a Session on another Mac runs `pi --no-session` with pi-axo in remote mode. pi-axo draws the local copy of the log (RFD0022's mirror), and sends what you type to the Mac that runs the Session, through this Mac's axod and the peers socket. No model and no tool runs on this Mac, and nothing is written to the copy.
- **Commands with receipts.** Every prompt has a `commandId`, which is now carried into the log, so that a prompt can be retried safely and recognised for sure when it lands. A stop names the turn it stops.
- **A Mac menu in the sidebar.** Workspaces mode goes away. Its button becomes a menu that chooses which Macs' Sessions the sidebar lists.

A Feynman spec, `specs/sessions/remote-sessions.ts`, models the design. It found that each of its seven rules is needed, and six of them fix commands from the phone and the web app too.

## Motivation

RFD0022 gives every paired Mac a copy of every other Mac's Sessions, but the Mac app still shows only its own. RFD0022 planned a native chat view for the others, like the phone's. Leo would rather see Pi itself, the way every local Session looks.

Pi cannot simply be run on the copy. It would treat the copy as its own Session: it could answer with a model on the wrong Mac and write to a file that only the mirror may write. And a Session must not have two writers. Its log is a hash chain uploaded by one host (RFD0018), and two Pis appending to it would fork it.

What makes a client Pi possible is that sending already works. A prompt from the phone goes from the ClientDO to the HostDO, then to axod and to pi-axo, which hands it to the running Pi. Another Mac can send the same `axo.client.command` over its peers socket, which signs in as an ordinary client. What is new is the client side: a Pi that shows a log it did not write, and turns typing into commands.

Reading Pi's source and modelling the path turned up problems in the commands that the phone and the web app use today:

1. **A stop can drop a prompt.** A prompt that arrives during a turn is passed to Pi as steering. In Pi's terminal UI, any stop, whether Escape or an extension's `abort()`, calls `restoreQueuedMessagesToEditor`. That moves the steering queue into the editor of the Studio's own pane. The prompt never reaches the log, and the phone shows it as pending forever.
2. **Pending prompts are matched by text.** A client retires a pending prompt when a user record with the same text arrives (RFD0018). Two "yes"es, one from the phone and one typed on the Mac, are confused: the phone can show its prompt as sent when it never arrived.
3. **A prompt cannot be retried.** Axod ignores the `commandId`, so sending a prompt again after "may have run" can run it twice. And the ClientDO answers a failed call with `-32603 "Unavailable; try again"`, which invites exactly that.
4. **A stop is the Escape key.** It stops whatever turn is running when it arrives, which may be a turn started after the one you meant.

## Goals

- Every Session of the account opens in the Mac app, in a terminal pane with Pi's own screen, live.
- From that pane you can prompt, stop and answer questions, with the same guarantees as the phone. A prompt runs at most once, a sent prompt shows as sent only once it is in the log, and a stop ends only the turn you saw.
- A Mac's own Sessions never depend on the cloud. Being able to see other Macs' Sessions adds nothing to the path of your own.
- The sidebar lists the Sessions of the Macs you choose.

## Non-goals

- **Terminals of other Macs.** The pane shows Pi's conversation, not the other Mac's shells (RFD0022).
- **Working without the cloud.** Reaching another Mac goes through the cloud. A direct link between Macs on one network is future work.
- **Continuing a Session here.** That is RFD0022's step 4. It uses the same pane, which then becomes a local Session.

## Guide-level explanation

Leo is on the MacBook. Next to "Recent" at the top of the sidebar, the button that switched to Workspaces is now a Mac menu, with **This Mac**, **Mac Studio** and **All Macs**. He ticks Mac Studio, and the Studio's chats join the list with "Mac Studio" in small text under their titles.

He opens one. A pane opens with Pi's screen and the whole conversation, drawn from the MacBook's copy. Its status line says "On Mac Studio". While the Studio's agent works, its reply appears as it is written, as in a local chat.

He types "yes" and presses Enter. The message shows at once as pending, "Sending to Mac Studio…", then as an ordinary message once the Studio has written it. If the Studio is busy, it says "Queued on Mac Studio" and runs when the turn ends. He presses Escape, and the turn he is looking at stops. If another turn has started meanwhile, it carries on.

When the Studio is asleep, the pane still shows the conversation, and a message he sends comes back into the editor with "Mac Studio is offline". Nothing is kept waiting in the cloud. If the network drops after he pressed Enter, the pane says "May not have reached Mac Studio; trying again". It tries again until it knows, and the prompt never runs twice.

## Reference-level explanation

### One writer

A Session's log is written only by the Pi of the Mac that runs it, called its **owner** below. Everyone else holds a copy and sends commands: the phone, the web app, and the other Macs' panes. A command's effect is only ever known from the log. The reply to a command says whether it was taken, never what it did.

### The remote pane

`axo.peer.session.open { hostId, sessionId }` asks this Mac's axod for a pane on another Mac's Session. Axod owns the pane's PTY like any other. It starts `pi --no-session` with pi-axo in remote mode, given `AXO_REMOTE_HOST_ID`, `AXO_REMOTE_HOST_LABEL`, `AXO_REMOTE_SESSION_ID` and `AXO_SOCKET` in the environment. `axo.peer.session.close` stops it.

- **Not a Session of this Mac.** It is not a row in `axo.db` and is never uploaded or mirrored. Its shell id comes from a range the database never reaches (2^48 and up), and it is kept apart from this Mac's panes, so nothing that lists, reaps or uploads this Mac's Sessions sees it. The working directory is the Session's `workspaceState.path` (RFD0022) when this Mac has that folder, or else Home.
- **The list.** Axod lists other Macs' Sessions from `peers.json` (`axo.peer.sessions.list`), each a Session record with its `hostId`, and tells the Mac app when the list changes or a pane opens or closes (a `peer.sessions.changed` event).

### pi-axo in remote mode

- **Nothing runs here.**
  - The `input` handler returns `{ action: "handled" }`, so Pi starts no turn.
  - No tools are active.
  - `before_agent_start` and `tool_call` refuse anything that slips through.
  - With `--no-session`, Pi writes no file.
- **It draws the copy.** It long-polls `axo.peer.session.watch { hostId, sessionId, epoch, cursor, version }`. Axod answers once something has changed since `version` (records, progress, the listing, the socket), with the records of the copy under `~/.axo/sessions/<host>/` after the pane's cursor, or with `reset` and the newest records when the pane's epoch or cursor is not in the copy. Only records the copy's state file counts are read, so a line being appended is never half drawn. Each record becomes a custom entry drawn with Pi's own `UserMessageComponent` and `AssistantMessageComponent`, and look-alike boxes for tool calls and results. Progress (the reply being written) comes in the same answer, from the peers socket's `axo.client.session.progress`, and is drawn in a widget.
- **A cut restarts the pane.** When the copy's epoch changes, the Session was cut back (RFD0018). pi-axo cannot remove what it has drawn, so it exits with code 75 and the pane's shell loop starts Pi again, which draws the copy afresh. The editor's text and the pending prompts are carried over in a file. Adding the lines after the ones on screen would keep records the owner deleted (rule `restartOnCut`).
- **It sends what is typed.** `axo.peer.command { hostId, method, params }` goes to this Mac's axod: prompts, stops (Escape while the other Mac works) and answers (`/yes`, `/no`). Axod sends nothing else to another Mac.
  - Pending prompts show in a widget until their receipt appears in the copy.
  - With no peers socket, axod answers `offline` and sends nothing.

### Commands

This amends RFD0018's Commands for every client.

**Through axod.** Axod sends the pane's command as `axo.client.command` on its peers socket. The target `{ hostId, hostGeneration }` comes from the hosts it follows. Replies are matched to the socket they came on, and a socket that closes answers its outstanding commands with "unknown".

**Receipts.** When pi-axo on the owner hands a remote prompt to Pi, it first writes `appendEntry("axo.command", { commandId })`, and then the user message. Clients retire a pending prompt when they see its receipt, and never by matching text (rule `commandReceipts`). This applies to the phone and the web app too.

- **Clients that send no `commandId`.** For a remote prompt without one, axod makes one up, so pi-axo still holds the prompt while Pi works. The client cannot retry such a prompt safely or match its receipt, but it is no longer lost to a stop.
- **No older pi-axo.** All of this ships at once to every Mac, so axod expects a pi-axo that takes `commandId` and `stop`. A Pi still running an older pi-axo after the update refuses both until it restarts.

**At most once.** pi-axo on the owner remembers the `commandId`s it has taken: those whose receipts are in the log when it starts, and every one since. A `commandId` it has seen gets `accepted` back, and Pi is not prompted again (rule `dedupeCommands`).

**Retries.** A client sends a prompt again, with the same `commandId`, while its outcome is unknown: after `-32004`, a timeout, a closed socket, or the ClientDO's `-32603` (rule `retryUnknown`). The ClientDO should answer a command whose call failed with `-32004`, not `-32603 "Unavailable; try again"`.

- An `offline` answer to a **first** try means nothing ran, so the text goes back to the editor.
- An `offline` answer to a **retry** proves nothing, because the first try may still land. The prompt stays pending until the owner is back (rule `unknownStaysUnknown`).

**pi-axo queues, Pi does not.** A remote prompt that arrives during a turn waits in pi-axo, which prompts Pi with it when the turn ends, in arrival order (rule `ownQueue`).

- **Why:** Pi's terminal UI moves its steering queue into the owner's editor on any stop (`restoreQueuedMessagesToEditor`). A steered remote prompt could therefore vanish from the log, and nobody would see it.
- **The cost:** remote prompts become follow-ups, never steering. A stop ends the turn, and a queued remote prompt still runs afterwards. The client shows it as "Queued on Mac Studio".

**A stop names its turn.** `axo.remote.session.stop { sessionId, turnId }` carries the entry id of the user record that started the turn the client showed running. pi-axo stops the turn only if that turn is the one running, and otherwise answers `ignored` (rule `stopNamesTurn`). It replaces sending Escape through `axo.remote.session.key` for stops. Answers to a question likewise name the question's tool call (`axo.remote.session.answer { sessionId, toolCallId, answer }`), which the spec does not model.

**A stop names what the client saw of the run** (amended 2026-11-07, after "the x on Thinking doesn't always stop it"). Naming the run by its user record alone failed in two common cases. In a long run, the newest page a client reads holds only tool records, so the client has no user record to name and its x did nothing. And right after sending, the client shows the run working before any of its records have arrived. A stop therefore carries everything the client saw: `turnId?` (a user record of the run), `seen?` (the newest entry it holds, which is always of the running run once its records arrive), and `commandIds?` (the client's own prompts, whose receipts are the run's first entries). It must carry at least one. pi-axo stops the running run if any of them belongs to it, and a run the client saw none of still goes on. A stop that finds Pi idle also re-publishes `activity.snapshot {working: false}`, because the client that sent it was showing a stale "working". A stop that stopped nothing ends the client's "Stopping…" at once, so the next tap tries again with what has arrived by then. Clients fall back to `turnId` alone against a Mac that refuses the new fields.

### The sidebar

- **No more Workspaces mode.** The sidebar always shows the recent list, latest activity first.
- **The Mac menu.** Where the mode button was, a menu lists This Mac, each other Mac by name (offline ones dimmed), and All Macs. The choice is saved under an `AxoPreferenceKey`.
- **Rows from other Macs** carry their Mac's name, and open a remote pane.
- **Commands for local Sessions** (rename, archive, Restart Pi) are not offered on other Macs' rows.

### Failure semantics

| What happens | What the pane shows | Effect |
| --- | --- | --- |
| The owner is offline, on a first try | The text back in the editor, "Mac Studio is offline" | Nothing ran, nothing is queued |
| The reply is lost, the call times out, a socket closes | "May not have reached Mac Studio; trying again" | Retried with the same `commandId`; it runs at most once |
| The owner is busy | "Queued on Mac Studio" | Runs when the turn ends |
| A stop arrives after its turn ended | Nothing changes | `ignored`; the current turn carries on |
| The Session is cut back | The pane restarts and draws the copy | The copy and the pane drop the cut records |
| The cloud is unreachable | The conversation, read-only, from the copy | This Mac's own Sessions are unaffected |

## Security and privacy

Nothing new leaves a Mac. A remote pane reads the copy that RFD0022 already keeps, and sends commands with the host credential, which may already reach every Session of the account. The pane runs no tools, so a Session from another Mac cannot run anything on this one.

## Rollout

All five steps ship together, to every Mac at once.

1. **Commands on the owner:** receipts, the `commandId` check, pi-axo's queue, and stops and answers that name their target. Plus the ClientDO's `-32004` for failed calls. This fixes the phone and the web app first.
2. **Clients match receipts:** the web app and the phone retire pending prompts by `commandId`, and retry unknown outcomes.
3. **axod:** `axo.peer.sessions.list`, `axo.peer.session.open` and `.close`, `axo.peer.session.watch`, `axo.peer.command`, and the `peer.sessions.changed` event.
4. **pi-axo remote mode.**
5. **The Mac app's sidebar.**

## Testing

- **Feynman:** `specs/sessions/remote-sessions.ts`.
  - It models seven actors: the MacBook's remote pane and its axod, the ClientDO, the HostDO, the cloud's copy, and the Studio's axod and Pi.
  - Faults: a lost call to the HostDO, a lost command to the Studio, and a lost reply from it. Without spending a fault, the Studio can also sleep and the peers socket can close.
  - It has seven scenarios, including a prompt while the Studio sleeps, a lost reply, and a prompt during a turn followed by a stop.
  - Its safety properties held on every path of up to 13 events, explored from the start and from the end of every scenario (8M states). Every scenario passes.
  - Each rule is needed. Without it, the property it protects breaks:

    | Rule | Property that breaks without it | Events | Needs |
    | --- | --- | --- | --- |
    | `commandReceipts` | a prompt shows as sent that never ran | 6 | nothing |
    | `dedupeCommands` | a prompt runs twice | 10 | one lost reply |
    | `retryUnknown` | a prompt stays pending forever | 7 | one lost message |
    | `unknownStaysUnknown` | a prompt given back to the editor runs anyway | 5 | one lost reply |
    | `ownQueue` | a remote prompt ends up in the Studio's editor | 12 | nothing |
    | `stopNamesTurn` | a stop ends a turn started after the one shown | 8 | nothing |
    | `restartOnCut` | the pane keeps records the Studio deleted | 5 | nothing |

    "Nothing" means it happens in normal use, with no lost message: a prompt typed on both Macs, a stop during a turn, or a rewritten file.

  - The spec also showed that the pane must ignore a copy older than the one it shows.
  - Folded away: the line-by-line upload and delivery, which `session-sync.ts` and `client-delivery.ts` check.
- **pi-axo:**
  - Remote mode starts no turn and runs no tool, whatever is typed.
  - On the owner, receipts come before user messages, a repeated `commandId` prompts once, and queued prompts survive a stop.
  - Stops and answers for a turn or question other than the current one are ignored.
- **axod end-to-end, with two axods and the Worker:**
  - A prompt from a peer lands once and appears in its copy.
  - With the reply dropped, the retry does not run it again.
  - A prompt to an asleep peer comes back as offline.
- **Mac app:** the sidebar's Mac menu, and opening a remote pane, against an isolated daemon.

## Drawbacks

- **Look-alike rendering.** Until Pi can show messages it did not write, pi-axo draws records with its own renderers, which can drift from Pi's look.
- **No remote steering.** Remote prompts wait for the turn to end. A phone prompt can no longer steer a running turn.
- **A pane restarts on a cut.** This is rare, since it needs a rewritten session file, but it is visible.

## Rationale and alternatives

- **A native chat view in the Mac app** (RFD0022 as written). It is the phone's view, so the Mac would have two ways to show a chat. Leo prefers Pi's screen everywhere.
- **Pi on the copy file.** It shows the log natively, but Pi would treat it as its own Session: it could run a turn on the wrong Mac and write to the copy.
- **Writing on any Mac, merged later.** This means several writers to a hash-chained log, and conflicts with no sensible resolution for a conversation. The owner as the single writer is what keeps the log one thing.
- **Keeping steering, with receipts written when the steer is read.** A steered prompt that a stop moves into the editor would then never get a receipt. That needs Pi to tell extensions when it drops queued messages; see Unresolved questions.

## Unresolved questions

- **Rendering.** Should Pi gain an API that lets an extension show user, assistant and tool messages it did not create? That would replace the look-alike renderers.
- **Steering.** If Pi told extensions when a steering message is read or dropped, remote prompts could steer again.
- **Editor text across a restart.** How is the editor's text carried over when the pane restarts, through the environment or a file?

## Future possibilities

- **Continue here** (RFD0022 step 4) turns the remote pane into a local Session, on the same screen.
- **A direct link between Macs on one network** could carry commands and copies with no cloud at all.
