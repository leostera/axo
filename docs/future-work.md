# Future work

Ideas and pain points from brainstorming, not yet designed or built. Each becomes an RFD before it is built; remove an item here once it has one, and link the RFD instead.

## Priorities

1. **Axo implements AXP**: [RFD0043](rfds/RFD0043-axo-on-axp.md) (Draft). It is blocked on three decisions:
   - **Device keys:** Ed25519 was chosen. Write the storage design into RFD0043: the key is encrypted under a Secure Enclave P-256 key and kept on this device only, and the phone and browser get new Ed25519 keys (non-extractable WebCrypto in the browser). Open checks: can a Rust daemon use the Secure Enclave directly, or does it need a small Swift helper? Does the data-protection Keychain work with our development-signed builds?
   - **`bash`:** `hosts.bash` in the core directory, or a tool of the `apps` extension?
   - **The converter gate:** wait 7 days of shadow chains, or check every stored Session once?
2. **Full ATXF support.** It mostly comes with AXP, since AXP logs are ATXF. Where each level stands:

   | Level | State |
   | --- | --- |
   | The cloud stores ATXF | Done (RFD0035) |
   | The Mac writes ATXF | Not started. Needs a streaming Pi converter in `atxf-rs`, identical to `atxf-ts`'s `pi.stream` (RFD0043 phase 3) |
   | Clients read ATXF, verifying hashes and chains | Not started (RFD0043 phases 3–4) |
   | ATXF 0.2 actors | Specified (ATXF RFD0001), not implemented |
   | Typed content (see below) | Needs an ATXF RFD |
   | Import and export: continue a Claude Code or Codex session in Axo; export a Session as ATXF | Not started. The ATXF repository's converters already exist |

## Operating Axo

- **Agents survive upgrades.** Installing a release stops every Pi on the Mac (47 at 0.50), and any turn in progress with it, because a Pi exits with its axod. Instead, Pis survive an axod restart and reconnect, or axod hands its sockets to the new axod. The upgrade waits until no Session is mid-turn.
- **A production canary.** Approving a consent prompt and a real `request_input` test have been waiting for weeks on a person. Instead, a test device and Session on `mac_studio` ask and answer a question end to end every hour, and an alert fires when it fails. It also covers push once APNs works.
- **Logs and alerts.** Debugging means grepping axod's log on the Mac (`~/.axo/server/stderr.log`, rotated only at startup). Ship structured logs to the cloud, alert on errors, and show the relay's health.
- **Resource monitoring.** axod samples Pi and shell memory and CPU, and how long each Pi was alive or dormant. This feeds Pi limits and usage metrics.
- **Push notifications.** APNs is blocked on the Apple key. Without push, an agent's question while the person is away times out unanswered.
- **Releases from CI.** Releases are manual today, need a clean checkout, and installing kills the Session that released. Build and publish from CI, and install with a handoff that keeps agents running.

## Building Axo

- **A worktree per Session.** Concurrent Sessions share one checkout. That means `index.lock` collisions, and one Session's uncommitted edits make the checkout unreleasable (0.50 was built from a fresh worktree because of this). Make a worktree per Session the default for repository work.
- **A shared Bazel cache.** One Session's long test run holds the Bazel server for the rest (15 minutes behind the phone UI tests), and a fresh worktree builds cold. Add a shared disk or remote cache, and perhaps a Bazel server per worktree.
- **CI.** Every test runs by hand, including the 64-second relay conformance suite. Run CI on every push, with `mac_studio` as the runner.
- **A repository brief.** Agents re-learn the Bazel rules, the end-to-end test commands and the release steps every time. Write them into the repository as skills or a brief, the `<axo>` brief idea applied to each project.
- **Docs that cannot drift.** The audit had to reconcile 30 RFDs, and AXP's `sessions` extension still has Workspaces (RFD0038 removed them). Add checks that tie RFD claims to code, as the conformance inventory does for methods.

## Axo features

### Profiles

A profile is a named set of settings a Session runs under. It is chosen by rule (by folder, by Mac, or by how the Session was made) and can be changed for one Session. axod enforces it, not pi-axo and not the prompt, and the brief tells the agent what its profile allows.

| Setting | Example |
| --- | --- |
| Replication | "work": nothing leaves the Mac; "personal": everything syncs |
| Default model and thinking level | a cheap model for scratch folders, the best one for main repositories |
| Model tiers allowed | up to `work`, or up to `think` |
| Pi limits | never put to sleep, idle timeout, counted toward the limit or not |
| Tools | computer use or not; which apps and MCP servers |
| Budget | spending a day, or for each Session |
| Remote access | visible on the phone and the web, or not |

Example: `~/Developer/gitlab.cfdata.org/**` runs as "work", with no replication to the personal account, no personal apps and no computer use.

Open questions:
- Do profiles live in the account, shared by every Mac with folder rules per Mac, or on each Mac?
- How do profiles apply to a Mac following another Mac's Sessions?
- Replication is what RFD0043 phase 3 rewrites, so design the two together.

### Model tiers

The agent switches its own model as the work changes: "reading more, cheap model", then "hard design question, the best model".

- **Fixed tier names, mapped by the profile:** `scan` (cheap, no thinking), `work` (normal coding), `think` (the strongest model, maximum thinking).
- **The tool:** `model_tier({ tier, reason })`. The switch applies from the next turn, through Pi's `setModel` and `setThinkingLevel`, so a run's prompt cache is never broken mid-turn.
- **Guardrails:**
  - The profile bounds the highest tier, and can make going up to `think` ask the person.
  - A budget caps the tier.
  - A model the person chose (Mac, phone, `/model`) pins it until they release it.
  - At most one switch a turn.
  - A tier whose context window is too small for the transcript is refused, or compaction runs first.
- **Shown everywhere, recorded everywhere:** each switch shows its reason ("switched to think: reviewing the migration's invariants") and is recorded in the transcript, so spending can be broken down by tier.
- **Later:** routing that suggests or picks the tier automatically, once metrics show where it helps.
- **Open question:** does going up to `think` ask by default, or just happen and show?

### Pi limits and dormant Sessions

The Mac ran 47 Pi processes, 2.7 GB in all (median 43 MB, the largest 285 MB), most of them idle.

- At most *N* live Pis (10–15?), least recently used first, plus an idle timeout (30 minutes?).
- **A dormant Session** keeps its pane and transcript, and its Pi starts again from the transcript on the next prompt or when the Session is opened. It shows dimmed, not gone.
- **Never put to sleep:** mid-turn, a question waiting for the person, a prompt queued, child processes (background shells, dev servers), being watched remotely, pinned.
- **Lost on restart:** codemode's `store()` values, open MCP connections, the warm prompt cache, and a second or two of start-up.
- **Not rotated:** terminal panes.
- **Already in place:** prompts already wait for Pi's bridge, and `DORMANT_PANE_REASON` exists unused in the protocol.

### Usage metrics

What is used on what, by model, provider, Session, folder, Mac, day and tier.

- **Computed from transcripts.** Pi records model, tokens and cost on every assistant message, and the cloud already holds every Session as ATXF, so history comes for free.
- **Also counted:** turns, tool calls by tool, apps calls by app, computer-use actions, questions asked and answered, plus axod's resource samples.
- **Where:** the cloud aggregates; a page in the web and Mac apps shows it.
- **Open questions:** budgets and alerts ("warn past $X a day"), or visibility only? Can agents read their own usage?

### Web rail, artifacts and inline graphics

All three share one sandbox, one store for content (assets, RFD0030) and one channel for events back to the agent. Design them together.

- **The web rail:**
  - A fixed panel on the right of the Session window: a sandboxed WebView the Session's agent owns, for showing rather than telling. Progress dashboards, diffs, charts, a dev server's preview.
  - Content is HTML the agent writes, or a URL (`localhost`); structured blocks that also render natively on the phone come later.
  - Tools: `rail_set`, `rail_patch`, `rail_eval`, `rail_screenshot`, `rail_clear`.
  - The page can send events back (a click, a selected row) as messages to the agent, treated as untrusted input.
  - Sandboxed: no cookies, a strict content security policy, no files, only `localhost` or the agent's own content unless the profile allows more.
  - Phone and web show it too. Open question: one rail per Session, or tabs?
- **Artifacts:**
  - A Session publishes a folder (one page or a built site) as a versioned static site. The rail is the live draft; publishing freezes it.
  - Each version is immutable and stored by content hash; the URL points at the latest, and older versions stay addressable.
  - Tools: `artifact_publish({ path | files, title, visibility })`, `artifact_list`, `artifact_unpublish`.
  - **Visibility:** private (the person, signed in; the default), an unlisted link (which can expire), or public (perhaps on the person's own domain). The profile limits it ("work": private only), and going public can ask.
  - **Never served from `axo.leostera.dev`:** a page there could act as the person. They go on a separate domain, one subdomain per artifact, the way GitHub uses `githubusercontent.com`.
  - Builds on `/axo-share` and the share page (`feature/share-page`), which publish a Session's transcript.
  - **Later:** dynamic artifacts (a Worker each), artifacts republished on a schedule, an artifacts page, forms that post back to the Session.
  - **Open questions:**
    - Static only at first?
    - The person's own domains?
    - Do artifacts outlive their Session? (Yes, probably.)
    - Do unlisted links expire by default?
- **Inline graphics:**
  - Diagrams instead of ASCII art, with the transcript as the source of truth: a graphic block (SVG, Mermaid, HTML) with alt text, rendered as well as each client can.

    | Client | Rendering |
    | --- | --- |
    | Phone and web | an inline sandboxed web view, animated and interactive |
    | Mac terminal (Pi's TUI) | a WebView over reserved cells (below) |
    | Ghostty or another terminal | a still image (Kitty graphics protocol; Pi's TUI already draws images) or the ASCII fallback |
    | Transcript and search | the alt text |

  - **The Mac terminal:** Pi prints an escape sequence reserving rows for a graphic. Axo, which draws its own terminal, lays a sandboxed WKWebView over those cells, scrolling with them and paused off screen. Other terminals ignore the sequence. `axo-vt` does not handle Kitty graphics yet.
  - **The order:**
    1. The phone and web render fenced `mermaid` and SVG blocks the models already write.
    2. Still images in Pi's TUI.
    3. ATXF graphic blocks and HTML graphics.
    4. The Mac terminal overlay.
  - **Pi:** a graphic has to exist in Pi's own file for ATXF's round trip to hold, perhaps as a custom entry written by a `show_graphic({ format, source, alt })` tool.

### ATXF typed content

An ATXF RFD, in the ATXF repository.

- **What 0.1 can already carry:** graphics and embeds fit the `resource` block (`uri`, `mediaType`, `text`): `image/svg+xml`, `text/vnd.mermaid`, `text/html`, links. A list of agreed media types is enough to start.
- **What it lacks:**
  - A fallback (`alt`).
  - Show versus context: the model reads the alt, not 200 KB of HTML, every turn.
  - Display hints: inline or rail, size, static or interactive, scripts or not.
- **The trap:** objects are closed, and readers skip records that fail validation. So a new block type makes an older reader drop the whole message, text and all.
- **The rule to add:** every block outside the core carries `alt`, and a reader that does not know a block treats it as text with that `alt`, keeping the record. Adding kinds of content then stops being a breaking change.
- **Where other ideas belong:**
  - A published artifact is an embed block, perhaps with an artifact record.
  - A tier switch is a `settings` record, with the reason in `ext`.
  - A question to the person stays a tool call.
  - Progress and the rail's live state stay out of the transcript: it holds what was said and shown, not live UI state.

### Wake-ups, background jobs and scheduled work

- **Wake-ups:** agents poll with `sleep` loops while builds run. Instead: "wake me when this process exits, this file appears, or this URL answers", and the Session gets a prompt when it happens.
- **Background jobs:** built on wake-ups.
- **Scheduled work:** recurring prompts ("every morning, summarise last night's CI"), built on wake-ups and profiles.

### Finding Sessions, and who edits what

- `session_catalog` gives no titles. Finding which of 24 Sessions in one folder edited a file meant grepping transcripts.
- Add titles and last activity to the catalog, search across every Mac's transcripts (the cloud holds them all), and show what each Session is doing now.
- axod knows which Session is editing which files.

### Voice mode

- Speak a prompt, and optionally hear a short spoken summary of the reply: push-to-talk on the Mac, hands-free on the phone.
- Speech-to-text runs on the device (Parakeet, already in the backlog).
- **Open question:** what to speak back. Reading out a diff is useless, so replies may need a spoken-summary form, perhaps a typed ATXF block.

### A Watch app

- **What for:** answering agents from the wrist. Questions to the person are yes/no by design, so a notification with two buttons fits them, and approving computer-use consent too.
- Also a glance at which Sessions are running or waiting, and dictating a quick prompt.
- Blocked on push notifications (APNs).

## Order and dependencies

- **Main track:** RFD0043 plus full ATXF. CI and a worktree per Session make each of its releases cheaper.
- **Profiles** come before model tiers, Pi limits and budgets.
- **Usage metrics** come before budgets, and tell us what Pi limits should be.
- **Wake-ups** come before background jobs and scheduled work.
- **ATXF typed content** comes before inline graphics everywhere; the phone and web can render Mermaid blocks before it.
- **The web rail and artifacts** are designed together.
- **CI** comes before releases from CI and the production canary.
- **APNs** comes before push, the Watch app, and the canary's push check.
