# RFD0086 - Axo: daemon-managed Linux desktop pane access

- Feature Name: `linux-managed-desktop-pane-access`
- Status: In progress
- Author: leostera
- Start Date: 2026-11-19
- Document Type: Implementation design
- Amends: [RFD0054](RFD0054-linux-desktop.md), [RFD0073](RFD0073-agents-vs-the-person-on-the-local-socket.md)

## Summary

The Linux workbench currently fails every pane attachment: it cannot satisfy the
macOS code-signature check and belongs to no Session. Have axod launch and retain
one bundled Linux desktop process. Give only that exact live direct child pane
control, not global human identity. Never admit every same-UID process, a claimed
PID, an executable basename, a process merely descended from the desktop, or a
bearer token in a file/environment variable.

## Guide

A workbench launch calls `axo.client.desktop.open` with no parameters. Axod opens
only `AxoDesktop` beside its own executable, with its own socket and bundled
resources. It never accepts a program, command, environment, or PID from the
request. Concurrent opens reuse the retained live child. An unmanaged launcher
hands off and exits; the daemon-created process proceeds to create its window.
This also lets opening the application after closing its window create a new
managed instance without restarting the daemon or its Sessions.

The normal attach-v3 request is unchanged. Kernel socket credentials identify
its caller, and axod compares process identity/start time and direct parentage
with its retained child before handing out any PTY. Reaping and retirement are
serialized with admission. A closed or replaced process has no grant. On daemon
shutdown the owned child is killed; the next daemon opens a fresh instance.
Existing/new Sessions and both agent/terminal panes use the same rule.

## Authority and limits

This is a local pane-controller role, not `Signer::AxoApp`, `Peer::Relay`, or a
Session. It does not authorize elicitation answers, protected-input answers,
account linking, permission grants, MCP ownership, unlabelled prompts, or the
managed desktop's children. Other callers keep RFD0073's rules. The bundled
runtime and daemon startup environment remain trusted installation inputs,
like the daemon executable itself. This does not sandbox malicious same-user
programs or defend against modifying the installation, ptrace, or driving the
person's GUI; those remain RFD0073's explicit non-goals.

Only Linux advertises the launch operation. Missing bundled artifacts fail
before registering a child, with no standalone terminal or arbitrary program
fallback. Launch workers are serialized and startup is bounded by ordinary
client transport deadlines; uncertain opens are reconciled by inspecting the
retained child, never launching a second process blindly. No credentials, relay
pairing, Session data, or signed macOS authority change.

## Tests and rollout

Test retained-child admission versus ordinary same-user callers, a copied name,
child descendants, stale connection identity, exited/replaced desktop, repeated
opens, failed launch, and explicit denial of broader human/Session authority.
Exercise real kernel peer credentials and attach v3 on isolated Sessions. Keep
existing cross-Session refusal tests. Validate existing and newly created panes
through the actual installed GTK workbench, without reading personal terminal
contents. Deploy only integrated clean main; preserve pairing and Session IDs.

## Alternatives

A same-UID or executable-name allowlist breaks Session isolation. Signature
impersonation falsely broadens every human-only operation. File/environment
secrets are readable by same-user agents. A new device-enrollment ceremony
conflicts with RFD0079 and would make local terminals depend on the relay.
Daemon launch ownership reuses the existing child-identity primitive without
introducing any of these authorities. Its cost is coupling the desktop lifetime
to axod and requiring both binaries/resources in the same installed runtime.
