# axo-computer-use

The computer-use extension of axod (RFD0028, RFD0029, RFD0034): what axod itself does around the
computer tools of `axo-computer`.

- `request_input`: reads the window's form, asks the person in the calling Session with this Mac's
  input key, fills what they sealed, and has `axo_computer::filled` remember each value, so
  every later computer result in axod, a script's reads included, shows `•••• (filled by you)`
  for it (RFD0070).
- Other Macs' calls (`ComputerUse::remote`): the same gate as the local tool; when it must ask,
  it asks in the calling Session and runs only on Accept.

`axo.computer.input` answers axod's own binary only. The rest of
axod is a `ComputerHost` (asking, the input key, axod's socket), passed to each call.

Named apart from `axo-computer`, the computer-use library it builds on.

Tests: `bazel test //crates/axo-computer-use/...`; who may call it in
`//crates/axod:conformance_account`; models in `specs/elicitations`.
