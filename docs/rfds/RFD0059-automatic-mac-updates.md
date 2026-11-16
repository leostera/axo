# RFD0059 - Axo: opt-in automatic Mac updates

- Feature Name: `automatic-mac-updates`
- Status: Implemented (unreleased)
- Author: leostera
- Start Date: 2026-11-16
- Document Type: Proposal
- Amends: [RFD0048](RFD0048-release-artifacts.md) (installation consent)

## Summary

Add Settings → General → Updates → Automatically install updates, off by default. Opting in authorizes installing newly published verified releases and completing their app/daemon handover without a per-release confirmation. Turning it off revokes pending installation authority, not an already committed replacement.

## Motivation and guide-level explanation

A person who wants the newest release should not have to repeatedly review and install it. Enable the setting once; Axo checks at startup and about every minute while running and awake. Axo downloads a newer release, verifies it, replaces its bundle and restarts. Updates including a different axod build can restart terminals and Pi processes, interrupting active work. History remains; message-free continuation still requires the compatible SDK described by [RFD0058](RFD0058-message-free-restart-continuation.md). Do not promise uninterrupted work.

Disable the setting to return to review-before-install. Manual checks and their existing confirmations remain available regardless of the preference. Enabling the setting immediately requests a fresh publication check.

## Reference-level explanation

- Persist one opt-in preference locally; missing means false. Do not enable it in the installed app during development or migration.
- Keep ordinary background checks hourly when disabled; use a one-minute tick/check cadence when enabled. Sleeping/offline systems cannot observe a release immediately. No server push service is added.
- Only a successfully fetched manifest and a newer published candidate may initiate automatic installation. Cached publications, local/development bundle replacements, unsigned hosts and a visible manual review are not automatic-install authority.
- Reuse the exact immutable archive, same bundle/team signature validation, target selection and captured metadata checks. Automatic mode does not weaken verification.
- One coordinator owns an admitted attempt until it actually retires. Disable cancels its task and changes a consent generation. Re-enabling cannot revive its old authority; another attempt waits for retirement.
- Unpack, verify and stage before commit. Immediately before atomic replacement, on the main actor, check cancellation and current consent. That short check-and-swap cannot interleave with a setting change. Previous-bundle rotation runs afterward off the main actor; if rotation fails, retain the old bundle in the unique staging directory.
- Replacement is the point of no return. If disable races after a successful replacement, complete handover into that already-installed build; do not strand a new on-disk app behind an old running process. Cancellation is not rollback.
- No foreground progress panels or alerts for routine automatic downloads. Surface an actionable failure in Settings and structured upgrade logs. Failed attempts back off for fifteen minutes from failure, including long downloads; no overlapping or receipt-loss retries. Successful handover does not admit another attempt within fifteen minutes.
- Manual review wins while its window is open. Skip/remind remain explicit per-release installation exclusions/delays. Notification delivery deduplication does not suppress automatic installation.

## Validation and rollout

Model consent revocation, commit and handover ordering with a bounded Feynman design model; it does not prove filesystem or OS behavior. Test the real coordinator with injected installer/restart effects and isolated defaults: opt-in persistence, single-flight ownership, disable/re-enable races, failure/backoff and post-commit completion. Test the installer gate using private staged bundle fixtures. Render the native Settings control in an isolated hidden window. Build/test the real Mac target without replacing the installed app, toggling its preferences or restarting its daemon/agents. Publication needs separate approval.

## Drawbacks and alternatives

Automatic restart can interrupt real work, especially without the optional Pi SDK capability. Default-off and explicit inline restart copy are essential. Install only when idle would be less disruptive but does not implement the requested as-soon-as-available behavior and can postpone indefinitely. Download-only still requires repeated manual action. Keeping hourly checks is simpler but too slow for the requested mode. Retain the existing updater rather than introduce a second updater framework or service.

## Scope and unresolved questions

The policy is implemented in the running Mac app, not a new privileged service. Device sleep, app shutdown, OS approval, installation permissions, and failed restart may prevent completion. This is not an iOS updater or permission repair mechanism. One-minute polling and fifteen-minute retry are initial policy choices, not measured latency guarantees.
