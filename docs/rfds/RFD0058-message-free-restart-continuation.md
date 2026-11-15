# RFD0058 - Axo: message-free restart continuation

- Feature Name: `restart-continuation`
- Status: Implemented locally (unreleased; requires Pi SDK capability)
- Author: leostera
- Start Date: 2026-11-15
- Updated: 2026-11-15
- Document Type: Proposal
- Amends: [RFD0051](RFD0051-generated-axo-cli.md)

## Summary

Resume interrupted Pi work after a managed Pi or axod restart using a dedicated control operation. Do not append a fabricated user prompt or hidden custom message to trigger it. Retain the existing daemon-stop record identifying interrupted Sessions, replacing the current synthetic stop-notice prompt.

## Behavior before this change

`crates/axo-server/src/stop_notice.rs` constructs “the session was stopped … you may continue”; `sessions.rs::restore` sends that as a normal prompt for Sessions recorded working at graceful daemon shutdown. An ordinary Pi restart does not use this path. `pi-axo`'s `RemoteCommands.resume()` instead restores queued real prompts; it is not model-turn continuation.

Pi's low-level `Agent.prompt([])` starts a model run without a starting message. Its higher-level `AgentSession` owns prompt/tool preparation, event hooks, retry/compaction and settlement. The installed extension API does not expose a corresponding high-level operation. Add that operation rather than bypassing lifecycle logic or smuggling an empty custom message through it.

## Guide-level explanation

A working Session is restarted. Its replacement loads the same transcript, binds its authenticated bridge identity, and receives one `resumeTurn` control for that runtime. Pi prepares its normal prompt/tools, then runs with no added starting message. The agent sees its saved conversation and produces the next response; Pi does not automatically replay saved completed tool calls. New tool calls still use normal tool hooks and permission checks. Idle/new Sessions are not given invented work. Sleeping Sessions stay asleep unless an existing lifecycle action starts them.

## Reference-level explanation

- Pi SDK: a real message-free resume operation on `AgentSession`, exposed to extensions. A distinct before-agent-start trigger must preserve normal lifecycle hooks, model/tool preparation, abort handling, retry, compaction and settlement. Busy/empty contexts are refused or reported, not queued as fabricated messages.
- Bridge: typed `resumeTurn` action, bound to the current authenticated Session/runtime. Unsupported SDKs must explicitly refuse; no prompt/custom-message fallback.
- Daemon: retain a pending-resume intent only for interrupted work. Consume it once per replacement runtime after bridge readiness. A known busy response means existing work wins; an uncertain receipt is not blindly retried. Reconnection to the same runtime cannot produce another resume.
- A newly queued real prompt supersedes automatic recovery rather than producing two starts. Successful prompt admission publishes that supersession before returning; queued new work excludes the old working observation from shutdown/exit recovery. Pending user prompts retain their existing durable receipt semantics.
- Graceful axod recovery uses the stored interrupted list. Per-Pi restarts capture working state before shutting down the old process. User stops, Session close, idle sleep and fresh Sessions must not become resume intents.
- Explicit stop admission disarms recovery before stop I/O, even if its receipt becomes uncertain or is refused as stale. Late start/user-message events from the stopping run cannot re-arm it. Observed settlement/idle followed by new work, or a newly admitted real prompt, re-arms normal recovery. This deliberately favors not resurrecting work over speculative recovery after an uncertain stop.
- Restarting code must not re-execute saved completed tools. Any interrupted tool whose side effect is uncertain must remain uncertain, not become a silent retry.
- Stored daemon-stop serialization must remain readable across the 0.69 upgrade boundary. No new user/custom message is added merely to start continuation; ordinary system/tool declaration updates remain legitimate lifecycle metadata.

## Validation

Use fake providers and isolated Pi/daemon Sessions only. Check actual provider inputs and transcript entries: no synthetic user/custom trigger, no duplicate completed tool execution, one resume across duplicate readiness/reconnection, busy/queued prompt races, ordinary Pi restart, axod restart, and no resume for idle/stopped/new Sessions. Bound build/test parallelism; do not restart or prompt the person's active Sessions during validation.

## Implementation and validation results

- `session/pi.rs` owns typed pending/claimed/suppressed recovery state. Bridge readiness claims once before sending; repeated readiness cannot reclaim it. The catalog retains recoverable intent through another graceful shutdown before the replacement is ready. `ops::stop_turn` disarms before transport admission.
- `sessions.rs` consumes the existing compatible graceful-stop record but no longer sends a stop-notice prompt. Unexpected Pi exits capture last-observed working state for the next managed start. Abrupt axod crashes without a graceful-stop record are not recovered by this change.
- `pi-axo` delegates control to the SDK API, once per runtime, refusing busy/held-prompt or unsupported hosts without any fabricated-message fallback.
- The SDK prerequisite and exact source patch are preserved in [third_party/pi](../../third_party/pi/README.md). It is not installed or published automatically. Release remains gated on distributing a supporting SDK.
- Eight focused Bazel test targets pass, including real MCP/daemon/relay conformance and private daemon/Pi restart scenarios. This is not a full application release gate. Five new daemon lifecycle tests cover working/idle restart, new-prompt priority, consecutive graceful shutdowns and explicit stop before receipt; three recovery-state tests cover reconnect claims, late start events and old-runtime settlement.
- The selected SDK regression run passes 112 tests, including six new resume cases. The portable Axo real-SDK/socket/provider test passes against the patched source and checks one provider call, one original user message and zero custom-message triggers despite duplicate controls. The ordinary dependency also passes its explicit-unsupported branch.
- The logical admission model explores 117 states and checks two properties, plus randomized runs. It has no injected faults or locked source ranges; no crash/exactly-once proof is claimed. Installed Pi agents and the app/daemon were not replaced or restarted for validation.

## Drawbacks and alternatives

This needs a Pi SDK capability in addition to the Axo bridge change; release must not claim continuation works on an unsupported host. Continuing to send a stop-notice prompt is simple but fabricates user authority. A hidden custom trigger filtered out of context still fabricates a transcript message and is rejected. Calling the raw agent directly would bypass the session lifecycle and is rejected. Exactly-once external side effects across crashes are not promised.
