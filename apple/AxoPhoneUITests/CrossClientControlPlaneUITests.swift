import XCTest

final class CrossClientControlPlaneUITests: XCTestCase {
    @MainActor func testPackagedMacSessionThroughRealAPIAndReconnect() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let machine = environment["AXO_E2E_MACHINE_ID"], UUID(uuidString: machine) != nil,
              let session = environment["AXO_E2E_SESSION_ID"], UUID(uuidString: session) != nil,
              let generation = environment["AXO_E2E_HOST_GENERATION"], UUID(uuidString: generation) != nil,
              let runtimeText = environment["AXO_E2E_RUNTIMES"] else {
            throw XCTSkip("Run scripts/check-cross-client.sh with its owned Mac/API/simulator fixture")
        }
        let runtimes = runtimeText.split(separator: ",").map(String.init)
        XCTAssertEqual(runtimes.count, 2)
        XCTAssertTrue(runtimes.allSatisfy { UUID(uuidString: $0) != nil })
        let app = XCUIApplication()
        app.launchArguments = ["--axo-control-plane-e2e"]
        app.launch()
        defer { app.terminate() }
        let host = app.buttons["machine-\(machine)"]
        XCTAssertTrue(host.waitForExistence(timeout: 20), "Real authenticated machine discovery")
        host.tap()
        let record = app.descendants(matching: .any)["control-plane-session-\(session)"]
        XCTAssertTrue(record.waitForExistence(timeout: 20), "Exact Mac standalone session identity")
        XCTAssertTrue(record.label.contains("Pi ready"), "Actual Mac Pi admission")
        let status = app.descendants(matching: .any)["machine-online-status"]
        XCTAssertEqual(status.value as? String, generation, "Exact Mac host generation")
        assertRuntimes(app, runtimes: runtimes, generation: generation)

        let disconnect = app.buttons["control-plane-disconnect"]
        for _ in 0..<3 where !disconnect.isHittable { app.swipeDown() }
        disconnect.tap()
        let reconnect = app.buttons["control-plane-reconnect"]
        for _ in 0..<3 where !reconnect.exists { app.swipeDown() }
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5))
        reconnect.tap()
        XCTAssertTrue(app.buttons["control-plane-disconnect"].waitForExistence(timeout: 15))
        XCTAssertTrue(record.waitForExistence(timeout: 10), "Reconnect retains original session identity")
        XCTAssertEqual(status.value as? String, generation)
        assertRuntimes(app, runtimes: runtimes, generation: generation)
    }

    @MainActor private func assertRuntimes(_ app: XCUIApplication, runtimes: [String], generation: String) {
        for runtime in runtimes {
            let row = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier == 'machine-runtime-current' AND value == %@", "\(runtime)|\(generation)"
            )).firstMatch
            for _ in 0..<3 where !row.exists { app.swipeUp() }
            XCTAssertTrue(row.waitForExistence(timeout: 10), "Exact daemon-owned runtime identity")
        }
        XCTAssertFalse(app.descendants(matching: .any)["machine-runtime-historical"].exists)
    }
}
