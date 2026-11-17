# RFD0066 - Axo: Mac pins prevent idle sleep

- Feature Name: `mac-pins-prevent-idle-sleep`
- Status: Implemented
- Author: leostera
- Start Date: 2026-11-17
- Document Type: Implementation design
- Amends: [RFD0045](RFD0045-idle-pis-sleep.md)

## Summary

Only a conversation pinned in Axo on the Mac which runs it is exempt from axod's idle
timeout and idle-count limit. Phone, iPad, web and other Macs' pins do not count. There is
no synchronization protocol, new database state, or migration.

## Guide-level explanation

Pin a conversation on its host Mac to keep its already-running Pi from being put to sleep
by the idle governor. Unpin it to restore the existing timeout and count rules on the next
scan. Pinning does not send a prompt, start an absent Pi, revive a Pi already asked to exit,
prevent explicit Stop/Close/Restart, or keep macOS itself awake.

The existing Mac sidebar preference survives app and daemon restarts. Axo need not remain
open. Pins elsewhere remain local presentation preferences.

## Reference-level explanation

The governor reads `sidebar.pinnedSessions.v1` in the existing `dev.leostera.axo`
application preferences through public Core Foundation preferences APIs. Refresh before
reading, parse a bounded array of Session UUID strings using the Mac's existing 256-pin
capacity, and ignore stale non-UUID strings as the Mac does. Never write these preferences
from axod. Other operating systems have no Mac-local pins and retain the existing policy.

Exclude pinned IDs before collecting idle candidates, so they are neither timed out nor
counted toward the idle-count limit. Refresh again after candidate selection, immediately
before each sleep admission; do not reuse a pre-pin scan. The Session task still checks
current activity before asking Pi to exit. A preference write is not a daemon acknowledgment:
this does not reverse a sleep admitted before a pin was observed.

Native preference reads run on the blocking pool, outside Session actors, with a two-second
deadline and one owned reader slot per daemon. A timed-out reader keeps its slot until it
actually returns, preventing accumulating blocked workers. On read failure, malformed
preference shape, or reader saturation, skip sleep rather than assuming no pins. Log the
failure category, not pin lists or preference contents.

## Validation

Isolated fake-Pi scenarios exercise zero timeout/zero idle limit with pinned and unpinned
conversations, unpinning, a pin arriving after candidate selection, and preference read
failure. Native parsing tests use synthetic CF objects. Test cores inject empty/read-controlled
sources and never read personal preferences or use live conversations as fixtures.

## Alternatives and costs

Cross-device pin unions were initially considered and explicitly rejected by the person:
only pins on the host Mac count. A new local RPC/database pin store would duplicate the
already-durable Mac preference. Direct preference reads add a small platform dependency;
the reader is isolated and fails safely. Future pin preference key or application-identity
changes must update the reader alongside the Mac app.
