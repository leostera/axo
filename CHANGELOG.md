# Changelog

What changed in each published version of Axo. Every publish raises the minor version; the build numbers are the Mac app's and axod's.

## 0.9 (Mac app build 280, axod 35)

### Changed

- **An agent waits the full 5 minutes for your answer.** In 0.8, Pi gave up on Axo's tools after 60 seconds, so an answer to `elicitation_request` given later never reached the agent; the same limit cut off `connections_execute` scripts, which may run for 5 minutes. Both now get 5½ minutes.
- **The agent's question looks like the chat's other cards:** a blue card with the question and small Yes and No buttons, on the web and on the phone (phone build 15).

### Fixed

- Nothing visible: axod's relay and store code was reorganized into smaller modules, with no change in behavior.

## 0.8 (Mac app build 279, axod 34)

### New

- **Agents can ask you yes or no, and only you can answer** (RFD0029). An agent calls `elicitation_request` with its question and waits up to 5 minutes. The question shows as a card in that chat on the web and on the phone, and the chat is marked as needing you in the list. Tap Yes or No on any device: the agent gets your answer, and the card goes away everywhere. Nobody answering in time counts as no answer (`cancel`).
- **The agent can't answer for you.** Nothing on the Mac answers a question: answers come only from your signed-in browser or phone, through your account. Another of your Macs can't answer either.

## 0.7 (Mac app build 278, axod 33)

### New

- **The sidebar groups Sessions by what needs you, not by the minute.** Pinned Sessions come first, in the order you pinned them. Then **Active**, A to Z: Sessions working or asking you, active in the last few minutes, or with activity you haven't seen (marked with a dot and a bolder name). Then **Earlier**, latest activity first. Busy Sessions no longer jump around: a row moves only when its Session joins or leaves a group, and groups are worked out every 30 seconds, so Sessions leave Active a few at a time. A Session is seen once you've had it selected with Axo in front; this is kept on each Mac.
- **Settings → Sessions** sets how long a Session stays Active, whether unseen Sessions stay Active, how often Sessions move between groups, each group's order, how unseen activity is marked, and whether group titles show.

### Changed

- Attachments show in Pi's terminal as one short line each (🖼 and the name, or 📎 with the name and size); the agent still reads them whole.

## 0.6 (Mac app build 276, axod 33)

### New

- **Attach photos and files to a message, from the web or the phone** (RFD0030). Tap the paperclip (or paste, or drop files on the box on the web), and each file uploads to your account at once; the message goes when they're all up, with words or without. Your Mac fetches every file, checks it against its SHA-256, and only then gives the agent the message, with all of its files or none.
- **The agent sees your photos.** PNG, JPEG, GIF and WebP up to 5 MB reach the model as images; anything else (PDFs, archives, larger images) is saved on the Mac in `~/.axo/assets/` and the agent is told where. The phone sends HEIC photos as JPEG, which models read.
- **Files live in your account,** up to 100 MB each and 10 GB in all, and are served through Workers Cache. Only your account can read them; a Mac reads them with its own credential.
- **Switch the sidebar between Macs with ⌃⇧⌘[ and ⌃⇧⌘].** They step through This Mac, each of your other Macs, then All Macs (Terminal → Previous Mac / Next Mac).
- **The command palette (⇧⌘P) searches every Session on every Mac,** whatever the sidebar shows. Another Mac's Sessions start their second line with its name, so typing a Mac's name finds them. Choosing a Session the sidebar isn't listing switches the sidebar to its Mac.

## 0.5 (Mac app build 275, axod 32)

### New

- **Copy Session Info.** Right-click a Session in the sidebar to copy its name, ID, Workspace, directory and transcript, with how an agent reaches it (`session_prompt` with its ID). Paste it into another Session to have that one talk to it. For another Mac's Session it names the Mac instead of the transcript.

### Fixed

- Previous and Next Session (⇧⌘[ and ⇧⌘]) step through the rows as they're shown, holding the list still while other Sessions move up.

## 0.4 (Mac app build 274, axod 32)

### New

- **Agents can use your Mac's apps** (RFD0028). Sessions get two tools, `computer` and `computer_tools`, that read a window's controls and text, click, type, scroll and press keys in other apps. They work in the background: the app being driven doesn't come to the front, and your pointer and keyboard stay yours. axod needs Accessibility and Screen Recording, granted in System Settings → Privacy & Security.
- **Risky actions are refused until the agent asks you.** Before a click, keystroke or typed text that looks like deleting, sending, paying, publishing or submitting (Return in a field counts), the agent gets a refusal telling it to ask you, and must call again with `confirm: true` once you've said yes. Reading windows is never stopped.
- **A local model double-checks those actions.** On a Mac with 16 GB of memory or more, the first computer-use call downloads Clef, a small model that judges whether a flagged action is really destructive, so harmless ones like "Remove filter" go through. The files are about 7.4 GB, are checked against their SHA-256, need 10 GB free, and go in `~/Library/Application Support/Axo/models/`. Until they're there, and on smaller Macs, the word list alone decides, which refuses more.
- **axod-infer** runs that model beside axod, in `Axo.app/Contents/Helpers`: one copy shared by every Session, using about 7 GB of memory while loaded and unloading after 10 idle minutes. A crash in it can't take axod down.

### Changed

- axod ships optimized and stripped: it is a quarter of the size and faster.
- Axo.app is 86 MB, up from 46 MB in 0.3: axod-infer carries the model runtime. The model itself is downloaded only when computer use is first used.
- The menu bar's upgrade item names the version, as in "Upgrade to Axo v0.4".

### Fixed

- After an update or a restart, only the loading screen shows until axod is fully running, instead of panes saying "Lost connection to axod".

## 0.3 (Mac app build 270, axod 29)

### New

- **Pin Sessions to the top of the sidebar.** Hover a Session and click its pin, or use Pin Session in its menu; click again to unpin. Pinned Sessions stay at the top, keep their recent-activity order among themselves and always show their pin, and Previous/Next Session (⇧⌘[ and ⇧⌘]) follow them. Pins belong to this Mac only.
- **Archived Sessions live in the cloud** (RFD0027). Once the cloud holds an archived Session's whole transcript, this Mac deletes its copy, freeing the space old conversations take in `~/.axo/sessions/`. Reopening the Session (⇧⌘T, or Pi's `/resume`) fetches the transcript back and checks it before Pi starts. Nothing Pi wrote is lost.
- **Other Macs' archived Sessions aren't kept here.** Opening one fetches its transcript, and this Mac's copy goes when its pane closes.

### Changed

- Reopening an archived Session whose transcript is in the cloud needs the cloud: if it can't be reached within 60 seconds the reopen fails and nothing changes. Try again once you're online.
