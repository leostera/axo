# RFD0026 - Axo: Native Remote Panes

- Feature Name: `axo-native-remote-panes`
- Status: Implemented (`packages/pi-axo/src/remote-view.ts`, `remote-mirror.ts`; `spawn_remote_view` in `crates/axo-agent/src/pi/launch.rs`)
- Author: leostera
- Start Date: 2026-11-02
- Updated: 2026-11-10 (reconciled with the code)
- Document Type: Proposal
- Amends: [RFD0024](RFD0024-remote-sessions-in-pi.md)

## Summary

A pane on another Mac's Session (RFD0024) is drawn by Pi itself instead of by pi-axo's look-alike renderers.

- **History** is a Pi session file built from this Mac's copy, opened with Pi's `switchSession`.
- **Live turns** are played in the pane's Pi. A provider answers each model call with the other Mac's assistant messages as they are written, and proxy tools wait for its tool results.
- **Each turn ends with a redraw** from the copy, so the screen always settles on exactly what the other Mac wrote.

Nothing runs on this Mac, and the other Mac remains the only writer.

## Motivation

RFD0024 drew each record as a custom entry with Pi's message components, plus boxes of its own for tool calls and results. The result drifted from Pi's look:

- tool calls and their results were split in two;
- edit diffs, bash timings and Pi's tool styling were missing;
- the reply being written was a widget under the editor, not Pi's streaming message;
- a cut restarted Pi (exit code 75), which flashed the pane.

RFD0024 listed a Pi API for showing messages Pi did not write as an open question. We tested what public Pi APIs already allow, in real Pi panes against a fake axod serving a real transcript. They are enough.

## Guide-level explanation

The pane looks like the other Mac's own Pi. Opening it shows the whole history as Pi draws it. When the other Mac's agent works, its reply streams in place: thinking, text, and tool calls whose boxes fill in when that Mac's results arrive. The footer names the Mac as the model ("Mac Studio • medium"), with the Session's real token counts and cost.

What is typed still goes to the other Mac (RFD0024). Escape asks it to stop. The turn on screen ends when that Mac's record says it stopped.

## Reference-level explanation

### Views

A view is the first `end` records of the copy as a Pi session file, under `$TMPDIR/axo-remote/<sessionId>/`. It differs from the copy in two ways:

- **The header:** a fresh one with this Mac's folder for the pane. Pi otherwise asks about a working directory that does not exist here.
- **Model changes:** they point at `axo-remote/<Mac name>`. Every turn in the pane is then answered by the other Mac, never by a real model.

Every other entry is the other Mac's own line.

pi-axo opens a view by running its `/axo-redraw` command (through `sendUserMessage` with `expandPromptTemplates`). The command calls `switchSession`. A redraw takes about 70 ms, even on a 12 MB, 1,260-record Session, and keeps the editor's text. The previous view file is deleted, and all of them are deleted when the pane quits.

`switchSession` builds a new extension runtime, so pi-axo keeps the pane's state (the copy, pending prompts, the turn being played) in one controller per process. Each runtime attaches to it.

Pi now starts with `--no-session`, then pi-axo opens the first view once it has read the whole copy. It pages through `axo.peer.session.watch` with an unbounded window. A cut opens a new view in place, and the restart loop and exit code 75 are gone.

### Playing a turn

A turn is open from a user message until an assistant message whose stop reason is not `toolUse`. When the copy has an open turn and the other Mac is in it, pi-axo plays it:

1. **Draw up to the prompt.** It opens a view that ends just before the turn's user message, if the screen does not end there already.
2. **Start the turn.** It sends that message with `sendUserMessage`. Pi starts a turn and calls the model.
3. **Answer the model calls.** The `axo-remote` provider answers each call with the turn's next assistant record. Until the record lands, it streams the message's progress (`axo.client.session.progress`'s `message` slot) as Pi's text, thinking and tool-call events. It ends with the record itself, usage included. A record stopped or failed there ends the call in `error`.
4. **Run the proxies.** Pi runs the tool calls through proxies registered under the same names. Pi's own definitions (bash, read, edit, write, grep, find, ls) keep its renderers, and any other name gets Pi's generic renderer. A proxy waits for the other Mac's tool result and shows its progress (the call's `partialResult`) meanwhile. Pi draws the result as if it had run here.
5. **Redraw.** When the turn ends here, pi-axo opens a view of the whole copy.

A turn the other Mac is in is either one its status says is running, or one whose prompt arrived while the pane watched (the status can lag the records). A turn left open by a Pi that crashed is drawn, not played.

The turn played here is given up if any of these happen:
- The other Mac's turn takes a path this one cannot follow: a user message mid-turn (a steer, another client's prompt) ends the model call.
- A cut arrives.
- The other Mac has been idle for 3 seconds since the last change to the copy.

A redraw follows. If the other Mac is still working, the next turn plays from its prompt.

### Invariants

- **Nothing runs here.** Only proxies are active tools. A `tool_call` handler blocks any call outside a played turn, or to a name that is not a proxy. `before_agent_start` aborts any turn that pi-axo did not start. Prompts typed in the pane are handled by the `input` handler and sent on, so they never start a turn here.
- **The screen settles on the copy.** What Pi draws during a turn comes from the other Mac's progress and records. Every turn ends with a redraw from the copy, so any difference between Pi's turn and the other Mac's lasts one turn at most.
- **No model is called.** The pane's only model is `axo-remote`. Its context window is large enough that Pi never compacts here.

### Flags

Axod starts the pane's Pi with `--no-session --no-extensions --no-mcp --no-skills --no-prompt-templates`, plus pi-axo. `--no-tools` is dropped, because it hides extension tools too, including the proxies. The proxies take over Pi's tools by name instead. `PI_OFFLINE` and `PI_SKIP_VERSION_CHECK` stay.

## Testing

- **pi-axo** (`packages/pi-axo/test/remote-view.test.ts`, `remote-mirror.test.ts`): the model keeps the copy record by record, and a cut replaces it. A view rewrites only the header and model changes. A turn's open span follows its stop reasons. `MirrorTurn` returns a turn's assistant messages in order, follows progress, and stops on a mid-turn user message, an abort, or giving up. `AssistantStream` emits balanced events and ends with the record.
- **Real panes**, checked when this landed. No test in the tree runs a remote pane in a real Pi. pi-axo ran in a real Pi, against a fake axod serving a real transcript:
  - opening the pane draws the history natively;
  - a turn streams and fills in its bash result;
  - joining mid-turn plays the rest;
  - a steer redraws and plays on;
  - Escape sends a stop and keeps the turn until the record;
  - typing sends a prompt and starts nothing;
  - a cut redraws in place with the draft kept.

## Drawbacks

- **Redraw notes.** Pi prints "Resumed session" after each redraw.
- **Small differences settle at the end of a turn.** During the turn, Pi's own timing ("Took 2.5s") shows the wait here, not the run there. Entries only the final redraw shows (custom entries, compaction) appear when the turn ends.
- **It relies on Pi behavior.** It depends on `switchSession` keeping the editor's text, and on commands being runnable through `sendUserMessage`.

## Rationale and alternatives

- **Restart Pi on each record.** This is native too, but too slow and too visible.
- **A Pi API for showing messages Pi did not write.** That would still be cleaner. Until Pi has one, public APIs suffice.
- **Only redraw, never play.** History looks native, but the reply being written could not stream.

## Unresolved questions

- Should pi-axo hide the "Resumed session" line, if Pi offers a way?
