# RFD0065 - Axo: choose a model before the first message

- Feature Name: `draft-model-selection`
- Status: Partially implemented — host catalog and web/mobile preselection; server-wide initialization barrier pending
- Author: leostera
- Start Date: 2026-11-17
- Document Type: Proposal
- Related: [RFD0064](RFD0064-universal-axo-mobile.md)

## Summary

A new chat can choose its model and thinking level before sending a message. Availability belongs
to the selected host and its Pi configuration, not the phone, browser, account inference service
or an arbitrary existing chat. Catalog inspection must not create a persisted chat or send a
synthetic prompt. This is a requested product contract, not optional client feature parity.

## As built in 0.83

Clients call `axo.remote.agents.models` with `target` (host ID and generation) and `agent`,
never a Session ID. The relay checks account ownership and the daemon checks target generation.
Axod resolves the installed executable, runs a bounded metadata-only probe, and returns model
references and only observed thinking levels. CLI output and diagnostics stay on the host. Pi uses
its CLI without extensions; OpenCode uses its catalog command without attaching to a shared
server on 2.x. Codex uses an owned stdio app-server and paged `model/list`. Claude Code sends only
`initialize` in bare, non-persisting stream mode, with tools and configured MCP disabled. Its
advertised model aliases are browse-only because Axo cannot yet set the model on that adapter.
A clean-home probe of each installed CLI matched the contract and left no conversation files.

iPhone/iPad and web keep pending choices by host generation and agent. They check model
availability again in the actual new Session and wait for the set acknowledgement before
sending. An error retains the original draft; there is no fallback to another model. This is a
client first-prompt fence, not yet the server-wide barrier described below.

## Earlier mobile delivery (superseded catalog source)

The mobile client can inspect a read-only catalog already announced by a Pi on the selected host,
without creating, waking, prompting or reconfiguring that existing chat. It checks up to three
live candidates and reports missing catalogs explicitly. Preferences belong to a host generation.
New-chat model controls support explicit host-default reset and model-specific thinking levels.

On Send, the client creates one chat, validates the choice against that chat's catalog in its
actual folder, and waits for model/thinking configuration acknowledgement before submitting its
own first prompt. Failed configuration retains the same chat, words, files and intent for explicit
retry. Navigation retires the Send, including A/B/A; an acknowledged creation remains reusable
before the account listing catches up. None of this requires restarting installed hosts.

This is deliberately narrower than the complete server contract below: a host with no reported
Pi catalog cannot yet offer preselection, other clients are not fenced by server initialization,
and web preselection is not implemented. Do not describe this mobile release as those features.
Owned empty-host discovery and a server-wide first-prompt barrier remain future work.

## Original boundary

`DraftComposer.pi` returns nil without an existing Session ID. `HostConnection.piModels(in:)`
uses `axo.remote.session.models`; `HostWorkbenchModel.setModel` also targets a Session.
`PhoneWorkbench.startChat` currently creates the chat and immediately sends its first prompt.
Simply showing the existing model button cannot implement pre-creation selection safely.

## Guide

Choose a host, tap the compact composer to open it, and choose Model and Thinking before Send.
Only that host's available chat models and each model's supported thinking levels appear.
“Use host default” is a deliberate unset preference, not a guessed client model. The first message
uses the selected configuration. Choosing another host refreshes availability; it never silently
moves the previous host's model choice across machines.

## Contract

- Introduce a host-scoped catalog operation shared by remote clients. Return only model
  references/display names, supported thinking levels, the reported default runtime and catalog
  ownership/freshness. Never expose provider credentials or use the unrelated native AI catalog.
- Obtain metadata from the host's configured Pi runtime/registry, including applicable provider
  configuration. Do not prompt, stop, reconfigure or use a person's existing chat as a test fixture.
  An owned in-memory RPC metadata process is a candidate, not an implemented mechanism.
- Bound discovery time, concurrency, output and cleanup. Correlate responses, ignore retired
  generations, and kill/reap only the owned process and its owned descendants. Do not log raw
  process output or credential-bearing diagnostics.
- Keep new-chat model intent with its host and host generation. Draft text/files may follow the
  existing host-switch behavior; model intent does not follow blindly. Returning to a host can
  recover its prior intent only after checking the current catalog.
- Distinguish loading, unavailable/offline, empty availability and failed discovery. A failed
  read is not proof that no models exist. Do not substitute cached presence for live authority.
- Thinking choices come from the selected model's real capabilities. Do not offer every
  thinking level globally or silently claim a rejected level is active.
- Carry the chosen configuration into session creation/initialization. No first prompt, including
  a queued or cross-client prompt, can run before initialization is confirmed. Validate again
  in the actual creation context; folder/provider extensions may differ from host-home defaults.
- A rejected or uncertain configuration does not send the draft under another model. Preserve
  text/files and chosen intent, expose recovery, and retain any already-created Session identity
  rather than blindly creating another one on retry.
- Capture the destination before awaits. Late catalog/configuration/create replies cannot
  redirect words to a different host or Session. Reconnection never auto-sends a draft.
- After creation, normal model controls address that Session. Preserve existing approval-before-
  Send fences and original-destination dictation; model selection grants no execution authority.

## Agent-specific discovery rationale

Discovery is owned by the host and selected agent, not by a Session. Reuse the executable
resolution used for launching agents. Separate installed-agent discovery from on-demand model
catalog lookup. Scope lookup results and draft intent to host generation, agent, and configuration
context; switching agents must not reuse another agent's catalog or model choice.

| Agent | Candidate metadata path |
| --- | --- |
| Pi | `pi --list-models` confirms the CLI surface. Prefer the same runtime registry for structured IDs and exact thinking capabilities. |
| OpenCode | [`opencode models`](https://opencode.ai/docs/cli/commands/). Verify the installed version's output and provider availability semantics. |
| Codex | Initialize a dedicated app-server connection, page `model/list`, then close it. No `thread/start`, `thread/resume` or `turn/start`. Verify version-dependent authentication behavior before enabling this probe. |
| Claude Code | [Agent SDK `supportedModels()`](https://platform.claude.com/docs/en/agent-sdk/typescript) reads initialization metadata. A bare CLI control handshake can expose the same advertised aliases without a user message. |

Do not trigger sign-in during discovery. When a verified probe is unavailable, keep host default
available and distinguish unsupported, sign-in required, failure and a genuinely empty catalog.
Existing Sessions still use their actual runtime for in-session changes. Catalog membership is not
proof of provider sign-in or that a Session in a different folder can use that model.

## Implementation questions

The server must establish the first-prompt barrier, not rely solely on client call ordering.
Verify whether strict launch-time model/thinking configuration supplies that invariant; otherwise
use an explicit initialization phase and acknowledged configuration before prompt admission.
Do not assume CLI model resolution fails closed without inspecting and testing the SDK path.

Verify discovery resource loading/provider extensions without running unrelated tools or MCP
servers. The installed Pi RPC exposes metadata commands, but its startup/configuration and cleanup
must be tested in isolated fixtures before using it as a host service.

Older daemons lack the proposed host catalog/creation contract. Negotiate support and show an
actionable update requirement; do not pretend a client-only release supplies the backend.
Installed host updates/restarts require their own approval and must not fabricate continuation.

## Validation and rollout

Use two fake hosts with disjoint model catalogs and thinking levels. Hold replies and switch
A/B/A, change generations, revoke availability, disconnect and change selection during creation.
Check unsupported levels, provider/auth failures, empty registries, bounded/hung discovery,
cancel/kill/reap, duplicate Sends and lost acknowledgements. Model-picker opening must create
zero persisted Sessions and zero messages. Observe the actual configuration before admitting the
first prompt, including another client's attempted Send during initialization.

Exercise the new-draft picker in fresh iPhone/iPad and browser fixtures. Keep Mac's embedded Pi
controls native, but use the same vocabulary and capability meaning. Obtain explicit rollout
approval before upgrading hosts; this document does not claim the feature is implemented,
deployed, or present in mobile build 57.
