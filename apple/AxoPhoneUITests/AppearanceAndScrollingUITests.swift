import XCTest
import UIKit

final class AppearanceAndScrollingUITests: XCTestCase {
    @MainActor
    func testAppearanceChangesImmediatelyFromSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-chat-preview"]
        app.launch()
        let menu = app.buttons["Sessions menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["Settings"].tap()
        let picker = app.descendants(matching: .any).matching(identifier: "appearancePicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        for (choice, light) in [("Light", true), ("Dark", false), ("System", UIScreen.main.traitCollection.userInterfaceStyle != .dark)] {
            picker.tap()
            app.buttons[choice].tap()
            // Screenshot of actual rendered colors, not a debug theme label.
            let value = try brightness(app, at: CGPoint(x: 2, y: app.frame.midY))
            if light { XCTAssertGreaterThan(value, 0.85, choice) }
            else { XCTAssertLessThan(value, 0.15, choice) }
        }
        app.buttons["Close settings"].tap()
    }

    @MainActor
    func testNewMessageFollowsWhenAlreadyAtLatest() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-live-history-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["LATEST MESSAGE"].waitForExistence(timeout: 10))
        addMessage(app)
        XCTAssertTrue(app.staticTexts["New synthetic message at the latest end."].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["New synthetic message at the latest end."].isHittable)
        XCTAssertFalse(app.buttons["back-to-bottom"].exists)
    }

    @MainActor
    func testNewMessageWhileReadingHistoryChangesJumpLabelWithoutScrolling() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-live-history-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["LATEST MESSAGE"].waitForExistence(timeout: 10))
        app.scrollViews.firstMatch.swipeDown()
        let jump = app.buttons["back-to-bottom"]
        XCTAssertTrue(jump.waitForExistence(timeout: 3))
        XCTAssertEqual(jump.label, "Jump to latest")
        addMessage(app)
        XCTAssertEqual(jump.label, "Jump to new message")
        XCTAssertFalse(app.staticTexts["New synthetic message at the latest end."].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Transparent jump to new message while reading history"
        shot.lifetime = .keepAlways
        add(shot)
        jump.tap()
        XCTAssertTrue(app.staticTexts["New synthetic message at the latest end."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["back-to-bottom"].exists)
    }

    @MainActor
    func testPublicThinkingAndRepliesRenderMarkdown() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--axo-markdown-preview"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Response heading"].waitForExistence(timeout: 10))
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(app.staticTexts["Public thinking heading"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["## Public thinking heading"].exists)
        XCTAssertFalse(app.staticTexts["## Response heading"].exists)
    }

    @MainActor
    private func addMessage(_ app: XCUIApplication) {
        app.buttons["Chat options"].tap()
        app.buttons["Add synthetic message"].tap()
    }

    @MainActor
    private func brightness(_ app: XCUIApplication, at point: CGPoint) throws -> Double {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let x = point.x / app.frame.width * CGFloat(image.width)
        let y = point.y / app.frame.height * CGFloat(image.height)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: -x, y: -(CGFloat(image.height) - y - 1), width: CGFloat(image.width), height: CGFloat(image.height)))
        return Double(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (3 * 255)
    }
}
