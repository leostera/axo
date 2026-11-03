import AppKit
import AxoDaemonManager
import XCTest

@testable import AxoMac

final class LaunchSplashGateTests: XCTestCase {
  func testWaitsUntilReadyHoweverLongItTakes() {
    XCTAssertFalse(LaunchSplashGate.shouldReveal(ready: false, elapsed: .seconds(3)))
    XCTAssertFalse(LaunchSplashGate.shouldReveal(ready: false, elapsed: .seconds(600)))
    XCTAssertTrue(LaunchSplashGate.shouldReveal(ready: true, elapsed: .seconds(3)))
  }

  func testDoesNotFlashWhenAlreadyReady() {
    XCTAssertFalse(LaunchSplashGate.shouldReveal(ready: true, elapsed: .milliseconds(200)))
  }

  func testAsksThePersonOnlyWhenAxodCannotStartWithoutThem() {
    XCTAssertEqual(LaunchSplashGate.attention(for: .requiresApproval), .approveInLoginItems)
    XCTAssertEqual(LaunchSplashGate.attention(for: .disabled), .turnOn)
    XCTAssertEqual(LaunchSplashGate.attention(for: .failed("boom")), .retry(reason: "boom"))
    XCTAssertNil(LaunchSplashGate.attention(for: .starting))
    XCTAssertNil(LaunchSplashGate.attention(for: .updating))
  }

  func testProgressFollowsTheLaunchSteps() {
    XCTAssertEqual(LaunchSplashGate.progress(daemonRunning: false, catalogLive: false), 0.25)
    XCTAssertEqual(LaunchSplashGate.progress(daemonRunning: true, catalogLive: false), 0.65)
    XCTAssertEqual(LaunchSplashGate.progress(daemonRunning: true, catalogLive: true), 1)
    // A live catalog without a running daemon is stale, not done.
    XCTAssertEqual(LaunchSplashGate.progress(daemonRunning: false, catalogLive: true), 0.25)
  }

  func testTheTerminalShowsOnlyAFullyOperationalAxod() {
    XCTAssertTrue(LaunchSplashGate.isOperational(daemonRunning: true, catalogLive: true))
    XCTAssertFalse(LaunchSplashGate.isOperational(daemonRunning: true, catalogLive: false))
    XCTAssertFalse(LaunchSplashGate.isOperational(daemonRunning: false, catalogLive: true))

    XCTAssertEqual(LaunchSplashGate.terminalHold(daemonRunning: true, catalogLive: true), .show)
    // Starting, updating, restarting: the splash at once, whatever the catalog last said.
    XCTAssertEqual(LaunchSplashGate.terminalHold(daemonRunning: false, catalogLive: true), .holdNow)
    XCTAssertEqual(LaunchSplashGate.terminalHold(daemonRunning: false, catalogLive: false), .holdNow)
    // Reported running but its catalog down: the splash unless it comes back within the grace.
    XCTAssertEqual(
      LaunchSplashGate.terminalHold(daemonRunning: true, catalogLive: false), .holdAfterGrace)
  }
}

@MainActor
final class TerminalSplashHoldTests: XCTestCase {
  private var window: NSWindow!
  private var hold: TerminalSplashHold.HoldView!
  private var splashOpens = 0

  override func setUp() async throws {
    TerminalWindowOpener.heldForSplash = false
    TerminalWindowOpener.heldWindow = nil
    hold = TerminalSplashHold.HoldView()
    hold.grace = .milliseconds(50)
    hold.openSplash = { [unowned self] in self.splashOpens += 1 }
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = hold
    window.orderFront(nil)
  }

  override func tearDown() async throws {
    window.orderOut(nil)
    TerminalWindowOpener.heldForSplash = false
    TerminalWindowOpener.heldWindow = nil
  }

  private func settle(_ duration: Duration = .milliseconds(150)) async throws {
    try await Task.sleep(for: duration)
  }

  func testAxodStoppingHandsTheScreenToTheSplashAtOnce() async throws {
    hold.hold = .holdNow
    XCTAssertEqual(window.alphaValue, 0, "hidden before it draws again")
    try await settle()
    XCTAssertFalse(window.isVisible)
    XCTAssertEqual(splashOpens, 1)
    XCTAssertTrue(TerminalWindowOpener.heldWindow === window)

    // Still not operational: the splash is already up, so nothing happens again.
    hold.hold = .holdAfterGrace
    hold.hold = .holdNow
    try await settle()
    XCTAssertEqual(splashOpens, 1)
  }

  func testACatalogBlipThatRecoversWithinTheGraceKeepsTheTerminal() async throws {
    hold.hold = .holdAfterGrace
    try await settle(.milliseconds(10))
    hold.hold = .show
    try await settle()
    XCTAssertTrue(window.isVisible)
    XCTAssertEqual(window.alphaValue, 1)
    XCTAssertEqual(splashOpens, 0)
  }

  func testACatalogOutagePastTheGraceHandsTheScreenToTheSplash() async throws {
    hold.hold = .holdAfterGrace
    XCTAssertTrue(window.isVisible, "waits out the grace first")
    try await settle()
    XCTAssertFalse(window.isVisible)
    XCTAssertEqual(splashOpens, 1)
  }
}
