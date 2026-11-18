# RFD0073 - Axo: agents vs the person on the local socket

- Feature Name: `agents-vs-the-person`
- Status: Accepted; slice 1 implemented
- Author: leostera
- Start Date: 2026-11-18
- Document Type: Proposal
- Amends: [RFD0015](RFD0015-sessions-as-axo-clients.md) (provenance), [RFD0057](RFD0057-runtime-session-timers.md) (timer provenance)

## Summary

Every process running as the person can connect to `axod.sock`, and that includes every agent's tool calls. Under RFD0015 that made every agent as powerful as the person. It could prompt any Session *as the person*, because a prompt without `fromSessionId` was the person's. It could also act as any other Session, because `axo.mcp.open` and the timer methods take the Session they act for as a parameter. This RFD names three kinds of caller (the person, a Session's agent, and any other local program), and says which operations each may perform and how axod tells them apart. It does this without credentials the person has to manage. Slice 1 makes human origin depend on code signature: a prompt is the person's only when the signed Axo.app sends it (or the account, through `axo.remote.*`). Anything else is a Session's agent, or else a local program, labelled as such and held to a rate limit.

## Motivation

A daemon security review found that the runaway-agent guards RFD0015 and RFD0057 describe could be bypassed by any agent with one command:

- `axo.session.prompt` without `fromSessionId` reaches the receiving agent unlabelled and unthrottled, so its transcript shows the words as the person's.
- `AXO_SESSION_ID=<another Session> $AXOD mcp` serves another Session's tools, so prompts, timers and questions go out as that Session and use up its limits.
- `axo.session.timer.create` trusts `fromSessionId` from any caller.

RFD0015 accepted same-user trust ("a client that omits it is treated as the person"), but the mitigations it relies on (labels, depth limits, rate limits) only hold if the label cannot be forged. Prompt injection spreading between Sessions is exactly the case where an agent forges, without anyone intending it.

## What same-user trust means, precisely

A process running as the person can already read `~/.axo`, read every Session's environment (macOS gives a process the arguments and environment of every process of the same user), and type into the person's terminals. No secret kept in a file or an environment variable separates one agent from another, so this RFD does not invent one. What a same-user process **cannot** forge cheaply is:

1. **Code signature.** The kernel checks the peer's audit token (`axo_ipc::peer`, RFD0029). A script cannot pass for Axo.app or `axod` signed by the team.
2. **Process ancestry.** A process cannot move itself under another Session's Pi or pane. axod started those panes and knows their pids.
3. **The person's answer.** An elicitation is answered on the person's own devices (RFD0029). An agent cannot answer for them.

Every rule below rests on one of these three. This RFD protects the meaning of Axo's labels and limits against an agent that is confused or injected. It does not protect against a determined local program that sets out to imitate the person by other means, such as typing into Axo.app with accessibility APIs. That remains out of scope, as it is for every same-user tool.

## Guide-level explanation

There are three kinds of caller:

- **The person.** Axo.app on this Mac (signed by the team), or the account through the relay (`axo.remote.*`, already restricted to `Caller::Relay`). Only they send unlabelled prompts, answer questions and grant OS permissions.
- **A Session's agent.** A process that acts as one Session. Today it says which Session through `fromSessionId` or `AXO_SESSION_ID`. Slice 2 derives the Session instead from the pane the process descends from.
- **A local program.** Anything else on the socket: a CLI run from a plain terminal, a script, an editor plugin. It may use the local API, but what it sends is labelled as coming from a local program, never as the person's.

What an agent sees after slice 1, when it calls the socket directly:

```text
$ axod-rpc axo.session.prompt '{"sessionId":"…","text":"ship it"}'
→ the receiving Pi gets:
  [From a local program]

  ship it
```

The same call from the CLI inside a Session (`AXO_SESSION_ID` set) is labelled with that Session, as before. The same words typed into Axo.app's composer, or sent from the phone, arrive unlabelled.

| Operation | The person | A Session's agent | A local program |
| --- | --- | --- | --- |
| Prompt a Session, unlabelled | yes (Axo.app, account) | no | no |
| Prompt a Session, labelled | — | as its own Session, 30/min and 10/min to self | as "a local program", 30/min shared by all of them |
| Answer an elicitation | yes (Axo.app, account) | no (already) | no (already) |
| Request an OS permission | yes (Axo.app) | no (already) | no (already) |
| Fetch assets, ask as a tool, computer input | via axod's own tools (`ThisBinary`, already) | via its MCP server | no (already) |
| Act as Session X (MCP, timers, `fromSessionId`) | — | only X itself, from slice 2 | no, from slice 2 |

## Reference-level explanation

### Slice 1: human origin depends on code signature (implemented)

- `axo-server` parses a prompt's sender once, at the boundary, into `session::prompts::Origin`:
  - `Origin::Session(id)` when the request names `fromSessionId` (unchanged rules: the Session must be open; 30 a minute; 10 to itself; `[From Axo Session <id> "<name>"]`);
  - `Origin::Person` when the peer is `Signer::AxoApp`, and for `axo.remote.session.prompt`, which only `Caller::Relay` reaches;
  - `Origin::LocalProgram` otherwise.
- Prompt sending, logging and rate limits take an `Origin`, not an `Option<SessionId>`. No other code decides who sent a prompt.
- `Origin::LocalProgram` prompts reach Pi headed `[From a local program]` and share one bucket of 30 a minute (`prompts::Sender::LocalProgram`). They are logged as `from_session_id=local_program`.
- Timers keep `Origin::Session(fromSessionId)`. Slice 2 binds that ID to the caller.

The receiving agent can therefore trust an unlabelled prompt as the person's, and labels and limits hold for anything an agent sends, whichever path it takes.

### Slice 2: a Session's agent is the Session it descends from (proposed)

- On `axo.mcp.open`, and on any local request that names `fromSessionId` or a timer owner, axod reads the peer pid from the audit token and walks its parent chain (`proc_pidinfo`, `pbi_ppid`). It looks for a pane process axod started (Pi or terminal) and checks its start time, so a reused pid is not accepted.
- The Session it finds is the caller's Session. A request naming a different Session is refused (`-32099`, "a Session acts only as itself"). A request from no Session's process tree is a local program: it may not name `fromSessionId` or own timers.
- The conformance suite opens MCP from the test process today. It will open it through the fake Pi instead (a fake Pi command starts `axod mcp` as its child), so tests exercise the binding rather than bypass it.

### Out of scope

Sandboxing agents, per-agent OS users, and protecting against a same-user process driving Axo.app's UI.

## Compatibility

- Local scripts and CLIs that prompted without `fromSessionId` keep working, with a label and a limit. Nothing external relied on being treated as the person: Axo.app does not send `axo.session.prompt`, and the phone and web use `axo.remote.*`.
- The parity table and method schemas are unchanged; only the text Pi receives, and the limits, change.

## Validation

- `crates/axo-server` unit tests: an unsigned peer's prompt is parsed as `Origin::LocalProgram`; it is labelled and held to the shared limit; a `fromSessionId` prompt is unchanged.
- Conformance tests that prompted locally without a sender now expect `SENT:[From a local program]`.

## Drawbacks

- A person running `axo session prompt` from a plain terminal is labelled "a local program". axod cannot tell them from an agent, and the label is true.
- Slice 2 adds a few `proc_pidinfo` calls per MCP open and per labelled request: negligible next to the request itself.

## Alternatives

- **Per-Session tokens in the environment.** Rejected: same-user processes can read every Session's environment, so a token would add ceremony without separating anyone.
- **Refuse unsigned person-less prompts.** Simpler, but it would break every local script for no gain over labelling them.
- **Do nothing.** Labels and limits stay advisory, and an injected agent can speak as the person.
