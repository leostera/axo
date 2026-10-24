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
}

public struct HostPairingResult: Decodable, Equatable, Sendable {
  public let linked: Bool
  public let hostLabel: String
}
