# RFD0080 - Axo: Linux GUI secure input

- Feature Name: `linux-gui-input`
- Status: In progress
- Author: leostera
- Start Date: 2026-11-18
- Document Type: Implementation design
- Amends: [RFD0029](RFD0029-ask-the-person.md), [RFD0053](RFD0053-linux-computer-use.md), [RFD0059](RFD0059-linux-sudo-input.md), [RFD0070](RFD0070-computer-use-as-a-real-boundary.md)

## Summary and guide

Prioritize GUI fields over the independent command-stdin proposal. Reuse encrypted
person-device input cards and bind Linux forms through AT-SPI object addresses,
not keyboard focus, clipboard or injected keystrokes. The person sees the running
executable, window title, document URL/origin when present, and requested fields.
The daemon fills only the exact retained fields after re-reading target identity.
AT-SPI numeric roles and Editable state attest inputs: GTK 4 can describe a
PasswordText role as an ordinary "text box" through GetRoleName. Retain structural
event subscriptions to invalidate a pending approval; scope document events so
unrelated browser chrome cannot retarget the form.

Use the existing `{pid,window_id,fields:[{kind,label?}],submit?}` interface. Linux
window IDs include 64-bit AT-SPI handles; no truncation to macOS CGWindowID widths.
Native GTK and same-bus browser accessibility trees are the first target. Refuse
cross-process trees whose frame ancestry cannot be established, unknown browser
origins, incomplete walks, locked desktops and unsupported field routes. Never
enable unsafe GNOME helpers: AT-SPI field writes require neither per-window capture
nor foreground activation. An accessibility window handle is not a compositor ID.

## Target discovery

Expose read-only `input_targets({pid})` to enumerate the kernel-bound application\'s
AT-SPI top-level handles, and `input_targets({pid,window_id})` to inspect one exact
form. Return executable/window/document metadata, labels, secure roles and buttons,
never existing field contents. Keep the ordinary desktop guard and source-level
privacy filtering, including before nested scripts can transform results. Bound
window inventory, wall time and concurrent discovery workers; cancellation must
not release a worker\'s concurrency permit before that worker exits.

Register discovery as an R2 private-observation operation in the canonical Cua
registry, preserving policy, manifests and the host guard. Standard observation
is promptless. Permission modes requiring resource grants fail closed until an
exact AT-SPI grant scope exists; never reinterpret these handles as compositor
window grants. Runtime session context is not caller approval.

Discovery is not approval or delivery evidence. Handles can become stale;
`request_input` performs its own reading and binding checks. `binding_available`
means eligible objects exist in this snapshot, not that an application\'s advertised
EditableText implementation actually edits its document. Only a confirmed write
establishes delivery. Do not ask for a secret merely to discover a window handle.

## Binding and delivery

Read the AT-SPI registry, pin unique bus owners and verify the application's kernel
peer PID. Select the exact accessibility top-level. Pin the process start time,
window object, document object/address, field objects, roles, labels and secure
status. Re-read those before each write/submit. Only the bound EditableText API may replace a field. Use one explicit
DeleteText/InsertText sequence, never a speculative write followed by a retry.
Read character counts and confirm plain-text settlement privately; zeroize any
readback, never return it. No focus acquisition, clipboard, value/numeric route,
keyboard fallback or implicit activation. Password kinds require an actual password role. Submit uses
one explicitly named button action, after accepted values, without retries.

Read metadata only when discovering forms, never existing Text contents. After
an accepted write, private readback may confirm the value just supplied. Bound each whole operation by a
wall-clock deadline and bound nodes/depth. Report fixed errors that cannot contain
secret D-Bus arguments. This does not isolate a malicious target app or other
same-user processes. The person must trust the displayed executable and origin.
Browser document identity comes from AT-SPI Document.DocURL, not address-bar text.
Unknown or mixed origins fail closed, rather than silently filling browser chrome.

## Agent-visible observation

Follow main's RFD0070 source-level boundary: `axo_computer::filled` protects direct
computer calls and each nested script read before the script can inspect it.
Extend that source with the Linux privacy journal. Do not resurrect removed hash
export or post-result sanitization RPCs: a script could transform data before such
a proxy scrub. Keep current caller and answer authorization unchanged.

On Linux retain bounded salted SHA-256 fingerprints and UTF-8 byte lengths, never
plaintext, in a private durable journal. Match every valid substring of those
lengths so embedded/unquoted Unicode and short secrets are removed. Fsync and
atomically replace the journal before the first fill; load it before serving
observations after restart. Corrupt/unreadable state withholds computer output.
Suppress image/screenshot content after any GUI secret has been filled: native
password masking alone does not protect email, code and text fields or reveal
buttons. This intentionally sacrifices agent screenshots while the journal retains inputs;
restoring screenshots needs separately proven field-lifetime/image masking, not an
agent-callable clear-redactions switch. The extra substring work and persistent salted fingerprints are a deliberate
trade-off against the prior token-only redactor, which misses arbitrary substrings.
Do not serialize plaintext, log values, or return them in receipts. Never evict old
fingerprints to admit a new fill: refuse when the bounded registry is full.

## Tests and rollout

Test metadata parsing, 64-bit handles, no focus fallback, password-role enforcement,
changed process/window/document/field identity, exact value-field sets, and fixed
error text. Test substring/key redaction, short/Unicode secrets, image suppression,
remote/local/script parity and fail-closed journal failures. Use owned GTK and browser
fixtures with synthetic input under a private display/bus; no real credentials.
Exercise encrypted cards and receipt-only MCP integration. Integrate and validate
clean main before a coordinated installation; do not claim GUI support from a
schema advertisement or a command-stdin test.

Existing terminal prompts and inaccessible/non-AT-SPI GUI controls remain outside
this slice. Native Wayland screenshot/focus guards, sudoers, pairing, relay
credentials and local answer authorization are not relaxed.
