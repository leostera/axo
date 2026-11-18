# RFD0059 - Axo: Linux sudo input

- Feature Name: `linux-sudo-input`
- Status: Proposed
- Author: leostera
- Start Date: 2026-11-18
- Document Type: Proposal
- Amends: [RFD0029](RFD0029-ask-the-person.md), [RFD0053](RFD0053-linux-computer-use.md), [RFD0051](RFD0051-generated-axo-cli.md)

## Summary

Support a narrow Linux `request_input` sudo target, independent of GUI field binding.
Axod owns one explicit noninteractive sudo invocation. The person approves its exact
arguments and working directory, then supplies a password through the existing
sealed input card only if sudo asks for one. A dedicated askpass helper delivers it
to sudo's private pipe, never a PTY, tool result, shell argument or environment.
Generic Linux GUI input stays unsupported; existing signed-caller and answer gates
are not relaxed for other methods.

## Motivation

Linux agents cannot currently use `request_input`: its GUI binding is macOS-only,
and the local proxy's signed-binary gate has no Linux implementation. Entering sudo
passwords in chat or enabling blanket passwordless sudo are not substitutes.

Writing into an arbitrary existing terminal is not the minimum correct solution.
An echo-off check is mutable, and the recipient can print the value into terminal
history or screenshots. Sudo already provides a separate password channel. Use it.

## Guide-level explanation

On Linux, the computer tool accepts an explicit target:

```js
computer({ tool: "request_input", args: {
  target: { kind: "sudo", argv: ["/usr/bin/apt-get", "update"] }
}})
```

The calling Session selects the working directory. The agent supplies no password,
answer, request ID, shell snippet to collect input, or approval token.

1. The person sees a confirmation for the exact argument array and directory.
2. On Accept, axod launches its fixed system sudo binary with askpass, ignoring
   cached authentication for this invocation. It does not change sudoers or SSH.
3. If sudo needs authentication, the person gets the existing password card on
   their phone/browser. Values remain sealed to this host and bound to that card.
4. Axod delivers one accepted password to the bound askpass helper. The helper's
   stdout is sudo's private pipe, not the terminal or the agent's stdout.
5. The tool returns only approval/input-handoff/exit status. Command stdout and
   stderr are discarded in this first slice; interactive commands are not supported.

This does not fill a password prompt already running in an arbitrary terminal.
The command must be invoked through this target. There is one password attempt;
a wrong password requires a fresh invocation and fresh person consent.

## Reference-level explanation

### Ownership and trust

The Linux local input handler accepts an **intent**, not values or an answer.
It handles only the parsed sudo target and returns only a receipt. Axod itself
constructs the confirmation and password card from the invocation it owns. This
route does not confer signed-application identity on same-UID callers. The macOS
GUI-input gate, redaction export, local answer gate, remote device signatures and
relay restrictions remain unchanged. In particular, no socket caller becomes Relay
and no agent-callable route resolves a request.

An agent may request a dangerous command; the person must decide whether to approve
what the daemon shows. Input is not approval of any other command. Sudo policy and
PAM remain authoritative. A separate confirmation is necessary even when existing
sudo policy would not require a password.

### Target and lifecycle

Parse a nonempty bounded argument array, with an absolute executable path, before
asking or spawning. Refuse unknown keys, approval claims, invalid bytes and oversized
previews. Obtain the calling Session's directory from axod, and pin the opened
directory for execution instead of resolving a mutable path again after consent.
The sudo executable is the fixed root-owned system binary, not an agent-selected
program or PATH lookup. The installed helper sits beside axod.

Create a private, unpredictable per-invocation Unix socket. Sudo invokes the helper
as the calling user. The broker checks the kernel peer credentials, that helper's
actual parent against the still-owned sudo process, and a per-invocation nonce.
Before delivering values, recheck liveness and the connection binding. Reject
foreign, replaced, duplicate and expired helper attempts without asking for values.
The helper accepts only a bounded response on this connection and writes the full
password plus a line terminator to its nonterminal stdout, once.

Sudo's `src/tgetpass.c::sudo_askpass` is the reference mechanism: it creates an
O_CLOEXEC pipe, forks, dup3s the write end to stdout, drops to the invoking user's
credentials, then execls the askpass path with the prompt. The parent reads that
pipe and waits for the helper. Implementation must verify these assumptions against
the deployed sudo version; a display or desktop input grant is not required.

Cancellation, parent exit, connection loss and expiry withdraw pending cards and
close the channel. No accepted value is replayed. A command already admitted after
authentication may have side effects and cannot be promised to roll back; disconnect
or cancellation is not permission to retry it. Root commands may outlive a failed
attempt to stop them, which must not be reported as an unexecuted operation.
Receipts distinguish a pre-spawn refusal from a post-launch decline/cancellation
with `may_have_run`; `input_delivered` means handoff to the bound helper, not PAM
acceptance or proof that the requested command succeeded.

### Secret lifetime and observation

Reuse `axo-questions` and `axo-seal`: device-signed, first-answer-wins HPKE input,
request-bound associated data, and zeroizing opened values. Plaintext exists only
in axod, the small helper and sudo/PAM. Do not derive Debug/Serialize for secret
buffers, put them in environment/argv, print errors containing values, or return
command output. No PTY receives the password, so VT snapshots, native terminal
widgets, terminal-screen RPCs and scrollback cannot acquire it through echo.

This is not isolation from a malicious process with the same OS user's powers,
a compromised installed helper, root/PAM, or a privileged command deliberately
approved by the person. Do not advertise code-signature authentication on Linux.

## Executable protocol model

[`specs/elicitations/linux-sudo-input.ts`](../../specs/elicitations/linux-sudo-input.ts)
models an immutable argv/directory target, person consent, the owned helper’s parent
and nonce, cancellation/expiry, process exit and duplicate/late answers. The existing
ask-the-person model owns device verification and sealing. This model checks the
new broker boundary, not Linux/PAM correctness or hostile same-UID isolation.

`bazel test //specs:linux_sudo_input` exhausts the bounded model, requires a reachable
valid delivery, and uses negative controls: removing one-shot settlement or helper
binding must produce counterexamples. OS tests exercise those abstractions with the
real askpass executable and private sockets/pipes.

## Testing

Use owned directories, a fake sudo process and fixed synthetic secrets, never the
person's password or real privileged operations. Check valid delivery and receipt-only
results; cancellation and expiry before/after asking; changed/dead parent and wrong
nonce; duplicate/helper replay; wrong field sets; newline/NUL rejection; missing
helper; no-question malformed targets; exact argv/directory; and output/log/transcript
absence of the synthetic secret. Test the protocol actors' consent, binding and
one-shot properties with the existing Feynman framework. Exercise the complete MCP
route against a private daemon, with sealed/signed fixture answers.

Actual sudo/PAM and phone/browser acceptance requires coordinated deployment and
person consent. Do not restart the active paired daemon or desktop during source
checks. Do not change sudoers, SSH policy, GNOME guards or authentication storage.

## Drawbacks and alternatives

- Two cards can be required: command consent and then password. This keeps command
  consent explicit even when sudo needs no authentication.
- Receipt-only output makes diagnosis less convenient. A future output path needs
  explicit capture/redaction semantics, not unbounded stdout forwarding.
- Existing terminal prompts and generic Linux GUI fields are deliberately outside
  this slice. Target-safe GUI input still needs its own native implementation.
- Bare same-UID authorization and simply deleting the existing peer gate would
  misrepresent trust and are rejected. A narrow daemon-owned intent handler has a
  different contract: request a bound operation, never receive values or approve it.
- Typing into an echo-off terminal is smaller but cannot establish the required
  observation boundary. Doing nothing leaves chat/passwordless-sudo workarounds.
