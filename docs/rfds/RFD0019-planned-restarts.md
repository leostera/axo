# RFD0019 - Axo: planned restarts

- Feature Name: `axo-planned-restarts`
- Status: Draft
- Author: leostera
- Start Date: 2026-10-31
- Updated: 2026-10-31
- Document Type: Proposal
- Amended By: [RFD0031](RFD0031-durable-objects-wake-on-demand.md)

## Summary

I propose that when axod is restarted on purpose (an upgrade, or the person asking Axo.app to restart it), clients see a planned restart instead of an outage.

Four changes make that happen:

- **Axo.app says why.** Before it has launchd restart axod, `DaemonController` calls a new axod method, `axo.daemon.prepareRestart { reason, toBuild }`.
- **axod says goodbye.** On SIGTERM, axod sends `axo.host.leaving { reason, toBuild }` on the host socket and then closes it with WebSocket code 1012 (Service Restart). Without a prepared restart, the reason is `stop`.
- **The HostDO keeps a third presence state.** A host is `online`, `restarting` or `offline`. `restarting` carries the reason and the build the host is moving to. It lasts until the next generation registers, or until a 60-second grace period runs out. Prompts sent meanwhile are told to wait, and a prompt that was in flight is reported as interrupted by the restart, not as "outcome unknown".
- **Clients say so.** The web app shows "Studio is upgrading to build 250…" and then "Studio · build 250", keeps the chat open, and keeps the unsent text. The phone does the same.

A Feynman spec, `specs/relay/planned-restart.ts`, models the design. Its properties hold, and each of its three rules is needed: without any one of them, a property breaks.

## Motivation

On 2026-10-31 at 03:55, build 250 of Axo.app was installed. At 03:58:47 the running Axo.app (build 249) got a Quit Apple Event and terminated cleanly. The new app started, found axod 249, and restarted it with `launchctl kickstart -k`. axod came back at 03:59:13 as a new generation, and every Pi Session was restored.

Nothing failed. In the web app, it looked as if everything had:

- The Mac went **offline**. `AxoHostRelay.webSocketClose` handles axod's socket closing exactly like a crash: `drop` → `fence` → `broadcastHostPresence(…, "offline")` (`packages/axo-api-worker/src/axo-host-relay.ts`). The HostDO clears every progress snapshot and agent status (`AxoHostDO.presenceChanged`).
- The composer locked with "Studio is offline" (`packages/axo-web-app/src/chat/conversation.tsx`).
- A prompt in flight failed with `-32004 Outcome unknown; reconcile commandId` (`AxoHostDO.fence`).
- Working agents stopped. axod's shutdown stops every pane (`SessionManager::shutdown`), and the new axod restores them (`restore_open_sessions`). The turns that were running are cut off.
- Then the Mac came back, with nothing saying why it had left.

The cause is that nobody on the path knows the restart is planned:

- `DaemonController.checkBuildAndRestartIfNeeded` knows it is an upgrade from 249 to 250, but only tells launchd.
- axod gets a bare SIGTERM. `request_shutdown` sets a flag, the relay worker stops, and the socket closes with no frame (`crates/axo-server/src/lib.rs`, `crates/axo-relay/src/relay.rs`).
- The HostDO sees a socket close and can't tell an upgrade from a kernel panic or a lost Wi-Fi network.

Upgrades are frequent while Axo is developed, so this is the most common way a client sees the Mac drop. It trains people to read "offline" as nothing, and makes real outages harder to notice.

## Goals

- A client can tell a planned restart from an outage, and can name the reason ("upgrading to build 250", "restarting").
- A prompt sent during a planned restart says to wait, and keeps its text.
- A prompt in flight when the restart starts is reported as interrupted by the restart, with a pointer to the transcript, never as "outcome unknown".
- A planned restart that doesn't finish turns into a plain `offline` after a bounded time.
- An unplanned stop (a crash, a lost network, a lost goodbye) still looks like one.
- A late goodbye from an older generation can't undo a newer generation's registration.

## Non-goals

- **Keeping agent turns alive across a restart.** axod still stops Pi on shutdown. Waiting for idle agents before an upgrade is discussed under Unresolved questions.
- **Restarting Pi without restarting axod**, or upgrading axod without a restart.
- **Announcing Worker deploys.** HostDO and ClientDO evictions are RFD0018's, and they heal through reconnects.
- **Queueing prompts** until the host is back. RFD0018 rejected this for offline hosts, and the same reasons apply here.
- **Telling clients ahead of time** ("Studio will restart in 5 minutes"). An upgrade starts as soon as the new app is launched.

## Guide-level explanation

### Vocabulary

- **Generation:** one run of axod, from start to exit. Each start gets a new `hostGeneration` (`crates/axo-server/src/session.rs`). The cloud already fences commands by generation.
- **Planned restart:** axod is stopped by Axo.app on purpose, knowing it will start again, either for an `upgrade` (another build) or a `restart` (the person asked).
- **Stop:** axod is stopped with no restart prepared: logout, shutdown, `launchctl bootout`. It isn't expected back soon.
- **Drop:** axod's socket closed without a goodbye: a crash, a lost network, or a lost goodbye.
- **Grace period:** how long a host may stay `restarting` before it counts as `offline`: 60 seconds.

### An upgrade, as the person sees it

Alice has the web app open on a chat with Studio. She installs build 250 on Studio.

1. Within a second, the Mac's dot turns blue and the chat header reads **"Studio is upgrading to build 250…"**. The chat stays open. The composer keeps what she was typing, with "Studio is upgrading. Send once it's back" in place of the send button.
2. About 20 seconds later the dot turns green: **"Studio · build 250"**. A short note in the chat says "Studio restarted for an upgrade to build 250."
3. If an agent was in the middle of a turn, the note adds: "The agent's turn was interrupted. Ask it to continue."

What she never sees is "Studio is offline".

### A prompt in flight

Alice sends a prompt just as the upgrade starts. Two things can happen:

- **The prompt reaches the agent before axod stops.** It is accepted as usual. The turn is then interrupted by the restart, as above.
- **axod's goodbye arrives first.** The prompt fails with "Interrupted by Studio's restart. Check the chat before sending again." The text goes back into the composer. If she sends again while Studio is restarting, she's told "Studio is restarting; try again in a moment", and nothing is sent.

### An upgrade that doesn't come back

If build 250 fails to start, the header reads "Studio is upgrading to build 250…" for 60 seconds, then "Studio is offline", with the last-seen time, as today.

### A crash, or a lost network

Nothing changes: the Mac goes offline at once, and a prompt in flight is "outcome unknown". Because upgrades no longer look like this, "offline" means something went wrong.

### Logging out

When Alice logs out of Studio, launchd stops axod without a prepared restart. axod's goodbye says `stop`, and the web app shows **"Studio was shut down"** with the time. That isn't an outage, and Studio isn't coming back on its own.

## Reference-level explanation

### Components and ownership

| Component | Owns | Changes |
|---|---|---|
| Axo.app (`DaemonController`) | when axod restarts, and why | calls `axo.daemon.prepareRestart` before `kickstart`, and before unregister/register |
| axod | the host socket and the goodbye | stores the prepared restart, says goodbye on SIGTERM, closes with 1012 or 1000 |
| HostDO | presence, per generation | `restarting` state, grace alarm, generation fencing, prompt outcomes, numbered presence notices |
| ClientDO | the tab's copy of presence | stores the restart fields, ignores older notices |
| Web app and phone | what the person sees | banner, composer, chat note, error copy |

### Preparing a restart: Axo.app → axod

A new method on axod's unix socket, beside `axo.daemon.health`:

```json
{ "method": "axo.daemon.prepareRestart",
  "params": { "reason": "upgrade", "toBuild": 250 } }
→ { "result": { "prepared": true, "generation": "6f0c…" } }
```

- `reason` is `upgrade` when `DaemonController.checkBuildAndRestartIfNeeded` restarts because of a build mismatch, and `restart` for `DaemonController.restartDaemon()` (an explicit restart).
- `toBuild` is the app's build number: the build launchd will start.
- axod keeps the latest prepared restart in memory. It isn't stored: a prepared restart belongs to the generation that received it.
- If the call fails or times out (axod is hung, which is often why it is being restarted), Axo.app restarts axod anyway. The restart then reads as a stop or a drop.
- A prepared restart that is never followed by SIGTERM is harmless. A later plain SIGTERM would read as planned, so the preparation expires after 30 seconds. `restartDaemon` sends SIGTERM within a second.

### Saying goodbye: axod → HostDO

When SIGTERM arrives, `request_shutdown` sets the flag as today. Before the relay worker stops, it sends one notification on the host socket:

```json
{ "jsonrpc": "2.0", "method": "axo.host.leaving",
  "params": { "hostId": "…", "hostGeneration": "6f0c…",
              "reason": "upgrade", "toBuild": 250 } }
```

Then it closes the socket:

- with code **1012** (Service Restart) for `upgrade` and `restart`;
- with code **1000** for `stop`.

The notification is the source of truth. The close code helps logs and tools, and covers a goodbye that doesn't parse. axod waits at most 500 ms for the close handshake, so shutdown time stays bounded.

The goodbye goes out before `SessionManager::shutdown` stops Pi. Clients therefore hear "restarting" before the Pi Sessions' last progress snapshots stop arriving.

### Presence in the HostDO

Presence becomes a state per host, with the generation it is about:

```text
           register(g)                  leaving(g, upgrade|restart)
 offline ─────────────▶ online(g) ───────────────────────────────▶ restarting(g, reason, toBuild)
    ▲                    │   │                                         │        │
    │   leaving(g, stop) │   │ socket closed, no goodbye (drop)        │        │ register(g' > g)
    │◀───────────────────┘   │                                         │        ▼
    │◀───────────────────────┘                                         │     online(g')
    │◀────────────────────── grace alarm (60 s) ───────────────────────┘
```

- **`leaving` is accepted only from the current generation, while it is online.** A goodbye from an older generation is ignored. A new axod's registration can overtake the old socket's goodbye, because they travel on different sockets.
- **Registration fences by generation.** A newer generation replaces a `restarting` or `online` older one. An older generation's registration is ignored.
- **The socket close that follows a goodbye is not a drop.** `webSocketClose` for a generation already `restarting`, or `offline` because it stopped, changes nothing.
- **The grace alarm** uses the HostDO's existing alarm scheduler (`AxoHostRelay.schedule`), as a deadline next to lease and pending deadlines.
- Progress and statuses are cleared when the host leaves, as today.
- Each generation's end (`planned`, `stopped`, `dropped`, `graceExpired`) is logged, not stored beyond the current one.

### Prompts during a restart

`AxoHostDO.command` and `callHost` gain two outcomes. They take the next free JSON-RPC error codes (-32004 to -32010 are taken):

| Situation | Today | Proposed |
|---|---|---|
| The host is `restarting` | `-32005 Host offline; nothing queued` | `-32011 Host restarting; nothing queued`, with `data: { reason, toBuild }` |
| A command is waiting for axod when the goodbye arrives | `-32004 Outcome unknown; reconcile commandId` | `-32012 Interrupted by a planned restart; check the transcript`, with `data: { reason, toBuild }` |
| A command is waiting for axod when the socket drops | `-32004` | unchanged |

`-32012` is no more certain than `-32004`: the prompt may have reached Pi. It says why, and clients word it so. RFD0016's connections calls (`callHost`) get the same two codes, so a script calling bash on a restarting Mac fails fast with a clear reason.

### Notices and the client contract

`HostNotice`'s presence notice gains the state, the restart and a sequence number:

```ts
{ kind: "presence", status: "online" | "restarting" | "offline",
  hostGeneration: string | null, seq: number,
  restart: { reason: "upgrade" | "restart", toBuild: number | null, since: string } | null,
  stopped: { at: string } | null }
```

- **`seq` increases with every presence change in the HostDO**, and is stored with presence so it survives eviction. The ClientDO ignores a notice older than the one it holds. A lease reply (`subscribe`) and a notice reach it on different calls, and either can arrive first. The spec found this.
- **The client schema (`clientHostSchema`)** replaces `online: boolean` with `status`, and adds `restart`, `stopped` and `presenceSeq`. Clients ignore an `axo.client.hosts` older than what they show. The ClientDO's socket is ordered, but its replay after a reconnect isn't guaranteed to be.
- **The phone** decodes the same fields (`apple/AxoPhone`), and the presence badge gets the third state.

### What clients show

| Presence | Dot | Header | Composer |
|---|---|---|---|
| `online` | green | "Studio · build 250" when the build changed during this visit, else "Studio" | enabled |
| `restarting`, `upgrade` | blue, pulsing | "Studio is upgrading to build 250…" | text kept, send disabled: "Send once it's back" |
| `restarting`, `restart` | blue, pulsing | "Studio is restarting…" | same |
| `offline` after a stop | grey | "Studio was shut down · 03:58" | disabled, as offline today |
| `offline` otherwise | grey | "Studio is offline · last seen …" | as today |

When a host goes from `restarting` to `online` while the chat is open, the chat shows a one-line note: "Studio restarted for an upgrade to build 250." If the open Session was `working` when the host left and is no longer working once the new generation reports it, the note adds "The agent's turn was interrupted." The open chat is never closed or deselected while the host is `restarting`.

### Failure semantics

| Failure | Behaviour |
|---|---|
| `prepareRestart` fails or times out | Axo.app restarts axod anyway. axod says goodbye with `stop`, and clients show "shut down" until it is back, then online |
| The goodbye is lost, or axod is killed before sending it | the HostDO sees a drop: offline, `-32004` for commands in flight. That's an outage as far as anyone can tell, which is honest |
| axod crashes after saying goodbye | the host is already `restarting`. launchd starts a new generation, and it registers |
| The new axod fails to start | `restarting` until the grace alarm, then `offline` |
| The new generation registers before the old goodbye arrives | the goodbye is from an older generation and is ignored |
| A presence notice is lost | the next lease renewal returns current presence (RFD0018) |
| Notices arrive out of order | `seq` drops the older one, at the ClientDO and at the client |
| The HostDO is evicted while `restarting` | presence, `seq` and the grace deadline are in SQLite, so the alarm still fires |
| Logout or shutdown | goodbye `stop`: `offline`, shown as shut down. No grace period |

### Invariants

The spec checks the first four as safety properties, and the last two as liveness:

1. **A planned stop never looks like a drop:** unless the network lost the goodbye, every generation axod stopped on purpose ends as `planned` or `stopped`, never `dropped` (`plannedStopsLookPlanned`).
2. **A planned restart is never shown as offline** before its grace period ends (`restartIsNeverShownOffline`).
3. **"Outcome unknown" needs a fault:** a prompt ends `-32004` only after a crash, a lost goodbye or a lost message. A planned restart says interrupted (`promptsDuringARestartSayWhy`).
4. **Presence never goes back:** a client never replaces a newer presence with an older one (`presenceNeverGoesBack`).
5. **Restarts end:** a `restarting` host ends up `online` again or, past the grace period, `offline` (`restartsEnd`).
6. **Clients catch up:** an open client ends up showing the HostDO's presence (`tabCatchesUp`).

### Observability

- axod: `event=daemon.restart_prepared reason=… to_build=…`, and `event=relay.leaving reason=… close_code=…`.
- Axo.app: the existing `event=daemon.restart_started` gains `reason`.
- HostDO (`recordApiEvent`): `host_leaving { reason, toBuild }`, `host_restarted { reason, downMs, fromBuild, toBuild }` when the next generation registers, `host_restart_expired { reason }` when the grace alarm fires, and `connection_closed` with the close code, as today.
- With these, "upgrades per day" and "time to come back after an upgrade" can be counted, and unplanned drops separated from planned ones.

## Security and privacy

- The goodbye comes over the host's own authenticated socket (RFD0013) and only changes that host's presence. A host could lie about its reason, but it can already go offline whenever it likes. The grace period bounds how long a false "restarting" can last.
- Build numbers are shown only to the account that owns the host. They reveal nothing beyond what the host reports at registration.
- `axo.daemon.prepareRestart` is on axod's unix socket (mode 0600), like every other local method.

## Rollout

Axo's clients ship with axod, and the same person deploys the cloud, so this is a cutover in four steps:

1. **Spec:** `specs/relay/planned-restart.ts`, done (see Testing).
2. **Cloud and web app, in one deploy:**
   - `axo-api` schemas: presence `status`, `restart`, `stopped`, `presenceSeq`, and the two error codes.
   - HostDO: `axo.host.leaving`, the `restarting` state, the grace alarm, generation fencing on `leaving`, and the stored `seq`.
   - ClientDO: stores and filters by `seq`.
   - Web app: dot, header, composer, chat note, error copy.

   The client schemas are `.strict()`, so a tab still running the old web app rejects the new host fields. `protocolVersion` is a literal, so the hello's version goes to 3 and an old tab is refused at negotiation. Today the web app has no answer to that refusal: it would keep reconnecting. Part of this step is that a refused hello reloads the page, so this and later protocol bumps reach open tabs.
3. **axod and Axo.app together:** `axo.daemon.prepareRestart`, the goodbye, and the close codes. The cloud from step 2 handles a host without them as today. Until this ships, every restart is a drop.
4. **Phone:** the same presence states. Until it ships, the phone shows `restarting` as offline. Swift's decoding ignores unknown keys, so nothing breaks.

## Testing

- **Feynman:** `specs/relay/planned-restart.ts` models Axo.app, launchd, axod, the HostDO, the ClientDO and a tab, with these faults: lost messages (including a lost goodbye), an axod crash, and a new axod that fails to start. It has five scenarios: an upgrade, a prompt during an upgrade, a crash, an upgrade whose new axod never starts, and a logout.
  - Without faults, the four safety invariants hold exhaustively to depth 14 (1.26M states).
  - With one fault, they hold on every path of up to 13 events (4M states). The spec's sequence number keeps states distinct, which limits the search.
  - The two liveness properties hold as far as the search reaches.
  - Rules: `announceRestart` is needed (without it, invariants 1 and 3 break in 3 and 11 events), `noticesInOrder` is needed (without it, invariant 4 breaks in 8 events), and `graceFallback` is needed (without it, invariant 5 breaks in 13 events).
  - The spec found that the ClientDO's lease reply can overtake a newer notice, and that the tab must also order what the ClientDO replays to it.
- **axod:** a relay test that SIGTERM after `prepareRestart` sends `axo.host.leaving` with the reason and closes with 1012, and that a plain SIGTERM sends `stop` and closes with 1000.
- **Axo.app:** `DaemonController` tests that a build mismatch calls `prepareRestart` with `upgrade`, and that a failed call still restarts.
- **Worker:** HostDO tests in `packages/axo-api-worker/tests`:
  - each transition;
  - a goodbye from an older generation;
  - the close after a goodbye isn't treated as a drop;
  - the grace alarm;
  - the `-32011` and `-32012` outcomes;
  - `seq` survives eviction.
- **Web:** workbench tests that a `restarting` host keeps the open chat and the composer text, and that `restarting` → `online` adds the note.
- **End to end:** the `axod-relay` e2e restarts axod with a prepared upgrade and checks that the client sees `restarting` and then `online`, and never `offline`.

## Drawbacks

- **A third presence state** that every client must handle. Code that tests `online` as a boolean has to change.
- **"Interrupted" is still uncertain.** It explains why, but a prompt may or may not have run, as with `-32004`.
- **A false sense of safety:** a restart that hangs shows "upgrading…" for up to a minute before it reads as offline.
- **More coupling:** Axo.app must call axod before restarting it, adding one more step to the restart path.

## Rationale and alternatives

### Do nothing

Upgrades keep looking like outages, and people learn to ignore "offline". That's the problem this RFD exists for.

### Infer the restart in the cloud

When a new generation registers within N seconds of a drop, show "Studio restarted" afterwards. This needs no axod change, but the person still sees "offline" during the restart, and a crash followed by launchd's restart would read as planned. It explains after the fact what this proposal shows while it happens.

### A close code alone

axod closes with 1012 and sends no notification. It's simpler, but a close code can't carry `toBuild`. Cloudflare's `webSocketClose` does report the code and reason, but the reason is limited to 123 bytes and is not structured. The notification is a few lines more and can say everything.

### Let axod decide alone

axod could learn that it is being upgraded from launchd's environment, or by comparing its own build with the bundle on disk at SIGTERM. Neither is reliable: the bundle may be replaced without a restart, and launchd says nothing about why it sends a signal. Axo.app is the one component that knows.

### Drain agents before upgrading

Wait for every Pi Session to be idle before restarting, as `axo.remote.session.pi.restart.auto` does for one Session. This keeps turns from being cut off, but an upgrade could then wait forever on a long turn. It is complementary and listed under Unresolved questions.

## Prior art

- **WebSocket close code 1012, Service Restart** ([IANA registry](https://www.iana.org/assignments/websocket/websocket.xml#close-code-number)): a server tells clients it is restarting and they may reconnect. That is exactly this, from the host's side.
- **HTTP/2 `GOAWAY`** and the **Discord gateway's `RECONNECT`** opcode: the peer says it is going away before closing, so the other side doesn't treat the close as an error.
- **Kubernetes `preStop` hooks and termination grace periods:** the orchestrator says why a pod is going away and allows a bounded time. The lesson for us is that the grace period must be bounded, and that the component that knows why (here, Axo.app) must be the one to say so.

## Unresolved questions

### Before acceptance

- **Is 60 seconds the right grace period?** axod took 26 seconds on 2026-10-31 (03:58:47 → 03:59:13), mostly restoring Sessions. A Mac with many Sessions may take longer.
- **Should an upgrade wait for idle agents?** For example, it could wait up to 2 minutes for working Sessions, and the person can always restart now. If so, Axo.app shows "Waiting for 2 agents to finish before upgrading" and clients could show "Studio will upgrade when its agents finish".

### During implementation

- The exact copy for the chat note and the composer, with the phone.
- Whether `presenceSeq` is per host, as proposed, or per account.

### Out of scope

- Announcing Worker deploys to clients.
- Restarting axod without stopping Pi.

## Future possibilities

- **Upgrade notes:** `toBuild` could link to what changed in that build.
- **Scheduled upgrades:** "Studio will upgrade at 03:00" for a Mac that installs builds automatically.
- **Pi that survives axod restarts:** if Pi runs outside axod's process tree, a planned axod restart would interrupt nothing, and `restarting` would only gate commands.
