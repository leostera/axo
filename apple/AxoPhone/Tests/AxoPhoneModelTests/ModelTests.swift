import AxoClient
import AxoProtocol
import XCTest

@testable import AxoPhoneModel

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

  func testAStoreThatBecomesAvailableCanRestoreButCannotUndoExplicitSignOut() throws {
    let store = MemoryTokenStore()
    let session = AccountSession(store: store)
    XCTAssertEqual(session.state, .signedOut)
    try store.save(SessionToken.fixture())
    session.restoreStoredSession()
    XCTAssertEqual(session.state, .signedIn)
    session.signOut()
    try store.save(SessionToken.fixture())
    session.restoreStoredSession()
    XCTAssertEqual(session.state, .signedOut)
    XCTAssertTrue(session.hasEndedSession)
    session.signIn(with: SessionToken.fixture())
    XCTAssertFalse(session.hasEndedSession)
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
  private struct Profile: SignedInAccountLoading {
    func signedInAccount() async -> SignedInAccount? { nil }
  }

  private func listing(_ macs: [Mac]) throws -> ClientHello {
    try JSONDecoder().decode(ClientHello.self, from: Data(Mac.listing(macs).utf8))
  }

  func testOnlineHostsComeFirstThenByName() throws {
    let model = HostsModel(profile: Profile())
    model.adopt(try listing([Mac("Zed", online: true), Mac("Alpha", online: false), Mac("Beta", online: true)]))
    XCTAssertEqual(model.hosts.map(\.label), ["Beta", "Zed", "Alpha"])
    XCTAssertEqual(model.phase, .loaded)
  }

  func testAHostsSessionsAreItsOwnAndChangesReplaceThem() throws {
    let a = Mac("A", online: true, sessions: [1, 2])
    let b = Mac("B", online: true, sessions: [3])
    let model = HostsModel(profile: Profile())
    model.adopt(try listing([a, b]))
    XCTAssertEqual(model.hosts.first { $0.hostId == a.id }?.sessions.count, 2)
    model.update(sessions: [ClientSession(hostId: a.id, sessionId: 1, metadata: SessionMetadata(name: "Renamed"))], of: a.id)
    XCTAssertEqual(model.hosts.first { $0.hostId == a.id }?.sessions.first { $0.sessionId == 1 }?.displayName, "Renamed")
    model.update(hosts: [ClientHost(hostId: b.id, hostGeneration: b.generation, label: "B", online: false)])
    XCTAssertEqual(model.hosts.map(\.label), ["B"], "a host no longer listed goes, with its Sessions")
    XCTAssertEqual(model.hosts.first?.sessions.map(\.sessionId), [3])
    XCTAssertEqual(model.hosts.first?.status, .offline)
  }

  func testAFailureBeforeTheFirstListingIsShownButNotAfter() throws {
    let model = HostsModel(profile: Profile())
    model.loading()
    XCTAssertEqual(model.phase, .loading)
    model.failed("no connection")
    XCTAssertEqual(model.phase, .failed("no connection"))
    model.adopt(try listing([Mac("A", online: true)]))
    model.failed("again")
    XCTAssertEqual(model.phase, .loaded, "what was shown stays")
  }
}

func sessionJSON(host: UUID, id: Int, name: String, shells: [Int]) -> String {
  let shellList = shells.map { #"{"shellId":\#($0)}"# }.joined(separator: ",")
  let layout = shells.first.map { #"{"kind":"pane","shellId":\#($0)}"# } ?? "null"
  return #"{"hostId":"\#(host.uuidString)","sessionId":"\#(SessionID.fixture(UInt32(id)))","name":"\#(name)","shells":[\#(shellList)],"layout":\#(layout),"updatedAt":"2026-10-16T00:00:00Z"}"#
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
