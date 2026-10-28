# Axo Phone visual references

`Phone/` contains the reviewed iPhone 17 simulator reference screenshots and a short reference recording for the `AxoPhone` UI. The UI scenarios are deterministic and use `PreviewFixture`; they do not sign in or contact a real Mac.

Run the visual lane from the repository root:

```bash
scripts/phone-visual-loop.sh verify
```

The lane also runs `AxoPhoneLayoutTests`, which measure element frames step by step (opening the keyboard, typing a message over several lines, opening and closing the chats) and assert that nothing moves that should not: the end of the conversation stays just above the composer, the text field keeps its width, and the conversation returns exactly to rest. Each step's frames are printed as `LAYOUT …` lines in the test log, with a screenshot attached.

The lane runs the four `testVisual…` cases in `AxoPhoneUITests`, asks XCTest to retain screenshots and its per-test screen recordings in an XCResult bundle, exports those attachments, and compares the named PNGs against the checked-in references. Current screenshots and the interaction recording are left in `/tmp/axo-phone-visual/` (override with `AXO_PHONE_VISUAL_ARTIFACTS`). A failed comparison prints the changed-pixel percentage; inspect both the reference and current PNG before deciding whether to change the UI or update a baseline.

To intentionally record new references after reviewing the current screenshots and video:

```bash
scripts/phone-visual-loop.sh record
git diff -- apple/AxoPhone/Snapshots
```

The PNG comparison ignores per-channel differences up to 18 and allows at most 0.3% changed pixels to accommodate small rendering noise. It still fails on dimension changes and meaningful geometry or color changes. The MP4 is a human-reviewed behavior reference, not a byte-for-byte video golden: simulator timing and codecs make that comparison noisy. XCTest regenerates a fresh video with every run so the interaction remains easy to inspect.

The committed reference set is tied to an **iPhone 17 / iOS 27.0 simulator**. When intentionally changing that device/runtime, regenerate and review the full set together. Keep changes to screenshots and the reference video in the same commit as the UI change that explains them.

## Swipe motion

`scripts/phone-swipe-motion.sh` records the simulator while `AxoPhoneMotionTests` swipes between
layers (slow drags held before release, and flicks), then follows a magenta stripe the app draws on
the conversation layer's edge (`AXO_PHONE_PREVIEW_MARKERS=1`) frame by frame. It prints each
movement's path and flags jumps back against the swipe (a snap on release) and late frames. Run it
after touching `LayerStack`; a smooth run has no `REVERSES`.
