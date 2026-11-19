# RFD0081 - Axo: hidden restart continuation

- Feature Name: `hidden-restart-continuation`
- Status: Accepted; in implementation
- Author: leostera
- Start Date: 2026-11-19
- Document Type: Policy
- Supersedes: the message-free SDK prerequisite in [RFD0058](RFD0058-message-free-restart-continuation.md)

## Summary

Recover interrupted Pi work through the supported `pi.sendMessage` API with `display: false`, `deliverAs: "followUp"` and `triggerTurn: true`. This is quiet continuation, not message-free continuation: one extension-authored recovery notice persists in Pi history and enters model context. Keep RFD0058's existing daemon admission, Stop suppression, real-prompt priority and uncertain-receipt protections.

## Motivation

The installed Pi has no `resumeTurn` extension API. Releases that require that optional SDK cannot actually continue interrupted work. The person explicitly requested the supported hidden-message mechanism and a Mac release rather than maintaining a private Pi fork.

## Guide-level explanation

A working Pi restarts. Axod recognizes interrupted work and claims its one recovery control after the replacement bridge binds. Pi receives a hidden runtime notice and continues the original request with its ordinary tool, permission, abort and settlement lifecycle. The notice is not shown as a human message. Idle, new, explicitly stopped and sleeping Sessions do not acquire invented work.

## Reference-level explanation

`ResumeTurnControl` claims before dispatch; duplicate controls acknowledge the existing claim without another message. Both Axo's held prompts and Pi's pending messages prevent recovery admission. The extension uses only the public custom-message API, never the raw agent or a synthetic human prompt. The runtime notice explicitly distinguishes recovery from human approval and requires reconciliation of uncertain side effects rather than repeating them. It carries no transcript contents, credentials or new authority.

A hidden custom message remains durable and model-visible. Pi's TUI honors its display flag; Axo conversation projections must not turn it into a user row or queued human prompt. A failed/uncertain dispatch cannot be automatically retried within that runtime. The daemon's existing captured recovery intent remains the sole trigger; changing tool availability or upgrading an idle Session does not trigger recovery. Abrupt daemon crashes without a graceful recovery record remain outside the existing contract.

## Validation and rollout

Run the real Pi SDK, authenticated bridge and fake provider in isolated Sessions. Require exactly one resumed provider request across duplicate controls, one hidden recovery entry, the original human request unchanged, normal system/tool preparation and no extension errors. Keep busy/queued-human priority, uncertainty, Stop and daemon lifecycle tests. Never restart or wake the person's live Sessions to test this. Publish immutable tested sources; activate Macs only after a fresh idle checkpoint.

## Drawbacks and alternatives

The notice adds model context and can affect the answer; hiding it does not remove it from history or manufacture exactly-once side effects. RFD0058's dedicated message-free API is cleaner but unavailable in installed Pi. Silently refusing recovery leaves the reported failure unresolved. Calling the low-level agent bypasses lifecycle preparation. A visible user prompt misrepresents authorship. Clankmail's hidden follow-up demonstrates the supported API shape, not a new permission boundary.
