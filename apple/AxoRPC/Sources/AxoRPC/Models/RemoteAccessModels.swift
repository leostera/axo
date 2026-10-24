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

  public var isConnected: Bool { state == .connected }

  public init(
    state: RemoteAccessConnectionState, connectedSinceUnixMillis: UInt64?, hostName: String,
    hostKind: String, lastError: String?
  ) {
    self.state = state
    self.connectedSinceUnixMillis = connectedSinceUnixMillis
    self.hostName = hostName
    self.hostKind = hostKind
    self.lastError = lastError
  }
}

public struct HostPairingResult: Decodable, Equatable, Sendable {
  public let linked: Bool
  public let hostLabel: String
}
