import AppKit
import AxoDaemonManager
import SwiftUI
import XCTest
@testable import AxoMac

@MainActor
final class ZenModeTests: XCTestCase {
  func testZenRendersFullWidthWithoutChangingTheCollapsedPreference() throws {
    let suite = "axo-zen-fixture-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let sessions = TerminalSessionsModel(client: FakeAxodClient())
    let ghostty = GhosttyRuntime(initializeGhostty: false)
    let daemon = DaemonController()
    func render(_ name: String) throws -> Data {
      let content = TerminalWorkbenchView(daemon: daemon, sessions: sessions,
        isPresentingNewSessionInFolder: .constant(false), daemonIsRunningOverride: true)
        .environment(ghostty).defaultAppStorage(defaults).frame(width: 1000, height: 600)
      let host = NSHostingView(rootView: content)
      host.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
      let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      defer { window.close() }
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      if let output = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"] {
        try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
      }
      return data
    }
    for collapsed in [false, true] {
      defaults.set(collapsed, forKey: AxoPreferenceKey.sidebarIsCollapsed)
      defaults.set(false, forKey: AxoPreferenceKey.zenMode)
      let normal = try render(collapsed ? "zen-before-rail" : "zen-before-expanded")
      defaults.set(true, forKey: AxoPreferenceKey.zenMode)
      let zen = try render(collapsed ? "zen-hidden-from-rail" : "zen-hidden-from-expanded")
      XCTAssertNotEqual(normal, zen, "Zen removes the sidebar rather than collapsing it")
      XCTAssertEqual(defaults.bool(forKey: AxoPreferenceKey.sidebarIsCollapsed), collapsed)
      defaults.set(false, forKey: AxoPreferenceKey.zenMode)
      XCTAssertEqual(try render(collapsed ? "zen-restored-rail" : "zen-restored-expanded"), normal)
    }
  }
}
