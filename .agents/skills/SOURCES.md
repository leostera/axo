# Vendored skill sources

The following upstream Agent Skills were added from the sources linked by OpenAI's [Build for iOS use case](https://learn.chatgpt.com/use-cases/native-ios-apps#leverage-skills). Snapshots were cloned on 2026-10-09. Each skill directory includes its upstream MIT license. The upstream `SKILL.md` files have a short Axo-specific compatibility section added near the top; supporting references, assets, and scripts are otherwise retained from the indicated revisions.

| Local skill | Upstream source | Snapshot |
| --- | --- | --- |
| `swiftui-expert-skill` | [AvdLee/SwiftUI-Agent-Skill](https://github.com/AvdLee/SwiftUI-Agent-Skill), `skills/swiftui-expert-skill` | `204dba7c67256a8b707ee3fbc5759a824191974f` |
| `swiftui-pro` | [twostraws/SwiftUI-Agent-Skill](https://github.com/twostraws/SwiftUI-Agent-Skill), `swiftui-pro` | `f9800713b24580bc444931949aad4519128605e8` |
| `swiftui-liquid-glass` | [Dimillian/Skills](https://github.com/Dimillian/Skills), `swiftui-liquid-glass` | `05ba982bfeb0d77d3c97d4542b0ee15034d05f84` |
| `swiftui-performance-audit` | [Dimillian/Skills](https://github.com/Dimillian/Skills), `swiftui-performance-audit` | `05ba982bfeb0d77d3c97d4542b0ee15034d05f84` |
| `swift-concurrency-expert` | [Dimillian/Skills](https://github.com/Dimillian/Skills), `swift-concurrency-expert` | `05ba982bfeb0d77d3c97d4542b0ee15034d05f84` |
| `swiftui-view-refactor` | [Dimillian/Skills](https://github.com/Dimillian/Skills), `swiftui-view-refactor` | `05ba982bfeb0d77d3c97d4542b0ee15034d05f84` |
| `swiftui-ui-patterns` | [Dimillian/Skills](https://github.com/Dimillian/Skills), `swiftui-ui-patterns` | `05ba982bfeb0d77d3c97d4542b0ee15034d05f84` |

## Axo compatibility notes

- These are project-local skills under `.agents/skills/` for Swift and SwiftUI work in `apple/AxoMac` and its libraries. The repository's `axo-macos-native-apps` skill remains authoritative for Axo's app structure, AppKit/Ghostty boundaries and validation.
- Axo's baseline is macOS 14.0 with Swift language mode 5 on a Swift 6.x toolchain (`apple/AxoMac/BUILD.bazel`, `.bazelrc`). Upstream recommendations for newer deployment targets, APIs, or language modes are not Axo requirements; preserve the baseline unless an explicit change is approved.
- The Liquid Glass skill is opt-in guidance for an explicitly requested visual treatment and needs availability/fallback handling for the macOS 14 baseline.
- Review upstream sources and update the recorded snapshot/licenses deliberately; do not silently replace local compatibility guidance.
