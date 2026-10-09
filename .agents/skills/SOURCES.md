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

- These are project-local skills under `.agents/skills/`, intended for relevant iOS/Swift work. For macOS-native UI, the repository's `axo-macos-native-apps` skill remains authoritative for Axo's scene, window, AppKit, and packaging boundaries.
- `apple/project.yml` currently sets iOS 18.0 and Swift language mode 5.0. Upstream recommendations for newer deployment targets, APIs, or Swift concurrency modes are not Axo requirements; preserve the project baseline unless an explicit change is approved.
- The Liquid Glass skill is opt-in guidance for an explicitly requested visual treatment and must include availability/fallback handling for Axo's current iOS baseline.
- Review upstream sources and update the recorded snapshot/licenses deliberately; do not silently replace local compatibility guidance.
