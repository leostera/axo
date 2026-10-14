# Rust Beta Banner

The legacy Swift app shows an inline banner at the top of Settings for Apple
silicon Macs running macOS 15 or newer. It links to `https://hex.kitlangton.com` and
never installs, replaces, quits, or migrates an app.

Dismissal is stored as `hasDismissedRustBetaBanner` in the existing settings
file. The About screen retains a link after dismissal. Older settings default
to showing the banner on compatible Macs.

## Native Screenshots

This is a macOS app, not an iOS Simulator target. The capture helper renders the
production Settings screen using in-memory fixtures and a reducer that starts no
audio, hotkeys, model downloads, or file-backed effects. It uses a separate,
ad-hoc-signed test app identity, `ly.anoma.Hex.LegacyBannerPreview`.

Run on an Apple silicon Mac with Xcode installed:

```sh
bun run tools/scripts/capture-rust-beta-banner.ts
```

The helper runs the focused XCTest suite and captures only its own preview
windows through ScreenCaptureKit's current-process API, including SwiftUI's
composited layers. It does not request general screen-recording access or capture
other applications. No HTTP server or external screenshot process is needed.

Outputs are under `build/banner-screenshots/`: light, dark, minimum-window-size,
and dismissed states. The Xcode result bundle also retains these attachments.
Build and test output is in `build/banner-preview.log`. Set
`HEX_PREVIEW_PACKAGES` to reuse an existing Xcode package checkout directory.

The helper disables localization extraction so preview builds do not rewrite
the localization catalog. It does not sign with a Developer ID, run the app's
normal listening lifecycle, or publish an update.

## Release Gate

The Rust beta download must be available before shipping this banner. This UI
change needs its own ordinary Swift app release; the separate website-only
Sparkle notice remains an alternative or supplementary announcement.

Related: https://github.com/kitlangton/Hex/issues/291.
