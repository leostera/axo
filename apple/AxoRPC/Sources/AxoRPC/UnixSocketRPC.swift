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

public struct ProtocolNegotiation: Decodable, Equatable, Sendable {
  public let protocolVersion: UInt32
  public let methods: [String]
}

public struct TerminalSession: Decodable, Equatable, Identifiable, Sendable {
  public let id: Int64
  public let initialPwd: String
  public let shells: [TerminalShell]
  public let layout: SessionLayout?

  public init(
    id: Int64,
    initialPwd: String,
    shells: [TerminalShell],
    layout: SessionLayout? = nil
  ) {
    self.id = id
    self.initialPwd = initialPwd
    self.shells = shells
    self.layout = layout
  }
}

public struct TerminalShell: Decodable, Equatable, Identifiable, Sendable {
  public let id: Int64
  public let processId: UInt32
  public let initialPwd: String
  public let ptyDevice: String
  public let attachSocketPath: String
}

public enum TerminalShellActivity: String, Decodable, Equatable, Sendable {
  case started
  case exited
  case attached
  case detached
}

public enum TerminalSessionEvent: Decodable, Equatable, Sendable {
  case sessionSnapshot(TerminalSession)
  case sessionRemoved(sessionID: Int64)
  case shellActivity(sessionID: Int64, shellID: Int64, activity: TerminalShellActivity)
  case terminalOutput(sessionID: Int64, shellID: Int64, sequence: UInt64, data: Data)

  private enum CodingKeys: String, CodingKey {
    case type, session, sessionId, shellId, activity, sequence, data
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .type) {
    case "session.snapshot":
      self = .sessionSnapshot(try container.decode(TerminalSession.self, forKey: .session))
    case "session.removed":
      self = .sessionRemoved(sessionID: try container.decode(Int64.self, forKey: .sessionId))
    case "shell.activity":
      self = .shellActivity(
        sessionID: try container.decode(Int64.self, forKey: .sessionId),
        shellID: try container.decode(Int64.self, forKey: .shellId),
        activity: try container.decode(TerminalShellActivity.self, forKey: .activity))
    case "terminal.output":
      let encoded = try container.decode(String.self, forKey: .data)
      guard let data = Data(base64Encoded: encoded) else {
        throw UnixSocketRPCError.invalidResponse("terminal output was not base64")
      }
      self = .terminalOutput(
        sessionID: try container.decode(Int64.self, forKey: .sessionId),
        shellID: try container.decode(Int64.self, forKey: .shellId),
        sequence: try container.decode(UInt64.self, forKey: .sequence),
        data: data)
    default:
      throw UnixSocketRPCError.invalidResponse("daemon sent an unknown session event")
    }
  }
}

public struct TerminalSubscriptionID: Decodable, Equatable, Sendable {
  public let subscriptionId: String
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

private struct ProtocolNegotiationRequest: Encodable {
  let protocolVersion: UInt32
}

private struct RemoteAccessDisabled: Decodable {
  let disabled: Bool
}

private struct RemoteAccessConnectResponse: Decodable {
  let requested: Bool
}

private struct CloseTerminalSessionRequest: Encodable {
  let sessionId: Int64
}

private struct CreateTerminalShellRequest: Encodable {
  let sessionId: Int64
}

private struct SetSessionLayoutRequest: Encodable {
  let sessionId: Int64
  let layout: SessionLayout
}

private struct SessionLayoutAcknowledgement: Decodable {
  let saved: Bool
}

private struct CloseTerminalShellRequest: Encodable {
  let sessionId: Int64
  let shellId: Int64
}

private struct SessionSubscribeRequest: Encodable {
  let sessionId: Int64?

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if let sessionId { try container.encode(sessionId, forKey: .sessionId) }
  }

  private enum CodingKeys: String, CodingKey { case sessionId }
}

private struct SessionEventsNextRequest: Encodable {
  let subscriptionId: String
  let timeoutMs: UInt64
}

private struct SessionEventsNextResponse: Decodable {
  let event: TerminalSessionEvent?
}

private struct SessionUnsubscribeRequest: Encodable {
  let subscriptionId: String
}

private struct SessionUnsubscribeResponse: Decodable {
  let unsubscribed: Bool
}

private struct TerminalInputRequest: Encodable {
  let sessionId: Int64
  let shellId: Int64
  let sequence: UInt64
  let data: String
}

private struct TerminalInputResponse: Decodable {
  let accepted: Bool
  let sequence: UInt64
}

private struct TerminalResizeRequest: Encodable {
  let sessionId: Int64
  let shellId: Int64
  let rows: UInt32
  let columns: UInt32
}

private struct TerminalResizeResponse: Decodable {
  let accepted: Bool
  let rows: UInt32
  let columns: UInt32
}

public enum UnixSocketRPCError: Error, LocalizedError {
  case connectionFailed(String)
  case invalidSocketPath
  case invalidResponse(String)
  case requestTimedOut

  public var errorDescription: String? {
    switch self {
    case .connectionFailed(let message): "Could not connect to axod: \(message)"
    case .invalidSocketPath: "axod socket path must be absolute and fit in a local socket address."
    case .invalidResponse(let message): "Invalid response from axod: \(message)"
    case .requestTimedOut: "axod did not respond before the request timed out."
    }
  }
}

public enum UnixSocketRPC {
  public static let protocolVersion: UInt32 = 1

  public static func negotiate(at socketPath: UnixSocketPath) async throws -> ProtocolNegotiation {
    try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.protocol.negotiate",
        params: ProtocolNegotiationRequest(protocolVersion: Self.protocolVersion)
      )
    }
  }

  public static func remoteAccessSettings(
    at socketPath: UnixSocketPath
  ) async throws -> RemoteAccessSettings {
    try await withResponse(at: socketPath) { session in
      try await session.response(to: "axo.relay.settings")
    }
  }

  public static func remoteAccessStatus(
    at socketPath: UnixSocketPath
  ) async throws -> RemoteAccessStatus {
    try await withResponse(at: socketPath) { session in
      try await session.response(to: "axo.relay.status")
    }
  }

  public static func requestRemoteAccessConnection(
    at socketPath: UnixSocketPath
  ) async throws {
    let response: RemoteAccessConnectResponse = try await withResponse(at: socketPath) { session in
      try await session.response(to: "axo.relay.connect")
    }
    guard response.requested else {
      throw UnixSocketRPCError.invalidResponse("axod has no remote relay configured")
    }
  }

  public static func configureRemoteAccess(
    _ configuration: RemoteAccessConfiguration,
    at socketPath: UnixSocketPath
  ) async throws -> RemoteAccessSettings {
    try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.relay.configure",
        params: configuration
      )
    }
  }

  public static func disableRemoteAccess(at socketPath: UnixSocketPath) async throws {
    let response: RemoteAccessDisabled = try await withResponse(at: socketPath) { session in
      try await session.response(to: "axo.relay.disable")
    }
    guard response.disabled else {
      throw UnixSocketRPCError.invalidResponse("daemon did not disable remote access")
    }
  }

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

  public static func subscribe(
    to sessionID: Int64? = nil,
    at socketPath: UnixSocketPath
  ) async throws -> TerminalSubscriptionID {
    try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.session.subscribe",
        params: SessionSubscribeRequest(sessionId: sessionID))
    }
  }

  public static func nextEvent(
    for subscription: TerminalSubscriptionID,
    timeout: Duration = .seconds(15),
    at socketPath: UnixSocketPath
  ) async throws -> TerminalSessionEvent? {
    let timeoutMilliseconds = min(20_000, max(1, timeout.milliseconds))
    let response: SessionEventsNextResponse = try await withResponse(
      at: socketPath,
      timeout: .milliseconds(timeoutMilliseconds + 1_000)
    ) { session in
      try await session.response(
        to: "axo.session.events.next",
        params: SessionEventsNextRequest(
          subscriptionId: subscription.subscriptionId,
          timeoutMs: UInt64(timeoutMilliseconds)))
    }
    return response.event
  }

  public static func unsubscribe(
    _ subscription: TerminalSubscriptionID,
    at socketPath: UnixSocketPath
  ) async throws {
    let response: SessionUnsubscribeResponse = try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.session.unsubscribe",
        params: SessionUnsubscribeRequest(subscriptionId: subscription.subscriptionId))
    }
    guard response.unsubscribed else {
      throw UnixSocketRPCError.invalidResponse(
        "daemon did not unsubscribe the session event stream")
    }
  }

  public static func sendTerminalInput(
    _ data: Data,
    to shellID: Int64,
    in sessionID: Int64,
    sequence: UInt64,
    at socketPath: UnixSocketPath
  ) async throws {
    let response: TerminalInputResponse = try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.terminal.input",
        params: TerminalInputRequest(
          sessionId: sessionID,
          shellId: shellID,
          sequence: sequence,
          data: data.base64EncodedString()))
    }
    guard response.accepted, response.sequence == sequence else {
      throw UnixSocketRPCError.invalidResponse("daemon did not accept terminal input")
    }
  }

  public static func resizeTerminal(
    shellID: Int64,
    in sessionID: Int64,
    rows: UInt32,
    columns: UInt32,
    at socketPath: UnixSocketPath
  ) async throws {
    let response: TerminalResizeResponse = try await withResponse(at: socketPath) { session in
      try await session.response(
        to: "axo.terminal.resize",
        params: TerminalResizeRequest(
          sessionId: sessionID,
          shellId: shellID,
          rows: rows,
          columns: columns))
    }
    guard response.accepted, response.rows == rows, response.columns == columns else {
      throw UnixSocketRPCError.invalidResponse("daemon did not apply terminal dimensions")
    }
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

  public static func setLayout(
    _ layout: SessionLayout,
    for sessionID: Int64,
    at socketPath: UnixSocketPath
  ) async throws {
    let acknowledgement: SessionLayoutAcknowledgement = try await withResponse(
      at: socketPath
    ) { session in
      try await session.response(
        to: "axo.session.layout.set",
        params: SetSessionLayoutRequest(sessionId: sessionID, layout: layout)
      )
    }
    guard acknowledgement.saved else {
      throw UnixSocketRPCError.invalidResponse("daemon did not save the session layout")
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
  fileprivate var milliseconds: Int {
    let components = components
    guard components.seconds >= 0 else { return 1 }
    guard components.seconds < 20 else { return 20_000 }
    let whole = components.seconds * 1_000
    let fractional = components.attoseconds / 1_000_000_000_000_000
    return Int(min(20_000, max(1, whole + fractional)))
  }

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
