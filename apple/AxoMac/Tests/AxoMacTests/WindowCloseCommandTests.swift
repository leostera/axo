import AppKit
import XCTest
@testable import AxoMac

@MainActor
final class WindowCloseCommandTests: XCTestCase {
  private final class Window: NSWindow {
    var closeRequests = 0
    var modal = false
    var blockingSheet: NSWindow?
    override var isSheet: Bool { modal }
    override var attachedSheet: NSWindow? { blockingSheet }
    override func performClose(_ sender: Any?) { closeRequests += 1 }
  }

  private func window(_ id: String?) -> Window {
    let window = Window(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled, .closable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.identifier = id.map { NSUserInterfaceItemIdentifier(rawValue: $0) }
    return window
  }

  func testAuxiliaryWindowsCloseWithoutEvenConsultingTheRememberedPane() {
    for id in ["settings", "axo-setup", LaunchSplashView.windowID, "updates", nil] as [String?] {
      let window = window(id)
      WindowCloseCommand.perform(keyWindow: window) {
        XCTFail("An auxiliary window must never request a terminal-pane close")
        return true
      }
      XCTAssertEqual(window.closeRequests, 1)
    }
  }

  func testTerminalWindowUsesTheExistingPaneClosePathWithoutClosingTheWindow() {
    for id in [TerminalWindowOpener.windowID, TerminalWindowOpener.windowID + "-1"] {
      let window = window(id)
      var paneRequests = 0
      WindowCloseCommand.perform(keyWindow: window) { paneRequests += 1; return true }
      XCTAssertEqual(paneRequests, 1, "Busy-pane confirmation remains owned by the existing request path")
      XCTAssertEqual(window.closeRequests, 0)
    }
  }

  func testTerminalWithoutAFocusedPaneClosesOnlyItsWindow() {
    let window = window(TerminalWindowOpener.windowID)
    WindowCloseCommand.perform(keyWindow: window) { false }
    XCTAssertEqual(window.closeRequests, 1)
  }

  func testNoKeyWindowNeverFallsBackToTheMainWindowOrRememberedPane() {
    WindowCloseCommand.perform(keyWindow: nil) {
      XCTFail("No key window means no close target")
      return true
    }
  }

  func testModalQuestionsCannotCloseThePaneBehindThem() {
    let parent = window(TerminalWindowOpener.windowID)
    let sheet = window(TerminalWindowOpener.windowID)
    parent.blockingSheet = sheet
    sheet.modal = true
    for window in [parent, sheet] {
      WindowCloseCommand.perform(keyWindow: window) {
        XCTFail("A modal question must not close a pane")
        return true
      }
      XCTAssertEqual(window.closeRequests, 0)
    }
  }
}
