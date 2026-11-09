These are Axo's existing assets, not replacement artwork.

- AppIcon.png is copied verbatim from assets/macos/Assets.xcassets/AppIcon.appiconset/icon_256x256.png.
- Axo.ico wraps that PNG in a Windows icon container.
- The other PNGs contain 12-column frame atlases rendered from assets/mascot/axo.riv.
  Mark: 64×36, Icon: 128×128, Face: 256×146 (120 frames each).
  Loader: 192×192 (90 frames); Happy: the Loader artboard's happy reaction (30 frames).
- windows/tools/generate-mascot.mjs documents and reproduces the extraction. It renders
  the original state machine through the mascot package's pinned Rive runtime.
  Original random looks mean regenerated frame bytes can differ.

The native client plays these at 30 fps, or holds the first frame when Windows animations
are disabled. It uses the Mark as a notification-area template, tinted for attention.
Normal builds consume the committed images; they do not download or generate artwork.
