import Foundation

/// Why a call to a host failed.
public enum AxoClientError: Error, Equatable, LocalizedError {
  /// The transport could not connect.
  case connectionFailed(String)
  /// The connection ended before the reply arrived.
  case connectionClosed
  case invalidSocketPath
  /// The reply did not have the expected shape or content.
  case invalidResponse(String)
  /// The host answered with a JSON-RPC error.
  case serverRejected(code: Int, message: String)
  case requestTimedOut

  public var errorDescription: String? {
    switch self {
    case .connectionFailed(let message): "Could not connect to axod: \(message)"
    case .connectionClosed: "The connection to axod closed before it replied."
    case .invalidSocketPath: "axod socket path must be absolute and fit in a local socket address."
    case .invalidResponse(let message): "Invalid response from axod: \(message)"
    case .serverRejected(let code, let message): "axod rejected the request (\(code)): \(message)"
    case .requestTimedOut: "axod did not respond before the request timed out."
    }
  }
}
