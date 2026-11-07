# Changelog

What changed in each published version of Axo. Every publish raises the minor version; the build numbers are the Mac app's and axod's.

## 0.22 (Mac app build 293, axod 45)

### Added

- **Pin chats to the top** on the phone and the web. Chats list as on the Mac: Pinned, Active and Earlier, set up in Settings › Chats.
- **Shared conversations have their own page**, with link previews, the Session's emoji and model, and a download as an ATXF transcript.

### Changed

- The message box on the phone and the web is one card: the words on top, a bar under them.
- **An agent's question goes away when the agent stops waiting for it**: when it cancels the call, or its Pi quits. It used to wait five minutes on every device.
- An agent can wait for several answers at once: `axod mcp` runs tool calls side by side.

### Fixed

- On the phone, new messages append without moving the conversation, and the conversation stays in its column.
- On the web, selecting a message's text no longer swipes to another pane.
- Home Sessions reopen when your home folder is reached through a symlink.
- `axod mcp` no longer lingers after its Pi has quit.

## 0.21 (Mac app build 292, axod 44)

### Fixed

- **The questions panel shows.** It opened with no size, so "1 Question…" seemed to do nothing.
- **`/axo-share` and other Axo commands work when sent from the phone, the web or the Mac app's composer.** They used to reach the agent as plain text.

## 0.20 (Mac app build 291, axod 44)

### Fixed

- **"1 Question…" in the menu opens the questions panel.** It closed again the moment it opened.

### Changed

- The menu bar Axo turns deep pink, not orange, while a question waits.

## 0.19 (Mac app build 290, axod 44)

### Changed

- **Questions on the Mac come from the menu bar.** When an agent or computer use asks you something, the menu bar Axo turns deep pink. Click it and choose "1 Question…": a panel opens right under Axo with every waiting question, one after the other, and the Session each comes from. Answer each in place, sign-in forms included; Return answers the first one, and the panel closes by itself once nothing is left. This replaces the notifications and the cards over the terminal.

## 0.18 (Mac app build 289, axod 44)

### Changed

- **No more allowing each phone and browser at the Mac.** Any device signed in to your account answers your Macs' questions straight away. Answers are still signed by the device, so none can be replayed onto another question or changed on the way (phone build 20).
- **Questions on the Mac are native notifications** with Yes and No, instead of cards over the terminal. Clicking one opens it in its Session. Sign-in forms still show in the window, since a notification can't take a password.

### Fixed

- The pointer over a card in the window is an arrow, not the terminal's text cursor.

## 0.17 (Mac app build 288, axod 43)

### Changed

- **The terminal window waits until axod is truly ready.** axod used to count as up as soon as it answered, while the agents it was restarting were still booting. Now it says it's ready only once those agents have come up (or failed, or after 15 seconds), and Axo keeps showing the loading card until then, so the Sessions you see take messages right away.

## 0.16 (Mac app build 287, axod 42)

### New

- **Only your own phones and browsers can answer for your Macs.** Each phone and browser now signs every answer with a key that never leaves it, and a Mac takes answers only from devices you allowed on it. The first time a new phone or browser answers, the Mac shows "Allow … to answer for this Mac?" with a short code; allow it if your device shows the same code, then answer again. Not even Axo's servers can answer for you, replay an old answer, or turn a No into a Yes (phone build 19).

## 0.15 (Mac app build 286, axod 41)

### New

- **Agents can sign in for you without ever seeing your password.** When an agent reaches a sign-in page on one of your Macs, it asks you instead of asking in the chat: your phone, the browser and the Mac show "Axo asks you to sign in", with the site's real address read from the browser, and the fields it needs. Your password manager fills them in. What you type is encrypted on your device for that Mac alone, so neither the agent nor Axo's servers can read it; the Mac fills it into the page and presses Sign in, and the agent only hears that it was done. Later reads of the page show it as •••• (filled by you) (phone build 18).
- **Screenshots of a whole screen** are now simply `screenshot`.

## 0.14 (Mac app build 285, axod 40)

### New

- **Drive any of your Macs from anywhere.** An agent on one Mac, including one you're chatting with from your phone, can now see and operate the apps on your other Macs, the way it already can on its own: `codemode.hosts.list()` shows your Macs and whether each can be driven, and `codemode.computer.run({ host, tool, args })` reads a window or clicks, types and scrolls there. Screenshots are saved to your account's files and the agent sees them.
- **Risky actions on another Mac ask you first, in the chat that asked.** When something looks like it may send, pay or delete, you get "Axo asks before acting on your Mac" in that conversation on your phone and in the browser, saying which Mac asked; nothing happens unless you tap Yes.

### Changed

- **Running a command on another Mac is now `codemode.bash.run({ host, command })`**, instead of a separate name per Mac. Every call to another Mac is in your account's call log, shown as Terminal or Computer use (phone build 17).

## 0.13 (Mac app build 284, axod 39)

### Changed

- **Agents you haven't used in the last hour don't start with axod.** After an update or restart, axod starts the agents an update interrupted, then those active in the last hour, most recent first. Older Sessions keep their agent asleep, so dozens of idle Pis don't all start at once. An asleep agent starts as soon as you open its Session ("Starting Pi…" for a moment), send it a message from anywhere, or another Session's agent prompts it. Its Session shows as ready meanwhile.

## 0.12 (Mac app build 283, axod 38)

### New

- **Agents an update interrupts pick up where they were.** When axod stops (to update Axo, say), the Sessions whose agent was mid-turn get their Pi back first, and each is told "(the session was stopped to update Axo from 0.11 to 0.12, you may continue)", so it carries on instead of sitting idle. Other Sessions come back most recently active first. This starts with the stop after this update: the axod being replaced doesn't know to leave the note.

## 0.11 (Mac app build 282, axod 37)

### New

- **Answer on your Mac too.** When an agent or Axo's computer use asks you something, the Mac shows a card over that Session's panes and a notification with Yes and No (Yes needs your Mac unlocked); clicking the notification opens the Session. Answering anywhere (Mac, phone or browser) clears it everywhere.

### Changed

- **You can tell who's asking.** A question from Axo's computer-use check is titled "Axo asks before acting on your Mac"; a question the agent wrote is titled "The agent asks you". Only Axo itself can ask as Axo: a script on the Mac can't, and only the Axo app can answer on the Mac (phone build 16).

## 0.10 (Mac app build 281, axod 36)

### Changed

- **Computer use asks you before anything risky, and the agent can't approve for you** (RFD0029). When an agent's click, typing or script looks like it may send, pay, delete or be hard to undo, you get a card on your phone, in the browser and on every device you have open, listing what it will do and in which window. It runs only if you tap Yes; a No or no answer within 5 minutes means it doesn't happen, and the agent is told. Before, the agent could pass `confirm: true` to go ahead by itself; now `confirm: true` means "ask the person first", for actions the check would let through.

## 0.9 (Mac app build 280, axod 35)

### Changed

- **An agent waits the full 5 minutes for your answer.** In 0.8, Pi gave up on Axo's tools after 60 seconds, so an answer to `elicitation_request` given later never reached the agent; the same limit cut off `connections_execute` scripts, which may run for 5 minutes. Both now get 5½ minutes.
- **The agent's question looks like the chat's other cards:** a blue card with the question and small Yes and No buttons, on the web and on the phone (phone build 15).

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
