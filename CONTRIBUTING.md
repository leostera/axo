# Contributing to Axo

Thanks for your interest in Axo. The project is under active development, so behavior and internal interfaces can change. For larger changes, open an issue or discussion first to align on scope before investing in an implementation.

## Before you start

- Axo's native app, daemon, and iOS client are developed on macOS with Xcode.
- The shared native build and test graph uses **Bazel 9.3.0** (pinned in `.bazelversion`). Install Xcode and its command-line tools as well.
- JavaScript packages use npm. Install dependencies in the package you intend to work on; several packages have their own lockfiles and test commands.
- Never commit API keys, OAuth secrets, signing credentials, personal session data, agent transcripts, or production configuration. Use local development fixtures and environment files, which should remain untracked.

## Build and test

Run checks that cover the area you changed. From the repository root:

```sh
# Rust daemon and supporting crates
bazel test //crates/...

# All JavaScript tests and type checks declared at the repository root
npm test
npm run typecheck

# Build the native Mac app and daemon
bazel build //apple/AxoMac:AxoApp //crates/axod:axod

# Generate the local Xcode project from Bazel targets when needed
bazel run //apple:xcodeproj
```

For the iOS app, use the phone-specific visual lane:

```sh
scripts/phone-visual-loop.sh verify
```

The native Mac visual UI suite is interactive and requires an unlocked desktop, Xcode UI Automation authorization, and macOS 14 or later:

```sh
bazel test //apple/AxoMac:AxoVisualUITestsBazel --test_output=all
```

The visual suite drives a real terminal surface. Do not run it in a locked session or bypass macOS's UI Automation authorization. Its screenshots and test results are written to local temporary/Bazel output directories.

To package a signed development app bundle, run:

```sh
bash scripts/build-mac.sh
```

This packaging step requires a valid Apple code-signing identity. It builds and verifies the app but does not run the test suite. Prefer the focused test command for your change; `bazel test //...` includes the interactive visual UI-test wrapper on macOS.

## Making a change

1. Start with a focused issue or proposal for changes that affect user-visible behavior, architecture, API contracts, or data handling.
2. Keep changes scoped and add or update tests for behavior that can be tested automatically.
3. Update the relevant documentation when setup, user behavior, APIs, or development workflows change. Treat `docs/` architecture notes and proposals as design records; check their status before assuming they describe shipped behavior.
4. Run the relevant checks and report any checks you could not run, including why.
5. Review your diff before submitting. Remove generated artifacts, local configuration, logs, screenshots, and personal data unless a reviewed visual baseline is intentionally part of the change.

## Pull requests and bug reports

A useful pull request includes:

- A short explanation of the problem and the chosen approach.
- The user-visible impact and any limitations or migration considerations.
- The tests and checks run, with results.
- Screenshots or a short recording for visual changes, after checking that they contain no personal or sensitive information.

For bug reports, include the affected platform, steps to reproduce, expected and actual behavior, and relevant sanitized logs. Do not attach Axo session files, Pi transcripts, credentials, or unredacted terminal output.

## Security issues

Please do not report suspected security vulnerabilities in a public issue. Contact the project maintainers privately instead. Include only the information needed to investigate, and avoid sharing real credentials or user data.
