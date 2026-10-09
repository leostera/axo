import XCTest
@testable import AxoCore

final class MacSessionStateTests: XCTestCase {
    private let session = AxoSessionID(), pane = PaneID(), generation = UUID()
    private func snapshot(_ state: MacAgentState, episode: String? = nil, reason: MacAttentionReason? = nil) -> MacSessionState {
        MacSessionState(version: 1, sessionID: session.rawValue.uuidString, paneID: pane.rawValue.uuidString,
                        runtimeGeneration: generation.uuidString, updatedAt: Date().timeIntervalSince1970 * 1_000, conversationID: "pi-conversation", state: state,
                        attentionID: episode, attentionReason: reason)
    }
    func testIdentityAndRuntimeMustMatchBeforeAnObservationIsAccepted() {
        let frame = snapshot(.working)
        XCTAssertTrue(frame.matches(session: session, pane: pane, generation: generation))
        XCTAssertFalse(frame.matches(session: AxoSessionID(), pane: pane, generation: generation))
        XCTAssertFalse(frame.matches(session: session, pane: PaneID(), generation: generation))
        XCTAssertFalse(frame.matches(session: session, pane: pane, generation: UUID()))
        XCTAssertFalse(snapshot(.attention).matches(session: session, pane: pane, generation: generation))
        XCTAssertFalse(snapshot(.working, episode: UUID().uuidString).matches(session: session, pane: pane, generation: generation))
    }
    func testExpiredAndFutureObservationsCannotRemainWorking() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot(.working))) as? [String: Any])
        for time in [0.0, Date().timeIntervalSince1970 * 1_000 + 10_000] {
            json["updatedAt"] = time
            let stale = try JSONDecoder().decode(MacSessionState.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertFalse(stale.matches(session: session, pane: pane, generation: generation))
        }
    }

    func testAttentionDeduplicatesAndAcknowledgesOnlyViewedEpisodes() {
        var receipt = MacAttentionReceipt()
        let first = snapshot(.attention, episode: UUID().uuidString, reason: .result)
        XCTAssertTrue(receipt.observe(first, isViewing: false))
        XCTAssertFalse(receipt.observe(first, isViewing: false))
        XCTAssertEqual(receipt.presentation(first), .attention)
        XCTAssertFalse(receipt.observe(first, isViewing: true))
        XCTAssertEqual(receipt.presentation(first), .idle)
        let second = snapshot(.attention, episode: UUID().uuidString, reason: .result)
        XCTAssertTrue(receipt.observe(second, isViewing: false))
        XCTAssertEqual(receipt.presentation(second), .attention)
        XCTAssertFalse(receipt.observe(snapshot(.working), isViewing: false))
    }
    func testVisibleQuestionsRemainAttentionUntilAnsweredButDoNotGenerateBanners() {
        var receipt = MacAttentionReceipt()
        let question = snapshot(.attention, episode: UUID().uuidString, reason: .question)
        XCTAssertFalse(receipt.observe(question, isViewing: true))
        XCTAssertEqual(receipt.presentation(question), .attention)
        XCTAssertFalse(receipt.observe(question, isViewing: false))
        XCTAssertEqual(receipt.presentation(snapshot(.working)), .working)
    }
    func testLocalObservationReaderRejectsSymlinksOversizedAndMalformedFiles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let link = file.appendingPathExtension("link")
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: link) }
        let frame = snapshot(.working)
        try JSONEncoder().encode(frame).write(to: file)
        XCTAssertEqual(MacSessionState.read(from: file.path), frame)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertNil(MacSessionState.read(from: link.path))
        try Data(repeating: 32, count: 4_097).write(to: file)
        XCTAssertNil(MacSessionState.read(from: file.path))
        try Data("bad json".utf8).write(to: file)
        XCTAssertNil(MacSessionState.read(from: file.path))
    }
}
