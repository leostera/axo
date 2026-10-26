# AxoPhone: the old apps compared with the current one

Written 2026-10-26 against `main` at `f2b4780`. Every claim below was read from the source at the named commit.

## The three versions

| | Commit | What it was | Phone code (Swift, excluding tests) |
|---|---|---|---|
| **A. Last before the restart** | `4f76729` (parent of `d885961 starting over...`) | A diagnostic "central control plane" browser. It used Cloudflare Access sign-in, listed machines, runtimes, workspaces and sessions, and opened a conversation in a sheet. | ≈2,100 lines in `apple/AxoPhone`, plus `AxoCore` (Central* types, `CentralInputBuffers`, JSON-RPC client) and `AxoVoice` |
| **B. Last chat-first app** | `d0889ec^` (before "cut phone workbench over to central sessions") | The full product app: chat UI, sliding menu, voice, attachments, files and steering. The current look was ported from it. | ≈4,850 lines in `apple/AxoPhone`, plus `AxoCore` (`ConversationClient`, `SessionFilesClient`, `Protocol`, `WorkbenchCatalog`, …) and `AxoVoice` |
| **C. Current** | `f2b4780` | Chat-first again, on the relay's Pi events, signed in with Cloudflare OAuth. It handles several Macs. | ≈2,330 lines (`AxoPhone` + `AxoPhoneModel`), on `AxoClient`/`AxoProtocol` |

A is the literal "last code before the restart", but it was an engineering screen, not a product. B is what people think of as "the old app". Both are compared below.

---

## 1. Sign-in and identity

| | A | B | C |
|---|---|---|---|
| Method | Cloudflare **Access** through an embedded web view (`ControlPlaneAccessLogin`) that captured the `CF_Authorization` cookie | Cloudflare Access cookie (`AccessLogin`/`AccessCredential`), plus a hand-entered relay endpoint kept in `UserDefaults` | Cloudflare **OAuth** with PKCE in `ASWebAuthenticationSession` (`SignInView`). The Worker issues a bearer token. |
| Storage | Keychain, per host | Keychain cookie, plus the endpoint in `UserDefaults` | Keychain (`KeychainTokenStore`) |
| Sign-out | Button in the main list | None in the UI | Settings → Sign out (also ends the token at the Worker) |
| Expiry handling | `unauthorized` → sign out, then "Access expired or was denied" | Reconnect only | A refused connection signs the phone out with "Sign in to continue." (tested) |

**What C dropped on purpose:** the endpoint field and Access. Both follow from RFD0013.

## 2. Where the data comes from

| | A | B | C |
|---|---|---|---|
| Transport | JSON-RPC over HTTPS/WebSocket to the private control plane (`AxoControlPlaneSession`) | One WebSocket to the relay (`ConversationClient`) with a custom event protocol (`catalog_page`, `snapshot`, `history`, `tool_output`, `ack`, …) | Per-Mac JSON-RPC WebSocket (`HostConnection`) with a negotiate handshake on every connection, plus HTTPS for history (`AccountClient.piEvents`) |
| Macs | Several (machine directory, **polled every 5 s**) | **One** relay, so effectively one Mac (`hostOnline` flag) | Several (`HostsModel`). The list loads once and on pull-to-refresh, **with no polling**. |
| Session list | `CentralCatalog`: workspaces, sessions, readiness, panes, runtimes, revision | `WorkbenchCatalog`, paged by cursor and revision, with a 15 s page timeout and a "catalog changed while paging" restart | The host listing's `sessions`, plus live snapshots on the open Mac |
| Conversation | `observePi` (live / stopped / notAdmitted) plus `piHistory`. Only **one page of 50**: "Earlier entries are not loaded." | A live `Snapshot` (messages, state, activities, question, runId) plus `history` pages in both directions (`before`/`after`), with a `viewId` | Stored Pi events newest-first, 50 at a time, older pages on demand, plus live `piEvent`s |

## 3. Navigation and screens

**A** is one `List` in a `NavigationStack`, with these sections:
- Cloudflare Access sign-in.
- Machines, with generation IDs.
- "Runtime metadata", with Connect, Refresh and Disconnect buttons.
- "Workspaces and sessions", showing readiness and the number of desired panes.
- "Runtimes", with PIDs, attached state and backlog bytes.

A conversation opened as a **sheet** (`CentralPhoneConversationView`) with Close and Refresh buttons. It was an operator's tool, full of IDs and generations.

**B** had the chat-first shell:
- `NavigationSplitView` with a custom sliding menu on compact width, a foreground shadow, a corner radius that grows as the menu opens, dimming, and a tap-to-close area.
- An edge swipe: 32 pt start zone, 80 pt threshold.
- The menu grouped sessions by workspace. Standalone sessions went under "Sessions". Empty workspaces said "No sessions yet".
- The row label was the name. The accessibility label added the availability (Running, Stopped or Failed).
- The header held a text "Axo" and Search. The footer held a "Session" menu (**New session / New workspace**) and Settings.
- The selected session was **remembered across launches** (`axo.selectedPhoneSessionID`). On first launch, it opened the first session.
- Navigation was blocked while voice capture was busy ("Finish or cancel voice capture…").

**C** has the same shell, layout and gesture as B (ported in `f2b4780`), with these differences:
- Header: the mascot instead of the "Axo" text.
- Footer: a plain **Chat** button (a blank new chat) instead of B's New session / New workspace menu.
- It **opens on a blank new chat** every launch, by request, and doesn't remember the last chat.
- It **lists chats only** (`hasAgent != false`), grouped by workspace. With several Macs, the Mac's name is added to each title.
- **No workspace creation and no named session creation.** A chat is created by its first message. With several workspaces it asks which. With none it says "Create one in Axo on the Mac."

## 4. The conversation

| Feature | A | B | C |
|---|---|---|---|
| Message look | Plain role label and text in a tinted box | User bubble on the right, assistant prose on the left, with copy, share and timestamp | Same as B |
| Markdown | No | **MarkdownUI**: headings, quotes, code with language label, **tables**, lists, remote images replaced by "Image omitted" | A small built-in parser: paragraphs, headings, `-`/`*` bullets and code fences. Inline formatting comes from `AttributedString`. **No tables, quotes or numbered lists.** |
| Thinking blocks | No | Yes, smaller and secondary | Yes, same |
| Tool cards | No | `ToolTranscriptView`: kind icon, status, `$ command`, coloured diff for edits, expand/collapse, **full output loaded on demand** in pages ("Load more output") | Ported card: kind, status, command, diff, expand. Output is **only what the stored `toolResult` holds**, with no paging of large output. |
| Live streaming | No | Yes. Snapshots carried running tool output (`activity.output`) and the agent's state. | **No.** Messages appear on `message.end`, so a reply shows up whole when it finishes. Large events over 60 KB never reach the relay. |
| Working indicator | Busy flag | "Pi is thinking / calling tools / waiting for your input / Cancelling…" with a **Cancel run** button and confirmation | "Thinking… / Using tools…", with **no cancel** |
| Questions from the agent | Yes: question title and option buttons (`answer(optionId:)`) | Yes: `ChatQuestionCard` | **No** |
| Cancel a run | Yes (`cancel` control) | Yes (`cancelAgent(runId:)`) | **No** |
| Sent message before it is recorded | Ticket states (dispatched, rejected, unresolved) shown as notices | `pendingPrompts` shown as dimmed bubbles labelled "Submitting…", "Submitted · not yet recorded", "Queued steering", "Delivery uncertain", "Not accepted · draft retained" | Text stays in the box until the Mac accepts it. The bubble appears when the agent records the message. No pending bubble. |
| Steering while busy | Allowed only when `interactionId` existed | Yes (`delivery: .steering`) | Typing while busy goes into the terminal as a paste. Whether that steers or queues is up to Pi. Not modelled. |
| History | First page only | Both directions; loads automatically near the top, at most one queued request; "Load newer messages" too | Newest-first; a "Load earlier messages" row loads older pages as it scrolls into view |
| Scroll behaviour | Scroll to the last entry on change | `ConversationScrollState`: follows the latest message unless the user scrolled; the anchor holds position when pages are prepended; **"Jump to new message"** label; tested (`ConversationScrollStateTests`) | `scrollPosition` anchor, near-bottom check, jump-to-latest capsule **without** the "new message" label. No unit tests for scroll state. |
| Drafts | Central input buffers, per binding, with revision capture | **Per session**, kept while switching sessions; cleared only when the matching prompt is acknowledged | One `@State` per screen. **Switching chats loses the draft.** |
| Exactly-once sending | **Yes**: `CentralInputBuffers` tickets, reconciliation after a lost reply, "will not be replayed" | Prompt IDs with ack and delivery state | A single `axo.remote.session.prompt` call. A lost reply means the result is unknown, and nothing reconciles. |
| Empty state | "Pi is not admitted" | "What are we working on?" with sparkle | Same words, with the mascot |

## 5. Composer

| | A | B | C |
|---|---|---|---|
| Editor | `TextField` with 1–5 lines | A UIKit `ComposerTextEditor` that **owns paste** (text, images, file URLs, data). It grows to several lines, then switches to a layout with an action row and an **expand to full screen** button. | SwiftUI `TextField` with 1–6 lines, Return to send |
| Attachments | No | **+ menu**: Session files, Camera, Photos (up to 8), Files. Clipboard paste of images and files. Drafts bar, upload confirmation ("readable by Cloudflare and the relay"), and a 16,000-character limit message. | **None** |
| Voice | Yes (`AxoVoice`, on-device Apple Speech) | Yes. Mic button, recording bar with waveform, **Stop → draft / Send → send**, setup consent alert, progress card. | **None** |
| Offline message | Notices | "Not sent. Axo won't queue messages while reconnecting." | The placeholder says "<Mac> is offline" and the box is disabled |

## 6. Files

B had a full **session files** feature: `SessionFilesClient` and `SessionFilesView` (384 lines), shared-file cards, photo thumbnails, a horizontal photo collection, zoomable full-screen photos, file previews, a cache with trimming, retry upload and delete. A and C have **nothing** like it.

## 7. Settings

| | A | B | C |
|---|---|---|---|
| Theme (appearance and accent) | Yes | Yes | Yes (same `@AppStorage` keys) |
| Other | — | "Browse machines" (the A-style private machine browser, kept as a debug screen) | Sign out |

## 8. App life cycle and robustness

| | A | B | C |
|---|---|---|---|
| Background/foreground | — | **Disconnects on background, cancels voice, reconnects on active** (`scenePhase`) | **Not handled.** The socket reconnects (and re-subscribes) only when the next call is made, so the live event stream may be dead after the app returns from background until something is sent. *Not verified on a device.* |
| Machine restarts | Detected by host generation; clears the catalog with "The host restarted…" | Catalog revision checks | Stale host is reported as a failure (tested); no generation check in the UI |
| Race fencing | An operation UUID for every async path (selection, discovery, conversation) | Request IDs and timeouts | Mostly a single flow; the known `stop()`-vs-send race is still open |
| Launch configuration | Xcode-generated `UILaunchScreen` and scene manifest; **`TARGETED_DEVICE_FAMILY: 1` (iPhone only)** | Same | Hand-written `Info.plist` with `UILaunchScreen` and (since `f2b4780`) a scene manifest. **Families: iPhone and iPad.** Landscape orientations are allowed. |

## 9. Tests

| | A | B | C |
|---|---|---|---|
| Unit | AxoCore: Central catalog, creation, rename, input buffers (12), display names, daemon integration | AxoCore: protocol (14), history window (5), scroll state (3), prompt submission (3), session files (9), transcript (4), catalog (3), names (5), … | AxoPhoneModel: 51 (transcript, markdown, host model, phone workbench, model), plus a **real Worker + real axod end-to-end** test |
| UI (XCUITest) | 2 (control plane, workbench) | 10 files, about 45 cases: appearance and scrolling, chat layout, clipboard, performance, message metadata, shared files, voice, workbench shell, cross-client | **None** (only simulator screenshots taken by hand) |

---

## What C does better than both

- **Real product sign-in** (OAuth and a bearer token) with no hand-entered endpoint.
- **Several Macs** in one menu (B had one relay; A listed machines but was not a chat app).
- **History is complete and lazy.** Every older page can be reached, unlike A's single page, and nothing streams the whole history.
- **Negotiation on every reconnect**, tested by dropping the socket.
- **Test coverage against the real stack** (Worker plus axod).
- Much less code for what it does (≈2.3k lines against ≈4.9k for B).

## What C is missing compared with B, roughly by how much people would notice

1. **Live streaming of replies and tool output.** Replies appear only once finished.
2. **Cancel a run** and **answer the agent's questions**.
3. **Voice prompts** (Stop → draft, Send → send).
4. **Attachments:** camera, photos, files, clipboard paste; and **session files**.
5. ~~**Pending-message bubbles with delivery state.**~~ Done in `b44f62c` (Sending, Sent, Queued).
6. ~~**Per-chat drafts** that survive switching chats.~~ Done in `b44f62c`.
7. ~~**Rich markdown:** tables, quotes, numbered lists.~~ Done in `b44f62c` (plus nested lists and rules).
8. **Paged full tool output** ("Load more output").
9. ~~**"Jump to new message"**~~ Done in `b44f62c`. The scroll-follow logic still has no tests.
10. **Background/foreground handling** of the connection.
11. **Creating workspaces and named sessions** from the phone.
12. **XCUITests.**
13. ~~**iPhone-only device family.**~~ Done in `95c1ee0`.

## A bug found while comparing (C)

The menu and search list chats from `PhoneWorkbench.hosts.hosts`, the host **listing**, which loads once and on pull-to-refresh. They don't use the open Mac's live `HostWorkbenchModel.sessions`. So **a chat created from the phone doesn't appear in the menu until the list is refreshed**, and the same goes for renames or chats created on the Mac. B read its list from the live catalog. Fix: build the open Mac's section from `current.sessions`, and keep the listing for the other Macs. **Fixed in `b44f62c`** (`PhoneWorkbench.sessions(of:)`).
