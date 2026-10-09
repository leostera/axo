import XCTest
@testable import AxoCore

final class ConversationScrollStateTests: XCTestCase {
    func testNewMessagesDoNotTurnOffFollowing() {
        var state = ConversationScrollState()
        state.latestMessageChanged(from: "first", to: "second")
        XCTAssertTrue(state.followsLatest)
        XCTAssertFalse(state.hasNewMessages)
    }

    func testArrivalWhileReadingOlderMessagesDoesNotMoveReadingIntent() {
        var state = ConversationScrollState()
        state.userScrolled(isAtLatest: false)
        state.latestMessageChanged(from: "first", to: "second")
        XCTAssertFalse(state.followsLatest)
        XCTAssertTrue(state.hasNewMessages)
        state.jumpToLatest()
        XCTAssertTrue(state.followsLatest)
        XCTAssertFalse(state.hasNewMessages)
    }

    func testInitialHistoryAndSameMessageStreamingAreNotNewArrivals() {
        var state = ConversationScrollState()
        state.userScrolled(isAtLatest: false)
        state.latestMessageChanged(from: nil, to: "first")
        state.latestMessageChanged(from: "first", to: "first")
        XCTAssertFalse(state.hasNewMessages)
        state.latestMessageChanged(from: "first", to: "second")
        state.userScrolled(isAtLatest: true)
        XCTAssertFalse(state.hasNewMessages)
        XCTAssertTrue(state.followsLatest)
    }
}
