import Foundation

public struct RemoteAccessSettings: Decodable, Equatable, Sendable {
  public let enabled: Bool
  public let relayUrl: String?
  public let hostLabel: String?
  public let hostKind: String?

  public init(
    enabled: Bool,
    relayUrl: String?,
    hostLabel: String?,
    hostKind: String?
  ) {
    self.enabled = enabled
    self.relayUrl = relayUrl
    self.hostLabel = hostLabel
    self.hostKind = hostKind
  }
}

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

public struct RemoteAccessConfiguration: Encodable, Sendable {
  public let relayUrl: String
  public let hostLabel: String
  public let hostKind: String

  public init(
    relayUrl: String,
    hostLabel: String,
    hostKind: String = "macos"
  ) {
    self.relayUrl = relayUrl
    self.hostLabel = hostLabel
    self.hostKind = hostKind
  }
}
