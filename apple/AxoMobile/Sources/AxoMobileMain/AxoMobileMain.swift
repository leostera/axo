import AxoMobile
import SwiftUI

@main
struct AxoMobileMain: App {
  @UIApplicationDelegateAdaptor(AxoMobileLifecycle.self) private var lifecycle

  var body: some Scene {
    WindowGroup { AxoMobileRoot() }
  }
}
