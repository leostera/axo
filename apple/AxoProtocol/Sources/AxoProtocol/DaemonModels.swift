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
  /// Whether axod has finished starting (the Pis it started at launch are up). An axod that
  /// predates this doesn't say, and was ready whenever it answered.
  public let ready: Bool
  /// Whether macOS lets axod run as a developer tool; nil from an axod that does not say.
  public let developerTools: PermissionState?

  public init(
    version: String?, buildNumber: UInt64, status: String, ready: Bool = true,
    developerTools: PermissionState? = nil
  ) {
    self.version = version
    self.buildNumber = buildNumber
    self.status = status
    self.ready = ready
    self.developerTools = developerTools
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decodeIfPresent(String.self, forKey: .version)
    buildNumber = try container.decode(UInt64.self, forKey: .buildNumber)
    status = try container.decode(String.self, forKey: .status)
    ready = try container.decodeIfPresent(Bool.self, forKey: .ready) ?? true
    // A state a later axod adds is as good as not saying.
    developerTools = (try? container.decodeIfPresent(String.self, forKey: .developerTools)).flatMap(PermissionState.init)
  }

  private enum CodingKeys: String, CodingKey { case version, buildNumber, status, ready, developerTools }
}

/// How axod stands with one of macOS's privacy permissions.
public enum PermissionState: String, Equatable, Sendable {
  case granted, denied, notAsked
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
