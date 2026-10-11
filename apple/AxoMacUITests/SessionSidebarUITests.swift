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

        let existing = Set(labels.allElementsBoundByIndex.map(\.identifier))
        createWorkspace(app, folder: root + "/workspace")
        wait { labels.count == 5 }
        let workspace = outline.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'workspace.'")).firstMatch
        XCTAssertTrue(workspace.exists, "Creating a workspace must update the sidebar without Refresh")
        let workspaceID = workspace.identifier
        let workspaceRow = outline.outlineRows.containing(.any, identifier: workspaceID).firstMatch
        let createdID = try XCTUnwrap(labels.allElementsBoundByIndex.first { !existing.contains($0.identifier) }).identifier
        XCTAssertTrue(workspaceRow.disclosedChildRows.containing(.any, identifier: createdID).firstMatch.exists)
        XCTAssertTrue(outline.outlineRows.containing(.any, identifier: createdID).firstMatch.isSelected,
            "Creating a workspace must immediately select its initial session")
        waitForNewSession(app)
        assertMinimalChrome(app)
        wait { app.textViews.count == 2 }
        let terminals = app.textViews.allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
        let terminal = try XCTUnwrap(terminals.first)
        XCTAssertLessThan(terminal.frame.minX, terminals[1].frame.minX, "Pi-left/shell-right")
        XCTAssertTrue(terminal.isEnabled)
        terminal.click()
        terminal.typeText("APP_STARTUP_TYPED_MESSAGE\n")
        wait { (terminal.value as? String)?.contains("Actual app Pi response") == true }

        // Command-T is a separate membership check, never a workaround for an
        // uninitialized first session. That session has already answered a turn.
        let beforeSecond = Set(labels.allElementsBoundByIndex.map(\.identifier))
        app.typeKey("t", modifierFlags: .command)
        wait { labels.count == 6 }
        let secondID = try XCTUnwrap(labels.allElementsBoundByIndex.first { !beforeSecond.contains($0.identifier) }).identifier
        XCTAssertTrue(workspaceRow.disclosedChildRows.containing(.any, identifier: secondID).firstMatch.exists)
        waitForNewSession(app)
        outline.outlineRows.containing(.any, identifier: createdID).firstMatch.click()
        wait { app.textViews.count == 2 && app.textViews.element(boundBy: 0).isEnabled }

        // Outside-selection Delete must target the clicked row, not this live Pi.
        let outside = outline.outlineRows.containing(.any, identifier: ids[0]).firstMatch
        outside.rightClick(); app.menuItems["Delete…"].click()
        XCTAssertTrue(app.sheets.buttons["Cancel"].waitForExistence(timeout: 10))
        app.sheets.buttons["Cancel"].click()
        XCTAssertEqual(labels.count, 6)
        XCTAssertTrue(outline.outlineRows.containing(.any, identifier: createdID).firstMatch.isSelected)
        outside.rightClick(); app.menuItems["Delete…"].click()
        XCTAssertTrue(app.sheets.buttons["Delete"].waitForExistence(timeout: 10))
        app.sheets.buttons["Delete"].click()
        wait { labels.count == 5 && !outline.descendants(matching: .any).matching(identifier: ids[0]).firstMatch.exists }
        XCTAssertTrue(terminal.isEnabled, "Deleting an outside row stopped the displayed Pi")

        // A selected cross-workspace pair is one confirmed batch, not two global-current actions.
        let selected = outline.outlineRows.containing(.any, identifier: ids[2]).firstMatch
        let project = outline.outlineRows.containing(.any, identifier: createdID).firstMatch
        selected.click()
        XCUIElement.perform(withKeyModifiers: .command) { project.click() }
        XCTAssertTrue(selected.isSelected && project.isSelected)
        project.rightClick(); app.menuItems["Delete…"].click()
        XCTAssertTrue(app.sheets.buttons["Delete"].waitForExistence(timeout: 10))
        app.sheets.buttons["Delete"].click()
        wait { labels.count == 3 && !outline.descendants(matching: .any).matching(identifier: ids[2]).firstMatch.exists
            && !outline.descendants(matching: .any).matching(identifier: createdID).firstMatch.exists }
        XCTAssertTrue(outline.descendants(matching: .any).matching(identifier: ids[1]).firstMatch.exists)
        XCTAssertTrue(outline.descendants(matching: .any).matching(identifier: ids[3]).firstMatch.exists)
        waitForNewSession(app)
        // Rust verifies exact committed membership and canonical file placement
        // after this app quits through its production save/owned-helper barrier.
    }

    private func createWorkspace(_ app: XCUIApplication, folder: String) {
        app.menuBars.menuBarItems["Workspace"].click()
        app.menuItems["New Workspace…"].click()
        let name = app.textFields["Axo.Workspace.Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.click(); name.typeText("UI Workspace")
        app.buttons["Axo.Workspace.ChooseFolder"].click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields["PathTextField"]
        XCTAssertTrue(path.waitForExistence(timeout: 10))
        path.click()
        path.typeKey("a", modifierFlags: .command)
        path.typeText(folder)
        XCTAssertEqual(path.value as? String, folder, "Go to Folder must contain the exact owned directory")
        path.typeKey(.return, modifierFlags: [])
        wait { !app.textFields["PathTextField"].exists }
        let open = app.sheets.buttons["OKButton"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        wait { open.isEnabled }
        open.click()
        wait { !app.sheets.matching(identifier: "open-panel").firstMatch.exists }
        let create = app.buttons["Axo.Workspace.Create"]
        wait { create.isEnabled }
        create.click()
    }

    private func assertMinimalChrome(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        XCTAssertEqual(window.toolbars.count, 0, "The titlebar must not contain a sidebar toolbar")
        for label in ["Settings", "Create workspace or session", "Conversation", "Start Pi"] {
            XCTAssertFalse(window.buttons[label].exists, "Unexpected healthy chrome: \(label)")
        }
        XCTAssertFalse(window.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'connected locally'")).firstMatch.exists)
        let headings = window.descendants(matching: .any)
        let workspaces = headings.matching(identifier: "Axo.Sidebar.Heading.workspaces").firstMatch
        let sessions = headings.matching(identifier: "Axo.Sidebar.Heading.sessions").firstMatch
        XCTAssertTrue(workspaces.exists && sessions.exists)
        XCTAssertLessThan(workspaces.frame.minY, sessions.frame.minY, "Workspaces must precede standalone Sessions")
        window.buttons["Collapse sidebar"].click()
        XCTAssertTrue(window.buttons["Expand sidebar"].waitForExistence(timeout: 10))
        XCTAssertFalse(window.buttons["Create workspace or session"].exists)
        window.buttons["Expand sidebar"].click()
        XCTAssertTrue(window.buttons["Collapse sidebar"].waitForExistence(timeout: 10))
        XCTAssertTrue(window.outlines.firstMatch.exists)
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
        let result = XCTWaiter.wait(for: [expectation], timeout: 60)
        if result != .completed, let application {
            let attachment = XCTAttachment(string: application.debugDescription)
            attachment.name = "Owned fixture UI at timeout"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(result, .completed, file: file, line: line)
    }
}
