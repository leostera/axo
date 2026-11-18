import AxoProtocol
import CryptoKit
import Foundation

/// Additional action metadata is separate from the backwards-compatible routing envelope.
public struct RequestNotificationAction: Sendable {
  public let digest: String
  public let expiresAt: Int64

  public init?(userInfo: [AnyHashable: Any]) {
    struct Wire: Decodable { let version: Int; let digest: String; let expiresAt: Int64 }
    guard let raw = userInfo["axoRequest"] as? [String: Any], Set(raw.keys) == ["version", "digest", "expiresAt"],
      JSONSerialization.isValidJSONObject(raw), let data = try? JSONSerialization.data(withJSONObject: raw), data.count <= 512,
      let wire = try? JSONDecoder().decode(Wire.self, from: data), wire.version == 1,
      wire.digest.count == 64, wire.digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      wire.expiresAt > 0
    else { return nil }
    digest = wire.digest
    expiresAt = wire.expiresAt
  }

  public func matches(_ question: Elicitation, route: RequestNotificationRoute, displayedMessage: String, now: Date = .now) -> Bool {
    guard question.kind == .confirm, question.input == nil, question.message == displayedMessage, question.id == route.requestID.uuidString.lowercased(),
      question.sessionId == SessionID(route.sessionID), question.expiresAt == expiresAt,
      Double(expiresAt) > now.timeIntervalSince1970 * 1000,
      question.message.unicodeScalars.count <= 240 else { return false }
    let current = SHA256.hash(data: Data(question.message.utf8)).map { String(format: "%02x", $0) }.joined()
    return current == digest
  }
}
