import AppKit
import XCTest

final class SessionSidebarUITests: XCTestCase {
    private var application: XCUIApplication?

    override func tearDownWithError() throws {
        if let application, application.state != .notRunning {
            application.activate()
            // Cancel only modal UI belonging to this explicitly owned fixture.
            // Command-Q can otherwise be consumed by an open save/folder panel.
            for _ in 0..<3 where application.sheets.count > 0 || application.dialogs.count > 0 {
                application.typeKey(.escape, modifierFlags: [])
            }
            application.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(application.wait(for: .notRunning, timeout: 15), "Owned UI fixture did not quit cleanly")
        }
    }

    func testSessionSelectionRenameAndWorkspaceShortcut() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let root = try XCTUnwrap(environment["AXO_UI_TEST_ROOT"])
        let bundle = try XCTUnwrap(environment["AXO_UI_TEST_APP"])
        XCTAssertTrue(root.hasPrefix("/") && bundle.hasPrefix("/"))
        // launch() would terminate an existing instance of the same bundle ID.
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "dev.leostera.axo.mac" }) else {
            XCTFail("Refusing to terminate a live Axo frontend. Close it explicitly before this isolated UI test.")
            return
        }
        let app = XCUIApplication(url: URL(fileURLWithPath: bundle))
        application = app
        app.launchArguments = ["-ui-test", root]
        app.launch()
        let outline = app.outlines.firstMatch
        XCTAssertTrue(outline.waitForExistence(timeout: 30))
        let labels = outline.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'session.'"))
        wait { labels.count == 1 }
        for count in 2...4 {
            waitForNewSession(app)
            app.typeKey("t", modifierFlags: .command)
            wait { labels.count == count }
        }
        let ids = labels.allElementsBoundByIndex.map(\.identifier)
        let rows = ids.map { id in outline.outlineRows.containing(.any, identifier: id).firstMatch }
        XCTAssertTrue(rows.allSatisfy(\.exists))
        rows[0].click()
        XCUIElement.perform(withKeyModifiers: .shift) { rows[2].click() }
        XCTAssertEqual(rows.map(\.isSelected), [true, true, true, false], "Native Shift-click range")
        XCUIElement.perform(withKeyModifiers: .command) { rows[3].click() }
        XCTAssertEqual(rows.map(\.isSelected), [true, true, true, true], "Native Command-click adds a row")
        XCUIElement.perform(withKeyModifiers: .command) { rows[1].click() }
        XCTAssertEqual(rows.map(\.isSelected), [true, false, true, true], "Native Command-click removes a row")
        app.typeKey("r", modifierFlags: .command)
        wait { rows[0].isSelected && !rows[1].isSelected && rows[2].isSelected && rows[3].isSelected }
        rows[0].rightClick()
        XCTAssertFalse(app.menuItems["Rename…"].isEnabled, "Rename must not batch-rename selected sessions")
        app.typeKey(.escape, modifierFlags: [])
        rows[0].click()
        rows[1].rightClick()
        app.menuItems["Rename…"].click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("UI renamed\n")
        wait { (outline.descendants(matching: .any).matching(identifier: ids[1]).firstMatch.value as? String) == "UI renamed" }

        // Rust observes the owned rename receipt and sets up a workspace through
        // public RPC. This UI-only case does not read/write another process's files
        // or claim to test the system folder picker.
        let refresh = app.menuBars.menuBarItems["Workspace"]
        wait {
            refresh.click()
            app.menuItems["Refresh"].click()
            return outline.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'workspace.'")).count == 1
        }
        let workspace = outline.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'workspace.'")).firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 30))
        workspace.click()
        let workspaceRow = outline.outlineRows.containing(.any, identifier: workspace.identifier).firstMatch
        if !workspaceRow.isSelected { workspaceRow.click() }
        wait { labels.count == 5 }
        let existing = Set(labels.allElementsBoundByIndex.map(\.identifier))
        waitForNewSession(app)
        app.typeKey("t", modifierFlags: .command)
        wait { labels.count == 6 }
        let created = try XCTUnwrap(labels.allElementsBoundByIndex.first { !existing.contains($0.identifier) })
        XCTAssertTrue(workspaceRow.disclosedChildRows.containing(.any, identifier: created.identifier).firstMatch.exists,
            "Command-T escaped the active workspace's sidebar group")
        waitForNewSession(app)
        wait { app.textViews.count == 2 }
        let terminals = app.textViews.allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
        let terminal = try XCTUnwrap(terminals.first)
        XCTAssertLessThan(terminal.frame.minX, terminals[1].frame.minX, "Pi-left/shell-right")
        XCTAssertTrue(terminal.isEnabled)
        terminal.click()
        terminal.typeText("APP_STARTUP_TYPED_MESSAGE\n")
        wait { (terminal.value as? String)?.contains("Actual app Pi response") == true }
        // Rust verifies exact committed membership and canonical file placement
        // after this app quits through its production save/owned-helper barrier.
    }

    private func waitForNewSession(_ app: XCUIApplication) {
        wait {
            // Native menus validate when opened; keeping a disabled menu open
            // does not revalidate it as asynchronous admission completes.
            app.menuBars.menuBarItems["Workspace"].click()
            let enabled = app.menuItems["New Session"].isEnabled
            app.typeKey(.escape, modifierFlags: [])
            return enabled
        }
    }

    private func wait(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 60), .completed, file: file, line: line)
    }
}
