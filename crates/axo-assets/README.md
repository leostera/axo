# axo-assets

The assets extension of axod (RFD0030, RFD0034): `axo.assets.fetch` on `axod.sock`, answered only
to axod's own binary (`axod mcp`), which shows the agent the images a script returned.

Assets live in the account. The relay fills the shared `AssetSlot` with this Mac's way to them
when it connects and empties it when it drops; a fetch while offline fails at once.

Tests: `bazel test //crates/axo-assets/...`; who may call it in `//crates/axod:conformance_account`.
