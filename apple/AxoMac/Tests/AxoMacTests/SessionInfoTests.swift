import AxoProtocol
import XCTest

@testable import AxoMac

final class SessionInfoTests: XCTestCase {
  func testThisMacsSessionNamesItsIDWorkspaceDirectoryAndTranscript() {
    let session = TerminalSession(
      id: 7, initialPwd: "/Users/leo/axo", shells: [],
      piSessionFile: "/Users/leo/.axo/sessions/w/7.jsonl", workspaceName: "axo",
      name: "axo: copy session info")
    XCTAssertEqual(
      SessionInfo.text(for: session),
      """
      Axo Session "axo: copy session info"
      Session ID: \(SessionID(7).rawValue)
      Workspace: axo
      Directory: /Users/leo/axo
      Transcript: /Users/leo/.axo/sessions/w/7.jsonl

      To message it, call the axo MCP tool session_prompt with sessionId "\(SessionID(7).rawValue)". \
      To see what it has been doing, read its transcript (JSONL).
      """)
  }

  func testAnotherMacsSessionNamesItsMacInsteadOfATranscriptPathHereCannotRead() {
    let session = TerminalSession(
      id: 3, initialPwd: "/Users/leo", shells: [], piSessionFile: "/elsewhere/3.jsonl")
    let text = SessionInfo.text(for: session, hostLabel: "Studio")
    XCTAssertTrue(text.contains("Runs on: Studio"), text)
    XCTAssertFalse(text.contains("Transcript"), text)
    XCTAssertFalse(text.contains("read its transcript"), text)
    XCTAssertTrue(text.contains("session_prompt with sessionId \"\(SessionID(3).rawValue)\""), text)
    XCTAssertFalse(text.contains("Workspace:"), "no Workspace line without a Workspace")
  }
}
