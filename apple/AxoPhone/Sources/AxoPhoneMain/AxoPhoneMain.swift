import AxoPhone
import SwiftUI

@main
struct AxoPhoneMain: App {
  @UIApplicationDelegateAdaptor(AxoPhoneLifecycle.self) private var lifecycle

  var body: some Scene {
    WindowGroup { AxoPhoneRoot() }
  }
}
