# axo-vt

A headless terminal backed by libghostty-vt from the pinned Ghostty build (`@ghostty_vt`, see `ghostty_vt_repository.bzl`).

Axod feeds every byte a PTY writes into a `Terminal`, so it always knows the screen the program drew: modes, contents, scrollback, cursor and keyboard state. A client attaching later gets `Terminal::snapshot()`, a byte stream that redraws that state, instead of the raw history. `plain_text()` is the screen as text, for `axo.terminal.screen`.

The emulator never answers the program: queries such as device attributes are dropped. The attached Ghostty surface parses the same bytes and is the one that responds.

## Build and test

```sh
bazel build //crates/axo-vt
bazel test //crates/axo-vt:axo_vt_tests
```
