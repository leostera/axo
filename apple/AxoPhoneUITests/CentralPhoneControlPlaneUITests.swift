import XCTest

final class CentralPhoneControlPlaneUITests: XCTestCase {
    @MainActor
    func testPrimaryPhoneReadsExactMacSessionAndBindingAfterReconnect() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let machine = environment["AXO_E2E_MACHINE_ID"], UUID(uuidString: machine) != nil,
              let session = environment["AXO_E2E_SESSION_ID"], UUID(uuidString: session) != nil,
              let generation = environment["AXO_E2E_HOST_GENERATION"], UUID(uuidString: generation) != nil,
              let runtimeText = environment["AXO_E2E_RUNTIMES"] else {
            throw XCTSkip("Requires an explicitly owned disposable Axod/API/Simulator fixture and exact AXO_E2E identities")
        }
        let runtimes = runtimeText.split(separator: ",").map(String.init)
        XCTAssertEqual(runtimes.count, 2)
        XCTAssertTrue(runtimes.allSatisfy { UUID(uuidString: $0) != nil })

        let app = XCUIApplication()
        app.launchArguments = ["--axo-control-plane-e2e"]
        app.launch()
        defer { app.terminate() }

        let host = app.buttons["machine-\(machine.lowercased())"]
        XCTAssertTrue(host.waitForExistence(timeout: 20), "Authenticated central machine discovery")
        host.tap()
        let record = app.descendants(matching: .any)["control-plane-session-\(session.lowercased())"]
        XCTAssertTrue(record.waitForExistence(timeout: 20), "Exact central Mac session identity")
        let status = app.descendants(matching: .any)["machine-online-status"]
        XCTAssertEqual(status.value as? String, generation.lowercased(), "Exact Mac host generation")
        assertRuntimes(app, runtimes: runtimes, generation: generation)

        let open = app.descendants(matching: .any)["control-plane-session-open-\(session.lowercased())"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let composer = app.descendants(matching: .any)["central-pi-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "Primary route reads the exact admitted Pi binding")
        XCTAssertTrue(composer.isEnabled, "The disposable fixture promises an exact live binding")
        XCTAssertFalse(app.buttons["central-pi-send"].isEnabled, "An empty draft cannot submit")
        app.buttons["Close"].tap()

        let disconnect = app.buttons["control-plane-disconnect"]
        for _ in 0..<3 where !disconnect.isHittable { app.swipeDown() }
        disconnect.tap()
        let reconnect = app.buttons["control-plane-reconnect"]
        for _ in 0..<3 where !reconnect.exists { app.swipeDown() }
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5))
        reconnect.tap()
        XCTAssertTrue(app.buttons["control-plane-disconnect"].waitForExistence(timeout: 15))
        XCTAssertEqual(status.value as? String, generation.lowercased())
        assertRuntimes(app, runtimes: runtimes, generation: generation)
    }

    @MainActor
    private func assertRuntimes(_ app: XCUIApplication, runtimes: [String], generation: String) {
        for runtime in runtimes {
            let row = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier == 'machine-runtime-current' AND value == %@", "\(runtime.lowercased())|\(generation.lowercased())"
            )).firstMatch
            for _ in 0..<3 where !row.exists { app.swipeUp() }
            XCTAssertTrue(row.waitForExistence(timeout: 10), "Exact daemon-owned runtime identity")
        }
        XCTAssertFalse(app.descendants(matching: .any)["machine-runtime-historical"].exists)
    }
}
