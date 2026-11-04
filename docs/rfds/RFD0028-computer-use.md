# RFD0028 - Axo: Computer Use

- Feature Name: `axo-computer-use`
- Status: Draft
- Author: leostera
- Start Date: 2026-10-31
- Updated: 2026-11-04 (as built)
- Document Type: Proposal
- Amends: [RFD0015](RFD0015-axo-mcp-server.md)

## Summary

A Session's agent can see and operate this Mac's apps through two tools in `axod mcp`:
- `computer({ tool, args, confirm? })` runs one computer-use tool, such as reading a window, clicking, typing or running a script.
- `computer_tools` gives those tools' full schemas.

Most actions happen in the background: no focus change, no pointer movement.

Before an action runs, a risk gate checks it. The gate refuses an action that looks destructive or hard to undo, unless the agent says the person agreed (`confirm: true`). The gate decides with Clef, Cloudflare's open decision model, running on this Mac in a side-car next to axod. If Clef isn't available, it decides with a word list.

## Motivation

Agents in Axo can already reach this Mac's terminal, other Macs (`codemode.<mac>.bash`) and remote MCP servers. They can't reach the apps the person actually uses, such as Mail, Messages, Slack or System Settings. Leo wants computer use in Axo, with three constraints:
- No separate "Axo Computer Use" app.
- Screenshots never leave the Mac to decide whether a click is safe.
- The agent, not Axo, is the first line of judgement: Axo steps in only when the agent didn't confirm.

Research behind this: `ai-research/personal/axo/computer-use/` (the options and the hand review) and `personal/axo/local-models-sidecar/` (runtimes and measurements).

## Guide-level explanation

An agent reads a window with `computer({ tool: "get_window_state", args: { pid, window_id } })`. It gets back the window's elements (`[N] AXButton "Send"`, addressed as element token `<snapshot>:N`) and a screenshot. It acts with `click`, `type_text`, `set_value`, `press_key`, `run_steps` (several actions with checks) or `run_script` (JavaScript over the same tools).

If an action looks destructive, it doesn't run. The agent gets back:

> Not done: "click AXButton \"Delete account\""; Clef, on this Mac, rates it 91% likely to be destructive or hard to undo. Ask the person whether to go ahead; if they agree, call `computer` again with the same tool and args and `confirm: true`.

The person answers in the conversation, and the agent calls again with `confirm: true`.

## Reference-level explanation

### Driver

- **`crates/axo-computer`** embeds Cua Driver's macOS runtime (`platform-macos`, MIT, pinned in `MODULE.bazel`) in-process.
  - Its Accessibility and Screen Recording checks therefore use axod's grants, since axod is the responsible process.
  - The runtime starts on first use, without Cua's daemon, MCP server, cursor overlay or telemetry.
- **Allowlist:** only 24 of Cua's 62 tools are exposed (`TOOLS`). Left out: killing processes, updates, extensions, configuration, recordings, the clipboard, and attaching to the person's logged-in browser.
- **Elsewhere:** on other platforms the crate is empty, and `axod mcp` doesn't offer the two tools.
- **Bazel:** two Cua build scripts compile Swift and run outside the sandbox (`.bazelrc`). `cua-driver-core`'s guides are patched into its crate; regenerate the patch on every Cua bump.

### Risk gate (`crates/axo-server/src/computer_gate.rs`)

The gate runs in `axod mcp` before every `computer` call.

1. **Confirmed or read-only:** `confirm: true` and read-only tools (`get_window_state`, `list_windows`, …) pass.
2. **Describe:** every action is described in words: its tool and target, plus its text, keys, value or script.
   - The target is the element's role and label, remembered from this process's last `get_window_state` of that window, or else `role`/`name` from the arguments.
   - `run_steps` contributes one action per step; `run_script` contributes its source.
3. **Filter:** a description is *flagged* if it contains, as a whole word, one of a short list ("delete", "send", "pay", "publish", "merge", …) or a commit key (Return), or if the typed text contains a newline. Anything not flagged passes without a check.
4. **Judge:** each flagged description goes to Clef, text only, with hand's risk question.
   - p ≥ 0.5 refuses the action; below that, it runs.
   - If Clef is unavailable or fails, the action is refused.

A refusal never reaches the app. Every call logs `event=mcp.computer_called tool=… outcome=ok|error|refused [confirmed=true]`.

### Side-car (`crates/axo-decide`, `third_party/llama.cpp`)

- **The binary:** `axo-decide` is llama.cpp's `llama-server` at a pinned commit.
  - Built by a Bazel repository rule: static, Metal with embedded shaders, no curl or OpenSSL.
  - Shipped as `Axo.app/Contents/Helpers/axo-decide` and signed as `dev.leostera.axo.decide`.
  - llama.cpp supports Clef natively and serves `POST /v1/systemone` on a Unix socket (`run/decide.sock`).
- **One instance, via a lock instead of a supervisor:**
  - Whichever process first needs the side-car takes an exclusive `flock` on `run/decide.lock`, then starts the side-car detached (`setsid`), handing it the locked file across `exec`.
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
- `axo-decide` unit tests: HTTP replies (plain and chunked), missing files turn checks off, one lock holder at a time, and reading memory and disk.
- `mcp` tests: computer use is offered only where it exists, and `computer_tools` lists only the allowlist.
- `//apple/AxoMac:package_test`: `axo-decide`'s minimum macOS and signing team.
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
- **Screen locked:** while the screen is locked, macOS hides every window from Accessibility, so computer use refuses to read or act.

## Unresolved questions

- **Cloud path:** computer use from the cloud (`codemode.<mac>.computer`), and logging computer calls in the account's call log.
- **More from the hand review:**
  - delivery receipts;
  - a screen lease shared across agents;
  - an injection warning on what `get_window_state` reads;
  - reading typed text back.
- **Screenshots:** when Clef's answer is uncertain or the target has no label, should the gate add the window's screenshot (about 4 s)?
- **Asking the person:** should Axo itself ask (a notification, or the Mac app), instead of only telling the agent to ask?
