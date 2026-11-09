# Changelog

What changed in each published version of Axo. Every publish raises the minor version; the build numbers are the Mac app's and axod's.

## 0.42 (Mac app build 313, axod 65)

### Changed

- axod runs on about half as many threads. Each terminal's output used to have a thread of its own; all of them now share two.
- Closing a Pi pane or restarting it again calls off a takeover still waiting for the old Pi at once, instead of within a tenth of a second. A restart also goes ahead the moment the old Pi exits.
- Signing in to an app on this Mac, and starting the local model, no longer check every few milliseconds whether they are done; they wake when something happens.

## 0.41 (Mac app build 312, axod 64)

### Changed

- The Mac app hears of changes to your Sessions the moment axod makes them, instead of asking again and again. An idle Axo costs nothing while nothing happens.
- A pane whose program exits closes at once, and stopping a shell no longer waits on a timer to see it gone.

## 0.40 (Mac app build 311, axod 63)

### Changed

- What an agent writes reaches the web and the phone at once. The Mac sent a Session's new lines up to half a second late, and woke twice a second to look for them; it now hears of each line as it is written, and does nothing while nothing happens.
- A Mac renews its place in the cloud once a minute instead of every ten seconds. A laptop that wakes on another network is let back in at once, even while its old connection is still held.

### Fixed

- A command from another Mac or the phone that runs past its time limit is stopped whole. Under load, the shell could outlive the stop and run the command's next step.

## 0.39 (Mac app build 310, axod 62)

### Fixed

- When you unpair a Mac, your other Macs let go of it cleanly. Before, one that was still opening that Mac's Sessions could ask the cloud for it, drop its connection and follow through the account for ten minutes; a command waiting on it now fails as offline at once.
- On the web and the phone, a message for a Mac they haven't connected to yet says it wasn't sent, instead of being taken for an older Mac and sent again another way.

## 0.38 (Mac app build 309, axod 61)

### Changed

- A Mac follows your other Macs' Sessions straight from each Mac's cloud host, instead of through the account. A reconnect costs one hello per Mac, and a Session whose copy is already current opens without reading anything. If the cloud can't serve that yet, the Mac follows through the account as before, and tries again ten minutes later.

## 0.37 (Mac app build 308, axod 60)

### Changed

- **Send interrupts.** A message sent from the web or the phone while the agent works stops its reply and is answered next, ahead of anything waiting. Hold Send for the gentler ways: Steer (read at the agent's next step) or Follow up (after its reply). On the web, ⌘↵ steers and ⌥↵ follows up. Every message is still written to the Session's log before it is accepted.
- Holding Send works on the phone and on a phone's browser, and the phone's Send is a plain solid circle again.

### Fixed

- A message sent while the agent works stays where it was sent, instead of sinking below every new reply until the agent took it. A `/axo-share` sent from a client no longer leaves a bubble waiting at the end.

## 0.36 (Mac app build 307, axod 59)

### Changed

- Inside axod, what the web and the phone ask of a Mac is answered by the same methods as local requests; the relay only carries it. Nothing changes on the wire.

## 0.35 (Mac app build 306, axod 58)

### Fixed

- Reopening a Session right after closing it no longer leaves its agent marked as unrecoverable: Axo waits for the old agent to finish exiting.

## 0.34 (Mac app build 305, axod 57)

### Fixed

- A large paste into a terminal whose program isn't reading no longer freezes Axo: only that terminal waits, more input to it gives up after 5 seconds, and closing it ends the wait.

## 0.33 (Mac app build 304, axod 56)

### Changed

- Inside axod, what it knows about its agents has its own lock, so health checks and agent controls no longer wait behind Session work.

## 0.32 (Mac app build 303, axod 55)

### Changed

- Apps are called apps everywhere: adding a server answers with the app, and agents read "no app named …" instead of "connection".

## 0.31 (Mac app build 302, axod 54)

### Fixed

- Computer use on a locked Mac says "this Mac is locked" instead of acting on the lock screen. Agents see a locked Mac in `codemode.hosts.list()`; `bash.run` still works there.
- A message sent from the phone or the web while the chat's Pi is starting stops waiting as soon as you leave, and is answered the moment Pi is up instead of up to 50ms later.
- A shell or Pi no longer keeps a copy of axod's sockets, which could stop the next axod from starting after a restart.

### Changed

- `axod attach` follows a terminal resize the moment it happens instead of checking every 25ms.

## 0.30 (Mac app build 301, axod 53)

### Changed

- Prompts, stops and model switches reach Pi about 200ms sooner: axod sends them the moment they arrive instead of on its next check of Pi's connection.
- axod sleeps when nothing is happening. It no longer wakes several times a second for each Session, open terminal and running command, so an idle Mac does less work.

## 0.29 (Mac app build 300, axod 52)

### Changed

- Your phone and the web reach this Mac faster: axod answers the moment a request arrives instead of checking every 20ms, and stays idle when nothing happens.

## 0.28 (Mac app build 299, axod 51)

### Fixed

- The x on "Thinking…" in the web app and on the phone stops the reply in more cases. It didn't in a long run, whose latest messages are all tool output, or right after sending, before the conversation had caught up. A stop now names everything the client saw of the run.
- Tapping the x while Pi is in fact idle clears a "Thinking…" that was stuck, instead of doing nothing.
- On the web, "Restarting…" no longer disappears at once on an idle chat.

## 0.27 (Mac app build 298, axod 50)

### Added

- **Session controls on the web and the phone** (RFD0033). The message box names the model and thinking level the chat's Pi runs ("Opus 4.1 · High"), and picking another switches it. Typing `/` lists the commands this Pi runs: prompt templates, skills and extension commands. Holding Send (or ⌘↵ on the web) steers a working agent at its next step instead of waiting for its reply. Chat info has Restart Pi.

### Changed

- A message sent while Pi works is written to the Session's log before it is accepted, so a reload, a closed tab, or Pi exiting or restarting can't lose it. It shows as Queued or Steering until Pi takes it, on every device.
- Restart works on a running Pi too: it stops the reply and starts Pi again on the same conversation.

## 0.26 (Mac app build 297, axod 49)

### Changed

- Agents' Axo tools answer from inside axod: each tool call is one call in axod instead of a new connection, and every Session shares one computer-use safety check. After an update, an agent's next Axo tool call reconnects by itself.

## 0.25 (Mac app build 296, axod 48)

### Changed

- Inside axod: it is now put together from extensions (apps, assets, questions, computer use), each in a crate of its own. Nothing should look different; tell me if something does.

## 0.24 (Mac app build 295, axod 47)

### Changed

- An agent runs a script on the account's apps with `apps_run` (it was `apps_execute`).

## 0.23 (Mac app build 294, axod 46)

### Changed

- **Connections are now Apps.** An agent's tools are `apps_list`, `apps_search`, `apps_run` (from 0.24; `apps_execute` in 0.23), `apps_add`, `apps_remove` and `apps_log`, and scripts, Settings and the phone all say Apps. Sign-ins you set up with a provider keep working.

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
