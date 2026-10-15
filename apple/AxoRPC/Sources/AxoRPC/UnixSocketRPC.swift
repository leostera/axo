import Foundation
import JSONRPC
import Network

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

public struct TerminalSession: Decodable, Equatable, Identifiable, Sendable {
  public let id: Int64
  public let initialPwd: String
  public let shells: [TerminalShell]

  public init(id: Int64, initialPwd: String, shells: [TerminalShell]) {
    self.id = id
    self.initialPwd = initialPwd
    self.shells = shells
  }
}

public struct TerminalShell: Decodable, Equatable, Identifiable, Sendable {
  public let id: Int64
  public let processId: UInt32
  public let initialPwd: String
  public let ptyDevice: String
  public let attachSocketPath: String
}

public struct ClosedTerminalSession: Decodable, Equatable, Sendable {
  public let archivedSessionId: Int64
  public let replacement: TerminalSession?
}

public struct ClosedTerminalShell: Decodable, Equatable, Sendable {
  public let archivedShellId: Int64
  public let archivedSessionId: Int64?
  public let replacement: TerminalSession?
}

private struct TerminalSessionList: Decodable {
  let sessions: [TerminalSession]
}

private struct CloseTerminalSessionRequest: Encodable {
  let sessionId: Int64
}

private struct CreateTerminalShellRequest: Encodable {
  let sessionId: Int64
}

private struct CloseTerminalShellRequest: Encodable {
  let sessionId: Int64
  let shellId: Int64
}

public enum UnixSocketRPCError: Error, LocalizedError {
  case connectionFailed(String)
  case invalidSocketPath
  case invalidResponse(String)
  case requestTimedOut

  public var errorDescription: String? {
    switch self {
    case .connectionFailed(let message): "Could not connect to Axo D: \(message)"
    case .invalidSocketPath: "Axo D socket path must be absolute and fit in a local socket address."
    case .invalidResponse(let message): "Invalid response from Axo D: \(message)"
    case .requestTimedOut: "Axo D did not respond before the request timed out."
    }
  }
}

public enum UnixSocketRPC {
  public static func health(at socketPath: UnixSocketPath) async throws -> DaemonHealth {
    let health: DaemonHealth = try await withResponse(
      at: socketPath,
      timeout: .seconds(2)
    ) { session in
      try await session.response(to: "axo.daemon.health")
    }
    if let version = health.version, version.isEmpty {
      throw UnixSocketRPCError.invalidResponse("daemon version must not be empty")
    }
    guard health.status == "running" else {
      throw UnixSocketRPCError.invalidResponse("daemon status was not running")
    }
    guard BuildNumber(health.buildNumber) != nil else {
      throw UnixSocketRPCError.invalidResponse("build number must be positive")
    }
    return health
  }

  public static func listSessions(at socketPath: UnixSocketPath) async throws -> [TerminalSession] {
    let response: TerminalSessionList = try await withResponse(at: socketPath) { session in
      try await session.response(to: "axo.session.list")
    }
    return response.sessions
  }

  public static func createSession(at socketPath: UnixSocketPath) async throws -> TerminalSession {
    try await withResponse(at: socketPath) { session in
      try await session.response(to: "axo.session.create")
    }
  }

  public static func closeSession(
    _ sessionID: Int64,
    at socketPath: UnixSocketPath
  ) async throws -> ClosedTerminalSession {
    try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.session.close",
        params: CloseTerminalSessionRequest(sessionId: sessionID)
      )
    }
  }

  public static func createShell(
    in sessionID: Int64,
    at socketPath: UnixSocketPath
  ) async throws -> TerminalShell {
    try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.shell.create",
        params: CreateTerminalShellRequest(sessionId: sessionID)
      )
    }
  }

  public static func closeShell(
    _ shellID: Int64,
    in sessionID: Int64,
    at socketPath: UnixSocketPath
  ) async throws -> ClosedTerminalShell {
    try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.shell.close",
        params: CloseTerminalShellRequest(sessionId: sessionID, shellId: shellID)
      )
    }
  }

  private static func withResponse<Response: Decodable>(
    at socketPath: UnixSocketPath,
    timeout: Duration = .seconds(5),
    request: @escaping @Sendable (JSONRPCSession) async throws -> Response
  ) async throws -> Response {
    let transport = UnixSocketTransport(socketPath: socketPath)
    try await transport.connect()
    defer { transport.close() }

    let session = JSONRPCSession(channel: transport.dataChannel)
    return try await withThrowingTaskGroup(of: Response.self) { group in
      group.addTask {
        try await request(session)
      }
      group.addTask {
        try await Task.sleep(nanoseconds: timeout.nanoseconds)
        transport.close()
        throw UnixSocketRPCError.requestTimedOut
      }
      defer { group.cancelAll() }
      guard let response = try await group.next() else {
        throw UnixSocketRPCError.requestTimedOut
      }
      return response
    }
  }
}

extension Duration {
  fileprivate var nanoseconds: UInt64 {
    let components = components
    let seconds = UInt64(max(0, components.seconds))
    let attoseconds = UInt64(max(0, components.attoseconds))
    return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
  }
}

private final class UnixSocketTransport: @unchecked Sendable {
  private static let maximumMessageBytes = 64 * 1024
  private static let connectionTimeout: DispatchTimeInterval = .seconds(1)

  private let connection: NWConnection
  private let queue = DispatchQueue(label: "dev.leostera.axo.rpc")
  private let stateLock = NSLock()
  private let dataContinuation: AsyncStream<Data>.Continuation
  private var readiness: CheckedContinuation<Void, Error>?
  private var pendingData = Data()

  private let dataSequence: AsyncStream<Data>

  init(socketPath: UnixSocketPath) {
    let (dataSequence, dataContinuation) = AsyncStream<Data>.makeStream()
    self.dataSequence = dataSequence
    self.dataContinuation = dataContinuation
    self.connection = NWConnection(
      to: .unix(path: socketPath.value),
      using: .tcp
    )
  }

  var dataChannel: JSONRPC.DataChannel {
    JSONRPC.DataChannel(
      writeHandler: { [self] data in try await send(data) },
      dataSequence: dataSequence
    )
  }

  func connect() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      stateLock.lock()
      readiness = continuation
      stateLock.unlock()

      connection.stateUpdateHandler = { [weak self] state in
        self?.handle(state: state)
      }
      connection.start(queue: queue)
      queue.asyncAfter(deadline: .now() + Self.connectionTimeout) { [weak self] in
        guard let self,
          self.finishReadiness(
            .failure(UnixSocketRPCError.connectionFailed("connection timed out")))
        else {
          return
        }
        self.connection.cancel()
        self.dataContinuation.finish()
      }
    }
  }

  func close() {
    connection.cancel()
    dataContinuation.finish()
  }

  private func handle(state: NWConnection.State) {
    switch state {
    case .ready:
      guard finishReadiness(.success(())) else { return }
      receiveNext()
    case .failed(let error):
      finishReadiness(.failure(UnixSocketRPCError.connectionFailed(error.localizedDescription)))
      dataContinuation.finish()
    case .cancelled:
      finishReadiness(.failure(UnixSocketRPCError.connectionFailed("connection was cancelled")))
      dataContinuation.finish()
    case .setup, .preparing, .waiting:
      break
    @unknown default:
      finishReadiness(.failure(UnixSocketRPCError.connectionFailed("unknown connection state")))
      dataContinuation.finish()
    }
  }

  @discardableResult
  private func finishReadiness(_ result: Result<Void, Error>) -> Bool {
    stateLock.lock()
    let continuation = readiness
    readiness = nil
    stateLock.unlock()
    guard let continuation else { return false }
    continuation.resume(with: result)
    return true
  }

  private func receiveNext() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumMessageBytes) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      if error != nil {
        self.dataContinuation.finish()
        self.connection.cancel()
        return
      }
      if let data, !data.isEmpty {
        self.receive(data)
      }
      if isComplete {
        self.dataContinuation.finish()
      } else {
        self.receiveNext()
      }
    }
  }

  private func receive(_ data: Data) {
    pendingData.append(data)

    while let newline = pendingData.firstIndex(of: 0x0A) {
      let message = Data(pendingData[..<newline])
      pendingData.removeSubrange(pendingData.startIndex...newline)
      guard message.count <= Self.maximumMessageBytes else {
        dataContinuation.finish()
        connection.cancel()
        return
      }
      if !message.isEmpty {
        dataContinuation.yield(message)
      }
    }

    if pendingData.count > Self.maximumMessageBytes {
      dataContinuation.finish()
      connection.cancel()
    }
  }

  private func send(_ message: Data) async throws {
    var framedMessage = message
    framedMessage.append(0x0A)

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: framedMessage,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(
              throwing: UnixSocketRPCError.connectionFailed(error.localizedDescription)
            )
          } else {
            continuation.resume()
          }
        })
    }
  }
}
