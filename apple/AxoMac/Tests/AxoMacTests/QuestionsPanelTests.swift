import AppKit
import AxoProtocol
import SwiftUI
import XCTest

@testable import AxoMac

@MainActor
final class QuestionsPanelTests: XCTestCase {
  /// Every waiting question shows, one after the other, with the Session that asks; a picture of
  /// the panel goes to the test outputs, to look at.
  func testThePanelListsEveryQuestionWithItsSession() throws {
    let model = ElicitationsModel(client: nil)
    model.sessionName = { $0 == 1 ? "Fix the build" : "Pay the invoice" }
    let input = InputRequest(
      app: "Safari", window: "Sign in", origin: "https://github.com",
      fields: [.init(id: "f0", label: "Password", kind: .password)], key: "QQ==")
    _ = model.apply(
      .elicitationRequested(
        Elicitation(id: "a", sessionId: 1, askedBy: .agent, message: "Delete the branch feat/old-ui?", createdAt: 1, expiresAt: 2)))
    _ = model.apply(
      .elicitationRequested(
        Elicitation(
          id: "b", sessionId: 2, askedBy: .computerUse,
          message: "Computer use wants to: click AXButton \"Pay now\" in Safari.", createdAt: 1, expiresAt: 2)))
    _ = model.apply(
      .elicitationRequested(
        Elicitation(id: "f", sessionId: 1, kind: .input, askedBy: .computerUse, message: "Fill.", input: input, createdAt: 1, expiresAt: 2)))
    var closed = 0
    let hosting = NSHostingView(rootView: QuestionsList(model: model, close: { closed += 1 }))
    let size = hosting.fittingSize
    XCTAssertEqual(size.width, QuestionsList.width)
    XCTAssertGreaterThan(size.height, 250, "three questions, one under the other")
    hosting.frame = NSRect(origin: .zero, size: size)
    if let outputs = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"],
      let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
    {
      hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: outputs).appendingPathComponent("questions-panel.png"))
    }
    XCTAssertEqual(closed, 0)
  }
}
