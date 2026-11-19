# RFD0083 - Axo: unread is not activity

- Feature Name: `unread-is-not-activity`
- Status: Implemented; not released
- Author: leostera
- Start Date: 2026-11-19
- Document Type: Policy

## Summary

On Mac, iPhone/iPad and web, unread status is an independent presentation marker. It never keeps a quiet conversation in Active. A conversation can remain unread in Earlier. Reading it or marking all read changes its unread marker, not its group or ordering.

## Behavior

Pinned conversations remain in Pinned. Unpinned conversations are Active while working, waiting for a real answer, or within the configured time since last activity; otherwise they belong in Earlier, whether read or unread. Reading is not new activity. Existing unread indicators, read timestamps, pin order, active-time preferences and Earlier folding/limits remain intact.

Remove the `unseenStayActive` option from the three clients' settings models and interfaces, rather than merely changing its default. Previously stored values, including `true`, are ignored through the existing unknown-key-tolerant settings parsers. Do not reset preferences or read marks and do not mark anything read as a migration.

This policy concerns sidebar classification, not whether axod's agent process is running or asleep. Focus retention, pin keep-alive behavior and Zen mode are separate requested changes; this document does not claim those are implemented.

## Validation

Mac, mobile and web model tests cover old unread conversations remaining in Earlier and reading not changing group membership. Stored-settings regressions ensure an obsolete `unseenStayActive: true` cannot restore the old behavior. Browser desktop/phone and native iPhone/iPad interaction tests check unread indicators in Earlier and stable row positions after Mark all read. Tests use owned fixtures, not personal conversations.

## Alternatives and costs

Changing only the default would retain the reported bug for existing users with a stored true value. Keeping a toggle conflicts with the requested invariant. Removing it intentionally changes that old preference's effect, while retaining every read mark and all unrelated settings. A recent unread conversation may still be Active because it is recent, not because it is unread.
