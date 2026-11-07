# axo-apps

The apps extension of axod (RFD0016, RFD0034): `axo.apps.*` on `axod.sock`. A Session's calls to
the account's apps (list, search, run, add, remove, log, sign-in) go up the relay unchanged, and
the account's answer or error comes back as is. A call is sent once; a dropped relay or a late
answer fails it as may-have-run. A caller that gives up stops the wait; the account's call runs on.

It holds no state and knows nothing of Sessions beyond checking that `sessionId` names one.

Tests: `bazel test //crates/axo-apps/...`; the Mac's half end to end in
`//crates/axod:conformance_relay`, and through the real Worker in
`//packages/axo-api-worker:relay_test`.
