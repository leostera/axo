import Darwin
import Foundation

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
