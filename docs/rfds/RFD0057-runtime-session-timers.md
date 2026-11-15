# RFD0057 - Axo: runtime Session timers

- Feature Name: `runtime-session-timers`
- Status: Implemented (unreleased; axod 84)
- Author: leostera
- Start Date: 2026-11-15
- Updated: 2026-11-15
- Document Type: Proposal
- Amends: [RFD0015](RFD0015-sessions-as-axo-clients.md), [RFD0050](RFD0050-codemode-run-limits.md)

## Summary

Expose `self()`, `sendAfter(...)` and `sendInterval(...)` through the Session MCP server, plus timer listing/cancellation. axod owns bounded in-memory timers, not an agent's codemode execution or MCP connection. The user explicitly rejected restart persistence: every timer disappears when axod restarts. Ordinary prompt provenance, queue limits and rate limits apply at each firing.

## Guide-level explanation

`self({})` returns `{sessionId}` for the calling Session, not the selected UI row or Pi transcript ID. `sendAfter({sessionId:"self",text:"Check the build",delayMs:60000})` schedules one message; `sendInterval({sessionId:"self",text:"Check progress",intervalMs:60000})` schedules recurring messages. Omitting sessionId targets self. Both return a timer ID, not a delivery acknowledgement. `session_timers({})` lists only this Session's timers; `session_cancel_timer({timerId})` closes future admission. A send already claimed, queued or delivered may still arrive: cancellation is not message retraction. The cancel receipt’s `inFlight` describes a pending admission/receipt, not whether an already accepted message is still queued.

## Reference-level explanation

- Local RPC: `axo.session.timer.create`, `.list`, `.cancel`. The create request has target `sessionId`, required sender `fromSessionId`, bounded prompt text, delivery and tagged timing. MCP always injects the calling Session as sender/owner, ignoring supplied provenance. self is answered from this bound context. whoami remains available for the fuller record.
- Product limits: 128 timers per daemon, 32 per sending Session; prompt text remains at most 16000 UTF-8 bytes. One-shot delays are 1 ms–30 days; intervals 1000 ms–24 hours. Values outside bounds, blank text, unknown fields and interrupt delivery fail before admission. These are resource policies, not claimed platform limits.
- Defaults: followUp delivery; steer and turn are explicit alternatives. Timers never claim human origin, request interrupt authority, type terminal input or bypass tool approvals. The existing 30 messages/minute per sender and 10/minute to self apply to timer and immediate messages together.
- Only open local Sessions can own/receive a timer. Closing either Session cancels related timers; daemon shutdown cancels all. Sleeping Pis may wake through the normal prompt path. No Session is unarchived automatically.
- At most one firing per timer is claimed at a time. Deadlines are monotonic. After a delayed wake or slow firing, advance to a future deadline instead of replaying missed ticks. No retries of the same occurrence; an uncertain send stops recurrence. Definitive busy/queue refusals may skip that occurrence and continue at the next future tick. Rate-limited intervals wait at least the existing limiter’s sixty-second window, not one rejection per short tick.
- A mutex owns admission, capacity, waiting/sending/cancelling state and cancellation signals; no await occurs under it. Cancellation retains the slot until the task retires. A claimed send can complete after cancellation; after ten seconds without a receipt it is marked uncertain and recurrence closes, but the scheduler keeps owning its future and slot until the admitted Session operation actually returns. A queued operation may still arrive later. The scheduler never retries or resumes that uncertain interval.
- Timer tasks use weak Core references while waiting, preventing a daemon ownership cycle. Creation survives a lost receipt because the daemon has admitted it; a caller should list before uncertain creation retries. Active entries expose owner/target/timing/state/last outcome, not message text. Finished one-shots and retired/cancelled timers leave the active list; this is not a durable execution-history API.
- Same-user local RPC trust remains as in RFD0015: it is not tenant isolation. MCP binds provenance and owner; raw local clients already have the local prompt capability. Timer methods are deliberately local-only; CLI parity records that decision rather than inventing remote scheduling.

## Invariants and validation

Protocol tests cover bounds, unknown fields, delivery choices and identifier parsing. Scheduler tests cover capacity/ownership, cancellation before firing, cancel-vs-claim, retirement, one-shot completion, interval skipping and unknown-outcome termination using private fixtures. MCP tests cover exact tool schemas, self resolution, forced provenance and timer ownership. Black-box daemon conformance exercises all advertised methods without production Sessions. The bounded Feynman model `specs/setup/session-timers.ts` covers claim/cancel/retire interleavings; it does not prove OS timing, restart durability or external exactly-once effects. Its source range is not in the global Feynman lock; no locked-source proof is claimed.

Validation performed: all 82 Bazel test targets pass. The bounded model explores 56 states and checks four properties, without fault injection or locked-source claims. Tests use private daemon/Session/Pi fixtures; no production Session was prompted or app/daemon restarted.

## Drawbacks and alternatives

Timers can wake agents and consume tokens; finite capacity and shared rate limits bound admission, not user spending. A daemon restart loses every timer intentionally. A persistent job table, cron/calendar scheduling, cross-host delivery and message retraction are out of scope. Keeping a codemode call alive or leaving an unawaited promise would violate its bounded-run contract and lose ownership when that call ends. A separate detached shell timer would be harder to inspect and cancel.
