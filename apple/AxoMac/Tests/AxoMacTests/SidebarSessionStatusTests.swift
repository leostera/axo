import AxoProtocol
import SwiftUI
import XCTest

@testable import AxoMac

final class SidebarSessionStatusTests: XCTestCase {
  private func session(_ availability: PaneAvailability, status: TerminalSessionStatus = .ready) -> TerminalSession {
    let shell = TerminalShell(id: 7, processId: availability == .dormant ? 0 : 42,
      initialPwd: "/fixture", ptyDevice: "", attachSocketPath: "/fixture/attach.sock", role: .pi,
      availability: availability)
    return TerminalSession(id: 1, folder: "/fixture", shells: [shell], status: status)
  }

  func testSleepingAgentIsGrayDespiteBeingReadyForTheNextPromptOnTheWire() {
    let value = sidebarStatus(for: session(.dormant), attention: [])
    XCTAssertEqual(value, .sleeping)
    XCTAssertEqual(value.accessibilityDescription, "sleeping")
    XCTAssertNotEqual(value.color, SidebarSessionStatus.ready.color)
    XCTAssertEqual(value.symbolName, "circle.fill")
  }

  func testAwakeReadyAndWorkingAgentsKeepTheirActualStates() {
    XCTAssertEqual(sidebarStatus(for: session(.available), attention: []), .ready)
    XCTAssertEqual(sidebarStatus(for: session(.available, status: .working), attention: []), .working)
  }

  func testAttentionAndUnavailableAreNotHiddenBySleepingPresentation() {
    XCTAssertEqual(sidebarStatus(for: session(.dormant), attention: [7]), .needsAttention)
    XCTAssertEqual(sidebarStatus(for: session(.dormant, status: .needsAttention), attention: []), .needsAttention)
    XCTAssertEqual(sidebarStatus(for: session(.dormant, status: .unavailable), attention: []), .unavailable)
  }
}
