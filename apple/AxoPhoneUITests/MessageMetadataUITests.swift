import XCTest

final class MessageMetadataUITests: XCTestCase {
    @MainActor
    func testHeaderTitleIsCenteredAcrossTheScreenDespiteAsymmetricActions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-chat-preview"]
        app.launch()
        let title = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Axo. '")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.frame.midX, app.frame.midX, accuracy: 1)
    }

    @MainActor
    func testRelativeTimestampRevealsTheFullTimeOnTap() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-chat-preview"]
        app.launch()
        XCTAssertTrue(app.buttons["message-timestamp"].firstMatch.waitForExistence(timeout: 10))
        let timestamp = try XCTUnwrap(app.buttons.matching(identifier: "message-timestamp").allElementsBoundByIndex.first { $0.isHittable })
        XCTAssertEqual(timestamp.value as? String, "5 minutes ago")
        timestamp.tap()
        let year = String(Calendar.current.component(.year, from: .now))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", year)).firstMatch.waitForExistence(timeout: 3))
    }
}
