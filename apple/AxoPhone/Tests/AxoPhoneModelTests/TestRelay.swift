import AxoClient
import AxoProtocol
import XCTest

@testable import AxoPhoneModel

/// Plays the account's ClientDO (RFD0018) on the wire: hands out channels, answers hello and
/// refresh with `listing`, keeps the notifications the phone sends, and lets the test answer
/// everything else.
final class ScriptedTransport: AxoTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var made: [ScriptedChannel] = []
  private var listingJSON: String
  private var refusal: Error?
  private var answer: (@Sendable (ScriptedRequest) -> ScriptedReply?)?

  /// Answers requests as they come; a request it gives no reply for waits for the test.
  var responder: (@Sendable (ScriptedRequest) -> ScriptedReply?)? {
    get { lock.withLock { answer } }
    set { lock.withLock { answer = newValue } }
  }

  init(listing: String = Wire.listing()) { listingJSON = listing }

  var connects: Int { lock.withLock { made.count } }

  /// What hello and refresh answer from now on.
  var listing: String {
    get { lock.withLock { listingJSON } }
    set { lock.withLock { listingJSON = newValue } }
  }

  /// Connecting fails with `error` from now on (nil connects again).
  func refuse(_ error: Error?) { lock.withLock { refusal = error } }

  func connect() async throws -> any AxoMessageChannel {
    try lock.withLock {
      if let refusal { throw refusal }
      let channel = ScriptedChannel(
        listing: { [weak self] in self?.listing ?? Wire.listing() }, responder: { [weak self] in self?.responder?($0) })
      made.append(channel)
      return channel
    }
  }

  /// The `number`th connection (1 is the first), once it is made.
  func channel(number: Int) async throws -> ScriptedChannel {
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
      if let channel = lock.withLock({ made.count >= number ? made[number - 1] : nil }) { return channel }
      try await Task.sleep(for: .milliseconds(2))
    }
    throw AxoClientError.connectionFailed("connection \(number) was never made")
  }

  /// The newest connection, once one is made.
  func channel() async throws -> ScriptedChannel {
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
      if let channel = lock.withLock({ made.last }) { return channel }
      try await Task.sleep(for: .milliseconds(2))
    }
    throw AxoClientError.connectionFailed("never connected")
  }
}

/// A request the phone sent. A command names its host's method: `method` and `params` are the
/// host's, as the old per-host socket had them.
struct ScriptedRequest: @unchecked Sendable {
  let id: Int
  let rpcMethod: String
  let method: String
  let params: [String: Any]
  let hostID: String?

  init?(_ raw: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any], let id = object["id"] as? Int,
      let rpcMethod = object["method"] as? String
    else { return nil }
    let params = object["params"] as? [String: Any] ?? [:]
    let command = rpcMethod == "axo.client.command"
    self.id = id
    self.rpcMethod = rpcMethod
    method = command ? (params["method"] as? String ?? "") : rpcMethod
    self.params = command ? (params["params"] as? [String: Any] ?? [:]) : params
    hostID = params["hostId"] as? String
  }
}

enum ScriptedReply {
  case result(String)
  case error(Int, String)
}

final class ScriptedChannel: AxoMessageChannel, @unchecked Sendable {
  let messages: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private let lock = NSLock()
  private let listing: @Sendable () -> String
  private let responder: @Sendable (ScriptedRequest) -> ScriptedReply?
  private var sent: [Data] = []
  private var consumed = 0
  private var sentNotices: [(method: String, params: [String: Any])] = []

  init(listing: @escaping @Sendable () -> String, responder: @escaping @Sendable (ScriptedRequest) -> ScriptedReply? = { _ in nil }) {
    self.listing = listing
    self.responder = responder
    (messages, continuation) = AsyncStream<Data>.makeStream()
  }

  func send(_ message: Data) async throws {
    guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else { return }
    let method = object["method"] as? String
    guard let id = object["id"] as? Int else {
      lock.withLock { sentNotices.append((method ?? "", object["params"] as? [String: Any] ?? [:])) }
      return
    }
    if method == "axo.client.hello" || method == "axo.client.refresh" {
      reply(to: id, result: listing())
      return
    }
    if let request = ScriptedRequest(message), let answer = responder(request) {
      switch answer {
      case .result(let result): reply(to: id, result: result)
      case .error(let code, let text): reply(to: id, error: code, message: text)
      }
      return
    }
    lock.withLock { sent.append(message) }
  }

  func close() { continuation.finish() }

  /// The notifications the phone sent: acknowledgements and closes.
  var notices: [(method: String, params: [String: Any])] { lock.withLock { sentNotices } }

  /// The cursors acknowledged for `session`, in order.
  func acks(of session: SessionID) -> [Int64] {
    notices.filter { $0.method == "axo.client.session.ack" && $0.params["sessionId"] as? String == session.rawValue }
      .compactMap { ($0.params["cursor"] as? NSNumber)?.int64Value }
  }

  func closes(of session: SessionID) -> Int {
    notices.filter { $0.method == "axo.client.session.close" && $0.params["sessionId"] as? String == session.rawValue }.count
  }

  func push(_ raw: String) { continuation.yield(Data(raw.utf8)) }

  /// A notification from the ClientDO.
  func notify(_ method: String, _ params: String) {
    push(#"{"jsonrpc":"2.0","method":"\#(method)","params":\#(params)}"#)
  }

  func reply(to id: Int, result: String) {
    push(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#)
  }

  func reply(to id: Int, error code: Int, message: String) {
    push(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":\#(code),"message":"\#(message)"}}"#)
  }

  func nextRequest() async throws -> ScriptedRequest {
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
      let raw = lock.withLock { () -> Data? in
        guard consumed < sent.count else { return nil }
        defer { consumed += 1 }
        return sent[consumed]
      }
      if let raw { return try XCTUnwrap(ScriptedRequest(raw)) }
      try await Task.sleep(for: .milliseconds(2))
    }
    throw AxoClientError.requestTimedOut
  }

  /// The next request for `method`; others before it are refused.
  func nextRequest(_ method: String) async throws -> ScriptedRequest {
    while true {
      let request = try await nextRequest()
      if request.method == method { return request }
      reply(to: request.id, error: -32601, message: "Method not found")
    }
  }

  /// Whether a request is waiting to be answered.
  var hasRequest: Bool { lock.withLock { consumed < sent.count } }

  func answerNext(result: String) async throws {
    reply(to: try await nextRequest().id, result: result)
  }
}

/// The ClientDO's JSON, built for tests.
enum Wire {
  static func host(_ id: UUID, _ label: String, online: Bool = true, generation: UUID = UUID()) -> String {
    #"{"hostId":"\#(id.uuidString.lowercased())","hostGeneration":"\#(generation.uuidString.lowercased())","label":"\#(label)","hostKind":"macos","online":\#(online),"lastSeenAt":"2026-10-16T00:00:00Z"}"#
  }

  static func session(
    host: UUID, id: SessionID, name: String, status: String? = nil, archived: Bool = false, createdAt: Int64? = nil,
    epoch: Int64? = 1, head: Int64 = 0
  ) -> String {
    let status = status.map { #""\#($0)""# } ?? "null"
    let created = createdAt.map(String.init) ?? "null"
    let epoch = epoch.map(String.init) ?? "null"
    return #"{"hostId":"\#(host.uuidString.lowercased())","sessionId":"\#(id.rawValue)","epoch":\#(epoch),"head":\#(head),"status":\#(status),"metadata":{"name":"\#(name)","emoji":null,"folderName":null,"hasAgent":true,"createdAt":\#(created),"lastMessageAt":null,"archived":\#(archived)}}"#
  }

  static func listing(hosts: [String] = [], sessions: [String] = []) -> String {
    #"{"hosts":[\#(hosts.joined(separator: ","))],"sessions":[\#(sessions.joined(separator: ","))]}"#
  }

  static func record(_ record: ClientRecord) -> String {
    let fields: [String: Any] = [
      "cursor": record.cursor, "id": record.id as Any? ?? NSNull(), "format": record.format, "line": record.line,
      "hash": record.hash,
    ]
    return String(decoding: try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
  }

  static func records(_ records: [ClientRecord]) -> String { "[" + records.map(record).joined(separator: ",") + "]" }

  static func opened(epoch: Int64? = 1, _ records: [ClientRecord], older: Int64? = nil, progress: String = "[]") -> String {
    let epoch = epoch.map(String.init) ?? "null"
    let older = older.map(String.init) ?? "null"
    return #"{"epoch":\#(epoch),"records":\#(Self.records(records)),"cursor":\#(records.last?.cursor ?? 0),"older":\#(older),"progress":\#(progress)}"#
  }

  static func olderPage(epoch: Int64 = 1, _ records: [ClientRecord], older: Int64? = nil) -> String {
    #"{"epoch":\#(epoch),"records":\#(Self.records(records)),"older":\#(older.map(String.init) ?? "null")}"#
  }

  static func recordsNotice(_ session: SessionID, epoch: Int64 = 1, _ records: [ClientRecord]) -> String {
    #"{"sessionId":"\#(session.rawValue)","epoch":\#(epoch),"records":\#(Self.records(records)),"cursor":\#(records.last?.cursor ?? 0)}"#
  }

  static func progressNotice(_ session: SessionID, slot: String, _ snapshot: String) -> String {
    #"{"sessionId":"\#(session.rawValue)","slot":"\#(slot)","snapshot":\#(snapshot)}"#
  }

  static func sessionsNotice(host: UUID, _ sessions: [String]) -> String {
    #"{"hostId":"\#(host.uuidString.lowercased())","sessions":[\#(sessions.joined(separator: ","))]}"#
  }
}

/// The receipt the Session's Pi writes just before a client's prompt (RFD0024).
func receipt(_ cursor: Int64, _ commandId: String) -> ClientRecord {
  ClientRecord(
    cursor: cursor, id: "e\(cursor)",
    line: #"{"type":"custom","id":"e\#(cursor)","customType":"axo.command","data":{"commandId":"\#(commandId)"}}"#)
}

/// A user or assistant message record.
func said(_ cursor: Int64, _ text: String, role: String = "user") -> ClientRecord {
  piRecord(cursor, message: #"{"role":"\#(role)","content":[{"type":"text","text":"\#(text)"}]}"#)
}

/// One Mac with its Sessions, as the phone holds it, and the account socket it is reached through.
@MainActor
struct HostWorld {
  let model: HostWorkbenchModel
  let transport: ScriptedTransport
  let feed: AccountConnection
  let account: AccountSession
  let host: RemoteHost

  init(sessions: [(SessionID, String)] = [(1, "One")], account: AccountSession? = nil, transport: ScriptedTransport? = nil) {
    let hostID = UUID()
    let client = ClientHost(hostId: hostID, hostGeneration: UUID(), label: "Studio", online: true)
    host = RemoteHost(client, sessions: sessions.enumerated().map { index, session in
      RemoteSession(ClientSession(
        hostId: hostID, sessionId: session.0,
        metadata: SessionMetadata(name: session.1, createdAt: Int64(index + 1)), epoch: 1, status: .ready))
    })
    self.transport = transport ?? ScriptedTransport()
    feed = AccountConnection(transport: self.transport, clientID: ClientID(rawValue: "test-client")!)
    self.account = account ?? AccountSession(store: MemoryTokenStore(SessionToken.fixture()))
    model = HostWorkbenchModel(
      host: host, connection: HostConnection(account: feed, host: host.reference), feed: feed, account: self.account)
    // A chat is open, as the person's tap on one would have made it.
    model.selectedSessionID = model.sessions.first?.sessionId
  }

  func channel() async throws -> ScriptedChannel { try await transport.channel() }

  /// Opens `id` and answers the open with `result`.
  func open(_ id: SessionID, answering result: String) async throws -> ScriptedRequest {
    let opening = Task { await model.loadHistory(of: id) }
    let channel = try await channel()
    let request = try await channel.nextRequest()
    channel.reply(to: request.id, result: result)
    await opening.value
    return request
  }
}

@MainActor
func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
  let deadline = ContinuousClock.now + .seconds(15)
  while !condition() {
    guard ContinuousClock.now < deadline else { return XCTFail("condition never held", file: file, line: line) }
    try await Task.sleep(for: .milliseconds(5))
  }
}
