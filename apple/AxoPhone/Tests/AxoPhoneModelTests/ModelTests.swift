import AxoClient
import AxoProtocol
import XCTest

@testable import AxoPhoneModel

final class MemoryTokenStore: SessionTokenStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var token: SessionToken?
  init(_ token: SessionToken? = nil) { self.token = token }
  func load() -> SessionToken? { lock.withLock { token } }
  var failsToSave = false
  func save(_ token: SessionToken) throws {
    if failsToSave { throw NSError(domain: "keychain", code: -34018) }
    lock.withLock { self.token = token }
  }
  func delete() { lock.withLock { token = nil } }
}

@MainActor
final class AccountSessionTests: XCTestCase {
  func testStartsSignedInOnlyWithAStoredToken() {
    XCTAssertEqual(AccountSession(store: MemoryTokenStore()).state, .signedOut)
    XCTAssertEqual(
      AccountSession(store: MemoryTokenStore(SessionToken.fixture())).state, .signedIn)
  }

  func testSigningInStoresTheTokenForClientsAndSigningOutForgetsIt() async throws {
    let store = MemoryTokenStore()
    let session = AccountSession(store: store)
    do {
      _ = try await session.tokens.sessionToken()
      XCTFail("no token before sign-in")
    } catch {
      XCTAssertEqual(error as? RelayError, .signInRequired)
    }
    session.signIn(with: try XCTUnwrap(SessionToken.fixture(1)))
    XCTAssertEqual(session.state, .signedIn)
    let token = try await session.tokens.sessionToken()
    XCTAssertEqual(token.value, SessionToken.fixture(1).value)
    session.signOut()
    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNil(store.load())
  }

  func testATokenThatCannotBeKeptDoesNotSignThePhoneIn() {
    let store = MemoryTokenStore()
    store.failsToSave = true
    let session = AccountSession(store: store)
    session.signIn(with: SessionToken.fixture())
    XCTAssertEqual(session.state, .signedOut)
    XCTAssertNotNil(session.signInFailure)
    store.failsToSave = false
    session.signIn(with: SessionToken.fixture())
    XCTAssertEqual(session.state, .signedIn)
    XCTAssertNil(session.signInFailure)
  }

  func testOnlyAnAccessRefusalSignsThePhoneOut() {
    let session = AccountSession(store: MemoryTokenStore(SessionToken.fixture()))
    XCTAssertFalse(session.noteFailure(RelayError.httpStatus(503)))
    XCTAssertFalse(session.noteFailure(AxoClientError.requestTimedOut))
    XCTAssertEqual(session.state, .signedIn)
    XCTAssertTrue(session.noteFailure(RelayError.signInRequired))
    XCTAssertEqual(session.state, .signedOut)
  }
}

@MainActor
final class HostsModelTests: XCTestCase {
  private struct Listing: HostListing {
    let result: Result<[RemoteHost], Error>
    func hosts() async throws -> [RemoteHost] { try result.get() }
  }

  func testOnlineHostsComeFirstThenByName() async throws {
    let hosts = try [host("Zed", .online), host("Alpha", .offline), host("Beta", .online)]
    let model = HostsModel(
      listing: Listing(result: .success(hosts)),
      account: AccountSession(store: MemoryTokenStore(SessionToken.fixture())))
    await model.refresh()
    XCTAssertEqual(model.hosts.map(\.label), ["Beta", "Zed", "Alpha"])
    XCTAssertEqual(model.phase, .loaded)
  }

  func testAnAccessRefusalSignsOutAndClearsHosts() async throws {
    let account = AccountSession(store: MemoryTokenStore(SessionToken.fixture()))
    let model = HostsModel(
      listing: Listing(result: .success([try host("A", .online)])), account: account)
    await model.refresh()
    XCTAssertEqual(model.hosts.count, 1)
    let refusing = HostsModel(
      listing: Listing(result: .failure(RelayError.signInRequired)), account: account)
    await refusing.refresh()
    XCTAssertEqual(account.state, .signedOut)
    XCTAssertTrue(refusing.hosts.isEmpty)
    guard case .failed = refusing.phase else { return XCTFail("\(refusing.phase)") }
  }

  func testAnOtherwiseFailedRefreshKeepsWhatWasShown() async throws {
    let model = HostsModel(
      listing: Listing(result: .failure(RelayError.httpStatus(503))),
      account: AccountSession(store: MemoryTokenStore(SessionToken.fixture())))
    await model.refresh()
    XCTAssertEqual(model.phase, .failed("The Axo relay answered HTTP 503."))
  }
}

func host(_ label: String, _ status: RemoteHostStatus, sessions: [String] = []) throws -> RemoteHost {
  let id = UUID().uuidString
  let json = """
    {"hostId":"\(id)","hostGeneration":"\(UUID().uuidString)","label":"\(label)","hostKind":"macos",
    "status":"\(status.rawValue)","stale":\(status == .offline),"lastSeenAt":"2026-10-16T00:00:00Z",
    "sessions":[\(sessions.joined(separator: ","))]}
    """
  return try JSONDecoder().decode(RemoteHost.self, from: Data(json.utf8))
}

func sessionJSON(host: UUID, id: Int, name: String, shells: [Int]) -> String {
  let shellList = shells.map { #"{"shellId":\#($0)}"# }.joined(separator: ",")
  let layout = shells.first.map { #"{"kind":"pane","shellId":\#($0)}"# } ?? "null"
  return #"{"hostId":"\#(host.uuidString)","sessionId":\#(id),"name":"\#(name)","shells":[\#(shellList)],"layout":\#(layout),"updatedAt":"2026-10-16T00:00:00Z"}"#
}

extension SessionToken {
  /// A well-formed token for tests; `seed` makes different ones.
  static func fixture(_ seed: UInt8 = 0) -> SessionToken {
    let secret = Data((0..<32).map { UInt8(($0 &+ Int(seed)) & 0xFF) }).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return SessionToken("axo1.6b0f0e0e-2c43-4b8e-9d0a-0d8f7b2b9c11.\(secret)")!
  }
}
