import XCTest

@testable import AxoMac

final class TerminalSurfaceStatusTests: XCTestCase {
  func testSecureInputReadonlyAndRendererHealth() {
    var status = TerminalSurfaceStatus()
    status.apply(.secureInput(.toggle))
    XCTAssertTrue(status.secureInput)
    status.apply(.secureInput(.toggle))
    XCTAssertFalse(status.secureInput)
    status.apply(.secureInput(.on))
    status.apply(.readonly(true))
    status.apply(.rendererHealthy(false))
    XCTAssertEqual(status.badges, ["Renderer unhealthy", "Read-only", "Secure input"])
    status.apply(.secureInput(.off))
    status.apply(.readonly(false))
    status.apply(.rendererHealthy(true))
    XCTAssertEqual(status.badges, [])
  }

  func testKeyTablesStackAndKeySequence() {
    var status = TerminalSurfaceStatus()
    status.apply(.keyTableActivate("resize"))
    status.apply(.keyTableActivate("nav"))
    XCTAssertEqual(status.badges, ["Key table: nav"])
    status.apply(.keyTableDeactivate)
    XCTAssertEqual(status.keyTables, ["resize"])
    status.apply(.keyTableDeactivateAll)
    status.apply(.keySequence(active: true))
    XCTAssertEqual(status.badges, ["Key sequence…"])
  }

  func testProgressReportStates() {
    var status = TerminalSurfaceStatus()
    status.apply(.progress(.set, percent: 42))
    XCTAssertEqual(status.progress, .value(42))
    status.apply(.progress(.set, percent: -1))
    XCTAssertEqual(status.progress, .indeterminate)
    status.apply(.progress(.error, percent: 120))
    XCTAssertEqual(status.progress, .error(100))
    status.apply(.progress(.pause, percent: -1))
    XCTAssertEqual(status.badges, ["Paused"])
    status.apply(.progress(.remove, percent: 0))
    XCTAssertNil(status.progress)
  }

  func testChildExitedIsShownFirst() {
    var status = TerminalSurfaceStatus()
    status.apply(.readonly(true))
    status.apply(.childExited(.init(exitCode: 2, runtimeMilliseconds: 3_000)))
    XCTAssertEqual(status.badges.first?.hasPrefix("Process exited with code 2 after"), true)
  }

  func testSearchTracksNeedleTotalsAndEnd() {
    var status = TerminalSurfaceStatus()
    status.apply(.searchTotal(3))
    XCTAssertNil(status.search, "counts without an active search are ignored")
    status.apply(.startSearch("foo"))
    status.apply(.searchTotal(5))
    status.apply(.searchSelected(1))
    XCTAssertEqual(status.search, .init(needle: "foo", total: 5, selected: 1))
    status.apply(.searchSelected(-1))
    XCTAssertNil(status.search?.selected)
    status.apply(.endSearch)
    XCTAssertNil(status.search)
  }

  func testBellFeaturesMapToEffects() {
    XCTAssertEqual(
      TerminalAttentionPolicy.bellEffects(.defaultValue), .init(beep: false, requestAttention: true))
    XCTAssertEqual(
      TerminalAttentionPolicy.bellEffects([.system]), .init(beep: true, requestAttention: false))
  }

  func testCommandFinishedFollowsGhosttyConfig() {
    var config = TerminalAttentionConfig()
    let long: UInt64 = 6_000_000_000
    XCTAssertEqual(
      TerminalAttentionPolicy.commandFinished(
        exitCode: 0, durationNanoseconds: long, surfaceFocused: false, config: config),
      .init(), "default is never")

    config.notifyOnCommandFinish = .unfocused
    config.commandFinishActions = [.bell, .notify]
    XCTAssertEqual(
      TerminalAttentionPolicy.commandFinished(
        exitCode: 0, durationNanoseconds: long, surfaceFocused: true, config: config), .init())
    XCTAssertEqual(
      TerminalAttentionPolicy.commandFinished(
        exitCode: 0, durationNanoseconds: 1_000_000_000, surfaceFocused: false, config: config),
      .init(), "shorter than notify-on-command-finish-after")

    let failed = TerminalAttentionPolicy.commandFinished(
      exitCode: 1, durationNanoseconds: long, surfaceFocused: false, config: config)
    XCTAssertTrue(failed.bell)
    XCTAssertEqual(failed.notification?.title, "Command Failed")
    XCTAssertEqual(failed.notification?.body.hasSuffix("exited with code 1."), true)

    config.notifyOnCommandFinish = .always
    let unknown = TerminalAttentionPolicy.commandFinished(
      exitCode: -1, durationNanoseconds: long, surfaceFocused: true, config: config)
    XCTAssertEqual(unknown.notification?.title, "Command Finished")
  }

  func testDesktopNotificationsRespectConfig() {
    var config = TerminalAttentionConfig()
    XCTAssertTrue(TerminalAttentionPolicy.shouldPostDesktopNotification(config: config))
    config.desktopNotifications = false
    XCTAssertFalse(TerminalAttentionPolicy.shouldPostDesktopNotification(config: config))
  }
}

@MainActor
final class TerminalFindTests: XCTestCase {
  func testFindActionsMatchGhosttyBindings() {
    XCTAssertEqual(TerminalFindAction.start.bindingAction, "start_search")
    XCTAssertEqual(TerminalFindAction.selection.bindingAction, "search_selection")
    XCTAssertEqual(TerminalFindAction.end.bindingAction, "end_search")
    XCTAssertEqual(TerminalFindAction.next.bindingAction, "navigate_search:next")
    XCTAssertEqual(TerminalFindAction.previous.bindingAction, "navigate_search:previous")
    XCTAssertEqual(TerminalFindAction.search("a b").bindingAction, "search:a b")
  }

  func testCountLabel() {
    XCTAssertEqual(TerminalFindAction.countLabel(nil), "")
    XCTAssertEqual(TerminalFindAction.countLabel(.init(needle: "x", total: nil, selected: nil)), "")
    XCTAssertEqual(TerminalFindAction.countLabel(.init(needle: "x", total: 1, selected: nil)), "1 match")
    XCTAssertEqual(TerminalFindAction.countLabel(.init(needle: "x", total: 5, selected: 1)), "2 of 5")
    XCTAssertEqual(TerminalFindAction.countLabel(.init(needle: "x", total: 0, selected: nil)), "0 matches")
  }

  func testFindBarFollowsSearchStateAndSendsQueries() {
    let bar = TerminalFindBarView()
    var sent: [TerminalFindAction] = []
    bar.onAction = { sent.append($0) }
    let bounds = NSRect(x: 0, y: 0, width: 600, height: 400)

    bar.show(.init(needle: "foo", total: 3, selected: 0), in: bounds)
    XCTAssertFalse(bar.isHidden)
    XCTAssertEqual(bar.field.stringValue, "foo")
    bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    XCTAssertEqual(sent, [], "an unchanged needle is not re-sent")

    bar.field.stringValue = "food"
    bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    XCTAssertEqual(sent, [.search("food")])
    XCTAssertTrue(
      bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    XCTAssertEqual(sent.last, .end)

    bar.show(nil, in: bounds)
    XCTAssertTrue(bar.isHidden)
  }
}
