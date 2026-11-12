# Axo Watch playground

A standalone, watch-only SwiftUI app (watchOS 11+). The first screen has a tap counter and click haptic. No sign-in, phone pairing, network connection, or live Session data yet. Simulator haptics need a real watch to feel.

From the repository root:

```sh
bazel build //apple/AxoWatch:AxoWatchApp
bazel run //apple:xcodeproj
open apple/Axo.xcodeproj
```

Select the **AxoWatchApp** scheme and an Apple Watch simulator, then Run. The watch target lives in the same generated project as the Mac and iPhone apps; do not create a separate project or edit the generated one.

Start experimenting in `Sources/AxoWatch/AxoWatchApp.swift`.

The default Bazel target builds for the simulator. Running on a physical watch additionally needs a watchOS provisioning profile and device signing configuration; this playground does not configure those yet.

Generating the shared project also analyzes the Mac app and its dependencies, including llama.cpp. The generator inherits PATH so it can find host tools such as CMake and Ninja. The watch-only build does not need those dependencies.

## Verified so far

- The Bazel simulator build succeeds.
- The same Swift source was built and development-signed through a temporary, local Xcode signing project, installed on a Series 10 running watchOS 26.6, and launched. The tap counter works on the physical watch. Signing profiles and the temporary project are not checked in.
- Shared Xcode project generation is still blocked by a llama.cpp Metal assembly build failure through sccache on the development Mac. Watch integration is declared in `apple/BUILD.bazel`, but the full project has not yet been generated successfully in this checkout.
