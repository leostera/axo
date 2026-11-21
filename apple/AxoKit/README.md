# AxoKit

Apple screens compose controls; AxoKit owns their appearance and interaction states. Pass the primary button a label, action and native disabled state, not a foreground color or tint. Keep feature-specific behavior (confirmation, retry, navigation) in the screen.

## Adding a component

- Start with a concrete consumer. Prefer native semantics for buttons, links, input and focus. Do not turn a link into a button just to reuse its appearance.
- Add a rendered contrast test alongside each component. Measure the actual label against its adjacent surface, including light/dark appearances and relevant states. Use at least 4.5:1 for normal text. Test the component under an inherited accent that would expose a missing foreground or fill. Do not rely solely on palette arithmetic.
- Contrast alone does not establish accessibility: verify accessible name, role, keyboard activation, focus, Dynamic Type and target size on the platforms adopting the control.
- Migrate existing screens incrementally. Web, Windows and Linux can share component roles, state names and contrast requirements, not the SwiftUI implementation. Their renderers need their own tests.

Run `bazel test //apple/AxoKit:AxoKitTests`. The first consumer is the shared Mac/iPhone/iPad fork confirmation. This suite does not yet cover every existing screen.
