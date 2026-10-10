import XCTest

/// UI-level stress coverage for already-loaded 2,000-message conversations; simulator metrics are directional, not device baselines.
final class ConversationPerformanceUITests: XCTestCase {
    @MainActor
    func testScrollingLargeConversation() throws {
        let app = launchPerformancePreview()
        let conversation = app.scrollViews["conversation-scroll"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Implementation note 399"].exists)

        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric]) {
            conversation.swipeUp()
        }
    }

    @MainActor
    func testTypingWithLargeConversationLoaded() throws {
        let app = launchPerformancePreview()
        let draft = app.descendants(matching: .any).matching(identifier: "promptDraft").firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            draft.typeText("x")
        }
    }

    @MainActor
    func testSwitchingBetweenLargeConversations() throws {
        let app = launchPerformancePreview()
        let menu = app.buttons["Sessions menu"]
        let title = app.staticTexts["conversation-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "Load test A")

        menu.tap()
        XCTAssertTrue(sessionRow("55555555-5555-4555-8555-555555555555", in: app).waitForExistence(timeout: 3))
        menu.tap()

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            menu.tap()
            sessionRow("55555555-5555-4555-8555-555555555555", in: app).tap()
            waitForTitle("Load test B", in: app)

            menu.tap()
            sessionRow("22222222-2222-4222-8222-222222222222", in: app).tap()
            waitForTitle("Load test A", in: app)
        }
    }

    @MainActor
    private func launchPerformancePreview() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-performance-preview"]
        app.launch()
        return app
    }

    @MainActor
    private func sessionRow(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "session-\(id)").firstMatch
    }

    @MainActor
    private func waitForTitle(_ expected: String, in app: XCUIApplication) {
        let title = app.staticTexts["conversation-title"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expected),
            object: title
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
