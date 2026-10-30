import Foundation

public struct BuildNumber: Equatable, Sendable, CustomStringConvertible {
  public let value: UInt64

  public init?(_ value: UInt64) {
    guard value > 0 else { return nil }
    self.value = value
  }

  public init?(bundleValue: Any?) {
    guard
      let text = bundleValue as? String,
      let value = UInt64(text),
      value > 0,
      String(value) == text
    else {
      return nil
    }
    self.value = value
  }

  public var description: String { String(value) }
}

public struct DaemonHealth: Decodable, Equatable, Sendable {
  public let version: String?
  public let buildNumber: UInt64
  public let status: String
}

public struct ProtocolNegotiation: Decodable, Equatable, Sendable {
  public let protocolVersion: UInt32
  public let methods: [String]

  /// The protocol version this Axo speaks; Axod must answer with the same.
  public static let supportedVersion: UInt32 = 2

  public init(protocolVersion: UInt32, methods: [String]) {
    self.protocolVersion = protocolVersion
    self.methods = methods
  }
}

public enum AxoConfigKey: String, Codable, Equatable, Sendable {
  case agentCommand = "agent.command"
  case shellCommand = "shell.command"
}

public struct AxoConfigValue: Decodable, Equatable, Sendable {
  public let key: AxoConfigKey
  public let value: String
}
