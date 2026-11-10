# RFD0042 - Axo: the relay and the extensions on axod's runtime, with no blocking bridges

- Feature Name: `async-relay-and-extensions`
- Status: Accepted
- Author: leostera
- Start Date: 2026-11-10
- Updated: 2026-11-10
- Document Type: Proposal
- Amends: [RFD0041](RFD0041-axod-session-tasks.md) (finishes "one runtime, no bridges"), [RFD0037](RFD0037-axod-reactive-core.md) (the relay's threads), [RFD0029](RFD0029-ask-the-person.md) (how a question waits)

## Summary

RFD0041 made axod's core async. Around it, the relay, the questions, apps, assets and computer-use extensions, and the MCP server's tools still run as blocking code, reached through bridges: `spawn_blocking` to call a synchronous trait, which `block_on`s or `call_blocking`s back into the async core. This change removes the bridges. `RelayHost` becomes async, so the relay calls axod's methods directly. The relay's own requests to the cloud become futures, and so do its jobs, the sync uploader and the peers link. Every method axod serves is async, and a question waits on a future, not a thread. The blocking pool is kept only for work that really blocks: Cua's macOS calls, the computer-use gate's word list and model, and hashing a large transcript.

The wires stay as they are: the relay protocol, every RPC method, the attach protocol and the bridge protocol.

## Motivation

0.47's outage came from this shape. One blocking read on a runtime worker held up the relay's task, which stopped heartbeating, and the Mac went offline while axod said it was connected. The read itself is fixed, but the relay is still built from the same pieces. Every hop is a thread that can be held:

- **`RelayHost` is synchronous** (18 methods). The relay calls it from `spawn_blocking` (9 places). axod implements it with `call_blocking` (10) and `Handle::block_on` (2). A phone's prompt goes async loop → blocking thread → `block_on` → async handler → back.
- **Requests to the cloud block a thread until the answer comes.** `RelayChannel::request` waits on an `mpsc::recv_timeout`. That covers the uploader, `axo.apps.*` forwarding, sharing a conversation, and asking the person on the phone.
- **A question holds a thread for as long as it is asked.** `axo-questions` waits on a channel for up to the question's timeout, which is minutes. Each pending question is one blocking-pool thread.
- **Extension methods are blocking handlers** (questions 3, apps 1, assets 1, computer use 2, axod's own 6, MCP 3), run through `add_blocking_method`. That function, and the thread-locals that carry the caller and cancellation onto the blocking thread (`peer::on_this_thread`, `cancel::on_this_thread`), exist only for them.
- **Jobs are threads.** Prompts, computer calls and sign-ins from the cloud each run on `spawn_blocking`. The sync uploader runs every turn there.
- **The peers link** is a mutex, a condvar and `mpsc` channels. `Peers::watch` and `Peers::command` in axod block on them.
- **HTTPS outside the WebSocket** (pairing, linking, fetching assets) uses `native-tls` on a `std::net::TcpStream`.

## Guide-level explanation

Nothing changes for a person. For axod:

- A request from the phone or the web is answered by the same async methods the Mac app calls, on the relay's task, with no thread in between.
- Asking the person a hundred questions costs a hundred futures, not a hundred threads.
- axod at rest runs the runtime's workers, its main thread and FSEvents, and nothing else. Threads appear on the blocking pool only while Cua or the local model works, and go away after.

## Reference-level explanation

### The relay

- **`RelayHost` is async.** Each method returns a boxed future (`Pin<Box<dyn Future + Send + '_>>`), as `next_remote_events` already does, so the trait stays object-safe without a macro crate. `HostLinkStore` likewise. axod's adapter awaits the store (`store.call`) and calls its methods directly. `answer_remote` awaits `IoHandler::handle_request` with the relay as the peer, on a task-local, with no `block_on`.
- **`RelayChannel` requests are futures.** Each pending request is a `oneshot` keyed by id. `request(..).await` races the answer, its timeout and the caller's cancellation (`axo_ipc::cancel`), so `request_abandonable`'s callback goes away. `notify` and `reply` stay non-blocking sends.
- **Jobs are tasks.** A prompt is a task awaiting `answer_remote`. A computer call is a task that awaits the gate and the person's answer; only `axo_computer::call` and the gate's judge run on the blocking pool. Bash is already async. A sign-in's loopback listener becomes a `tokio::net::TcpListener`. The per-kind limits stay (`MAX_COMPUTER_JOBS`, `MAX_SIGN_INS`), as semaphores.
- **The uploader is async.** It reads transcripts with `tokio::fs` and awaits its requests. A turn that must hash more than one read buffer of a large transcript hashes on the blocking pool; nothing else does.
- **The peers link** keeps its state behind a `watch` channel, and a command's answer comes back on a `oneshot`. axod's `Peers::watch` and `Peers::command` are async.
- **HTTPS** (pairing, link, assets) runs on `tokio::net::TcpStream` with `tokio-native-tls`, which the WebSocket already depends on.

### The extensions

- **Every method is async.** `axo-ipc` keeps `add_typed_async` and `add_typed_only_async`, renamed `add_typed` and `add_typed_only`. The blocking variants, `add_blocking_method` and the thread-local hand-offs go. A handler that does nothing slow (listing pending questions) is an `async` block that never awaits.
- **Questions** wait on a `oneshot` raced with their timeout and the caller's cancellation. `MAX_PENDING` stays the limit, and it no longer counts threads. `QuestionsHost` and `ComputerHost` become async where they wait (`ask_with`); their lookups stay synchronous.
- **Apps, assets, share**: `axo.apps.*` forwarding and sharing await `RelayChannel::request`; `axo.assets.fetch` awaits the async HTTPS client.
- **Computer use, local and remote**: the gate (`check`, `remember`) and `axo_computer::call` run on the blocking pool, awaited; everything around them is async. The side-car client (`axod-infer`) speaks HTTP over `tokio::net::UnixStream`, and waits for a cold start on its `notify` watch as a future.
- **MCP**: tool calls already run as tasks; the three blocking handlers become async like the rest.

### What goes

`call_blocking` and the store's runtime handle, every `Handle::block_on` outside `main` and tests, `add_blocking_method`, `peer::on_this_thread`, `cancel::on_this_thread`, `RelayChannel::request_abandonable` and `Abandon`, the `mpsc` waits in `outbound.rs`, `peers/live.rs` and `axo-questions`, the peers link's `Condvar`, and the blocking `OutputSubscriber::next`, `Exit::wait` and `Exit::wait_until` once nothing calls them.

### Tests

- **First, separately: port the unit tests RFD0041 dropped** that still describe behaviour (from `git show e41018e:crates/axo-server/src/session/...`): terminal attachments, prompts and provenance, readiness, stop notices, transcripts, peer views, remote methods. Takeover tests are obsolete and stay deleted. This is a commit of its own before the change, so the change is checked against them.
- **The contract:** `//crates/axod:conformance_relay`, `conformance_elicitations`, `conformance_mcp`, `conformance_account`, `rpc_tests`, the relay's end-to-end tests (`axod-relay`, `phone-path`, `apps-e2e`, `axod-peers`, `attachments-e2e`, `elicitations-e2e`), and `AxoClientDaemonInteropTests`.
- **New:** asking many questions at once does not grow axod's threads; a slow method answered through the relay does not delay the relay's heartbeat; a request whose caller gives up stops waiting at once.

## Drawbacks

- One large change again. As with RFD0041, the wires do not move, and the integration suites carry it.
- Boxed futures in `RelayHost` cost an allocation per call. That is noise next to a network round trip.
- `tokio::fs` itself runs on the blocking pool. A transcript read is short, and is still no thread waiting on the network.

## Rationale and alternatives

- **Keep the bridges and harden them** (timeouts on every `block_on`, a dedicated runtime for the relay). Rejected: a second runtime is what RFD0041 removed, and every bridge is a place a held thread stalls a task.
- **`async_trait`.** Boxed futures written out keep the trait readable without a proc macro, and there are few implementors (axod's adapter and the relay's test hosts).
- **`hyper` or `reqwest` for HTTPS.** Three small requests do not need an HTTP stack; `tokio-native-tls` on the existing request code is enough.

## Unresolved questions

- Whether Cua's calls can be made async upstream; until then they stay on the blocking pool.
- The relay's periodic resets (a TCP reset without a WebSocket close every 30 to 60 minutes per socket) are unrelated, and are investigated on their own.
