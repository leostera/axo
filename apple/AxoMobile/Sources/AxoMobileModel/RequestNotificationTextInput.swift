import AxoProtocol
import CryptoKit
import Foundation
import UserNotifications

public enum RequestNotificationReplyAction {
  public static let categoryIdentifier = "AXO_INPUT_TEXT_V1"
  public static let actionIdentifier = "AXO_INPUT_REPLY_V1"

  public static func category() -> UNNotificationCategory {
    UNNotificationCategory(identifier: categoryIdentifier, actions: [
      UNTextInputNotificationAction(identifier: actionIdentifier, title: "Reply", options: [.authenticationRequired],
        textInputButtonTitle: "Send", textInputPlaceholder: "Reply (not a password or code)"),
    ], intentIdentifiers: [], options: [])
  }
}

/// A complete, non-secret single-text-field request, safe to display and bind to an inline reply.
public struct RequestNotificationTextInput: Sendable {
  public let input: InputRequest
  public let field: InputRequest.Field
  public let body: String
  public let digest: String

  public init?(_ question: Elicitation) {
    guard question.kind == .input, let input = question.input,
      input.fields.count == 1, let field = input.fields.first, field.kind == .text else { return nil }
    let body = [question.message, "\(input.app) · \(input.window)", input.origin, field.label,
      input.submit.map { "Then: " + $0 }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    guard body.unicodeScalars.count <= 140 else { return nil }
    let parts = ["axo.notification.text-input/v1", question.message, input.app, input.window,
      input.origin.map { "1" + $0 } ?? "0", field.id, field.label, field.kind.rawValue,
      input.submit.map { "1" + $0 } ?? "0", input.key]
    let binding = parts.map { "\($0.utf8.count):\($0)" }.joined()
    self.input = input
    self.field = field
    self.body = body
    digest = SHA256.hash(data: Data(binding.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Preserve whitespace exactly; never silently truncate or send a blank/malformed reply.
  public func seal(_ text: String, requestID: String) throws -> SealedInput {
    guard !text.isEmpty, text.unicodeScalars.count <= 1000 else { throw Failure.invalidLength }
    return try InputSeal.seal([field.id: text], to: input.key, requestID: requestID, origin: input.origin)
  }

  public enum Failure: Error { case invalidLength }
}

/// No reply values are stored. Once dispatch may happen, the notification can never resend it.
/// All callers run on the same actor; uncertain replies require a fresh review inside the app.
@MainActor
public struct RequestNotificationReplyLedger {
  private let defaults: UserDefaults
  private let storageKey = "push.inputReplyAttempts.v1"

  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  public func claim(_ route: RequestNotificationRoute, expiresAt: Int64, now: Date = .now) -> Bool {
    let timestamp = now.timeIntervalSince1970 * 1000
    guard Double(expiresAt) > timestamp else { return false }
    let key = [route.accountID, route.hostID, route.sessionID, route.requestID]
      .map { $0.uuidString.lowercased() }.joined(separator: "/")
    var attempts = (defaults.dictionary(forKey: storageKey) as? [String: Double] ?? [:]).filter { $0.value > timestamp }
    guard attempts[key] == nil, attempts.count < 512 else { return false }
    attempts[key] = Double(expiresAt)
    defaults.set(attempts, forKey: storageKey)
    // Unlike display preferences, this fence must reach persistent storage before dispatch.
    return defaults.synchronize()
  }
}
