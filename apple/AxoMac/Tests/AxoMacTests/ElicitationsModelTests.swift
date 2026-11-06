import AxoClient
import AxoProtocol
import XCTest

@testable import AxoMac

@MainActor
private final class FakeElicitationClient: AxodElicitationClient {
  var pending: [Elicitation] = []
  var answers: [(String, ElicitationAnswer)] = []
  var values: [[String: String]?] = []
  var rejection: Error?

  func pendingElicitations() async throws -> [Elicitation] { pending }

  func resolveElicitation(_ id: String, action: ElicitationAnswer, values: [String: String]?) async throws {
    answers.append((id, action))
    self.values.append(values)
    if let rejection { throw rejection }
  }
}

@MainActor
final class ElicitationsModelTests: XCTestCase {
  private func question(_ id: String, session: SessionID = 1, askedBy: Elicitation.Asker = .agent)
    -> Elicitation
  {
    Elicitation(
      id: id, sessionId: session, askedBy: askedBy, message: "Go?", createdAt: 1, expiresAt: 2)
  }

  func testAFormGoesOnlyWithItsValuesAndACancelWithNone() async {
    let client = FakeElicitationClient()
    let model = ElicitationsModel(client: client)
    let input = InputRequest(
      app: "Safari", window: "Sign in", origin: "https://github.com",
      fields: [.init(id: "f0", label: "Password", kind: .password)], key: "QQ==")
    _ = model.apply(
      .elicitationRequested(
        Elicitation(id: "f", sessionId: 1, kind: .input, askedBy: .computerUse, message: "Fill Password.", input: input, createdAt: 1, expiresAt: 2)))
    await model.answer("f", .accept)
    XCTAssertTrue(client.answers.isEmpty, "a form is not accepted without its values")
    await model.answer("f", .accept, values: ["f0": "hunter2"])
    XCTAssertEqual(client.values.first??["f0"], "hunter2")
  }

  func testAQuestionIsListedOnceForItsSession() {
    let model = ElicitationsModel(client: FakeElicitationClient())
    model.sessionName = { _ in "Fix the build" }
    XCTAssertTrue(model.apply(.elicitationRequested(question("a", session: 1))))
    XCTAssertTrue(model.apply(.elicitationRequested(question("a", session: 1))))
    XCTAssertEqual(model.questions(in: 1).map(\.id), ["a"])
    XCTAssertTrue(model.questions(in: 2).isEmpty)
    XCTAssertEqual(model.asking, [1])
    XCTAssertFalse(model.apply(.peerSessionsChanged))
  }

  func testTheCardStaysUntilAxodSaysItIsSettled() async {
    let client = FakeElicitationClient()
    let model = ElicitationsModel(client: client)
    _ = model.apply(.elicitationRequested(question("a")))
    await model.answer("a", .accept)
    XCTAssertEqual(client.answers.map(\.0), ["a"])
    XCTAssertEqual(model.questions.map(\.id), ["a"], "only axod's resolved removes it")
    XCTAssertTrue(model.answering.contains("a"))
    await model.answer("a", .decline)
    XCTAssertEqual(client.answers.count, 1, "one answer per question")
    _ = model.apply(.elicitationResolved(id: "a", sessionID: 1, action: .accept))
    XCTAssertTrue(model.questions.isEmpty)
    XCTAssertTrue(model.answering.isEmpty)
  }

  func testAQuestionAnsweredElsewhereGoesAwayOnAnswering() async {
    let client = FakeElicitationClient()
    client.rejection = AxoClientError.serverRejected(
      code: ElicitationError.notPending, message: "already answered")
    let model = ElicitationsModel(client: client)
    _ = model.apply(.elicitationRequested(question("a")))
    await model.answer("a", .accept)
    XCTAssertTrue(model.questions.isEmpty)
    XCTAssertNil(model.failure)
  }

  func testAnAnswerThatFailsSaysSoAndCanBeTriedAgain() async {
    let client = FakeElicitationClient()
    client.rejection = AxoClientError.serverRejected(
      code: ElicitationError.notAPerson, message: "only Axo.app answers")
    let model = ElicitationsModel(client: client)
    _ = model.apply(.elicitationRequested(question("a")))
    await model.answer("a", .accept)
    XCTAssertEqual(model.questions.map(\.id), ["a"])
    XCTAssertFalse(model.answering.contains("a"))
    XCTAssertNotNil(model.failure)
  }

  func testRefreshTakesAxodsPendingList() async {
    let client = FakeElicitationClient()
    let model = ElicitationsModel(client: client)
    _ = model.apply(.elicitationRequested(question("old")))
    client.pending = [question("new", askedBy: .computerUse)]
    await model.refresh()
    XCTAssertEqual(model.questions.map(\.id), ["new"])
  }
}
