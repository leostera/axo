import Foundation

/// A banner links to its originating conversation. It carries no execution authority.
public struct RequestNotificationRoute: Equatable, Sendable {
  public let accountID: UUID
  public let hostID: UUID
  public let sessionID: UUID
  public let requestID: UUID

  public init?(userInfo: [AnyHashable: Any]) {
    guard let raw = userInfo["axo"] as? [String: Any],
      Set(raw.keys) == ["version", "accountId", "hostId", "sessionId", "requestId"],
      JSONSerialization.isValidJSONObject(raw),
      let data = try? JSONSerialization.data(withJSONObject: raw), data.count <= 1024
    else { return nil }
    struct Wire: Decodable {
      let version: Int
      let accountId: UUID
      let hostId: UUID
      let sessionId: UUID
      let requestId: UUID
    }
    guard let wire = try? JSONDecoder().decode(Wire.self, from: data), wire.version == 1 else { return nil }
    accountID = wire.accountId
    hostID = wire.hostId
    sessionID = wire.sessionId
    requestID = wire.requestId
  }
}
