# Choosing a coding harness for a cross-host fork (implementation contract)

Before enabling confirmation, call read-only `axo.remote.session.fork.plan` on the destination with `{target, sourceHostId, sessionId, epoch, head}` (same snapshot fields and account/generation routing checks as fork). Do not accept a client assertion about the source agent or format. Resolve both against the authenticated snapshot. No child, durable request claim, folder mutation, package install or agent launch during planning.

Successful result: `{sourceAgent, historyFormat, decision}`. The decision is exactly one of:

- `{kind:"keep", agent}`: agent equals sourceAgent and is runnable with a compatible importer.
- `{kind:"choose", agents:[...]}`: nonempty, distinct compatible alternatives, no implicit default. Even one choice requires an affirmative selection.
- `{kind:"unavailable"}`: no compatible runnable importer. Offer another host or cancel.

Unsupported/unknown snapshot or stale authorization is an error, not “harness missing.” Runnable means launchable on this host; compatible means the adapter can preserve history, append hidden destination provenance, and start idle without tool replay. A host's generic agent catalog cannot promise compatibility. A client must not interpret an old host's missing plan method as permission to try another harness.

Creation uses existing `axo.remote.session.fork` plus optional `agent`. Omitted always means preserve source; never silently change it. Explicit agent is bound to the exact operation payload (destination, snapshot, folder, agent, requestId). Atomically arbitrate duplicates. For a known request, verify matching identity/payload and replay its prior outcome, not current capability detection. For a new request, revalidate authorization, snapshot, destination generation, folder and selected adapter before creating or starting anything. Definitive harness rejection returns structured error data `{kind:"forkHarnessUnavailable", created:false}`; UI re-plans, does not send another fork automatically. Unknown post-dispatch outcomes keep their original request ID and never trigger fallback. A fresh choice or changed folder after definitive rejection gets a fresh ID.

Clients keep the source chat/draft selected until a confirmed child returns. GTK may explicitly offer **Open in web** for that returned child after success, using only an allowlisted first-party URL and validated host/session IDs. Never pass credentials in that URL. This does not establish native peer navigation.
