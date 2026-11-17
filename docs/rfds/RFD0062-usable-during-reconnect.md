# RFD0062 - Axo: usable while reconnecting

- Feature Name: `usable-during-reconnect`
- Status: Implemented (unreleased)
- Author: leostera
- Start Date: 2026-11-16
- Document Type: Implementation record
- Amends: [RFD0049](RFD0049-web-conversation-cache.md) (composer readiness), [RFD0061](RFD0061-approval-turn-ordering.md)

## Summary

Separate local reading/editing, authenticated command readiness, and transcript freshness. After the existing sign-in check, saved chats and drafts stay usable while the socket connects. A fresh authenticated listing and live destination enable Send without waiting for its history window. The cache alone never authorizes a command.

## Motivation and guide

The cache route repeatedly reapplied the startup deep link, undoing attempts to browse another saved chat. The entire composer was disabled whenever Send was unavailable, and a live connection still could not send until history finished loading.

A person reloads, switches between saved chats, searches, and edits each draft while “Connecting…” is visible. When live metadata confirms that Mac and Session, Send becomes available even if history is still updating. No reconnection automatically submits a draft. Focus remains where the person put it.

## Contract

- Keep cache account ownership, parsing, bounds and storage unchanged. Sign-in verification still precedes cache access; no stored identity becomes authentication.
- Explicit navigation supersedes the startup route. A cached deep link is consumed once, not replayed on every selection. Browser Back/Forward and URLs continue working during reconnect.
- Local draft editing, picking attachments and starting dictation are independent of socket readiness. Uploads still authenticate through the account HTTP API. An explicit submission in flight may lock its draft as before.
- Send requires the connected authenticated account, a fresh listing, an online Mac and a live chat destination (or explicit new-chat destination). Do not infer any of these from persisted presence or metadata.
- Cached cursors still never resume a subscription. The fresh history window replaces the preview, but its completion is not a prerequisite for sending.
- Normal Send before fresh history queues as a follow-up rather than interrupting unseen work. Pending approvals retain RFD0061's stronger protection. Stale transcript controls such as Stop remain unavailable.
- Connection failure leaves drafts editable and unsent. Do not add a hidden outbox, automatic submission, offline credentials or cross-account draft migration.
- This does not reduce network handshake latency, change the SDK's all-host connection policy, make sign-in offline, or provide a service-worker app shell.

## Validation

Hold the initial cloud reply during reload, navigate between two cached Sessions, edit independent drafts and verify URLs/selection survive connection. Then hold only history reads, release the authenticated listing, and submit once to the intended Session while its preview is still visible. Verify follow-up delivery, fresh replacement, retained drafts, no automatic sends and no focus theft. Use model fixtures and desktop/phone headless browsers only.

The final gates pass TypeScript checking, 101 web model tests and all 19 browser checks. Desktop and phone cases hold both connection and history independently, exercise cached navigation/new drafts, and send once before history is released. The model tests also check that cached-only submission is blocked and cached entries cannot target Stop. No production deployment, installed-client change or real approval is a test effect.

## Drawbacks and alternatives

This deliberately changes RFD0049's conservative read-only composer rule. The live destination, not a cached transcript, supplies authority; sends before fresh history are conservative follow-ups. Keeping the whole composer disabled is simpler but recreates the reported freeze. A durable offline outbox is a separate feature requiring explicit queued intent, cancellation, destination revalidation and uncertain-delivery handling; it is not smuggled into a connectivity fix.
