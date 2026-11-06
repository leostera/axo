import AppKit
import AxoClient
import AxoProtocol
import Foundation
import Observation
import UserNotifications

/// The daemon operations for questions to the person (RFD0029). axod takes an answer on its socket
/// only from Axo.app, by code signature.
@MainActor
protocol AxodElicitationClient: AnyObject {
  func pendingElicitations() async throws -> [Elicitation]
  func resolveElicitation(_ id: String, action: ElicitationAnswer, values: [String: String]?) async throws
  func answeringDevices() async throws -> AnsweringDevices
  func decideDevice(_ key: String, allow: Bool) async throws
}

extension AxodConnection: AxodElicitationClient {}

/// Shows and withdraws the macOS notification for a question; tests use a fake.
@MainActor
protocol ElicitationNotifying: AnyObject {
  func post(_ elicitation: Elicitation, sessionName: String)
  func withdraw(_ id: String)
}

/// What agents and Axo's computer-use gate are asking the person on this Mac, as axod reports
/// it. A card shows over the Session's panes and a notification offers Yes and No; the first
/// answer from any device wins, and axod's `resolved` removes the question everywhere.
@MainActor
@Observable
final class ElicitationsModel {
  /// Waiting for the person, oldest first.
  private(set) var questions: [Elicitation] = []
  /// Questions whose answer is on its way to axod.
  private(set) var answering: Set<String> = []
  /// Why the last answer did not go, worded for the person.
  private(set) var failure: String?
  /// Phones and browsers that answered without being allowed: the person compares each
  /// fingerprint with the one the device shows, then allows it or turns it away.
  private(set) var waitingDevices: [AnsweringDevice] = []
  /// Devices whose decision is on its way to axod.
  private(set) var deciding: Set<String> = []

  @ObservationIgnored private let client: AxodElicitationClient?
  @ObservationIgnored private let notifier: ElicitationNotifying?
  /// The Session name a notification shows.
  @ObservationIgnored var sessionName: @MainActor (SessionID) -> String = { _ in "a Session" }
  /// Shows a Session when the person opens a notification.
  @ObservationIgnored var showSession: @MainActor (SessionID) -> Void = { _ in }

  init(client: AxodElicitationClient?, notifier: ElicitationNotifying?) {
    self.client = client
    self.notifier = notifier
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
    let known = Set(questions.map(\.id))
    let now = Set(pending.map(\.id))
    for gone in known.subtracting(now) { notifier?.withdraw(gone) }
    for new in pending where !known.contains(new.id) {
      notifier?.post(new, sessionName: sessionName(new.sessionId))
    }
    questions = pending
    answering.formIntersection(now)
    await refreshDevices()
  }

  private func refreshDevices() async {
    guard let client, let devices = try? await client.answeringDevices() else { return }
    waitingDevices = devices.pending
    deciding.formIntersection(Set(devices.pending.map(\.key)))
  }

  /// Allows a waiting device to answer this Mac's questions, or turns it away.
  func decide(_ key: String, allow: Bool) async {
    guard let client, waitingDevices.contains(where: { $0.key == key }), !deciding.contains(key) else { return }
    deciding.insert(key)
    do {
      try await client.decideDevice(key, allow: allow)
      waitingDevices.removeAll { $0.key == key }
    } catch {
      failure = "Axo couldn’t save that: \(error.localizedDescription)"
    }
    deciding.remove(key)
  }

  /// Applies an event; false when it is not about questions.
  func apply(_ event: TerminalSessionEvent) -> Bool {
    switch event {
    case .elicitationRequested(let elicitation):
      guard !questions.contains(where: { $0.id == elicitation.id }) else { return true }
      questions.append(elicitation)
      notifier?.post(elicitation, sessionName: sessionName(elicitation.sessionId))
    case .elicitationResolved(let id, _, _):
      settle(id)
    case .deviceRequested(let device):
      if !waitingDevices.contains(where: { $0.key == device.key }) { waitingDevices.append(device) }
    case .devicesChanged:
      Task { await refreshDevices() }
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
    notifier?.withdraw(id)
  }
}

/// The macOS notification for a question, with Yes and No, and opening its Session on a click.
/// Its identifier is the question's id, so a settled question's notification is withdrawn.
@MainActor
final class ElicitationNotifications: NSObject, ElicitationNotifying,
  UNUserNotificationCenterDelegate
{
  static let shared = ElicitationNotifications()
  static let category = "axo.elicitation"
  /// A form: it is filled in Axo, never from the notification.
  static let inputCategory = "axo.elicitation.input"
  private static let accept = "accept"
  private static let decline = "decline"

  /// The model notifications answer through.
  weak var model: ElicitationsModel?
  private var registered = false

  /// Becomes the notification center's delegate, so answers from a notification reach axod and
  /// notifications show while Axo is in front.
  func install() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: Self.category,
        actions: [
          UNNotificationAction(identifier: Self.accept, title: "Yes", options: [.authenticationRequired]),
          UNNotificationAction(identifier: Self.decline, title: "No", options: [.destructive]),
        ],
        intentIdentifiers: []),
      UNNotificationCategory(identifier: Self.inputCategory, actions: [], intentIdentifiers: []),
    ])
  }

  func post(_ elicitation: Elicitation, sessionName: String) {
    // Questions can carry what an agent is working on; never log them.
    Task {
      let center = UNUserNotificationCenter.current()
      guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
      let content = UNMutableNotificationContent()
      switch (elicitation.kind, elicitation.askedBy) {
      case (.input, _): content.title = "Axo asks you to sign in"
      case (_, .computerUse): content.title = "Axo asks before acting on your Mac"
      case (_, .agent): content.title = "The agent asks you"
      }
      content.subtitle = sessionName
      content.body = elicitation.message
      content.sound = .default
      content.categoryIdentifier = elicitation.kind == .input ? Self.inputCategory : Self.category
      content.interruptionLevel = .timeSensitive
      content.userInfo = ["sessionId": elicitation.sessionId.rawValue]
      try? await center.add(
        UNNotificationRequest(identifier: elicitation.id, content: content, trigger: nil))
    }
  }

  func withdraw(_ id: String) {
    let center = UNUserNotificationCenter.current()
    center.removeDeliveredNotifications(withIdentifiers: [id])
    center.removePendingNotificationRequests(withIdentifiers: [id])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let id = response.notification.request.identifier
    let session = (response.notification.request.content.userInfo["sessionId"] as? String)
      .flatMap(SessionID.init(rawValue:))
    let action = response.actionIdentifier
    await MainActor.run {
      guard let model = self.model else { return }
      switch action {
      case Self.accept: Task { await model.answer(id, .accept) }
      case Self.decline: Task { await model.answer(id, .decline) }
      default:
        if let session { model.showSession(session) }
        NSApp.activate(ignoringOtherApps: true)
      }
    }
  }
}
