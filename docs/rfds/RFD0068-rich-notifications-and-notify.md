# RFD0068 - Axo: rich notifications and notify

- Feature Name: `rich-notifications-and-notify`
- Status: In progress
- Author: leostera
- Start Date: 2026-11-18
- Document Type: Implementation design
- Amends: [RFD0060](RFD0060-global-elicitation-inbox.md), [RFD0063](RFD0063-apple-distribution-and-apns.md)

## Summary and guide

Give the person useful, agent-authored notifications and a distinct informational
`await codemode.notify({title, message, idempotencyKey?})` tool. Elicitations remain questions;
notify never asks for or grants approval. Both use the existing canonical sandbox delivery path.
The person requested implementation after confirming a visible iPhone notification.

After the first device rollout, the person requested useful text by default, concise bottom-line-first
copy, and direct conversation navigation. Updated installs default to rich previews; explicit
per-installation opt-out and OS preview/Focus settings remain authoritative. Old registrations stay
generic until the updated client enrolls. Secret input remains generic and opens Axo.

Ordinary notification taps open the originating account-owned host/Session, never a notification
feed or an approval. Cold-start navigation refreshes the catalog if needed; missing or foreign
conversations do not fall back to an unrelated chat. Drafts survive navigation and no prompt is sent.

The person selected mockup B for chat requests: flat inline text, a decision-first headline, muted
supporting detail, compact Yes/No actions, and a quiet divider. No orange outline or enclosing card.
Long approval scope stays readable on demand; Yes is unavailable until the full request is revealed.

## Reference contract

- New informational titles are at most 48 Unicode code points, messages at most 140.
  Retained notices keep their original 60/240 bounds so history remains readable. No arbitrary
  destinations, actions, approval flags or URLs. The caller's account/host/Session come from the
  authenticated apps boundary, not input. Never include passwords, codes or other secrets.
- Queue informational intent durably before acknowledging it. An optional UUID idempotency key
  binds the exact caller and content; reuse with different content is refused. Bound retention,
  rate and dispatch work. Return queued, never claim APNs acceptance or visible delivery.
- Notifications are not an execution outbox. Neither informational taps nor ordinary notification
  taps approve. There are no implicit retries of answers after disconnect, timeout or uncertainty.
- Only a preview-enabled confirmation whose **entire** question fits the 140-code-point preview receives Yes/No
  actions. Truncated questions and sensitive input are review-only. Notification categories and
  metadata are server-controlled, never agent-supplied.
- Both Yes and No require OS authentication/unlock. The native handler fetches current account-
  owned pending state over authenticated HTTPS, matches request/Session/expiry and question hash,
  restores an existing approval signer without creating one, and signs the existing DeviceProof.
  The server rechecks current content and host generation before the existing HostDO/Mac resolution
  path. The Mac still checks device trust/signature and admits the first answer only.
- A request ID cannot mutate its question or lifetime on replay. A stale, changed, offline,
  resolved, expired, revoked-account or untrusted-device action does not execute. Failure directs
  the person to review in Axo; sensitive values never pass through notification replies.
- Keep the existing v1 routing envelope usable by installed clients. Action metadata and
  informational classification are separate, bounded fields; old registrations stay generic.
- `notify` is a reserved callable codemode tool, advertised through the existing tool catalog and
  charged to the existing run budgets. It has no approval authority or external-recipient scope.
- Do not log notification content, tokens, device proof or provider exceptions. Keep the existing
  untraced APNs transport and sampled structured outcomes. Rich text necessarily reaches APNs and
  OS notification storage only when the installation's preview preference permits it.

## Validation and rollout

Use provider/payload tests, real Worker integration for ownership/idempotency/rate limits and
answer races, native parsing/signing tests and UI tests. Preserve source apps, existing Keychain
namespaces and both Watch installs. Test and integrate clean main before development deployment.
Do not claim a visible banner from a receipt callback or confirmation button: require the person's
explicit observation. Actual Yes/No tests use harmless test questions, not destructive operations.
Production push and app submissions remain out of scope.

## Alternatives and limits

Generic-only notifications protect privacy but do not communicate the request. Showing sensitive input or bypassing an explicit preview opt-out would leak text onto lock screens. Answering directly from an unauthenticated
payload bypasses current state and device trust. These are rejected. Rich text, categories and
native signed answers reuse existing transport and authority rather than introducing a second
approval system. Free-form conversational replies are a later, separately specified feature;
password/code input continues through the existing encrypted in-app flow.
