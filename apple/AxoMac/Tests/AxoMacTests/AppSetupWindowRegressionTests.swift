import AppKit
import AxoProtocol
import XCTest

@testable import AxoMac

@MainActor
final class AppSetupWindowRegressionTests: XCTestCase {
  private func model() async -> AppSetupModel {
    let name = "axo-window-regression-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    addTeardownBlock { defaults.removePersistentDomain(forName: name) }
    var snapshot = AppSetupTests.snapshot()
    snapshot.permissions = DaemonPermissions(processId: 42, accessibility: .granted, inputControl: .granted,
      screenRecording: .granted, developerTools: .granted, fullDiskAccess: .granted,
      automationFinder: .granted, automationSystemEvents: .notRunning)
    let model = AppSetupModel(defaults: defaults, effects: AppSetupEffects(check: { snapshot },
      fix: { _ in XCTFail("Layout must never request OS permissions") },
      connectionStatus: { XCTFail("Not on Connections"); throw CancellationError() },
      guide: { _, _, _ in XCTFail("No permission guide from layout") },
      openTerminal: { XCTFail("No terminals from layout") }, restartDaemon: { XCTFail("No restart from layout") }))
    await model.refresh()
    model.next()
    return model
  }

  func testSmallWindowsKeepReviewAndNavigationVisibleAndExplainOverflow() async throws {
    _ = NSApplication.shared
    let model = await model()
    var frames: [SetupLayoutElement: CGRect] = [:]
    let controller = AppSetupWindowController(model: model, appIcon: try AppFixtureArtwork.icon(),
      layoutObserver: { frames[$0] = $1 }, onClose: {})
    let window = try XCTUnwrap(controller.window)
    defer { window.close() }
    let content = try XCTUnwrap(window.contentViewController?.view)
    for size in [NSSize(width: 740, height: 560), NSSize(width: 820, height: 720), NSSize(width: 820, height: 1000)] {
      window.setContentSize(size)
      // Draw the real hosting controller to evaluate both layout and overflow preferences.
      for _ in 0..<4 {
        content.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try await Task.sleep(for: .milliseconds(10))
      }
      let bounds = CGRect(origin: .zero, size: content.bounds.size).insetBy(dx: -1, dy: -1)
      for element in [SetupLayoutElement.back, .primary, .review] {
        let frame = try XCTUnwrap(frames[element], "Missing actual layout for \(element)")
        XCTAssertFalse(frame.isEmpty)
        XCTAssertTrue(bounds.contains(frame), "\(element) must stay within \(size), got \(frame)")
      }
      let viewport = try XCTUnwrap(frames[.viewport]).insetBy(dx: -1, dy: -1)
      if size.height == 1000 {
        XCTAssertNil(frames[.scrollHint], "A fully visible list must not falsely tell the person to scroll")
        for item in SetupItem.allCases {
          XCTAssertTrue(viewport.contains(try XCTUnwrap(frames[.row(item)])), "\(item) should fit without scrolling at the preferred height")
        }
      } else {
        let hint = try XCTUnwrap(frames[.scrollHint], "A constrained list must explain that it scrolls")
        XCTAssertTrue(bounds.contains(hint))
        XCTAssertFalse(viewport.contains(try XCTUnwrap(frames[.row(.systemEvents)])), "The fixture must actually hide the unchecked row")
      }
      XCTAssertFalse(window.isVisible, "Never show or activate the person's app for layout tests")
    }
  }
}
