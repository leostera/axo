# RFD0070 - Axo: computer use as a real boundary

- Feature Name: `computer-use-boundary`
- Status: Implemented (unreleased)
- Author: leostera
- Start Date: 2026-11-17
- Document Type: Proposal
- Amends: [RFD0028](RFD0028-computer-use.md), [RFD0029](RFD0029-ask-the-person.md)

## Summary

RFD0028 says an action reaches an app only if the gate passed it or the person allowed it. RFD0029 says what the person fills in never reaches the agent. A review found both claims held only for an agent that chose to use the `computer` tool and to read its results as given. This RFD makes them hold for an agent that tries to get around them:

- Processes the agent starts stop inheriting axod's Accessibility and Screen Recording grants.
- Every action inside `run_script` goes through the gate.
- An element the gate cannot name is checked rather than passed.
- Key names are read the way Cua reads them.
- The question puts what stopped the call first.
- `launch_app` shows what it opens.
- Filled values are hidden by substring, at the source, before a script can see them.
- App tools that send, pay, delete or reveal a secret ask the person.

## Motivation

The agent is the adversary in RFD0029's model: it may follow instructions found in a web page, an email or a file. A review of the computer-use and apps code found these ways past the boundary:

1. **Inherited grants.** Pi is a child of axod, and so is every shell the agent runs, so macOS treats axod as their responsible process for privacy (TCC). From the agent's bash, `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()` both return true. A ten-line program can therefore press Mail's Send button without the gate seeing it. Remote `bash.run` has the same reach on every Mac.
2. **Unnamed elements.** Cua's `get_window_state` returns only Markdown by default and removes `elements` from `structuredContent`. The gate learns labels from `elements`, so after a normal read, `click {element_token}` is described as `click element s1:4`. That description contains no risk word, so the click runs unchecked.
3. **Scripts.** `run_script` is checked only by searching its source for risk words. Its actions run straight through Cua's registry, so `["S","e","n","d"].join("")` gets past the check.
4. **Key names.** Cua folds `re-turn`, `Re Turn`, `e_n_t_e_r` and `numpad_enter` into Return. The gate does not. Backspace, delete and cmd+backspace (Move to Trash) are not checked at all.
5. **Truncated questions.** A question lists every action and puts the reason last, then is cut at 1,000 characters. Thirty harmless steps hide a final "Send".
6. **`launch_app`.** Its `urls`, `additional_arguments` and `webkit_inspector_port` are not in the description. A Shortcuts deep link runs unchecked, and even `confirm: true` shows only "launch app".
7. **Redaction.** Filled values are hidden only when they appear as a whole word, so `me@example.com.` leaks. A script can also reverse a value before returning it.
8. **App tools.** Every app tool runs as soon as it is called. `onepassword.read` hands the agent the password that `request_input` exists to keep from it, and `gmail.send_message` and `kraken.call` (any private method, including withdrawals) run without asking.

## Guide-level explanation

The agent still drives apps through `computer`, scripts through `run_script`, and services through `codemode.apps`. What changes is what it meets:

- **A shell is just a shell.** Pi, the Session's terminal, and every command `bash.run` runs are started *disclaimed*: each is its own responsible process, so none of them holds axod's Accessibility or Screen Recording grant. `osascript` UI scripting, `CGEventPost` and `screencapture` fail or prompt for their own grant, as they would in any app the person never trusted. Only axod's `computer` tool can operate apps.
- **Every element has a name.** axod reads every window with its elements, remembers each element's role and label for the gate, then gives the agent Cua's usual Markdown read. A token the gate never saw (a stale one, or one remembered before the store evicted it) is checked as if it were risky.
- **A script's actions are checked one by one.** Inside `run_script`, every click, key and typed text goes through the gate. An action the gate passes runs. One it would ask about fails in the script with *Not done in a script: "click AXButton "Send"" needs the person. Do it as its own computer call, so they can be asked.* The script's source is no longer searched for words.
- **The question leads with why.** The card says why the gate stopped first, then each flagged action, then the rest, summarised when they don't fit:

  > Computer use wants to: Stopped because Clef, on this Mac, rates this 97% likely to be destructive or hard to undo.
  > • click AXButton "Send" — in Mail — Inbox
  > Also: 30 more actions (scroll element s9:0 — in Mail — Inbox, …)

- **`launch_app` says what it opens.** The description includes the app, each URL and each argument. A URL that isn't a file path, and any argument, makes the launch flagged. `webkit_inspector_port` is refused outright, as Cua already refuses remote debugging.
- **Filled values stay hidden.** Every string in every computer result, including reads inside a script before the script sees them, has each filled value replaced wherever it occurs as a substring. A script can't transform a value it never received.
- **App tools ask.** Each app tool declares its consent: `none`, or `ask`, with what to ask. A call to an `ask` tool, such as `gmail.send_message`, `kraken.add_order`, `drive.delete_file` or `onepassword.read`, runs only after the person allows it in the calling Session:

  > Gmail (me@example.com) wants to: send a message to bob@example.com, "Invoice".

  A decline fails the call with *Not done: the person declined.*

## Reference-level explanation

### Disclaimed children (`crates/axo-pty`)

- `axo_pty::disclaim::exec_disclaimed(&mut Command)` installs a last `pre_exec` step. It replaces the forked child with the target program by `posix_spawn(POSIX_SPAWN_SETEXEC)` with `responsibility_spawnattrs_setdisclaim(attr, 1)`, the attribute LLDB and Chromium use for the same purpose.
  - The program, argv and envp are built in the parent: the parent's environment with the command's changes applied.
  - In the child only the attribute and the prepared pointers are used.
  - If the exec fails, the spawn fails. It never falls back to an ordinary exec.
- `axo_pty::process::spawn` (Pi, terminal panes) and `axo_relay::bash` (remote `bash.run`) use it.
- Invariant: a process axod starts for the agent or the person's shell is its own responsible process (`responsibility_get_pid_responsible_for_pid(child) == child`), so a TCC check from it or its descendants never uses axod's grants.
- Unsupported: `Command::env_clear` on these commands. Nothing in axod uses it, and the parent-built environment would not honour it.

### The gate (`crates/axo-computer`)

- **Reads:** `axo_computer::call` asks Cua for `tree_format: "both"` when the caller named no format, passes the result to `Gate::remember`, then removes `elements` so the caller gets Cua's default shape. A caller that asked for a format gets exactly that.
- **Unknown tokens:** an `element_token` the gate cannot name is described as `element <token> (not read by Axo)` and is flagged.
- **Label store:** entries are evicted oldest first past 20,000, so a newer read never wipes older labels in bulk.
- **Verdicts:** `Allow`, `Ask(question)`, and new `Refuse(reason)` for calls no answer should run (`launch_app` with `webkit_inspector_port`).
- **Keys:** `key`, `keys` and `modifiers` are canonicalised as Cua's `canonical_key_name` does (lowercase; drop space, `_` and `-`; `kpenter` and `numpadenter` become `enter`) before matching. Return and enter are commit keys. Backspace, delete, forwarddelete and del are risk words.
- **Questions:** the text is the reason, then each flagged action, then the unflagged ones while they fit, then "Also: N more actions". Only the last line is ever cut, so the reason and the first flagged action always show.
- **`launch_app`:** the description includes `bundle_id` or `name`, `urls` and `additional_arguments`. A URL is flagged unless it is an absolute or `~` path or a `file:` URL. Any argument is flagged.

### Scripts through the gate

- axod builds two Cua registries.
  - The *driver* registry is Cua's own, and every direct call goes to it as before.
  - The *script* registry holds a `GatedTool` for each driver tool, plus the script tool. Direct `run_script` calls go there, so every tool a script calls passes through a `GatedTool`.
- A `GatedTool` runs `Gate::check` on its call:
  - **Allow:** it invokes the driver registry.
  - **Ask or Refuse:** it returns an error, which the script sees as a thrown `CuaError`.
  - Reads pass the gate as read-only. Their results are remembered and redacted before the script sees them.
- A top-level `run_script` is no longer checked by its source. `confirm: true` still asks before it runs. An Allow on a script approves running it, not each flagged action inside it.
- Invariant: an action inside a script that the gate flags never runs.

### Filled values (`crates/axo-computer::filled`)

- The values the person filled in are kept in axod's memory (zeroised on eviction, at most 256). Hashes are no longer exported.
  - `axo_computer::call` and every `GatedTool` read hide them in their results.
  - `axod mcp` runs inside axod and gets them hidden through the same call.
  - `axo.computer.redactions` is removed.
- A value is replaced wherever it occurs as a substring of a string, longest first, for values of at least 4 characters. Image data is left alone, as before. Secure fields are hidden by macOS; plain fields in screenshots remain visible, as RFD0029 already says.

### App tools that ask (`packages/axo-apps`, `packages/axo-api-worker`)

- `AppTool` gains `consent?: (input) => string | null`. It returns what to ask about the call, or null when the call needs no one.
  - Tools that send, post, pay, trade, delete, share, revoke or reveal a secret declare it. The general `request` tool asks for every method but GET, and Mac apps' raw `op` asks always.
  - Read-only tools declare nothing.
- The account runner asks before running such a tool. It sends `axo.apps.consent` down the calling Mac's relay socket, with `{ accountId, callId, sessionId, message, timeoutMs }`. The calling Mac's axod asks the person in the calling Session, as the gate does, with `askedBy: computerUse`, which clients show as Axo asking.
  - The message names the app, the account and the call's own description, never the agent's words.
  - Only `accept` runs the tool.
  - A call that can't ask (an older Axo, the Mac offline, no time left) fails. It never runs unasked.
- Every app call already goes through the call log. The consent outcome is logged with it (`consent=accepted|declined|unavailable`).

## Invariants

- No process axod starts for an agent, a terminal pane or `bash.run` holds axod's TCC grants.
- An unconfirmed action whose description is flagged runs only if Clef answers p < 0.5. Inside a script, it never runs.
- An element token the gate can't name is flagged.
- A question to the person always contains why the gate stopped and the first flagged action.
- A filled value of 4 or more characters appears in no computer result's text, inside or outside a script.
- An app tool that declares consent runs only after the person's accept for that call.

## Testing

- `axo-pty`: a spawned child's responsible pid is its own pid, and the same for `bash.run`'s shell.
- `axo-computer`:
  - a default Markdown read still names the element;
  - an unknown token asks;
  - eviction keeps recent labels;
  - every Cua key spelling of Return asks, and so does backspace;
  - the question leads with the reason and the flagged action;
  - `launch_app` URLs and arguments ask, and an inspector port is refused;
  - substring redaction works;
  - a script's flagged action is refused while an unflagged one runs, through a script registry over fake tools.
- `specs/elicitations/tools-ask.ts`: a script's action is gated, and a flagged one never runs.
- Worker: an `ask` tool runs only on accept, and a decline or an unreachable Mac fails it.

## Drawbacks

- Reads ask Cua for both formats: about twice the work in Cua, for the same text to the agent. The Markdown-only "element_token for row [N]" hint line is lost from the header. The tool description still explains tokens.
- Scripts can no longer include a flagged action. The agent splits the risky step out into its own call. That is the point, but it means more round trips.
- A terminal the person opens in Axo no longer inherits axod's grants. Anything they run there that needs Accessibility asks for it as a new app would.
- App consent asks on the calling Mac. A Session whose Mac is offline cannot use ask tools.

## Alternatives

- **Always ask before `run_script`.** Simpler, but every script, even a read-only loop, would wait on the person. Rejected.
- **Parse Cua's Markdown for labels.** Brittle, and diff reads show only changed rows. Rejected in favour of asking Cua for elements.
- **Keep hashes and add more candidate splits.** A transform still leaks. Hiding at the source closes it.
- **Document the reach (RFD0029, Drawbacks) and do nothing.** The gate would stay advisory against exactly the agent it was built for.
