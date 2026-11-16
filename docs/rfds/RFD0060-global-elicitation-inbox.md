# RFD0060 - Axo: global elicitation inbox

- Feature Name: `global-elicitation-inbox`
- Status: Implemented (foreground scope; unreleased)
- Author: leostera
- Start Date: 2026-11-16
- Document Type: Implementation record
- Amends: [RFD0029](RFD0029-ask-the-person.md) (presentation and notification delivery)

## Summary

Make pending elicitations account-wide in signed-in web/iOS clients, accessible from a bell with a pending count regardless of the selected Session. Keep the originating Mac app's global questions panel, add native desktop notifications, and test multi-client fanout independently of conversation subscriptions. A notification only opens the inbox; it never answers a question.

## Problem and guide

A request may arrive correctly but remain hidden because another Session, the chats list or Settings is open. Existing UI shows web/iOS cards only for the selected Session. The local Mac panel requires opening the menu. Transport tests mostly exercise the older relayed client protocol.

A person sees a bell badge and, where permitted, one desktop notification for a new request. The inbox names the originating Mac and Session and supports existing confirm/input cards. The person's first valid answer wins; resolution removes the request from every connected inbox and clears its notification. Closing the inbox or notification is not declining or approving.

## Contract and boundaries

- All authenticated person clients receive requests independently of open Session subscriptions. Host/agent credentials still cannot receive or answer person requests. Never weaken authentication to make another Mac look signed in.
- Direct host-socket clients must not wait for slow legacy ClientDO fanout. Run those delivery paths independently; failures on one must not prevent the other.
- Preserve request identity, signed remote answers, input-key pinning and sealed values. No input values enter notifications, logs or transcripts.
- Catch-up must not replay a request that resolved during subscription. Use request-scoped catch-up ownership rather than an unbounded history of all resolved ids.
- Only unexpired requests appear. The bell is global and available even with no conversation selected. Existing Session attention badges remain useful.
- Desktop notifications use request-specific identifiers/tags, existing permission only, no automatic prompt and no inline approval actions. An explicit control may request notification permission. Clicking opens the inbox. Duplicate replay does not produce another banner while the request remains pending; resolve/expiry closes it. Re-check current state after asynchronous delivery to handle a concurrent answer.
- Background notification delivery is not implied by a live socket. iOS currently suspends its socket in the background, and APNs/Web Push is not implemented. Background/locked delivery needs a separately configured push channel and physical-device validation.
- The native Mac app currently authenticates to its local daemon, not to the cloud as a person. Its notifications cover that daemon's questions; a signed-in browser on another Mac is a person client. Account-wide native Mac requests need person sign-in, not reuse of host credentials.

## Validation

Use private Worker/daemon fixtures and headless browsers, never real approval requests against active Sessions. Cover multiple simultaneous protocol-2/3 clients, no open Session, late join, reconnect, resolution, person/host authorization separation and delayed legacy delivery. Browser tests must show the bell/inbox in a different Session and clear it across clients. Inject desktop notification effects and permission state; never post a notification or change the installed app's permissions/preferences as a test. Native tests use hidden owned windows and simulator fixtures. Model fanout/presentation as a bounded design check, not a production-delivery proof.

## Implementation evidence

- Web/iPhone bells open all unexpired requests without changing the selected Session. Mac expanded/collapsed sidebars and the menu open the local-daemon inbox.
- A shared Mac notification delegate routes both updater and question notifications. Injected tests cover permission denial, deduplication, resolution during delayed delivery, reconnect during authorization retirement, and expiry. No real notification or permission change is a test effect.
- Worker tests exercise legacy plus multiple direct person clients and late join, one client's answer forwarding and shared resolution, deterministic stalled-legacy/direct-failure ordering, and retired/resolution-racing subscription snapshots. Existing append/cut no-extra-read regressions remain green.
- Three browser clients exercise another selected Session, pre-answer Send from another device, recording → Yes → Send with a held acknowledgment, private notification copy, deduplication, first-answer removal, late replay and expiry. Native permission effects and recording are stubbed.
- A fresh owned iOS 26.5 simulator switches to another Session, opens the original request in the global inbox, and closes it without navigation. Native audio/background delivery is not validated by that test.
- The bounded design model explores 48 states/three properties without network/crash faults: a design check, not a production-delivery proof.
- Web/Worker public `:typecheck` targets consume the compiler's no-emit output group, so ordinary gate builds actually run TypeScript rather than just copy inputs.

## Alternatives and scope

Auto-navigating to the requesting Session interrupts reading and typing. One modal per request competes with other requests and input forms. A global inbox with native notifications provides attention without changing the selected conversation. In-transcript-only cards caused the current visibility gap. Polling selected Sessions cannot repair account-wide presentation or wake a suspended phone.

The watch app does not yet expose this inbox. APNs configuration, notification token registration/revocation, person sign-in on additional native Macs, and OS delivery while locked remain explicit gaps until implemented and validated. Do not describe the foreground inbox as fixing those.
