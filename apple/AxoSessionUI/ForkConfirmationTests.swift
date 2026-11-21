import AxoProtocol
import Foundation
import XCTest

@testable import AxoSessionUI

final class ForkConfirmationTests: XCTestCase {
  private func plan(_ decision: String) throws -> SessionForkPlan {
    try JSONDecoder().decode(SessionForkPlan.self, from: Data(
      #"{"sourceAgent":"pi","historyFormat":"pi/3","decision":\#(decision)}"#.utf8))
  }

  func testOnlyKeepCanConfirmWithoutAnExplicitHarness() throws {
    var confirmation = ForkConfirmation()
    XCTAssertNil(confirmation.submit(folder: ""))
    confirmation.receive(try plan(#"{"kind":"unavailable"}"#))
    XCTAssertNil(confirmation.submit(folder: ""))
    confirmation.receive(try plan(#"{"kind":"keep","agent":"pi"}"#))
    let request = try XCTUnwrap(confirmation.submit(folder: ""))
    XCTAssertNil(request.agent)
  }

  func testRetryFreezesPayloadAndDefinitiveRejectionsRequireFreshID() throws {
    var confirmation = ForkConfirmation()
    let choice = try plan(#"{"kind":"choose","agents":["codex"]}"#)
    confirmation.receive(choice)
    XCTAssertNil(confirmation.submit(folder: ""), "Even one alternative must be explicitly selected")
    confirmation.selectedAgent = .codex
    let first = try XCTUnwrap(confirmation.submit(folder: ""))
    XCTAssertEqual(first.agent, .codex)
    XCTAssertEqual(confirmation.submit(folder: "/ignored"), first)
    confirmation.rejectFolder()
    XCTAssertNil(confirmation.submit(folder: "relative"))
    let withFolder = try XCTUnwrap(confirmation.submit(folder: #"C:\repo"#))
    XCTAssertNotEqual(withFolder.id, first.id)
    XCTAssertEqual(withFolder.folder, #"C:\repo"#)
    XCTAssertEqual(withFolder.agent, .codex)
    confirmation.rejectHarness()
    confirmation.receive(choice)
    XCTAssertNil(confirmation.submit(folder: #"C:\repo"#))
    confirmation.selectedAgent = .codex
    let replanned = try XCTUnwrap(confirmation.submit(folder: #"C:\repo"#))
    XCTAssertNotEqual(replanned.id, withFolder.id)
  }

  func testMalformedPlanCannotEnableAChoice() {
    for bad in [
      #"{"kind":"keep","agent":"codex"}"#,
      #"{"kind":"choose","agents":[]}"#,
      #"{"kind":"choose","agents":["codex","codex"]}"#,
      #"{"kind":"choose","agents":["pi"]}"#,
      #"{"kind":"choose","agents":["unknown"]}"#,
      #"{"kind":"fallback"}"#,
    ] {
      XCTAssertThrowsError(try plan(bad), bad)
    }
  }
}
