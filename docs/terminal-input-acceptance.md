# Native terminal input acceptance

## Verification checkpoint — 2026-10-21

The terminal-input parity goal remains incomplete. The Ghostty pin remains
`81598385d608dda4946093d6d6a234d204a2f225`; no Ghostty or ownership architecture
changes were made for this checkpoint.

### Text-input reconciliation

Compared `GhosttyTerminalView.swift` and `TerminalTextInput.swift` with the pinned
`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` NSTextInputClient
implementation:

- External committed text uses key events, not paste. Text delivered during
  keyDown joins its accumulator. Both implementations require an associated
  AppKit current event.
- Preedit updates immediately outside keyDown and clears on unmark/commit;
  keyDown retains its existing composition and input-source handling.
- Selection/accessor behavior intentionally follows the pinned surface:
  selectedRange comes from the terminal selection, attributedSubstring returns
  that selection for a nonempty proposed range, and characterIndex returns zero.
  These are terminal-selection semantics, not a new editable-document model.
- Candidate geometry uses the IME point for matching ranges, the selection
  origin for Quick Look's mismatching range when available, and the existing
  zero-width dictation indicator offset. Window/screen coordinate conversion
  remains in the actual AppKit view.

Added helper regressions for Foundation NSString emoji/CJK commits, attributed
CJK commits, pending-surrogate interruption by attributed/Foundation/empty
commits, replacement of an unmatched lead surrogate, matching-selection candidate
geometry, and candidate fallback when no selection position is available.

### Evidence

`bazel test --cache_test_results=no //apple/AxoMac:AxoMacTests` passed:
**72 XCTest cases, zero failures**, including **14 TerminalTextInputTests**.
`git diff --check` passed. These tests use component objects and do not launch the
regular frontend, drive UI automation, or touch the user's session database or
clipboard. The test target emitted an existing XCTest deployment-target linker
warning; the tests still executed successfully.

This proves helper decoding and geometry behavior only. It does **not** prove
real IME composition/commit/cancel, input-source changes, actual dictation,
external committed-text delivery through AppKit, live preedit synchronization,
font/selection accessor behavior, or candidate placement on screen.

### Remaining acceptance and safe-resume condition

A normal Axo frontend was running (PID 33021 at this checkpoint). No UI tests,
packaged app launch, frontend termination, daemon restart, or active-session
changes were performed. Do not launch the UI suite or close a discovered frontend
automatically.

When the user provides a safe UI-test window with no regular frontend open:

1. Recheck the frontend safeguard, current source, and fixture isolation.
2. Run the focused context-menu case and revised per-case visual suite, including
   the actual-AppKit Kitty Enter/Shift+Enter case. An earlier reported Kitty pass
   is historical evidence, not a fresh pass on this checkpoint.
3. Run applicable isolated workbench and packaged startup acceptance lanes.
4. Exercise physical CJK composition/commit/cancel, emoji, dead keys, source
   changes, dictation and candidate placement; continue the physical pointer,
   Force Touch, Services, drag/drop, clipboard-consent and VoiceOver checklist.
5. Record exact results and source/package identities before closing goal tasks.

The broader inventory and manual checklist are in
`personal/axo/ghostty-terminal-input-parity/README.md` in the user's private
ai-research repository. Its package/PID details are historical and must not be
used as current runtime evidence. No pending parity task is considered complete
by this checkpoint alone.
