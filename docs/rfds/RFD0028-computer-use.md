# RFD0028 - Axo: Computer Use

- Feature Name: `axo-computer-use`
- Status: Implemented, with computer use from anywhere; computer use on a locked Mac is refused, and how to make it work is still open
- Author: leostera
- Start Date: 2026-10-31
- Updated: 2026-11-10 (reconciled with the code)
- Document Type: Proposal
- Amends: [RFD0015](RFD0015-sessions-as-axo-clients.md), [RFD0016](RFD0016-connections-and-tools.md)
- Amended By: [RFD0029](RFD0029-ask-the-person.md)

## Summary

A Session's agent can see and operate this Mac's apps through two tools in `axod mcp`:
- `computer({ tool, args, confirm? })` runs one computer-use tool, such as reading a window, clicking, typing or running a script.
- `computer_tools` gives those tools' full schemas.

Most actions happen in the background: no focus change, no pointer movement.

Before an action runs, a risk gate checks it. For an action that looks destructive or hard to undo, the gate asks the person on their own devices and runs it only if they allow it ([RFD0029](RFD0029-ask-the-person.md)); the agent cannot approve. `confirm: true` makes the gate ask whatever the check says. The gate decides with Clef, Cloudflare's open decision model, running on this Mac in a side-car next to axod. If Clef isn't available, it decides with a word list.

## Motivation

Agents in Axo can already reach this Mac's terminal, other Macs (`codemode.bash.run`) and remote MCP servers. They can't reach the apps the person actually uses, such as Mail, Messages, Slack or System Settings. Leo wants computer use in Axo, with three constraints:
- No separate "Axo Computer Use" app.
- Screenshots never leave the Mac to decide whether a click is safe.
- The agent, not Axo, is the first line of judgement: Axo steps in only when the agent didn't confirm.

Research behind this: `ai-research/personal/axo/computer-use/` (the options and the hand review) and `personal/axo/local-models-sidecar/` (runtimes and measurements).

## Guide-level explanation

An agent reads a window with `computer({ tool: "get_window_state", args: { pid, window_id } })`. It gets back the window's elements (`[N] AXButton "Send"`, addressed as element token `<snapshot>:N`) and a screenshot. It acts with `click`, `type_text`, `set_value`, `press_key`, `run_steps` (several actions with checks) or `run_script` (JavaScript over the same tools).

If an action looks destructive, it doesn't run yet. The gate asks the person, and the card on their phone, browser and Mac reads:

> Computer use wants to:
> • click AXButton "Delete account" — in Mail — Inbox
> Stopped because "click AXButton "Delete account"" may be destructive or hard to undo: Clef, on this Mac, rates it 91% likely.

The call waits, up to 5 minutes. If the person allows it, the click runs and the agent gets its result; otherwise the agent gets `Not done: the person declined.` or `Not done: nobody answered in time.`

## Reference-level explanation

### Driver

- **`crates/axo-computer`** embeds Cua Driver's macOS runtime (`platform-macos`, MIT, pinned in `MODULE.bazel`) in-process.
  - Its Accessibility and Screen Recording checks therefore use axod's grants, since axod is the responsible process.
  - The runtime starts on first use, without Cua's daemon, MCP server, cursor overlay or telemetry.
- **Allowlist:** only 24 of Cua's 62 tools are exposed (`TOOLS`). Left out: killing processes, updates, extensions, configuration, recordings, the clipboard, and attaching to the person's logged-in browser.
- **Elsewhere:** on other platforms the crate is empty, and `axod mcp` doesn't offer the two tools.
- **Bazel:** two Cua build scripts compile Swift and run outside the sandbox (`.bazelrc`). `cua-driver-core`'s guides are patched into its crate; regenerate the patch on every Cua bump.

### Risk gate (`crates/axo-computer/src/gate.rs`)

The gate runs before every `computer` call: in `axod mcp` for this Mac's agents, and in axod for other Macs' scripts (`crates/axo-computer-use`). Its `Judge` is async. Since [RFD0042](RFD0042-async-relay-and-extensions.md), only gate initialization and Cua's calls run on the blocking pool.

1. **Asked for, or read-only:** `confirm: true` asks the person without the checks below; read-only tools (`get_window_state`, `list_windows`, …) pass. `computer` refuses any argument but `tool`, `args` and `confirm`, so nothing passed can approve.
2. **Describe:** every action is described in words: its tool and target, plus its text, keys, value or script.
   - The target is the element's role and label, remembered from this process's last `get_window_state` of that window, or else `role`/`name` from the arguments.
   - `run_steps` contributes one action per step; `run_script` contributes its source.
3. **Filter:** a description is *flagged* if it contains, as a whole word, one of a short list ("delete", "send", "pay", "publish", "merge", …) or a commit key (Return), or if the typed text contains a newline. Anything not flagged passes without a check.
4. **Judge:** each flagged description goes to Clef, text only, with hand's risk question.
   - p ≥ 0.5 asks the person; below that, it runs.
   - If Clef is unavailable or fails, the person is asked.
5. **Ask:** the gate's question lists every action with its window and why it stopped, all from its own reading. `axod mcp` sends it as `axo.elicitation.request` for the agent's Session and waits; the answer comes back only on that connection (RFD0029, Tools ask; agents cannot approve).

An action reaches the app only if it passed or the person allowed it. Every call logs `event=mcp.computer_called tool=… outcome=ok|error|not_allowed [allowed_by=person]`, and the gate logs `event=computer.gate_asked reason=agent|clef|unjudged`.

### Side-car (`crates/axod-infer`, `third_party/llama.cpp`)

- **The binary:** `axod-infer` is llama.cpp's `llama-server` at a pinned commit.
  - Built by a Bazel repository rule: static, Metal with embedded shaders, no curl or OpenSSL.
  - Shipped as `Axo.app/Contents/Helpers/axod-infer` and signed as `dev.leostera.axo.infer`.
  - llama.cpp supports Clef natively and serves `POST /v1/systemone` on a Unix socket (`run/infer.sock`).
- **One instance, via a lock instead of a supervisor:**
  - Whichever process first needs the side-car takes an exclusive `flock` on `run/infer.lock`, then starts the side-car detached (`setsid`), handing it the locked file across `exec`.
  - The lock lives exactly as long as the side-car, so there is never more than one. Others wait for the socket.
  - A crashed side-car frees the lock and is started again on the next question.
- **Memory:** the side-car unloads the model after ten idle minutes (`--sleep-idle-seconds 600`).
- **Model files:** `ggml-org/Clef-Flash-GGUF` Q4_K_M plus the vision file mmproj Q8_0 (7.4 GB), pinned by revision and SHA-256.
  - The first `axod mcp` that finds them missing downloads them in the background into `~/Library/Application Support/Axo/models/clef-flash/`.
  - Each file goes to `.part`, its checksum is checked, and only then is it renamed. Interrupted downloads resume.
  - There's only one download at a time (`.download.lock`), and only on Macs with at least 16 GB of memory and 10 GB of free disk.
- **Measured** on an M4 Pro (48 GB):
  - cold start about 12 s;
  - restart after a crash about 3 s;
  - a text question 1–3 s;
  - about 7 GB of RAM while the model is loaded.

### Computer use from anywhere

An agent on any of the account's Macs, including one the person chats with from the phone, drives another Mac through `apps_run` (first built as `connections_execute`; connections are now apps):

```js
const macs = await codemode.hosts.list();
// [{ name: "studio", label: "Studio", online: true, kind: "macos", self: false,
//    computerUse: { available: true, accessibility: true, screenRecording: true } }, …]
const shot = await codemode.computer.run({ host: "studio", tool: "get_window_state", args: { pid, window_id } });
await codemode.computer.run({ host: "studio", tool: "click", args: { pid, window_id, element_token: "s3:12" } });
await codemode.bash.run({ host: "studio", command: "ls ~/Desktop" });
```

**Names.** The account's Macs are no longer services. Three namespaces take the Mac as an argument instead, so a script finds every Mac with one call and no Mac's label can collide with a connection:
- `codemode.hosts.list()`: every Mac of the account, with its `name` (the label as a JavaScript-safe name, unique among the account's Macs), `label`, `online`, `kind` (`macos`), `self` (the Mac the script was started from) and, for an online Mac, `computerUse`: whether this Mac can do it now (Accessibility and Screen Recording granted). Asked of each online Mac, at most 3 seconds; `null` when it did not answer.
- `codemode.computer.run({ host, tool, args, confirm? })`: one computer-use tool, as the local `computer` tool takes it.
- `codemode.bash.run({ host, command, cwd?, timeoutMs? })`: replaces `codemode.<mac>.bash`, which goes away. No external release depended on it.

`host` is a name from `hosts.list()`, or `"self"`. An unknown host fails listing the account's Macs; an offline one fails as offline (`hostOffline`), naming the online ones. `hosts`, `computer`, `bash` and `apps` are reserved: no connection is added under those names. Mac apps (1Password) still name a Mac by the same `name`.

**On the Mac.** The Worker sends `axo.apps.computer` (first built as `axo.connections.computer`) down the target Mac's relay socket, like `bash`: `{ accountId, callId, tool, args, confirm, sessionId, from, timeoutMs }`, where `sessionId` is the calling Session and `from` the calling Mac's label. axod (the daemon, which holds the Accessibility and Screen Recording grants) runs it as a task. Since RFD0042, Cua's call runs on the blocking pool, and the gate and the person's answer are awaited:
1. **The gate,** the same checks as the local tool: `confirm: true` asks; otherwise the word filter and Clef decide.
2. **Asking** is an elicitation made by the target Mac's axod, `askedBy: computerUse`, in the *calling* Session: its card shows in that chat on the web and the phone (clients place cards by Session id, and answer the Mac that asked), and on the target Mac in the menu bar's questions panel (RFD0029 step 3, which replaced the first build's notification). The question says where it came from: *asked from Laptop's Session*. It expires before the script's time runs out.
3. **Images** in the result (screenshots, window captures) are uploaded to the account's assets (RFD0030) with the Mac's host credential, through the same asset route the web and the phone upload to (`axo_relay::assets::upload`, beside the download of a prompt's attachments), and replaced by `{ type: "image", attachment }`, where `attachment` is the same `Attachment` a prompt's files are (`{ asset: "sha256:…", name, mimeType, size }`). A result stays small and the images show wherever assets do. The text and `structuredContent` come back as they are.

`axo.apps.computer.status` answers `{ available, accessibility, screenRecording, locked }` for `hosts.list()`.

**Back to the agent.** `axod mcp`'s `apps_run` returns the script's value as before; for image attachments anywhere in it (at most 4, 5 MiB in all) it asks axod to fetch them (`axo.assets.fetch`, only for axod's own binary, by code signature), which uses the same fetch as a prompt's attachments, into `~/.axo/assets`, and adds each to the tool result as an MCP image, so the model sees the screenshot. Images past the limit stay as references.

**Logging.** Every `computer.run` and `bash.run` is in the account's call log (RFD0016) before it is sent, as service `computer` or `bash`, tool the computer tool's name or `run`, with the target Mac. Screenshots are not logged; typed text is, as commands are.

**Not built here:** a card in the target Mac's chat view for a Session it doesn't have. Its questions panel names such a Session only as "a Session", and the question's text names the calling Mac. Also not built: binding an Allow to the window it named (RFD0029).

### Invariants

- An unconfirmed action whose description is flagged runs only if Clef answers p < 0.5.
- There is at most one side-car per Mac, and a dead one is never waited for: a free lock means it died.
- A model file is used only after its SHA-256 matched.

## Testing

- `computer_gate` unit tests:
  - harmless actions are never judged;
  - flagged actions run only if judged harmless or confirmed;
  - without a model, the word list alone refuses;
  - every `run_steps` step and every script is looked at;
  - the filter matches whole words.
- `axod-infer` unit tests: HTTP replies (plain and chunked), missing files turn checks off, one lock holder at a time, and reading memory and disk.
- `mcp` tests: computer use is offered only where it exists, and `computer_tools` lists only the allowlist.
- `//apple/AxoMac:package_test`: `axod-infer`'s minimum macOS and signing team.
- Checked by hand on 2026-11-04 through the shipped `axod mcp`:
  - cold start, then refusals of "Delete account", "Send" and "ship it\n";
  - "Remove filter" flagged but passed by Clef, and "Settings" not flagged;
  - two concurrent processes sharing one side-car;
  - recovery after `kill -9`;
  - the download with a good and a bad checksum;
  - the word-list fallback while the model is missing.

## Drawbacks

- axod grows from 10 MB to 28 MB, and the app gains a 23 MB helper. Clean builds pay for about 370 more crates, plus a llama.cpp build of about 2 minutes.
- **Coordinate clicks:** a click at bare coordinates names no element, so the gate sees only the window. It passes unless its text is flagged.
- **Word list:** the list misses risky actions that use other words, and flags harmless ones (each costs a Clef question of about 1 s).
- **Screen locked:** while the screen is locked, macOS hides every window from Accessibility. Every tool except `check_permissions` and `get_guide` refuses with "Not done: this Mac is locked…" (`axo_computer::LOCKED`), and `computer.status` reports `locked`.

## Unresolved questions

- **Cloud path:** settled in *Computer use from anywhere*.
- **More from the hand review:**
  - delivery receipts;
  - a screen lease shared across agents;
  - an injection warning on what `get_window_state` reads;
  - reading typed text back.
- **Screenshots:** when Clef's answer is uncertain or the target has no label, should the gate add the window's screenshot (about 4 s)?
- **More models in `axod-infer`:** the side-car is named for inference in general, not for Clef. Speech, such as NVIDIA's Parakeet for transcription, is next. llama.cpp can't run Parakeet, so `axod-infer` will need a second runtime: parakeet-mlx, sherpa-onnx or a Core ML conversion. The question is whether one process should hold both runtimes, or each runtime gets its own socket.
- **Computer use on a locked Mac (open, 2026-11-08).** Someone away from their Mac, which is the point of computer use from anywhere, usually has it locked. Locked, the login window owns the screen: screenshots show the lock screen or nothing, and synthesized key and mouse events go to the login window, not the apps. What to find out in a spike, in order:
  - what still works while locked: Cua's accessibility calls (`get_window_state`, `AXPress`, setting values) on apps that keep running, with no screenshot and no synthesized event;
  - whether a virtual display, or a second graphical session, can host the apps while the physical one stays locked;
  - whether the person can unlock it on purpose from their phone, with Face ID as in RFD0029, and have it lock again when the call ends; macOS offers no public remote unlock, so this may not exist;
  - keeping the Mac awake (the display-awake guard does that) is not enough, and keeping it unlocked is a security setting axod must not change for the person.
  Until then a computer call on a locked Mac says so plainly rather than act on the lock screen. That refusal is built (`refusal_while` in `crates/axo-computer/src/lib.rs`). The spike is not done.
- **Asking the person:** proposed in [RFD0029](RFD0029-ask-the-person.md). The gate asks the person on their own clients instead of refusing, and `confirm: true` only asks (built). Values such as logins and cards now go past the agent too: `request_input` is built (RFD0029, step 4).
