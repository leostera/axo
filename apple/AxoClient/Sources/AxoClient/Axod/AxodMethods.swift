import AxoProtocol
import Foundation

struct ConfigGetRequest: Encodable {
  let key: AxoConfigKey
}

struct ConfigSetRequest: Encodable {
  let key: AxoConfigKey
  let value: String
}

/// `axo.session.create`: in `folder`, beside the open Session `like`, or, with neither, at home.
struct SessionCreateRequest: Encodable {
  let folder: String?
  let like: SessionID?
}

struct SessionRenameRequest: Encodable {
  let sessionId: SessionID
  let name: String
}

struct ProtocolNegotiationRequest: Encodable {
  let protocolVersion: UInt32
}

struct RemoteAccessConnectResponse: Decodable {
  let requested: Bool
}

struct ViewportAcknowledgement: Decodable {
  let accepted: Bool
}

struct HostPairingRequest: Encodable {
  let code: String
}

struct CloseTerminalSessionRequest: Encodable {
  let sessionId: SessionID
}

struct PeerSessionRequest: Encodable {
  let hostId: String
  let sessionId: SessionID
}

struct PeerSessionClosed: Decodable {
  let closed: Bool
}

struct RestartPiSessionRequest: Encodable {
  let sessionId: SessionID
  let shellId: ShellID
}

struct CreateTerminalShellRequest: Encodable {
  let sessionId: SessionID
}

struct SetSessionLayoutRequest: Encodable {
  let sessionId: SessionID
  let layout: SessionLayout
}

struct SessionLayoutAcknowledgement: Decodable {
  let saved: Bool
}

/// Identifies one shell; used by `axo.shell.close` and `axo.shell.busy`.
struct ShellRequest: Encodable {
  let sessionId: SessionID
  let shellId: ShellID
}

struct SessionSubscribeRequest: Encodable {
  let sessionId: SessionID?
  let includeTerminalOutput: Bool

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    if let sessionId { try container.encode(sessionId, forKey: .sessionId) }
    try container.encode(includeTerminalOutput, forKey: .includeTerminalOutput)
  }

  private enum CodingKeys: String, CodingKey { case sessionId, includeTerminalOutput }
}

/// Wire parameters for methods that take none.
typealias NoParams = String?

/// One axod JSON-RPC method: its name, parameter and result types, and how long a call may take.
struct AxodMethod<Params: Encodable & Sendable, Result: Decodable & Sendable>: Sendable {
  let name: AxodMethodName
  let timeout: Duration

  init(_ name: AxodMethodName, timeout: Duration = .seconds(5)) {
    self.name = name
    self.timeout = timeout
  }
}

/// axod's methods with their types. `AxodConnection` wraps each with argument shaping and
/// result checks.
enum AxodMethods {
  static let negotiate = AxodMethod<ProtocolNegotiationRequest, ProtocolNegotiation>(.negotiate)
  static let health = AxodMethod<NoParams, DaemonHealth>(.health, timeout: .seconds(2))
  static let relayStatus = AxodMethod<NoParams, RemoteAccessStatus>(.relayStatus)
  static let relayConnect = AxodMethod<NoParams, RemoteAccessConnectResponse>(.relayConnect)
  static let relayLink = AxodMethod<HostPairingRequest, HostPairingResult>(.relayLink)
  static let configGet = AxodMethod<ConfigGetRequest, AxoConfigValue>(.configGet)
  static let configSet = AxodMethod<ConfigSetRequest, AxoConfigValue>(.configSet)
  static let sessionList = AxodMethod<NoParams, TerminalSessionListSnapshot>(.sessionList)
  static let sessionCreate = AxodMethod<SessionCreateRequest, TerminalSession>(.sessionCreate)
  static let sessionClose = AxodMethod<CloseTerminalSessionRequest, ClosedTerminalSession>(.sessionClose)
  static let sessionRename = AxodMethod<SessionRenameRequest, TerminalSession>(.sessionRename)
  static let peerSessionsList = AxodMethod<NoParams, PeerSessionList>(.peerSessionsList)
  /// Starts Pi in remote mode for the Session before answering.
  static let peerSessionOpen = AxodMethod<PeerSessionRequest, PeerSession>(.peerSessionOpen, timeout: .seconds(20))
  static let peerSessionClose = AxodMethod<PeerSessionRequest, PeerSessionClosed>(.peerSessionClose, timeout: .seconds(10))
  /// Starts the Session's terminals and resumes its Pi before answering.
  static let sessionReopen = AxodMethod<NoParams, TerminalSession>(.sessionReopen, timeout: .seconds(20))
  static let sessionLayoutSet = AxodMethod<SetSessionLayoutRequest, SessionLayoutAcknowledgement>(.sessionLayoutSet)
  static let piRestartForce = AxodMethod<RestartPiSessionRequest, TerminalSession>(.piRestartForce, timeout: .seconds(20))
  static let piRestartAuto = AxodMethod<RestartPiSessionRequest, TerminalSession>(.piRestartAuto, timeout: .seconds(20))
  static let shellCreate = AxodMethod<CreateTerminalShellRequest, TerminalShell>(.shellCreate)
  static let shellClose = AxodMethod<ShellRequest, ClosedTerminalShell>(.shellClose)
  static let shellBusy = AxodMethod<ShellRequest, TerminalShellBusy>(.shellBusy)
  /// Older daemons do not offer this; check negotiation first.
  static let clientViewportSet = AxodMethod<ClientViewport, ViewportAcknowledgement>(.clientViewportSet)
  static let elicitationList = AxodMethod<NoParams, PendingElicitations>(.elicitationList)
  static let elicitationResolve = AxodMethod<LocalElicitationAnswer, ElicitationResolution>(.elicitationResolve)
}
