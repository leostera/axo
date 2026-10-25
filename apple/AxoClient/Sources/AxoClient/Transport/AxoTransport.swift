import Foundation

/// How a client reaches a host: a Unix socket to the local axod now; a WebSocket through the
/// account's relay next. Everything above it (JSON-RPC, typed methods) is shared.
public protocol AxoTransport: Sendable {
  /// Opens a new connection. Fails with `AxoClientError.connectionFailed`.
  func connect() async throws -> any AxoMessageChannel
}

/// One open connection carrying whole JSON-RPC messages in both directions; framing is the
/// transport's business.
public protocol AxoMessageChannel: AnyObject, Sendable {
  /// Incoming messages in order. Finishes when the connection ends, from either side.
  var messages: AsyncStream<Data> { get }
  /// Sends one message. Fails with `AxoClientError.connectionClosed` once the connection ended.
  func send(_ message: Data) async throws
  /// Ends the connection; `messages` finishes. Safe to call more than once.
  func close()
}
