# RFD0014 - Axo: workspaces and agent-led sessions

- Feature Name: `axo-workspaces-and-agent-led-sessions`
- Status: Proposal
- Author: leostera
- Start Date: 2026-10-17
- Updated: 2026-10-17
- Document Type: Proposal

## Summary

I propose making a host-local project Workspace the owner of multiple independent Axo Sessions. Each open Session has exactly one interactive Pi agent pane, at least one shell terminal pane, and its own persisted split layout and exact Pi conversation binding. Creating a Workspace creates its first Session; adding a Session creates another independent agent-plus-terminal pair in the same project. Axod owns this desired graph and restores it after daemon restart, while Pi remains the authority for its canonical conversation history. This proposal changes the local data model, daemon lifecycle, shared contracts, Mac UI, remote metadata, and browser Workbench; it does not change Cloudflare Access policy or persist terminal bytes.

## Motivation

Axo currently treats a session as a set of generic shells. `crates/axo-server/src/session.rs` creates one shell in the daemon's home directory, stores open sessions/shells and an optional shell-ID layout in SQLite, and restores replacement shells on daemon startup. It has no Workspace grouping, pane role, or Pi conversation binding. `packages/axo-api/src/v1.ts` likewise publishes shell IDs and layout without Workspace or Pane roles.

That model does not match how I work: I open a project, start an agent in one pane and a terminal beside it, and sometimes create multiple independent agent-led sessions in the same project. Closing one agent means that particular line of work is done; it should not close other sessions in the Workspace.

Some shared TypeScript state contracts already sketch Workspace, Session, and Pi/shell roles in `packages/axo-api/src/state-contracts.ts`. They are not yet enforced by the current Axod session implementation, and they do not yet encode the exact-one-Pi, at-least-one-shell, and pane-layout invariants proposed here.

## Goals

- Model a project root as a host-owned Workspace that can contain multiple Sessions.
- Make each new Session start with one Pi agent PTY and one shell PTY, with Pi on the left and the shell on the right.
- Give each Session its own stable Pi conversation binding, even when several Sessions share a Workspace root.
- Let users add and remove shell panes without changing another Session's state.
- Restore the desired Workspace/Session/Pane graph and Pi conversation after daemon restart without replaying prompts or shell input.
- Keep the Mac app and browser Workbench as clients of Axod-owned session state.
- Keep project paths and Pi history local to the owning host; do not persist terminal input/output in cloud storage.

## Non-goals

- Replacing Pi's interactive TUI with an Axo-authored chat UI or adopting Pi RPC mode as the initial agent presentation.
- Reimplementing Pi history, branching, compaction, model selection, or tool execution inside Axod.
- Automatically retrying a prompt, tool call, or unfinished agent turn after restart.
- Synchronizing project files or Pi history across hosts.
- Persisting terminal output or shell command history as session recovery data.
- Changing production Cloudflare Access controls, adding Cloudflare Sandbox hosts, or making the cloud an execution owner.
- Silently deleting existing local sessions or treating a missing Pi history file as permission to create a new conversation.

## Guide-level explanation

### Mental model

A Workspace is a project on one host. A Session is one independent agent-led thread inside that project. A Pane is a stable, role-bearing surface backed by a PTY.

```text
Workspace (host-local project root)
  Session A
    Pi agent pane  |  terminal pane  |  optional additional terminals
    Session A layout and Pi conversation
  Session B
    Pi agent pane  |  terminal pane  |  optional additional terminals
    Session B layout and a different Pi conversation
```

A new Workspace creates its first Session. **New Session** within a Workspace creates another Pi-plus-shell pair using the same project root but a different Pi conversation. The default layout is a rightward split with the agent first/left and the terminal second/right. Each Session owns its layout; changing one does not affect its siblings.

Closing the agent through Axo closes that Session and its terminal panes, but leaves the Workspace and its other Sessions intact. The Pi conversation file remains available. Removing a terminal pane removes only that pane, and the Session cannot be left open without its required terminal pane.

### Example: two sessions in one project

1. The user creates a Workspace for `/projects/axo`. Axod creates the Workspace and its first Session as one logical operation.
2. Axod starts Pi and a shell in that project root and stores the default split.
3. The user chooses **New Session** in the Axo Workspace. Axod creates a second Pi pane with a different Pi session binding and a new shell, both rooted at `/projects/axo`.
4. The two Pi conversations are independent. A daemon restart restores each against its own exact Pi session file; it never chooses the most recent conversation for that directory.
5. Closing Session A's agent closes Session A only. Session B and the Workspace remain open.

## Reference-level explanation

### Architecture and boundaries

- **Axod (Rust):** authoritative Workspace/Session/Pane desired state, SQLite migrations, stable IDs, layout, Pi conversation binding, PTY ownership, startup/restart reconciliation, and local RPC.
- **Pi CLI and public extension APIs:** Pi's interactive TUI, agent runtime, and canonical JSONL conversation history. Axod does not parse terminal output to infer Pi state.
- **Shared contracts (`packages/axo-api`):** validated Workspace/Session/Pane and control/observation records, schema fixtures, and compatibility negotiation.
- **Mac app:** Workspace/project selection, Session navigation, pane layout and terminal presentation, and user input. It does not orchestrate separate shell and Pi startup calls.
- **Relay and browser Workbench:** discover and control the same host-owned Sessions. Remote metadata excludes absolute project paths, Pi files, transcripts, and terminal bytes.

The initial Pi surface remains the real interactive `pi` CLI in a daemon-owned PTY. Axod resolves the globally installed executable and starts it with the Session's working directory and user configuration. A structured Axo extension/control channel can expose exact Pi identity, status, title, and later supported send/steer/cancel/answer operations. It must use public Pi extension APIs and exact Session/runtime bindings; terminal scraping is not a control API. Pi RPC mode remains an alternative only if Axo later deliberately replaces Pi's TUI with a custom client.

### Data model and interfaces

Conceptual records (exact SQLite names and wire names are implementation details):

- `Workspace`: stable ID, owning host, local root directory, display metadata, lifecycle, and references to its Sessions.
- `Session`: stable ID, Workspace ID, lifecycle, display metadata, Pane records, layout, and one Pi binding.
- `Pane`: stable pane ID, Session ID, closed role (`pi` or `shell`), desired lifecycle, and role-specific launch/runtime metadata.
- `Pi binding`: exact Pi session ID and canonical session-file location, stored only on the owning host. The Pi JSONL remains Pi-owned and is not copied into Axod's database.
- `Layout`: a bounded split tree whose leaves reference pane IDs. Every present Pane occurs exactly once; it is not inferred from pane creation order.

Required open-Session invariants:

1. Exactly one present Pi pane and at least one present shell pane.
2. At least two present panes/PTYs when the Session is ready.
3. Pane IDs are unique and all layout leaves refer to panes in that Session exactly once.
4. Each Session's Pi binding is distinct, including within one Workspace. A host's path is not an identity for a Pi conversation.
5. Workspace root paths and Pi history paths are local-only. Account/relay snapshots may publish Workspace and Session labels, role-bearing pane IDs, layout, and bounded status, but never absolute paths or history content.

Workspace creation and its first Session are accepted as one backend graph operation; a follow-up client request must not be required to launch Pi or create the first shell. Creating a Session in an existing Workspace similarly creates the Pi and shell pane intents, default layout, and operation record atomically. Readiness may be `materializing` or `blocked`; a partial startup must not be reported as ready.

### Pi session continuity and control

Pi supports explicit session selection (`--session <path|id>`) and exact session IDs (`--session-id`). Axod must persist the actual binding for the first launch and use that binding on subsequent launches. It must not use `--continue` as a Workspace-level selector: multiple Axo Sessions may share a working directory. `--session-id` creates a session when the ID is absent, so after a binding has been committed, a missing file is an error/blocked state—not permission to silently create a fresh conversation.

A restart recreates PTYs and loads the same Pi history, but does not restore the previous terminal screen or active process execution. A new shell starts in the Workspace root; `cd` state and shell input are not recovered. The Pi transcript is the only conversation recovery source. The system must not replay a submitted prompt or tool call to approximate continuity.

Pi and Axod must not concurrently write one conversation. Before starting a replacement Pi process, Axod must establish that the previous writer is gone or that an explicit ownership/fencing mechanism makes replacement safe. If daemon-crash recovery cannot prove this, the Session is blocked pending reconciliation; it must not start a second Pi writer. The recovery spike and acceptance tests must determine whether Axod's current PTY/process-group ownership is sufficient or needs a dedicated process/writer lease.

### Lifecycle and failure semantics

- **Create Workspace:** validate and canonicalize a user-selected directory; atomically persist Workspace plus its first Session, Pi pane, shell pane, and layout before materialization.
- **Create Session:** persist an independent Session/Pi binding and initial shell pane in the selected Workspace, then materialize both panes under the original operation.
- **Add/remove terminal:** add a shell pane at the Workspace root and update layout; removing a terminal cannot remove the final required shell pane.
- **Close agent in Axo:** archive/close that Session, terminate its owned panes, and preserve the Pi conversation file. Sibling Sessions and the Workspace remain unchanged.
- **Unexpected Pi exit:** do not treat process exit as explicit Session closure. Reconcile the exact saved Pi binding only after writer ownership is safe. The behavior of a user entering Pi's own `/quit` command is an unresolved interaction detail.
- **Daemon restart:** restore Workspace/Session/Panes/layout, create replacement shells, and resume Pi by its exact saved binding. Never duplicate a possibly-live Pi writer or replay work when previous ownership is uncertain.
- **Pi missing or invalid:** mark the agent pane/Session blocked with a bounded reason. Do not silently substitute a shell or new Pi conversation.
- **Terminal bytes:** remain transient. A daemon restart creates a fresh terminal screen; no cloud or local database transcript of terminal output is implied.

### Invariants

- Axod is the only authority for desired session topology and local PTY ownership; the frontend does not sequence shell and Pi startup.
- Pi remains the only writer/authority for canonical conversation history.
- Every open Session has exactly one Pi pane and at least one shell pane; only an explicit Session lifecycle action removes the required agent.
- Every Session has one exact Pi history binding; missing evidence never means “continue latest” or “create a new chat.”
- Restart never resubmits prompts, tool calls, or shell input.
- A replacement Pi writer starts only after old-writer termination/ownership is proven.
- Absolute project paths, provider credentials, Pi transcript content, terminal input, and terminal output are never put in account/relay metadata or logs.
- Closing one Session never closes sibling Sessions in the same Workspace.

### Compatibility and migration

The current Axod SQLite schema is version 3 and stores shell-only sessions plus shell-ID layout. Current `axo.session.*`/`axo.shell.*` RPC and `packages/axo-api/src/v1.ts` host snapshots do not represent Workspaces or Pane roles. This is a coordinated model transition, not a UI-only change.

The migration must preserve existing open shell PTYs, their layouts, and retained rows. It must not automatically create Pi conversations in existing sessions, silently merge sessions based only on equal current directories, or discard shell-only work. A compatibility/conversion policy for these existing sessions must be decided before rollout. New Workspace/Session creation must use the new graph API; the client must not fall back to the old create-one-shell choreography when the daemon lacks the new capability.

### Security, privacy, and observability

The Pi executable and extension run with the user's local permissions and can access the Workspace and the user's Pi configuration. Axod must resolve `pi` safely in the LaunchAgent environment, pass arguments without shell-string interpolation, set the expected user home and Workspace working directory, and honor Pi's project-trust behavior rather than automatically approving project resources.

The Workspace path and Pi session-file path remain host-local and are excluded from remote snapshots. Provider credentials remain in Pi's existing user-managed credential storage. Structured logs may record opaque Workspace/Session/Pane IDs, lifecycle, readiness, and bounded failure categories; they must not include paths, prompts, transcripts, terminal data, or credentials.

### Rollout and validation

Implement in dependency order:

1. **Resolve behavior and recovery:** decide existing-session migration, Pi `/quit` versus Axo close behavior, and the hard-crash writer-ownership guarantee. Prototype global Pi resolution, exact session creation/resume, and abrupt daemon termination before committing to automatic restart semantics.
2. **Schema-first domain:** refine `packages/axo-api/src/state-contracts.ts` and `packages/axo-api/src/v1.ts`, add canonical JSON schemas/fixtures, and validate exact-one-Pi, at-least-one-shell, same-Workspace membership, and layout-leaf invariants. Keep host-local paths out of remote schemas.
3. **Axod persistence/materializer:** migrate SQLite transactionally; implement Workspace creation with its initial Session, Session creation, Pane add/remove, close semantics, safe Pi binding, process supervision, readiness, restart, and local RPC. Test migration against preserved shell-only records before switching clients.
4. **Mac workbench:** make Workspace/project selection primary, show multiple Sessions per Workspace, create the default agent-left/terminal-right pair, and route explicit close/add/remove actions through backend operations.
5. **Relay and browser Workbench:** publish role-bearing Workspace/Session/Pane metadata without paths; support selecting among Sessions in one Workspace and reconnecting to each Pane. Preserve account ownership and existing relay bounds.
6. **Acceptance and rollout:** run Rust/Bazel unit and restart tests, package/daemon integration tests, Pi CLI/extension tests, Mac UI tests, and browser acceptance. Exercise graceful and forced daemon restart with idle and active Pi turns; prove no duplicate writer and no replay. Deploy web changes after their validation and leave Cloudflare Access settings unchanged. Package the Mac app after validated Mac changes; packaging does not imply launch or install.

Rollback must preserve both Axod database contents and Pi history files. It must not re-enable old client choreography in a way that creates duplicate sessions or Pi writers.

## Drawbacks

- Workspace/Session/Pane semantics require coordinated changes across the Rust daemon, shared schemas, native UI, relay, and browser Workbench.
- Multiple sessions in one directory make implicit Pi `--continue` behavior unsafe; Axod must maintain exact Pi bindings.
- Restart recovery is more than respawning a process: Axod must prove exclusive writer ownership and distinguish desired Session closure from unexpected process exit.
- A host-local root path cannot be used by another host; remote clients can discover/control sessions but do not thereby gain access to project files.
- Preserving existing shell-only sessions without silently changing their behavior requires a deliberate migration/conversion path.

## Rationale and alternatives

### Proposed design

A host-scoped Workspace groups a project's local root and multiple independent agent-led Sessions. Each Session owns its agent, terminal panes, layout, and exact Pi conversation. This matches the user's project workflow while preventing two sessions in one directory from sharing whichever Pi session happens to be most recent.

### Keep sessions as arbitrary shell groups

This is the smallest code change, but it leaves project identity, agent role, conversation ownership, and session close behavior implicit. It does not provide safe Pi resume or multiple independent sessions within one project.

### Use Pi RPC mode and build an Axo chat UI

Pi RPC provides structured commands and events, but it replaces Pi's interactive TUI with an Axo-owned presentation layer. That is not necessary to get stable project sessions or limited structured control and would significantly broaden the initial implementation.

### Do nothing

Axo continues to restore generic shells and layouts but cannot guarantee an agent pane, associate a Pi conversation with an Axo Session, or group multiple independent sessions under one project.

## Prior art

- The shared Axo state contracts in `packages/axo-api/src/state-contracts.ts` already model workspaces, sessions, pane roles, Pi bindings, and chat operations. This proposal tightens their creation invariants and aligns Axod runtime ownership with those concepts.
- The current terminal backend in `crates/axo-server/src/session.rs` owns PTYs and shell layouts, but generic shell IDs do not yet express Pi agent identity or conversation persistence.
- Pi's public [CLI session options](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli.md#sessions) support exact session selection, while [Extensions](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md) provide public lifecycle and control APIs. Pi remains the conversation-history authority; Axo stores a binding, not a second transcript.

## Unresolved questions

### Before acceptance

- How should existing shell-only sessions appear after the schema migration, and how may users explicitly convert them without starting Pi unexpectedly or losing layout/process state?
- What is the required guarantee for forced daemon termination when a Pi process may outlive Axod? Which owner/lease mechanism proves a prior writer is gone before resume?
- Does invoking Pi's `/quit` close/archive the Axo Session, or is closing the agent exclusively an Axo workbench action?

### During implementation

- Exact SQLite tables and transactional migration from schema version 3.
- Exact global `pi` executable resolver and LaunchAgent PATH behavior.
- How Axod obtains and durably verifies the canonical Pi session ID/file on first launch before recording the binding.
- The first supported Axo-to-Pi control surface; shared contracts currently sketch send, steer, cancel, and answer, but implementation should be capability-negotiated.
- Workspace/session naming, rename precedence, and whether session working directories may differ from the Workspace root.

### Out of scope

- Sharing Workspace files between hosts, team workspaces, automatic git worktree creation, transcript synchronization, and persistent terminal scrollback.
- Replaying an in-progress model turn or shell command after a crash.
- Replacing Pi's interactive TUI with a custom Axo chat application.

## Future possibilities

A later version may add Workspace-level presentation preferences, richer Pi attention/status, or additional pane roles. These do not change the initial rule that each Session has one Pi conversation and one or more independent shell panes.
