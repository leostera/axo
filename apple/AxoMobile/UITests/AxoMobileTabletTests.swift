import XCTest

/// Owned simulator only: no sign-in, device permissions or live Mac commands.
final class AxoMobileTabletTests: XCTestCase {
  @MainActor
  func testSidebarAndConversationStayTogetherAcrossRotationAndNewChat() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchEnvironment = ["AXO_PHONE_PREVIEW": "1", "AXO_PHONE_PREVIEW_CHAT": "3"]
    app.launch()
    let title = app.staticTexts["conversation-title"]
    let sidebar = app.scrollViews["workbench-menu"].firstMatch
    XCTAssertTrue(title.waitForExistence(timeout: 20))
    XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
    XCTAssertTrue(sidebar.isHittable)
    XCTAssertLessThan(sidebar.frame.width, app.windows.firstMatch.frame.width / 2)

    let opened = NSPredicate(format: "label != %@", "New chat")
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: opened, object: title)], timeout: 10), .completed)
    let selected = title.label
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
    XCTAssertEqual(title.label, selected)
    XCTAssertTrue(sidebar.isHittable)

    app.buttons["New chat"].tap()
    let blank = NSPredicate(format: "label == %@", "New chat")
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: blank, object: title)], timeout: 5), .completed)
    XCTAssertTrue(sidebar.isHittable, "Choosing a conversation must not dismiss the iPad sidebar")
    let welcome = app.staticTexts["What are we working on?"]
    XCTAssertTrue(welcome.waitForExistence(timeout: 5))
    XCTAssertGreaterThanOrEqual(welcome.frame.minX, sidebar.frame.maxX, "The transcript must not extend beneath the sidebar")
    let screenshot = app.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "axo-mobile-ipad"
    attachment.lifetime = .keepAlways
    add(attachment)
    Snapshots.save(screenshot.pngRepresentation, named: "axo-mobile-ipad")
  }
}
