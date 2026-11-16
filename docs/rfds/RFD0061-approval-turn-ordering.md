# RFD0061 - Axo: approval turns take priority over Send

- Feature Name: `approval-turn-ordering`
- Status: Draft
- Author: leostera
- Start Date: 2026-11-16
- Document Type: Proposal
- Amends: [RFD0029](RFD0029-ask-the-person.md), [RFD0060](RFD0060-global-elicitation-inbox.md)

## Summary

A normal Send must not abort a pending elicitation or the work just approved by the person. Serialize each client's in-flight answer before its same-Session send. At daemon admission, convert interrupt delivery to follow-up for a run which has asked the person, until that run settles. Dedicated Stop remains an explicit override.

## Motivation

While recording, the person taps Yes on an elicitation and then Send. Send currently means interrupt: it can abort the tool waiting for the answer, cancelling the request or its approved operation. Merely ordering network requests is insufficient: answer acceptance happens before the approved action finishes.

## Contract

- Creating an elicitation posts protection to the owning Session actor before publishing the question to clients. No agent can set approval by doing this; it only changes prompt scheduling.
- Pending questions always protect against ordinary interrupt prompts. The run remains protected after resolution until AgentSettled/an idle activity snapshot. An explicit Stop disarms protection and may cancel work.
- Preserve the original text, attachments, commandId, sender provenance and at-most-once prompt receipt. Only delivery changes to followUp. Steer/followUp/strict-turn semantics remain unchanged.
- Apply this at shared daemon admission, not only a particular UI, so sending from another device cannot bypass it. Return effective delivery with the admitted link and log the actual delivery.
- Web/iOS register answer operations before asynchronous signing/RPC. A same-Session send waits for those operations to retire. On failure it leaves the draft unsent, without blindly retrying an uncertain answer. Capture/revalidate the destination after waiting; changing chats cannot redirect words.
- With a pending/in-flight answer, show the new message as a follow-up rather than an interruption. Logged queue delivery is authoritative for pending UI.
- Acceptance does not prove an external side effect finished. Protect the whole run rather than infer completion from the elicitation's resolved event. Stop is a separate explicit user action, not the normal Send button.

## Validation and limits

Use isolated fake Pi/daemon fixtures and injected client RPC gates. Cover Send before answer acknowledgment, after Yes but before run settlement, sends from a second client, failed answer, a chat switch during the wait, normal interrupt after settlement, and explicit Stop. No installed Pi/daemon restart, real approval, fabricated user message or side effect is part of testing. A bounded logical model is a design check, not an exactly-once external-effects proof.

This deliberately queues a normal Send behind a run that asked the person. Someone who wants to cancel that run uses Stop. Abrupt process failure, OS tool failure and cloud/SDK availability still require their existing reconciliation; this feature cannot promise the approved action succeeds.
