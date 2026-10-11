# Xcode sidebar and workspace-session acceptance

Run `bash scripts/check-mac-ui.sh` after `scripts/build-mac.sh`. The AxoMac scheme includes the `AxoMacUITests` Xcode UI-testing target. The Rust-owned startup fixture runs XCTest against the actual packaged `dist/Axo.app`, with private HOME/state/preferences, an owned helper and the ambient vanilla Pi plus an owned model provider.

## Checked

- Actual Command-T creates sessions through the production menu/coordinator path.
- Native outline plain/Shift/Command clicks select ranges and add/remove identities; metadata refresh preserves the exact selection and existing visible row order.
- Right-click inside a multi-selection disables single-target rename. Right-click outside it renames exactly the clicked row, not the displayed session.
- Rust observes the owned committed rename and creates one workspace fixture via public local RPC, without editing work records. XCTest selects its sidebar row and Command-T adds exactly one session inside that workspace group.
- XCTest clicks the left, enabled Ghostty text area and types one real Pi turn. Its bounded accessibility value contains the actual visible provider response.
- After the production app quit/save barrier and owned-helper cleanup, Rust checks exact committed workspace membership and one ambient-Pi canonical JSONL under `<workspace>/.axo/sessions/<work-session UUID>/`, with directory permissions `0700`. Exactly one model request is allowed.

Pi creates canonical JSONL lazily; an empty directory is not evidence of a persisted conversation. No Axo writer invents transcript records. Existing Pi bindings retain their original directories and histories; there is no migration or restart.

## Safety and boundaries

The runner refuses while any Axo frontend is open, because `XCUIApplication.launch()` may terminate same-bundle applications. It never implicitly closes a discovered frontend or touches normal daemon state. Test windows are marked temporary and placed on the primary display. Fixture roots/results remain private; failures retain their xcresult for diagnosis.

XCTest performs UI actions/observations only. Rust owns process orchestration, public-RPC fixture setup and filesystem assertions; a sandbox denial is not permission to bypass it. Native menus are reopened while waiting for enabled state, because an open menu does not revalidate asynchronous admission changes.

This lane does not establish folder-picker creation, argument-free Finder launch, normal ServiceManagement or old-helper handoff, physical keyboard/IME behavior, independent windows, or batch move/delete. Focused pure/AppKit checks remain regressions, not substitutes for this Xcode UI lane.
