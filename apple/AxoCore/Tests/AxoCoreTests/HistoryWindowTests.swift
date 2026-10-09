import XCTest
@testable import AxoCore

final class HistoryWindowTests: XCTestCase {
    private func snapshot(_ ids: [Int], view: String = "view", text: String = "Synthetic message") throws -> RelayEvent {
        let messages = ids.map { ["id": "message-\($0)", "role": "user", "text": text] }
        return try RelayEvent.decode(JSONSerialization.data(withJSONObject: ["type": "snapshot", "sessionId": "session", "viewId": view,
            "state": "idle", "messages": messages, "hasEarlierMessages": true, "question": NSNull()]))
    }

    @MainActor
    func testIdleRecentWindowDoesNotStartHistoryRestoration() async throws {
        let client = ConversationClient()
        defer { client.disconnect() }
        client.apply(try snapshot(Array(980..<1000)))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(client.messages.count, 20)
        XCTAssertTrue(client.hasEarlierMessages)
        XCTAssertFalse(client.isLoadingHistory)
    }

    @MainActor
    func testDisjointLatestWindowDoesNotDiscardOlderReadingRange() throws {
        let client = ConversationClient()
        defer { client.disconnect() }
        client.apply(try snapshot(Array(0..<20)))
        client.isBrowsingHistory = true
        client.apply(try snapshot(Array(1000..<1020)))
        XCTAssertEqual(client.messages.first?.id, "message-0")
        XCTAssertTrue(client.hasLaterMessages)
        XCTAssertTrue(client.backToBottom())
        XCTAssertEqual(client.messages.first?.id, "message-1000")
        XCTAssertEqual(client.messages.last?.id, "message-1019")
        XCTAssertFalse(client.hasLaterMessages)
        XCTAssertFalse(client.isBrowsingHistory)
    }

    @MainActor
    func testBranchIdentityInvalidatesOldRangeEvenWhenMessageIDsOverlap() throws {
        let client = ConversationClient()
        defer { client.disconnect() }
        client.apply(try snapshot(Array(0..<20)))
        client.isBrowsingHistory = true
        client.apply(try snapshot(Array(19..<39), view: "new-branch"))
        XCTAssertEqual(client.messages.map(\.id), (19..<39).map { "message-\($0)" })
    }

    @MainActor
    func testDecodedHistoryCacheIsBoundedAndBottomRetainsOnlyRecentWindow() throws {
        let client = ConversationClient()
        defer { client.disconnect() }
        for end in stride(from: 20, through: 1000, by: 10) {
            client.apply(try snapshot(Array((end-20)..<end), text: String(repeating: "x", count: 4000)))
            XCTAssertLessThanOrEqual(client.messages.count, 200)
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(client.messages).count, 270 * 1024)
        }
        XCTAssertTrue(client.backToBottom())
        XCTAssertEqual(client.messages.count, 20)
        XCTAssertEqual(client.messages.last?.id, "message-999")
    }

    @MainActor
    func testOfflineBottomUsesLatestCachedWindowWithoutDispatching() throws {
        let client = ConversationClient()
        defer { client.disconnect() }
        client.apply(try snapshot(Array(0..<20)))
        client.isBrowsingHistory = true
        client.apply(try snapshot(Array(100..<120)))
        client.apply(.presence(false))
        XCTAssertTrue(client.backToBottom())
        XCTAssertEqual(client.messages.last?.id, "message-119")
        XCTAssertFalse(client.canSend)
        XCTAssertTrue(client.notice?.contains("cached") == true)
    }
}
