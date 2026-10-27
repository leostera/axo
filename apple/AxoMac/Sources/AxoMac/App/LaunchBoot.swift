import AppKit
import SwiftUI

/// The app's heavy start-up work (libghostty, the Rive Dock icon, registering and connecting to
/// Axod), held back until the launch splash has drawn its first frame, so Axo is on screen
/// before anything else boots. Runs exactly once.
@MainActor
enum LaunchBoot {
  private static var work: (() -> Void)?
  private(set) static var hasBooted = false

  /// If the splash never draws (or is turned off), boot anyway after this.
  static let fallbackDelay: Duration = .milliseconds(750)

  static func hold(_ boot: @escaping () -> Void) {
    work = boot
  }

  static func run() {
    guard !hasBooted, let work else { return }
    hasBooted = true
    Self.work = nil
    work()
  }

  /// Called once AppKit has finished launching, as the backstop for `run()`.
  static func scheduleFallback() {
    Task { @MainActor in
      try? await Task.sleep(for: fallbackDelay)
      run()
    }
  }
}
