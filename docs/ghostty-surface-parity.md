# Ghostty surface parity audit

Pinned Ghostty: `81598385d608dda4946093d6d6a234d204a2f225`. Sources compared:
`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`, `SurfaceScrollView.swift`,
`Ghostty.App.swift` (action dispatch), `Features/Terminal/BaseTerminalController.swift`
(occlusion), against `apple/AxoMac/Sources/AxoMac/{GhosttyTerminalView,GhosttyRuntime}.swift`.

Status: **match** = equivalent today; **port** = gap to implement (goal task in brackets);
**unsupported** = intentionally omitted, with reason.

## AppKit surface view

| Ghostty behavior | Status |
| --- | --- |
| Key down/up, flagsChanged, performKeyEquivalent, doCommand redispatch | match, Axo menu wins collisions [keyboard-routing verifies] |
| NSTextInputClient (marked text, insertText, firstRect, selection accessors) | match [text-ime verifies] |
| Mouse buttons, extra buttons, drags, enter/exit, focus-only click suppression | match |
| Scroll multiplier (2× precise) and momentum flags | match since `5a0b762` |
| `SurfaceScrollView` native overlay scrollbar, `scroll_to_row` drag, `scrollbar` config | match since `5a0b762` (overlay instead of document-view wrapper) |
| Pressure / force-click Quick Look | match |
| Cursor shape and visibility | match |
| Backing-scale / contentsScale sync | match |
| Tracking areas (`activeAlways`, `inVisibleRect`) | match |
| Context menu | match for copy/paste/split/close; **port**: paste selection, reset terminal, toggle read-only [surface-state] |
| `pasteAsPlainText`, `pasteSelection` | **port** [appkit-integrations] |
| Find: `find`, `selectionForFind`, `scrollToSelection`, `findNext/Previous`, `findHide` | **port** [find-search] |
| `toggleReadonly`, `resetTerminal` | **port** [surface-state] |
| `changeTitle` / prompt title | unsupported: Axo session names are owned by the sidebar rename flow and Pi titles |
| Services requestor, drag/drop | match [appkit-integrations verifies] |
| Accessibility (role, value, ranges, lines, attributed string) | match, bounded to 64 KiB visible text [terminal-accessibility verifies] |
| `showUserNotification` / notification handling | **port** [attention-signals] |
| Terminal inspector | unsupported: out of scope (developer tool, separate window) |
| Splits left/up | unsupported: Axo splits right/down through its own layout commands |
| Focus-follows-mouse | unsupported: belongs to Ghostty's window controller; Axo pane focus is presentation-owned |

## Rendering and lifecycle

| Ghostty behavior | Status |
| --- | --- |
| Wakeup → `ghostty_app_tick` on main | match |
| Occlusion updated on `NSWindow.didChangeOcclusionState` | **port**: Axo sets it only on `viewDidMoveToWindow`, so hidden windows keep rendering and restored windows can stay occluded [rendering-parity] |
| Focus updated on key-window and app-active changes | match (app active); verify key-window changes [rendering-parity] |
| Render speed vs Ghostty.app | **measure** [rendering-parity] |

## Ghostty actions (`action_cb`)

Axo handles today: `MOUSE_SHAPE`, `MOUSE_VISIBILITY`, `SCROLLBAR`, `CELL_SIZE`. All others return
`false`.

| Action | Status |
| --- | --- |
| `MOUSE_OVER_LINK`, `OPEN_URL` | **port** with Ghostty `UntrustedURL` rules [links] |
| `START_SEARCH`, `END_SEARCH`, `SEARCH_TOTAL`, `SEARCH_SELECTED` | **port** [find-search] |
| `PROGRESS_REPORT`, `RING_BELL`, `DESKTOP_NOTIFICATION`, `COMMAND_FINISHED` | **port**, gated by Ghostty config, feeding Axo attention status [attention-signals] |
| `SECURE_INPUT`, `KEY_SEQUENCE`, `KEY_TABLE`, `READONLY`, `RENDERER_HEALTH`, `SHOW_CHILD_EXITED` | **port** [surface-state] |
| `SET_TITLE`, `PWD` | **port** as presentation hints only; never rename sessions [surface-state] |
| `COLOR_CHANGE`, `CONFIG_CHANGE`, `RELOAD_CONFIG` | **port** scrollbar appearance/config refresh [surface-state] |
| `SELECTION_CHANGED`, `UNDO`, `REDO` | match: selection is read on demand; undo/redo route through Axo commands |
| `COPY_TITLE_TO_CLIPBOARD` | unsupported: title is not a terminal-owned value in Axo |
| `NEW_SPLIT`, `GOTO_SPLIT`, `RESIZE_SPLIT`, `EQUALIZE_SPLITS`, `TOGGLE_SPLIT_ZOOM` | unsupported: Axo splits are Axod-owned panes; Ghostty keybinds must not create surfaces |
| `NEW_WINDOW`, `NEW_TAB`, `CLOSE_TAB`, `CLOSE_WINDOW`, `CLOSE_ALL_WINDOWS`, `MOVE_TAB*`, `GOTO_TAB`, `GOTO_WINDOW`, `PRESENT_TERMINAL` | unsupported: no tabs/windows in Axo's model (user decision) |
| `TOGGLE_FULLSCREEN`, `TOGGLE_MAXIMIZE`, `FLOAT_WINDOW`, `INITIAL_SIZE`, `RESET_WINDOW_SIZE`, `RESIZE_WINDOW`, `TOGGLE_BACKGROUND_OPACITY`, `TOGGLE_VISIBILITY`, `TOGGLE_QUICK_TERMINAL`, `TOGGLE_COMMAND_PALETTE` | unsupported: window-level, owned by Axo's AppKit window |
| `INSPECTOR`, `RENDER_INSPECTOR`, `EXPORT_TERMINAL_IO`, `OPEN_CONFIG`, `CHECK_FOR_UPDATES`, `QUIT` | unsupported: Ghostty app chrome; Axo has its own settings/update/quit |
| `SET_TAB_TITLE`, `PROMPT_TITLE` | unsupported: no tabs; naming is sidebar-owned |
