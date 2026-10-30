# Axo brand assets

`axo-logo-original.jpeg` is the tentative logo (an axolotl). Everything else is generated from it:

```bash
swift make-icons.swift   # from this directory
iconutil -c icns ...     # macos/AppIcon.icns is built from the appiconset PNGs
```

- `ios/Assets.xcassets/AppIcon.appiconset`: one flat 1024 px square, no transparency; iOS rounds it.
- `macos/Assets.xcassets/AppIcon.appiconset` and `macos/AppIcon.icns`: a rounded square at 80% of the canvas on a transparent one, 16 to 1024 px, as macOS expects.
- `web/`: `favicon-32.png`, `favicon-192.png`, `apple-touch-icon.png` (180), `icon-512.png`.

The original has its rounded shape baked in with black corners, so the script cuts the artwork out of
it and re-places it on the flat background grey (`#DFDFDF`). A vector or square source would give
cleaner edges at large sizes. None of these are wired into the apps or sites yet.

`mascot/axo.riv` is the animated axolotl for the menu bar, the Dock and in-app use. It is generated
by `packages/axo-mascot` (`npm run build`), not by the Rive editor.
