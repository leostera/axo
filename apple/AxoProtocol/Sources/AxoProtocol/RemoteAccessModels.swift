import Foundation

public enum RemoteAccessConnectionState: String, Decodable, Equatable, Sendable {
  case connecting
  case connected
  case disconnected
}

public struct RemoteAccessStatus: Decodable, Equatable, Sendable {
  public let state: RemoteAccessConnectionState
  public let connectedSinceUnixMillis: UInt64?
  public let hostName: String
  public let hostKind: String
  public let lastError: String?
  /// Nil means an older daemon did not report durable account linking; never infer unlinked.
  public let linked: Bool?

  public var isConnected: Bool { state == .connected }

  public init(
    state: RemoteAccessConnectionState, connectedSinceUnixMillis: UInt64?, hostName: String,
    hostKind: String, lastError: String?, linked: Bool? = nil
  ) {
    self.state = state
    self.connectedSinceUnixMillis = connectedSinceUnixMillis
    self.hostName = hostName
    self.hostKind = hostKind
    self.lastError = lastError
    self.linked = linked
  }
}

public struct HostPairingResult: Decodable, Equatable, Sendable {
  public let linked: Bool
  public let hostLabel: String
}
