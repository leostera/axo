# RFD0084 - Axo: viewed Session group retention

- Feature Name: `viewed-session-group-retention`
- Status: Implemented
- Author: leostera
- Start Date: 2026-11-19
- Document Type: Policy
- Complements: [RFD0083](RFD0083-unread-is-not-activity.md)

## Summary

An Active conversation does not age into Earlier during one uninterrupted interval of viewing it. Opening an Earlier conversation does not make it Active. Unread state remains independent. This is sidebar presentation, not a command to start an agent or continue a turn.

## Contract

Keep a transient viewed identity and a retained Active identity. On changing the viewed conversation or losing visibility, clear retention. Latch Active when the viewed conversation genuinely qualifies as Active through work, a real question, or recent activity; retain it across subsequent aging. New work can legitimately promote a viewed Earlier conversation. Pins keep their Pinned classification. Identity includes the host on mobile and web. Persist neither the latch nor a fabricated last-activity timestamp, and do not carry it across foreground intervals or launches.

Mac tracks the selected terminal only while its window is key and Axo is active; Settings and other windows do not count as viewing the terminal. Window focus and grouping-clock lifecycle belong to the workbench, not its optional sidebar, so Zen mode does not stop them. Mobile tracks the visible foreground conversation, excluding modal settings/search/request screens. Web tracks the visible, navigable open conversation. Existing pointer/keyboard ordering holds are separate and remain intact.

## Validation

Model tests cover aging while viewed, selecting Earlier, genuine new work, switching hosts and losing/regaining focus. Mac tests exercise the actual Session model. Browser tests advance the real app's clock and switch from an aged retained Active conversation to Earlier. No test prompts or restarts personal Sessions.

## Alternatives

Always keeping the selected conversation Active would incorrectly promote Earlier on opening it. Updating last-activity timestamps on reading would couple classification back to read state and propagate invented activity. A nonpersistent focus latch preserves the requested distinction without either change. Agent sleep policy and pin keep-alive are separate concerns.
