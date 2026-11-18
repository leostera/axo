# RFD0069 - Axo: Pi agent question UI

- Feature Name: `pi-agent-question-ui`
- Status: Implemented; running Mac/daemon rollout pending
- Author: leostera
- Start Date: 2026-11-18
- Document Type: Implementation snapshot
- Amends: [RFD0029](RFD0029-ask-the-person.md)

## Summary and guide

Show the agent's own yes-or-no elicitations in its Pi terminal: a bold title, the complete
question/description, then a keyboard-selectable Yes/No list. The heading comes from the
elicitation’s optional short `title`, falling back to “Agent asks” for existing callers. Arrow keys select, Enter answers,
and Escape cancels. No truncation or new model-facing answer tool. The existing elicitation
registry remains authoritative; the first answer from any supported surface wins.

This is deliberately **advisory agent questions only**. RFD0029 already specifies that their
answers authorize nothing. Protected computer-use requests and all input forms remain on the
existing signed-app/device approval path. Pi is an agent-controlled process and is not a
security-grade person credential.

## Reference contract

- Axod sends `elicitation` and `dismissElicitation` commands through the existing bound Pi bridge.
  Requests contain only id, title, message and expiry; input/sealed-value fields are refused.
- The owning Session records the dispatched question's runtime. A reply must come from that
  still-current runtime and match a dispatched id before entering the question registry.
- The registry independently rechecks Session ownership, `askedBy: agent`, `kind: confirm`,
  absence of input, live expiry and pending state. Only then can it settle that advisory question.
  `axo.elicitation.resolve` retains its existing signed-Axo.app admission; no agent RPC is added.
- `pi-axo` renders with Pi's own TUI components and theme. All ordinary description text wraps
  without truncation; terminal control characters cannot execute as display instructions.
  RPC UI hosts use the existing `ui.select` fallback; headless contexts decline presentation.
- One prompt is displayed at a time, with a bounded FIFO queue. Dismiss-before-show tombstones
  fence reordered dispatch; remote resolution, expiry, identity changes, disconnect and shutdown
  cannot become Yes. Escape is Cancel, not an inferred No or Yes.
- A selected answer is an ephemeral bridge event on a live authenticated connection. It is not
  buffered or blindly retried after transport uncertainty. Failed writes show a generic warning;
  the question remains answerable in Axo. Replies are consumed locally rather than relayed as
  generic Pi progress events; the normal resolved event dismisses other clients.
- Existing Pi bridge versions remain usable: older extensions refuse unknown commands and the
  question stays available on the existing clients. No automatic consent or synthetic prompt
  fallback is permitted.

## Drawbacks and alternatives

A Pi process can be inspected or controlled by its agent's own OS user. Therefore these replies
must never unlock protected tools, fill secrets, or be accepted as device-signed approvals. A
broader terminal approval surface needs a separately trusted human-input boundary; making the
ordinary resolve RPC callable by agents is not an acceptable shortcut.

Doing nothing leaves the person switching to another client for ordinary agent questions. A
second standalone question tool would split pending state and first-answer-wins behavior, so
this implementation reuses the existing registry instead.

## Validation and rollout

Tests cover the real SelectList renderer and keyboard selection, bound Unix-socket extension
commands/replies, protocol bounds, cancellation, FIFO ordering, remote dismissal, stale identity,
headless mode, transport failure, first-answer-wins, foreign Sessions, and refusal of protected or
expired requests. Run Pi extension typechecking and agent/questions/server tests through Bazel.

Both the new daemon and bundled extension are required. Test with isolated owned processes;
do not patch installed Pi, restart active Mac apps/daemons/Sessions, or claim a live rollout
without the existing idle checkpoint and integrated-main deployment process.
