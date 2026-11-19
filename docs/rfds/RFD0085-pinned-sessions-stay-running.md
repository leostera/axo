# RFD0085 - Axo: pinned Sessions stay running

- Feature Name: `pinned-sessions-stay-running`
- Status: Implemented; not released
- Author: leostera
- Start Date: 2026-11-19
- Document Type: Policy
- Supersedes: the no-wake rule in [RFD0066](RFD0066-mac-pins-prevent-idle-sleep.md)

## Summary

A conversation pinned on its host Mac is an always-running Session, not merely exempt from future idle sleep. Start old pinned Sessions during daemon restoration, wake dormant pinned agents, and recover unavailable pinned agents on the bounded governor scan. Do not restart an already-running agent, fabricate a prompt, resume stopped work, or reopen an explicitly closed Session just because a stale pin remains.

## Guide-level explanation

Pin a local Session: its unavailable agent is started through the existing unavailable-only restart path. Axod keeps the agent available while the Mac app is closed. On daemon restart, even an old pinned Session starts normally rather than waiting dormant for a viewer. Unpinning restores ordinary timeout/count behavior; it does not itself kill a process. Explicit Session Close wins because closed Sessions leave the open registry. Explicit turn Stop remains a turn Stop: keeping a process available grants no authority to continue work.

## Reference-level explanation

Keep the existing host-local Mac sidebar preference, its parser, capacity and failure behavior. Do not synchronize phone/browser/peer-Mac pins, add a pin store, mutate preferences from axod, or keep macOS itself awake. Unknown IDs never create or reopen Sessions.

Restoration gives captured interrupted work its existing recovery priority; other pinned Sessions use the ordinary start mode, without a recovery notice. If pin preferences cannot be read, log the failure category and use existing activity-based restoration until a later successful governor scan; do not guess pins or start every old Session.

The governor reconciles pinned open Sessions before considering ordinary idle candidates. Session actors serialize admission: running/launching agents are unchanged, dormant/unavailable agents start, and an agent already exiting for idle sleep is marked to restart after that exit. Repeated scans cannot start another process while one is running or launching. A pin arriving after candidate selection is re-read before sleep, preserving the existing safeguard. An unavailable pinned agent may retry startup once per normal scan; failures do not spin or replay user messages. Stop/restart/close and pending-prompt/recovery safeguards retain their existing authority.

Mac pinning asks only its own host to start an unavailable agent, never a running agent or a peer's agent. The existing automatic-unavailable restart RPC checks current state again and cannot force-restart work. Axod remains authoritative for ongoing reconciliation when the app is absent. The governor scan remains bounded and pins remain excluded from timeout and idle-count accounting.

## Validation

Use isolated fake agents and private stores. Test startup of old pinned versus unpinned Sessions, pinning a dormant Session, recovering an unavailable pinned agent, pin arriving during idle shutdown, repeated reconciliation without another restart, unpinning, read failure and stale pins after explicit Close. Require no synthetic prompts or new turn starts. Never pin, restart or wake personal Sessions as a test.

## Drawbacks and alternatives

Pinned agents consume memory and may wait at their normal authentication/trust UI; availability does not mean model credentials are valid. Keeping only the old sleep exemption leaves the reported failure after daemon startup or prior sleep. UI-only waking fails while Axo is closed. A cross-client union would change the previously chosen host-local pin boundary and is not introduced. The guarantee depends on readable preferences and successful normal startup, not an exactly-once or crash-free process claim.
