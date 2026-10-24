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

public struct UnixSocketPath: Equatable, Sendable {
  public let value: String

  public init(_ value: String) throws {
    let address = sockaddr_un()
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    guard value.hasPrefix("/"),
      !value.utf8.contains(0),
      value.utf8.count < pathCapacity
    else {
      throw UnixSocketRPCError.invalidSocketPath
    }
    self.value = value
  }
}

public struct DaemonHealth: Decodable, Equatable, Sendable {
  public let version: String?
  public let buildNumber: UInt64
  public let status: String
}

public struct ProtocolNegotiation: Decodable, Equatable, Sendable {
  public let protocolVersion: UInt32
  public let methods: [String]

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

public enum UnixSocketRPCError: Error, LocalizedError {
  case connectionFailed(String)
  case invalidSocketPath
  case invalidResponse(String)
  case serverRejected(code: Int, message: String)
  case requestTimedOut

  public var errorDescription: String? {
    switch self {
    case .connectionFailed(let message): "Could not connect to axod: \(message)"
    case .invalidSocketPath: "axod socket path must be absolute and fit in a local socket address."
    case .invalidResponse(let message): "Invalid response from axod: \(message)"
    case .serverRejected(let code, let message): "axod rejected the request (\(code)): \(message)"
    case .requestTimedOut: "axod did not respond before the request timed out."
    }
  }
}
