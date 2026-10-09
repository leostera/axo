# Ghostty Swift reuse in Axo

Source revision: **7ec9e26a29399b30ef78f06985fc75045b3cecb6**, matching `scripts/build-ghostty.sh`.

These MIT-licensed sources are copied from the pinned Ghostty macOS app rather than reimplementing terminal geometry:

| Local file | Upstream path | Changes |
| --- | --- | --- |
| `SplitTree.swift` | `macos/Sources/Features/Splits/SplitTree.swift` | Attribution header only |
| `SplitView.swift` | `macos/Sources/Features/Splits/SplitView.swift` | Attribution header only |
| `SplitView.Divider.swift` | `macos/Sources/Features/Splits/SplitView.Divider.swift` | Attribution header only |
| `Array+Extension.swift` | `macos/Sources/Helpers/Extensions/Array+Extension.swift` | Attribution header only |
| `PointerBackport.swift` | `macos/Sources/Helpers/Backport.swift` | Extracted only the pointer styles required by the divider |
| `Tests/SplitTreeTests.swift` | `macos/Tests/Splits/SplitTreeTests.swift` | Attribution header and test module name |

`LICENSE.txt` carries Ghostty's complete license and is distributed with the Mac app. Do not modify the ignored vendor checkout to make Axo work. Update these copies deliberately together with the pinned Ghostty revision and rerun their original tests:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path apple/AxoMac/Ghostty
```

The package is a test harness for the same source compiled into the app, not another terminal runtime or an application launcher. Xcode excludes its package manifest, tests, and build directory from Axo's sources.

Axo-specific code supplies stable pane IDs, stopped-pane placeholders, workspace/session persistence, and Pi/shell launch policy. It adapts `TerminalSplitTreeView.swift` to Axo's leaf hosts instead of pulling in Ghostty's application/configuration/inspector/drag-and-drop globals. Split insertion, sibling-collapse, spatial focus, weighted equalization, keyboard resizing, structural identity, divider gestures, and divider accessibility stay in the reused upstream primitives.

Lifecycle patterns to preserve from `BaseTerminalController.swift` and `Ghostty.SurfaceView`:

- Resolve ownership from the retained tree/registry, not transient `NSView.window` attachment.
- Restore focus after reparenting; verify the originating surface still belongs to the destination.
- Synchronize every surface's focus with actual key-window and first-responder state.
- Synchronize occlusion independently from focus; hidden work remains alive.
- Make a close action performable only for owned nodes, capture its target before confirmation, and never let cancellation stop a process.
- Use inherited surface configuration where appropriate, but deliberately replace managed Pi commands with an ordinary shell for Axo splits.
- Serialize layout references without decoding or restarting live terminal processes.

Ghostty's full window/tab controllers are not drop-in libraries: they reference its app delegate, undo service, configuration, notifications, inspectors, and update UI. Reusing the focused primitives avoids importing those unrelated policies while preserving the proven terminal behavior.
