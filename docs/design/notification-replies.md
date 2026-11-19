# Input replies from notifications

Single-field requests classified as `text` can use iOS/iPadOS’s native Reply → Send action.
It requires unlocking and enabled rich previews. Passwords, codes, usernames, email fields,
multi-field forms, and requests whose complete destination cannot fit the preview stay in Axo.
This extends existing host input requests; it does not expose secret values to agents.

The complete preview shows the question, app/window, browser origin, field label, and any
submit action. A domain-separated SHA-256 binding covers those attributes plus the field ID
and host encryption key, using UTF-8 byte-length prefixes shared by Swift and TypeScript.
Missing optional attributes are distinct from present attributes.

The native client re-reads live authenticated state, checks route/expiry/body/binding, and seals
the untrimmed reply to the current host key with the existing request/origin-bound HPKE.
Only ciphertext reaches the relay’s new `operation: "reply"` path. It independently checks
eligibility, expiry and binding, then uses ordinary human-authorized elicitation resolution.
Yes/No cannot submit input, and a text reply cannot approve a confirmation.

A metadata-only persistent dispatch fence is flushed before sending. OS callback redelivery,
reconnect and uncertain responses cannot resend a reply. Failure opens a review-only notification;
the person reviews current state in Axo. No reply text is stored in defaults, reports or logs.
Successful settlement uses existing cross-device silent retraction and foreground cleanup.

Tests cover native category/unlock configuration, a cross-language Unicode binding vector,
target changes, expired/changed requests, secret/form exclusions, HPKE opening and AAD mismatch,
transport uncertainty, persistent fencing, authenticated Worker forwarding and retraction.
Physical banner presentation and typing remain separate device acceptance evidence.
