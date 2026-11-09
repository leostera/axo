# RFD0038 - Axo: Sessions without Workspaces, and a task per Session

- Feature Name: `session-actors`
- Status: Accepted
- Author: leostera
- Start Date: 2026-11-09
- Updated: 2026-11-09
- Document Type: Proposal
- Supersedes: [RFD0014](RFD0014-workspaces-and-agent-led-sessions.md) (Workspaces)
- Amends: [RFD0022](RFD0022-sessions-across-macs.md) (transcript paths), [RFD0034](RFD0034-axod-as-an-axp-server.md) (split by owner), [RFD0037](RFD0037-axod-reactive-core.md) (step 5)

## Summary

Workspaces go, from axod and every client. A Session has a folder, its own, chosen when it is made and the home directory by default; nothing groups Sessions or keeps one open. Then the Session manager, today one object behind one lock, becomes a task per Session that owns everything about it, a registry that finds and starts them, and one task that writes SQLite.

## Motivation

- **`SessionManager` does everything.** It holds the SQLite connection and every pane behind one `std` mutex, the Pis' state behind a second, and about twenty more fields, a third of them nothing to do with Sessions (questions, assets, the input key, computer use). It is 13,000 lines across 26 files. Every handler gets the whole of it.
- **It cannot be made async as it is.** Every change to the state writes SQLite while the lock is held; an async write would hold a lock across an await. RFD0037 stopped every wait polling, but only by adding `StateChanges`, `wait_for_state` and `Interrupt`, which exist because everything waits on one lock.
- **Workspaces are the only thing that spans Sessions.** "Keep one Session open in each Workspace", the home Workspace that can't be archived, archiving a Workspace's Sessions together, and the replacement Session made when the last one closes are the only operations that need more than one Session at once. Without them every invariant is about one Session.
- **Workspaces no longer earn their place.** The Mac's sidebar stopped grouping by them; a title's first word says what a Session is about. What is left is a name for a folder, a creation sheet, a confirmation when the last Session closes, and two remote methods.

## Guide-level explanation

You start a Session in a folder: "New Session in Folder…" (⌘N, and the sidebar's +) searches the folders under your home directory and offers to pick any other; the palette also lists "New Session in <folder>" for the folders of your open Sessions. "New Session" (⌘T) starts one beside the selected Session, or in your home directory. Cloning a GitHub repository starts a Session in the clone, or shows the one already open there. Closing a Session closes it, without asking; nothing opens in its place. axod opens none by itself: with none open, the sidebar says so and offers a new one.

On the phone and the web, a new chat starts in the Mac's home directory; the remote API can also start one beside another (`like`). Chats show their folder's name where they showed their Workspace's, and the phone's grouped menu groups them by it.

Later, Pi will be able to move its Session to another folder (`/axo-set-cwd` in pi-axo); the folder is the Session's, so that is one more method, not a model change.

## Reference-level explanation

### Part 1: Sessions without Workspaces

- **A Session's folder** is `sessions.initial_pwd`, which every Session already has (a Workspace Session's is its Workspace's directory). `SessionRecord.folder` carries it to the Mac. The remote snapshot and the sync metadata carry `folderName`, its last component: remote clients never see a path from them.
- **Creating:** `axo.session.create { folder? | like? }` makes a Session with Pi and a terminal in `folder` (absolute, an existing directory), in the folder of the open Session `like`, or in the home directory; both at once, a relative or missing folder, or a `like` that is not open are invalid params. A Session whose Pi cannot start is not made. `axo.remote.session.create { target, like? }` takes only `like`: the phone and the web never send a path. axod's MCP tool `session_create` takes `like`, where `"self"` is the agent's own Session.
- **Removed outright** (the app and axod ship together; the Worker first):
  - local: `axo.workspace.list`, `.create`, `.rename`, `.archive`, `.session.create`, and the `workspaceChanged` event;
  - remote: `axo.remote.workspace.list` and `axo.remote.workspace.session.create`;
  - `WorkspaceRecord`, `RemoteWorkspace`, `workspaceId` and `workspaceName` in records, snapshots and sync metadata;
  - the home Workspace, `ensure_open_workspace_sessions` and its retry timer, the replacement Session, and security-scoped bookmarks (the app is not sandboxed; a bookmark the app makes cannot give axod anything).
- **Stored data stays where it is.** axo.db keeps its `workspaces` table and `sessions.workspace_id`, unread and unwritten; no migration. The cloud's stored metadata named `workspaceId` and `workspaceName`; a HostDO schema step rewrites each stored row without them, naming its folder from `workspaceState.path` where the Mac had read it, and the Worker keeps rejecting them from a Mac. `workspaceState` (a Session's git state, RFD0022) keeps its name: it is stored in the cloud and was always the Session's.
- **Transcript paths.** A new Session's transcript is `<sessions>/<hostId>/<sessionId>.jsonl`, not under a Workspace directory; an existing one stays where `pi_session_file` says. Another Mac's copies are `<sessions>/<peerHostId>/<sessionId>.jsonl`, fetched again on first follow.
- **Importing a Pi transcript** (pi-axo) makes a Session in the importing Session's folder.

### Part 2: a task per Session

Started once part 1 has shipped. It gets its own Feynman spec, `specs/sessions/session-task.ts`, before any code moves: create, close, a pane's exit, restore, a Pi's restart and takeover, and shutdown, with races and crashes.

- **One task per Session** owns its panes, its layout, its Pi (the bridge on `AsyncFd`, takeover as a state machine, queued prompts, activity) and its rows. Everything that happens to a Session is a message in its mailbox, handled one at a time: a close, a pane's exit and a restart cannot interleave, and whichever comes second sees what the first did. A child's exit is a message to its Session, so the reaper goes; a close or shutdown is the next message, so `Interrupt` and `wait_for_state` go.
- **A registry task** keeps the index of open Sessions and each one's summary (updated by its task), settings and the viewport; it lists, creates, restores at startup, and restarts a Session's task if it panics.
- **A writer task** owns the SQLite connection; everyone writes through it, matching SQLite's one writer. Reads that need no ordering use their own read-only connections.
- **Shared, not owned:** the event bus, as it is. Peer views move out of the Session state to their own owner beside the relay.
- **Not the Session manager's:** questions, assets, the input key, computer use, devices and each Session's git state become services the server owns; handlers take what they need.
- **Order:** the services move out; the 30 RPC handlers become async, still calling the old code; peer views get their owner; the writer task; Session tasks and the registry, operation by operation, while the lock shrinks; then the Pi's side (`pi_recovery`, `pi_bridge`, takeover) moves into the Session task.

## Drawbacks

- A group of Sessions can no longer have a name other than its folder's.
- An empty project no longer stays in the sidebar; recent folders in "New Session in…" are how you get back to it.
- Part 2 trades one lock for about 120 small tasks and a protocol between a Session's task and the registry; the spec is what keeps that honest.

## Rationale and alternatives

- **Split by concern** (a catalog actor, a panes actor, a Pis actor). Each is small, but every Session operation becomes a conversation between them with undo steps, and today's races come back as message races. Splitting by Session puts each invariant inside one task, as one Erlang process would own one Session's lifecycle.
- **Keep Workspaces, split by Session anyway.** Leaves the registry with the only multi-Session operations, and keeps a concept the app has stopped showing.
- **Group by git root.** Unneeded: the sidebar no longer groups at all.
- **Drop the stored columns now.** `sessions.workspace_id` is a foreign key, which SQLite can only drop by rebuilding the table under `foreign_keys = OFF`; nothing gains from it yet.

## Unresolved questions

- Whether a Session's task should also own its libghostty-vt terminal state, or keep reaching it through a channel.
