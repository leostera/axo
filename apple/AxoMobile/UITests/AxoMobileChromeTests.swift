import CoreGraphics
import XCTest

/// Reproduce the reported phone states with synthetic data in a fresh owned simulator.
final class AxoMobileChromeTests: XCTestCase {
  @MainActor
  private func launch(_ environment: [String: String] = [:]) -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_CHAT": "2"]
      .merging(environment) { $1 }
    app.launchArguments = ["-appearance", "light"]
    app.launch()
    let title = app.staticTexts["conversation-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 15))
    let opened = NSPredicate(format: "label == %@", "Fix the sidebar spacing")
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: opened, object: title)], timeout: 10), .completed)
    return app
  }

  @MainActor
  private func capture(_ app: XCUIApplication, _ name: String) {
    let shot = app.screenshot()
    Snapshots.save(shot.pngRepresentation, named: name)
    let attachment = XCTAttachment(screenshot: shot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  func testCollapsedEarlierKeepsTheSelectedChatVisibleAndNamed() {
    let app = launch()
    let title = app.staticTexts["conversation-title"]
    XCTAssertGreaterThan(title.frame.width, 40, "The title must be visible, not a one-point AX-only label")
    app.buttons["Chats menu"].tapWhereItIs()
    let earlier = app.buttons["chat-group-earlier"]
    XCTAssertTrue(earlier.waitForExistence(timeout: 5))
    let expanded = NSPredicate(format: "value == %@", "Expanded")
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expanded, object: earlier)], timeout: 5), .completed)
    earlier.tapWhereItIs()
    let collapsed = NSPredicate(format: "value == %@", "Collapsed")
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: collapsed, object: earlier)], timeout: 5), .completed)
    let selected = app.buttons["Fix the sidebar spacing"]
    XCTAssertTrue(selected.exists)
    XCTAssertTrue(selected.isHittable)
    XCTAssertTrue((selected.value as? String ?? "").contains("Selected"))
    XCTAssertEqual(title.label, "Fix the sidebar spacing")
    let search = app.buttons["Search chats"]
    let bell = app.buttons["elicitation-bell"]
    XCTAssertEqual(app.buttons.matching(identifier: "elicitation-bell").count, 1)
    XCTAssertTrue(search.isHittable)
    XCTAssertTrue(bell.isHittable)
    XCTAssertFalse(search.frame.intersects(bell.frame), "The global bell belongs inside the active layer's header")
    capture(app, "phone-selected-earlier-folded")
    selected.tapWhereItIs()
    XCTAssertTrue(title.isHittable)
  }

  @MainActor
  func testContentIsFullBleedWithoutFakeDisplayCorners() {
    let app = launch()
    assertLightCorners(app)
    app.buttons["Chats menu"].tapWhereItIs()
    XCTAssertTrue(app.buttons["Search chats"].waitForExistence(timeout: 5))
    assertLightCorners(app)
    capture(app, "phone-flat-menu")
  }

  @MainActor
  private func assertLightCorners(_ app: XCUIApplication) {
    guard let image = app.screenshot().image.cgImage else { return XCTFail("Missing screenshot") }
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    XCTAssertTrue(drawn)
    for (x, y) in [(2, 2), (width - 3, 2), (2, height - 3), (width - 3, height - 3)] {
      let offset = (y * width + x) * 4
      XCTAssertTrue(pixels[offset..<(offset + 3)].allSatisfy { $0 > 200 },
        "Light app content must reach screenshot corners; never paint a black phone bezel")
    }
  }

  @MainActor
  func testMixedOrUnknownHardwareSaysHostsRatherThanMacs() {
    let app = launch(["AXO_PHONE_PREVIEW_HOSTS": "1", "AXO_MOBILE_PREVIEW_MIXED_HOSTS": "1"])
    XCTAssertTrue(app.staticTexts["Hosts"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["Macs"].exists)
    XCTAssertTrue(app.buttons["Pair a host"].exists)
    XCTAssertEqual(app.buttons.matching(identifier: "elicitation-bell").count, 1)
    XCTAssertTrue(app.buttons["elicitation-bell"].isHittable, "Account requests must stay inside its own pane")
    capture(app, "phone-mixed-hosts")
  }
}
