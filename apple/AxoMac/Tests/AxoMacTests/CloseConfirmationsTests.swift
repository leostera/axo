import AxoProtocol
import XCTest

@testable import AxoMac

final class CloseConfirmationsTests: XCTestCase {
  private func session(_ id: SessionID, workspace: String? = nil) -> TerminalSession {
    TerminalSession(id: id, initialPwd: "/", shells: [], workspaceId: workspace)
  }

  private let workspaceA = WorkspaceRecord(workspaceId: "a", name: "Alpha", directoryPath: "/a")

  func testClosingAPaneAsksExactlyWhenItIsBusyOrAxodCannotSay() {
    let idle = TerminalShellBusy(busy: false, foregroundProcess: nil)
    let vim = TerminalShellBusy(busy: true, foregroundProcess: "vim")
    typealias Reason = ShellCloseConfirmation.Reason
    XCTAssertNil(Reason(closing: .terminal, busy: idle))
    XCTAssertNil(Reason(closing: .pi, busy: idle))
    XCTAssertEqual(Reason(closing: .terminal, busy: vim), .runningProcess("vim"))
    XCTAssertEqual(Reason(closing: .pi, busy: vim), .piWorking)
    XCTAssertEqual(Reason(closing: .terminal, busy: nil), .unknown)
    XCTAssertEqual(Reason(closing: .pi, busy: nil), .unknown)
  }

  func testOnlyAWorkspacesLastSessionNeedsArchiveConfirmation() {
    let standalone = session(1)
    let onlyInA = session(2, workspace: "a")
    XCTAssertEqual(
      SessionClosePlan(closing: standalone, sessions: [standalone], workspaces: [workspaceA]),
      .close)
    XCTAssertEqual(
      SessionClosePlan(closing: onlyInA, sessions: [standalone, onlyInA], workspaces: [workspaceA]),
      .confirmArchive(
        WorkspaceArchiveConfirmation(workspaceID: "a", workspaceName: "Alpha", sessionID: 2)))

    let siblingInA = session(3, workspace: "a")
    XCTAssertEqual(
      SessionClosePlan(closing: onlyInA, sessions: [onlyInA, siblingInA], workspaces: [workspaceA]),
      .close)
  }

  func testTheLastSessionOfAnUnlistedWorkspaceIsNotClosedBlind() {
    let onlyInA = session(2, workspace: "a")
    XCTAssertEqual(
      SessionClosePlan(closing: onlyInA, sessions: [onlyInA], workspaces: []),
      .workspaceUnavailable)
  }

  func testAnArchiveConfirmationLapsesWhenItsWorkspaceChanges() {
    let confirmation = WorkspaceArchiveConfirmation(
      workspaceID: "a", workspaceName: "Alpha", sessionID: 2)
    let onlyInA = session(2, workspace: "a")
    XCTAssertTrue(confirmation.stillApplies(sessions: [onlyInA], workspaces: [workspaceA]))
    // A Session joined the Workspace, the Session went away, or the Workspace did.
    XCTAssertFalse(
      confirmation.stillApplies(
        sessions: [onlyInA, session(3, workspace: "a")], workspaces: [workspaceA]))
    XCTAssertFalse(confirmation.stillApplies(sessions: [], workspaces: [workspaceA]))
    XCTAssertFalse(confirmation.stillApplies(sessions: [onlyInA], workspaces: []))
  }

  func testAPendingSplitResizesOnlyWhileCreatingAndStaysInsideThePane() {
    var split = PendingTerminalSplit(
      id: UUID(), sessionID: 1, anchorShellID: 1, direction: .right, ratio: 0.5,
      status: .creating)
    split.resize(to: 0.3)
    XCTAssertEqual(split.ratio, 0.3)
    split.resize(to: -4)
    XCTAssertEqual(split.ratio, 0.01)
    split.resize(to: 9)
    XCTAssertEqual(split.ratio, 0.99)
    split.status = .rejected("no")
    split.resize(to: 0.5)
    XCTAssertEqual(split.ratio, 0.99)
  }
}

@MainActor
final class AxodCapabilitiesTests: XCTestCase {
  func testNegotiatesOncePerConnectionAndAgainAfterForgetting() async throws {
    let client = FakeAxodClient()
    let capabilities = AxodCapabilities(client: client)
    let supportsBusy = try await capabilities.supports(.shellBusy)
    XCTAssertTrue(supportsBusy)
    let supportsList = try await capabilities.supports(.sessionList)
    XCTAssertTrue(supportsList)
    XCTAssertEqual(client.negotiateCount, 1)

    client.methods.removeAll { $0 == AxodMethodName.shellBusy.rawValue }
    capabilities.forget()
    let supportsBusyAfterUpgrade = try await capabilities.supports(.shellBusy)
    XCTAssertFalse(supportsBusyAfterUpgrade)
    XCTAssertEqual(client.negotiateCount, 2)
  }

  func testRefusesAnotherProtocolVersionOrAMissingRequiredMethod() async {
    let otherVersion = FakeAxodClient()
    otherVersion.protocolVersion = ProtocolNegotiation.supportedVersion + 1
    await assertIncompatible(otherVersion)

    let missingList = FakeAxodClient()
    missingList.methods.removeAll { $0 == AxodMethodName.sessionList.rawValue }
    await assertIncompatible(missingList)
  }

  func testUnknownMethodNamesAreIgnoredAndOptionalOnesAreRequiredOnDemand() async throws {
    let client = FakeAxodClient()
    client.methods = AxodCapabilities.requiredMethods.map(\.rawValue) + ["axo.future.method"]
    let capabilities = AxodCapabilities(client: client)
    try await capabilities.negotiate()
    do {
      try await capabilities.require(.workspaceRename)
      XCTFail("an Axod without workspace rename must refuse it")
    } catch {
      XCTAssertTrue(error is SessionCommandError)
    }
  }

  private func assertIncompatible(_ client: FakeAxodClient, line: UInt = #line) async {
    do {
      try await AxodCapabilities(client: client).negotiate()
      XCTFail("negotiation must fail", line: line)
    } catch {
      XCTAssertTrue(error is SessionCommandError, line: line)
    }
  }
}
