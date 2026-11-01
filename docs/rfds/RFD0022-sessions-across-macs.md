# RFD0022 - Axo: Sessions across Macs

- Feature Name: `axo-sessions-across-macs`
- Status: Draft
- Author: leostera
- Start Date: 2026-11-01
- Updated: 2026-11-01 (the peers socket, as built)
- Document Type: Proposal
- Amends: [RFD0015](RFD0015-sessions-as-axo-clients.md), [RFD0018](RFD0018-session-sync-and-client-delivery.md)

## Summary

I propose that every Mac paired with an account shows and keeps a copy of every Session in the account, not just its own, and that a Session can be continued on another Mac.

- **Pairing is the sign-in.** A paired Mac already holds a host credential (RFD0013). Axod uses it to follow the account the way the phone and the web app do (RFD0018). There is no second sign-in in the Mac app.
- **The copy is made as you go.** Axod mirrors other Macs' transcripts from the cloud while they are written. By the time you want a Session on this Mac, its history is already here. Nothing is copied when you continue it.
- **Continuing a Session moves the agent, not the files.** Your Macs usually already have the same repositories. "Continue on Mac Studio" starts Pi on the Studio from the mirrored history. The first thing that Pi reads is a **handoff**: what the workspace looked like on the old Mac, what is different on the new one, and how to bring it up to speed. While the old Mac is online, its own agent writes the handoff after checking the new Mac with its `bash` tool (RFD0016).

## Motivation

Leo works from a MacBook Pro and a Mac Studio. Four things are wrong today:

1. **The web app does not say which Mac a chat is on.** This is fixed in 0325533: with more than one Mac, each chat row names its Mac.
2. **New chats cannot choose their Mac.** This is also fixed in 0325533: the message box has a Mac picker.
3. **The Mac app shows only its own Sessions.** It asks only its local axod, which knows only the Sessions it runs. A Session opened on the MacBook is visible on the phone and in the web app, but not in the Studio's Mac app. RFD0015 and RFD0018 both list this as future work ("Sessions on other Macs", "Remote Sessions on the Mac").
4. **A Session cannot follow you.** Work started on the laptop has to be explained again on the Studio, or continued remotely through the laptop, which has to be awake.

Two facts make this cheap:

- **The cloud already has every transcript.** It is stored as Pi's own session-file lines, tagged `pi/3`, in one SessionDO per Session (RFD0018). A mirror can rebuild the exact `session.jsonl` that Pi wrote.
- **An agent can already reach another Mac.** Through `codemode`, the `bash` tool of any paired Mac (`codemode.<mac>.bash`, in `packages/axo-api-worker/src/connections/account.ts`) runs commands on that Mac. So the agent that knows the work can check the other Mac itself.

## Goals

- The Mac app lists every Session of the account, grouped or labelled by Mac, with the same chat view as the phone: read live, prompt, stop, answer questions.
- A paired Mac keeps an up-to-date local copy of every other Mac's transcripts, with no sign-in beyond pairing.
- "Continue on <Mac>" works from the Mac app, the web app and the phone. It starts the Session on the chosen Mac within seconds, with no history transfer at that moment.
- The continued Session starts with a handoff that tells Pi how to bring the workspace up to date. The handoff is written by the original agent when its Mac is online, and by axod from recorded workspace state when it is not.

## Non-goals

- **Moving files.** Axo does not copy, sync or check out a workspace's files. The handoff tells the new agent what to check; the agent and the user do the rest.
- **Terminals of other Macs.** A remote Session's shells are not shown in the Mac app. This needs RFD0018's opt-in terminal streams first.
- **Two Macs writing one Session at once.** A Session has one owning Mac at a time. Continuing it hands ownership on by starting a new Session (see [Continuing](#continuing-a-session)).
- **Merging diverged transcripts.** The same as RFD0018: that waits for ATXF.

## Guide-level explanation

### The Studio sees the laptop's Sessions

Leo pairs the Mac Studio. Its sidebar shows its own Sessions as before, and under them a section for each other Mac, here "MacBook Pro", with that Mac's chats. Opening one shows the conversation from the Studio's own disk copy, live while the laptop works. Leo can prompt it, and the prompt goes through the cloud to the laptop, where the Session runs. The header says "On MacBook Pro". If the laptop is asleep, the chat is still readable but the message box says "MacBook Pro is offline", with **Continue here** next to it.

### Continue on the Studio

In the chat's menu, or from the message box's Mac picker on a chat that is already going, Leo chooses **Continue on Mac Studio**. Then:

1. The laptop's agent gets a short system turn: write a handoff for the Mac Studio. It checks its own workspace, then the Studio's, with commands like these:

   ```js
   const here = await codemode.macbook_pro.bash({ command: "git -C ~/src/axo rev-parse HEAD && git -C ~/src/axo status --short && git -C ~/src/axo branch --show-current" });
   const there = await codemode.mac_studio.bash({ command: "test -d ~/src/axo && git -C ~/src/axo fetch -q && git -C ~/src/axo rev-parse HEAD && git -C ~/src/axo status --short" });
   ```

   It answers with a handoff like this one:

   > Continuing from MacBook Pro. We were fixing the relay backoff in `~/src/axo` on `feat/relay-backoff` at `3f2c1aa`. That commit is pushed; the Studio is on `main` at `9e01b2c` with a clean tree. Before going on, run `git -C ~/src/axo switch feat/relay-backoff && git pull`. Two files were uncommitted on the laptop, `crates/axo-relay/src/relay.rs` and `relay_test.rs`, so they are not on the Studio; ask Leo whether to commit them on the laptop first. Then run `cargo test -p axo-relay` to check where we are.

2. The Studio creates a new Session in the matching Workspace, from the mirrored history. Pi opens it with the whole conversation, then the handoff as the next message.
3. The laptop's Session is archived, with a note pointing to the new one. Its history stays readable.

Leo goes on typing on the Studio. The new agent follows the handoff, so it checks the branch before it edits anything.

If the laptop is offline, the Studio writes the handoff itself from the last workspace state the laptop recorded, and tells the new agent to verify it:

> Continuing from MacBook Pro, which is offline. Its last known state of `~/src/axo` was `feat/relay-backoff` at `3f2c1aa`, with uncommitted changes. Check whether this Mac has that repository and commit, and say what is missing before changing anything.

## Reference-level explanation

### Following the account from axod

Axod opens a second socket next to its host socket: the same client socket a browser tab opens (RFD0018), signed in with the host credential instead of the account sign-in.

```
GET /api/v1/accounts/<account>/hosts/<host>/peers     (WebSocket)
Authorization: Bearer <host credential>
X-Axo-Credential-Id: <credential id>
```

The Worker checks the credential with the account (`authorizeHost`, as for the daemon socket), then hands the socket to an ordinary ClientDO named `(account, "host-" + hostId)`. Everything after that is the client protocol unchanged: `axo.client.hello`, `session.open` with `have`, `records` batches paced by `ack`, `reset`, `command`. Two things differ:

- **This Mac's own Sessions are left out.** A ClientDO whose client id is `host-<hostId>` does not follow that host; axod has those Sessions already.
- **An open from nothing returns Pi's header line.** `session.open` with `have.cursor` 0 carries `header`, so the copy is the whole file Pi wrote. Other clients never ask for it.

This keeps the HostDO and ClientDO as they are. A ClientDO driven over the host socket would have needed a second way to deliver everything the ClientDO now sends to its one socket.

**Authorization.** The host credential is enough. A paired Mac can already run commands on every other Mac of the account through connections, so reading and prompting their Sessions grants nothing new. The socket is signed in for an hour, and axod opens it again before then, so a revoked Mac is refused within the hour.

**Pacing.** Axod sends at most 30 frames a second (the ClientDO closes a client past 60), with at most 4 opens waiting at once.

### The mirror

Axod writes peer transcripts under `~/.axo/server/peers/<hostId>/<sessionId>.jsonl`. These are Pi's header line and then the cloud's `pi/3` lines in order, so they are the files Pi wrote, and Pi can open them. Next to each is `<sessionId>.state.json` with `{ epoch, cursor }`, saved after the lines are on disk and before the batch is acknowledged. `peers/index.json` holds the other Macs and their Sessions as the cloud last listed them, for the catalog.

- **Crash safety:** on its first look at a copy, axod cuts away lines past the saved cursor. A copy shorter than its state is made again from nothing.

- **Which Sessions are mirrored:** all of them. That includes archived ones, so continuing an old chat needs nothing. At about one transcript per chat, this is far less than one Mac's disk.
- **Truncation:** a `reset` (the source Mac rewrote history) truncates the mirror to the cut and reads on, as the ClientDO's reads already do.
- **Invariant: a Mac uploads only the Sessions it owns.** The peers directory is outside `pi-sessions/`, so the uploader never sees it. A mirror is never sent back to the cloud.
- **Catalog:** `axo.session.catalog` gains `host: { hostId, label, online }` and `mirror: true` on peer Sessions. Prompt, stop and answer on a mirror go out as `axo.client.command` on the peers socket.

### The Mac app

The sidebar groups Sessions by Mac: this Mac first, then each peer by label, offline ones dimmed. A peer Session opens in the existing chat view, fed by axod from the mirror plus the forwarded progress. It shows no terminal or shell panes. The message box gets the same Mac picker as the web app: on a new chat it chooses the Mac, and on a peer chat it offers **Continue here**.

### Workspace state

To make offline handoffs possible, the owning axod records each Session's workspace state in its metadata (`axo.host.session.meta`), after every agent turn that ran a tool:

```ts
workspaceState: {
  path: string,            // the Session's working directory
  repoRoot: string | null, // git rev-parse --show-toplevel
  remote: string | null,   // the URL of the upstream remote
  branch: string | null,
  head: string | null,     // commit hash
  upstreamHead: string | null, // what the branch's upstream was at
  dirty: string[],         // git status --short, the first 50 paths
  at: number,
}
```

These are cheap local git calls with a short timeout. A Session outside a repository records only `path`.

### Continuing a Session

`axo.remote.session.continue { sessionId, targetHostId, commandId }` goes to the **target** Mac, which:

1. **Picks the Workspace.** It uses the one whose path equals `workspaceState.repoRoot` (or `path`) on this Mac. Otherwise it uses one whose repository has the same remote, and otherwise Home. The handoff says which it chose.
2. **Gets the handoff.** If the source Mac is online, the target asks it with `axo.remote.session.handoff { sessionId, targetHostId }`. The source axod runs one extra Pi turn in the Session with a fixed instruction: inspect your workspace and the target's with their `bash` tools, and answer with a handoff of at most 300 words covering repository, branch, commit, what is pushed, what is only here, and the first commands to run there. The turn is marked internal, so clients show it folded as "Handoff to Mac Studio". It times out after 3 minutes. Otherwise, or on timeout or failure, the target writes the template handoff from `workspaceState`.
3. **Starts the Session.** It creates a new Session with a new UUID (RFD0017) from the mirrored file, rewritten only in its header: a new id, the new working directory, and `parentSession` pointing to the original. Then it starts Pi and sends the handoff as the first message, with Pi's `followUp` delivery so it is read before any user prompt.
4. **Archives the original** through `axo.remote.session.archive` on the source Mac, with `continuedOn { hostId, sessionId }` in its metadata. If the source is offline, the archive waits in the target's queue until the source next comes online. Clients already show the pair as one thread through `continuedFrom` / `continuedOn`.

The new Session is the target Mac's own from then on, and uploads as any other.

The handoff runs **before** the new Session starts. If the source agent is busy, it waits until the turn ends, at most the 3-minute timeout, and then the template is used. Messages the source receives after the handoff began are refused with "This chat is moving to Mac Studio".

### Failure semantics

- **The target is offline:** Continue is disabled for that Mac.
- **The mirror is behind:** the target first reads up to the head it was told about. A mirror more than 30 s behind fails the command with "Still copying this chat".
- **The handoff fails:** the template handoff is used, saying the source could not be asked.
- **The archive fails:** it is retried. Until then both Sessions are listed, and the original shows a "Continued on …" banner.

## Security and privacy

- Every paired Mac stores every transcript of the account on disk. Today only the cloud and the owning Mac do. That is a real change in where the data lives. Revoking a Mac does not erase its mirror, and the Pairing settings must say so.
- The handoff turn runs commands on the target Mac. They are ordinary `bash` connection calls, logged in the connections log like any other.

## Rollout

1. **Workspace state** in metadata. axod only, harmless alone.
2. **The peers socket and the mirror.** Worker and axod. Copies and the index are on disk, with no UI yet.
3. **The Mac app's peer sections and chat view.**
4. **Continue**: the `session.continue` and `session.handoff` methods, the handoff turn, and the button in the Mac, web and phone apps.

Each step bumps axod's `BUILD_NUMBER`, and the Worker ships before the axod that uses it.

## Testing

- **Worker:** `HostDO` peers tests with two fake hosts. Each host follows the other, its own Sessions are left out, and acknowledgements pace the records.
- **axod:** the mirror rebuilds a byte-identical file from a fake cloud, including across a reset. Peer files never reach the uploader. `session.continue` picks the Workspace and falls back to the template.
- **A `specs/` model** of continue: the handoff, the start and the archive, with either Mac going offline at each step. No message may be lost, and no Session may end up with two owners writing.
- **Web and phone:** browser and model tests for Continue in the Mac picker.

## Drawbacks

- Mirroring the whole account onto every Mac costs disk and bandwidth, even for chats never opened on that Mac.
- A continued chat gets a new id, so links to the old one go to the archived original. The banner points on, but it is one more hop.
- The handoff costs one extra agent turn on the source Mac.

## Rationale and alternatives

- **The Mac app signs in to the account like the phone.** This is a second sign-in for something pairing already proves, and it would need a token store in the Mac app. Leo ruled it out.
- **Copy the history when continuing.** This is slower at exactly the moment it matters, and it fails if the cloud is slow. The mirror makes Continue local.
- **Keep the same Session id and move ownership.** This is cleaner for links. But SessionDOs are named by `(account, host, session)`, and RFD0018's host-wins rule assumes one owner forever. Changing either is a larger change than a fork with `parentSession`, which Pi already understands.
- **A template handoff only.** This is simpler, but only the original agent knows which files mattered and why. With the agent's check, the handoff reflects the new Mac's actual state, not a guess.
- **Sync the files.** This is out of scope, and usually unnecessary: Leo's Macs already share their repositories through git.

## Unresolved questions

- Should the mirror skip archived Sessions older than some age, and fetch them on demand?
- Should the handoff turn be able to *act* on the target (for example `git switch`), or only describe? This proposal only describes, leaving the edits to the new agent where Leo can see them.
- Is 300 words the right size for a handoff?

## Future possibilities

- **Terminals of other Macs**, through RFD0018's opt-in terminal streams.
- **Continue on the phone's behalf:** "Continue on whichever Mac is online" when the owning Mac sleeps.
- **ATXF union merge**, which would let a Session keep one id across Macs.
