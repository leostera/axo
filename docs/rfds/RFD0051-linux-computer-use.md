# RFD0051 - Axo: Linux computer use

- Feature Name: `linux-computer-use`
- Status: Implemented (experimental X11 acceptance; native GNOME 50 parity blocked)
- Author: leostera
- Start Date: 2026-11-14
- Updated: 2026-11-14
- Document Type: Proposal
- Amends: [RFD0028](RFD0028-computer-use.md) (Linux platform adapter)

## Summary

Embed the already-pinned Cua Linux platform alongside its macOS platform, retaining Axo's tool allowlist, risk gate, confirmation channel and secret-input protections. Support X11 and capability-dependent Wayland operations without pretending that XWayland connectivity proves native desktop control. Never automate a locked or unverifiable desktop. CUDA implementation and acceptance precede this work; implementation is serial.

## Motivation

The paired Linux daemon currently provides terminals and local inference but no computer tools. The pinned Cua revision contains X11, AT-SPI and Wayland support. Reusing it preserves window/process identity and target-routing checks rather than implementing unrelated command-line input injection.

## Guide-level explanation

The existing computer tool schemas and account route select the target Linux host. Tools retain the same names and screenshot alias. Linux requires the graphical user's session environment: DISPLAY/XAUTHORITY for X11, WAYLAND_DISPLAY and explicit native-Wayland opt-in where relevant, XDG_RUNTIME_DIR and the session bus. Starting over SSH alone does not supply a graphical session.

Native support is not a claim that every compositor supports every tool. AT-SPI can enumerate and operate accessible applications; per-window capture and focus-bound input need additional compositor capabilities. Linux permission probes are observations, not Apple's TCC grants. Missing display, accessibility, capture, verified focus or portal consent must return an actionable refusal rather than success with no effect.

starbase2 runs GNOME 50.1. The pinned WinRects helper deliberately refuses GNOME 50 following session-ending native crashes. Do not install/enable an older helper, patch out its guard, restart GNOME or fall back to unverified foreground input. Its native per-window capture and focus-bound input remain unavailable until a safe upstream implementation is verified. An isolated X11 test is useful acceptance evidence for X11, never evidence that the actual GNOME desktop works.

## Reference-level explanation

- Add the pinned `platform-linux` crate with portal/libei input support. Keep Linux-only dependencies out of macOS target linkage.
- Share registry lifecycle, allowlist filtering and serialization across the two supported platforms; keep platform initialization, lock detection and permission probes in platform modules.
- Construct the Linux tool registry without nested-desktop startup, overlay or telemetry. No implicit compositor, display switch, root input-device grant or GNOME extension installation is permitted.
- Query logind for this user's active graphical session and require an explicit unlocked state. Unknown, inactive, missing, ambiguous or locked sessions fail closed. A small pinned-core patch installs a host-owned async guard at Cua's canonical dispatch boundary, so nested script/batch calls recheck too. That patch also removes non-allowlisted tools from the registry; filtering advertised schemas alone would leave them reachable internally. Public arguments cannot replace the guard.
- For an active GNOME helper, query ShellVersion and helper API against an immutable bus owner and recheck ownership/Cua attestation. Require GNOME 45–49 and API 9 or newer, preventing both unsafe GNOME 50 execution and old stage-crop fallback. Unknown versions fail closed. Permission and guide reads need no screen.
- Keep every action behind the existing Axo gate. Linux same-UID peers do not acquire the right to approve elicitations or other privileged local IPC calls.
- Preserve snapshot-bound input targets, remember-before-fill redaction, receipt-only answers and the tool allowlist. Linux secure field/origin attestation is not implemented: do not advertise `request_input`; refuse it before collecting values or opening an input request. Do not approximate browser origin or field identity with generic typing.
- Keep desktop packaging and test launchers under `linux/`, shared runtime code under `crates/`.

## Validation and rollout

Test registry filtering, exact schema inventory, unsupported tools, platform permission interpretation and fail-closed lock parsing. Test headless and locked-session refusals without reading screen content. In an isolated X11 session, drive a fixture window through actual listing, accessibility/screenshot readback and harmless text input. Exercise stale targets and preserve the existing gate/redaction regression suites.

Test the extracted runtime's native library requirements and existing daemon smoke. Real-desktop tests require the person to unlock and approve any Wayland portal grant. Never log or store their actual desktop screenshots, accessible text or credentials in Git/research notes. Retain honest compositor-specific blockers. Do not restart the paired daemon or publish production artifacts as part of acceptance.

### Acceptance status

The final Linux check passes 17 Bazel suites (379 inner Rust tests and seven Python configuration tests), plus the extracted archive's isolated daemon smoke. The owned X11/GTK test passes real enumeration, AT-SPI readback, screenshots, edits, clicks, stale-token rejection and lock changes inside a script. The actual locked GNOME session refuses before driver dispatch without reading user content. Both real GGUF tests still pass after integration: 25 CUDA layers versus zero forced CPU layers, with reuse and retirement checked.

On macOS, both focused computer-use suites pass (33 inner Rust tests). This is not a full macOS GUI or repository-wide regression claim. The executable checks live in `linux/check.sh`, `linux/computer-smoke.sh`, `crates/axo-computer/src/linux_desktop_tests.rs`, the ignored real-lock test, and the GGUF service acceptance targets.

No GNOME helper was installed or enabled. Native unlocked GNOME 50 interactions, window capture and focus-bound input are not accepted by the X11 test. The paired daemon was kept running during implementation; installing the candidate requires a separate restart decision because it currently has open sessions.

## Drawbacks and alternatives

- Linux adds native X11/XKB library requirements and more transitive crates. Portal reachability alone does not prove target-safe input.
- A separate helper could isolate synchronous desktop calls further, but duplicates the existing runtime/IPC integration. Keep the same dedicated Cua runtime and blocking-pool boundary for this first slice.
- X11-only support would be simpler but would misrepresent the actual GNOME Wayland host. Supporting it as an explicit tested capability is useful; treating it as native Wayland parity is not.
- Arbitrary xdotool/ydotool/uinput injection lacks the existing identity and confirmation protections and is not the selected implementation.
- Doing nothing leaves Linux terminal-only despite an upstream native platform adapter.

## Unresolved questions

A safe GNOME 50 capture/activation implementation is an upstream blocker, not authorization to disable the guard. Broader compositor acceptance, interactive desktop consent UX and persistent tray/service installation are subsequent work.
