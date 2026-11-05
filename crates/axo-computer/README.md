# axo-computer

Computer use on this Mac, embedded in `axod mcp`: seeing and operating apps through Cua Driver's macOS runtime (`platform-macos`), in-process, so its Accessibility and Screen Recording checks use Axo's grants and never prompt.

- `TOOLS` is the allowlist of Cua tools agents may call. Process killing, updates, extensions, configuration, recordings, the clipboard and attaching to the person's browser are left out.
- `tool_definitions()` returns their MCP definitions; `call(tool, args)` runs one and returns its result as JSON.
- The runtime is built on first use, since every Pi starts its own `axod mcp` and most never touch the screen.
- On anything but macOS, `AVAILABLE` is `false` and there are no tools.

`axo-server`'s `computer_gate` decides which calls need the person's agreement; this crate only runs them.

## Build

```sh
bazel build //crates/axo-computer
```
