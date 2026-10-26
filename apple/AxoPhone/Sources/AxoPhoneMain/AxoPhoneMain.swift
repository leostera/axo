// Bazel compiles the screens as the `AxoPhone` module; the Xcode project compiles them into the
// app target itself, where there is nothing to import.
#if canImport(AxoPhone)
  import AxoPhone
#endif
import SwiftUI

@main
struct AxoPhoneMain: App {
  var body: some Scene {
    WindowGroup { AxoPhoneRoot() }
  }
}
