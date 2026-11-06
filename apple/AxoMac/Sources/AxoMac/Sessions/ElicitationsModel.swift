import AppKit
import AxoClient
import AxoProtocol
import Foundation
import Observation

/// The daemon operations for questions to the person (RFD0029). axod takes an answer on its socket
/// only from Axo.app, by code signature.
@MainActor
protocol AxodElicitationClient: AnyObject {
  func pendingElicitations() async throws -> [Elicitation]
  func resolveElicitation(_ id: String, action: ElicitationAnswer, values: [String: String]?) async throws
}

extension AxodConnection: AxodElicitationClient {}

/// What agents and Axo's computer-use gate are asking the person on this Mac, as axod reports
/// it. While any waits, the menu bar Axo takes a color; its menu opens the questions panel under
/// it, which shows them all, one after the other (`QuestionsPanel`). The first answer from any
/// device wins, and axod's `resolved` removes the question everywhere.
@MainActor
@Observable
final class ElicitationsModel {
  /// Waiting for the person, oldest first.
  private(set) var questions: [Elicitation] = []
  /// Questions whose answer is on its way to axod.
  private(set) var answering: Set<String> = []
  /// Why the last answer did not go, worded for the person.
  private(set) var failure: String?

  @ObservationIgnored private let client: AxodElicitationClient?
  /// The name of the Session that asks, shown over its question.
  @ObservationIgnored var sessionName: @MainActor (SessionID) -> String = { _ in "a Session" }
  /// Shows a Session, from its question.
  @ObservationIgnored var showSession: @MainActor (SessionID) -> Void = { _ in }

  init(client: AxodElicitationClient?) {
    self.client = client
  }

  func questions(in sessionID: SessionID?) -> [Elicitation] {
    guard let sessionID else { return [] }
    return questions.filter { $0.sessionId == sessionID }
  }

  /// Sessions with a question waiting, for the sidebar.
  var asking: Set<SessionID> { Set(questions.map(\.sessionId)) }

  /// Takes what axod has pending now, after a (re)subscription.
  func refresh() async {
    guard let client, let pending = try? await client.pendingElicitations() else { return }
    questions = pending
    answering.formIntersection(Set(pending.map(\.id)))
  }

  /// Applies an event; false when it is not about questions.
  func apply(_ event: TerminalSessionEvent) -> Bool {
    switch event {
    case .elicitationRequested(let elicitation):
      guard !questions.contains(where: { $0.id == elicitation.id }) else { return true }
      questions.append(elicitation)
    case .elicitationResolved(let id, _, _):
      settle(id)
    default:
      return false
    }
    return true
  }

  /// The person's answer. The card stays until axod says the question is settled.
  /// An accepted form goes with its `values`, straight to axod on this Mac.
  func answer(_ id: String, _ action: ElicitationAnswer, values: [String: String]? = nil) async {
    guard let client, let question = questions.first(where: { $0.id == id }), !answering.contains(id) else {
      return
    }
    if question.input != nil, action == .accept, values == nil { return }
    answering.insert(id)
    failure = nil
    do {
      try await client.resolveElicitation(id, action: action, values: action == .accept ? values : nil)
    } catch AxoClientError.serverRejected(let code, _) where code == ElicitationError.notPending {
      settle(id)
    } catch {
      answering.remove(id)
      failure = "Your answer didn’t reach axod: \(error.localizedDescription)"
    }
  }

  private func settle(_ id: String) {
    questions.removeAll { $0.id == id }
    answering.remove(id)
  }
}
