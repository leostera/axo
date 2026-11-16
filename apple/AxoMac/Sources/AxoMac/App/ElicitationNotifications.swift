import AxoProtocol
import Foundation
import OSLog
import UserNotifications

/// Native attention for local requests. All effects are injected; rendering never asks permission.
@MainActor
final class ElicitationNotifications {
  nonisolated static let category = "dev.leostera.axo.elicitation"
  static let shared = ElicitationNotifications(
    authorized: {
      let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
      return status == .authorized || status == .provisional
    },
    deliver: { try await UNUserNotificationCenter.current().add($0) },
    remove: { ids in
      UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
      UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    })

  var openInbox: () -> Void = {}
  var expired: ([String]) -> Void = { _ in }
  private let authorized: () async -> Bool
  private let deliver: (UNNotificationRequest) async throws -> Void
  private let remove: ([String]) -> Void
  private let now: () -> Date
  private var pending: [String: Elicitation] = [:]
  private var sentUntil: [String: Int64] = [:]
  private var expiration: Task<Void, Never>?
  private var sending: [String: Task<Void, Never>] = [:]

  init(authorized: @escaping () async -> Bool, deliver: @escaping (UNNotificationRequest) async throws -> Void,
    remove: @escaping ([String]) -> Void, now: @escaping () -> Date = Date.init) {
    self.authorized = authorized
    self.deliver = deliver
    self.remove = remove
    self.now = now
  }

  static func identifier(_ id: String) -> String { "\(category).\(id)" }

  func update(_ questions: [Elicitation]) {
    let time = now().timeIntervalSince1970 * 1_000
    let next = Dictionary(questions.filter { Double($0.expiresAt) > time }.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first })
    let gone = pending.keys.filter { next[$0] == nil }
    if !gone.isEmpty { remove(gone.map(Self.identifier)) }
    for id in gone { sending[id]?.cancel() }
    pending = next
    expiration?.cancel()
    if let deadline = next.values.map(\.expiresAt).min() {
      let delay = max(1, Double(deadline) - time)
      expiration = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
        guard let self else { return }
        let expired = self.pending.values.filter { Double($0.expiresAt) <= self.now().timeIntervalSince1970 * 1_000 }.map(\.id)
        self.expired(expired)
        self.update(Array(self.pending.values))
      }
    }
    sentUntil = sentUntil.filter { Double($0.value) > time }
    for question in next.values where sentUntil[question.id] == nil && sending[question.id] == nil {
      let id = question.id
      sending[id] = Task {
        defer {
          sending[id] = nil
          // Reconnect may restore the request while its cancelled authorization check retires.
          if Task.isCancelled, pending[id] != nil, sentUntil[id] == nil {
            update(Array(pending.values))
          }
        }
        guard await authorized(), !Task.isCancelled, pending[id] != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Axo needs your answer"
        // No question/input text in lock-screen notification previews.
        content.body = "A Session has a request waiting. Open Axo to review it."
        content.categoryIdentifier = Self.category
        content.userInfo = ["elicitationId": id]
        let request = UNNotificationRequest(identifier: Self.identifier(id), content: content, trigger: nil)
        do {
          try await deliver(request)
          sentUntil[id] = question.expiresAt
          // add() may complete after a different device answered: retract again after admission.
          if pending[id] == nil || Double(question.expiresAt) <= now().timeIntervalSince1970 * 1_000 {
            remove([request.identifier])
          }
        } catch {
          AxoTrace.elicitations.error("event=elicitation.notification_failed code=\((error as NSError).code)")
          // The inbox remains available; a later snapshot can retry.
        }
      }
    }
  }
}
