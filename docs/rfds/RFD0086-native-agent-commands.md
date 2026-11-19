# RFD0086 - Axo: native agent commands in client composers

- Feature Name: `native-agent-commands`
- Status: Implemented (Pi SDK controls; other adapters unchanged)
- Author: leostera
- Start Date: 2026-11-19
- Document Type: Snapshot
- Amends: [RFD0033](RFD0033-session-controls-for-clients.md)

## Summary

A slash menu describes the selected Session's actual agent, not a client-maintained universal list. Remove the web's eight-result cutoff, keep every bounded server result scrollable, and show the command on the left with its description on the right. Native actions need real adapter execution; ordinary prompts must not impersonate commands.

## Guide-level explanation

For Pi, `/reload`, `/compact`, `/name`, `/model` and `/thinking` join its discovered extensions, prompts and skills. Picking a row only inserts the command; Send executes it. The existing model picker remains available. Reload refreshes Pi's resources and replaces its bridge without prompting the model or starting another conversation.

## Reference-level explanation

Pi's SDK command catalog omits built-in TUI commands, and `sendUserMessage` does not dispatch those built-ins. `packages/pi-axo/src/native-commands.ts` supplies only five reviewed SDK-backed equivalents through one internal extension command. Public names are translated only at Pi dispatch, after the existing command-ID receipt/queue machinery. The internal transport alias is omitted from the published catalog. Existing discovered commands own their names, including collisions with these controls. Attachments on these native invocations are refused before acceptance rather than leaking a purported control command to the model. Native controls always use the durable command path, even for a legacy request without an ID; a requested steer becomes a follow-up because these SDK actions require idle command context.

The catalog retains the existing `extension | prompt | skill` wire shape: SDK-backed controls are dispatched by the extension. The server's 500-command bound remains; the client no longer discards all but eight. Mouse hover does not hijack keyboard navigation when rows scroll, selected keyboard rows scroll into view, and wheel/touch panning remains local to the bounded menu. Native text uses semantic Dynamic Type styles with at least 44-point touch targets.

Only the Pi extension installs this adapter. Claude Code, Codex and OpenCode do not receive a fabricated Pi catalog. Their terminal-only or currently unexposed native actions remain outside this implementation until the owning adapter can both discover and execute them correctly. Session replacement, authentication, settings and terminal-only navigation are not silently approximated through model prompts.

## Validation

A real Pi SDK session receives `/reload` over the authenticated Axo bridge, actually reloads its resources, reconnects its replacement bridge, and ignores a repeated command ID. The test proves no model call or user message was created; native rename also reaches the SDK. Unit tests cover catalog collisions and argument-preserving routing. Browser tests cover 60 commands, both scroll directions, keyboard wrap/Home/End, filtering, focus and no-send selection at desktop, phone and short landscape sizes. Phone/tablet UI tests scroll 40 commands in both directions and inspect compact rendered fixtures.

## Drawbacks and alternatives

Each agent needs its own capabilities rather than one guessed list. Reusing only Pi's SDK catalog omits native reload and compaction. Hard-coding all TUI names in clients would advertise actions that are treated as plain prompts or require an inaccessible terminal dialog. Injecting keystrokes into a terminal could overwrite a person's unsent editor or answer an unrelated prompt; reviewed SDK actions avoid that ownership problem.
