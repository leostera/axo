# Axo Phone visual references

`Phone/` holds the reviewed iPhone 17 simulator screenshots the `AxoPhone` UI is compared against. The scenarios are deterministic and use `PreviewFixture`; they do not sign in or contact a real Mac.

```bash
bazel test //apple/AxoPhone:AxoPhoneUITests --test_filter=AxoPhoneUITests/testVisual
```

Each `testVisual…` case takes a screenshot and compares it with its baseline here (`UITests/Snapshots.swift`), which the test bundle carries. The comparison ignores per-channel differences up to 18 and allows at most 0.3% changed pixels, for rendering noise; it still fails on a change of size, geometry or colour. A failure says how many pixels changed and attaches both images to the XCTest result.

Every run also writes its screenshots to `bazel-testlogs/apple/AxoPhone/AxoPhoneUITests/test.outputs/snapshots/`. To accept them as the new baselines, after looking at them:

```bash
bazel run //apple/AxoPhone:record_snapshots
git diff -- apple/AxoPhone/Snapshots
```

The references are tied to an **iPhone 17 / iOS 27.0 simulator** (`apple.simulator` in `config.json`). When changing that device or runtime, record and review the whole set together. Keep changed screenshots in the same commit as the UI change that explains them.

`AxoPhoneLayoutTests` measure element frames step by step (opening the keyboard, typing a message over several lines, opening and closing the chats) and assert that nothing moves that should not. Each step's frames are printed as `LAYOUT …` lines in the test log, with a screenshot attached.

## Swipe motion

```bash
bazel test //apple/AxoPhone:AxoPhoneUITests --test_filter=AxoPhoneMotionTests --test_output=all
```

`AxoPhoneMotionTests` swipes between layers (gentle pushes, slow drags held before letting go, and flicks) while the app notes where the conversation layer is at every frame (`AXO_PHONE_PREVIEW_MOTION`, `LayerMotion.swift`). It prints each movement as a `MOTION …` line and fails on a snap: the layer's speed changing by over 2500 pt/s from one frame to the next. The frames are left in `test.outputs/motion.txt`. Run it after touching `LayerStack`.
