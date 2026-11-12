import AxoClient
import AxoProtocol
import XCTest
@testable import AxoPhoneModel
@testable import AxoWatchModel

@MainActor
final class WatchChatModelTests: XCTestCase {
  private let accountID = UUID(uuidString: "6b0f0e0e-2c43-4b8e-9d0a-0d8f7b2b9c11")!
  private var sessionID: SessionID { SessionID(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!) }

  private func fixture() throws -> (WatchChatModel, RemoteHost) {
    let session = RemoteSession(hostId: UUID(), sessionId: sessionID, name: "Watch test", hasAgent: true)
    let host = RemoteHost(hostId: session.hostId, hostGeneration: UUID(), label: "Test Mac", status: .online, sessions: [session])
    let profile = TestProfile()
    let hosts = HostsModel(profile: profile)
    hosts.adopt(ClientHello(hosts: [ClientHost(hostId: host.hostId, hostGeneration: host.hostGeneration, label: host.label, online: true)],
      sessions: [ClientSession(hostId: host.hostId, sessionId: sessionID, metadata: SessionMetadata(name: "Watch test", hasAgent: true))]))
    let token = try XCTUnwrap(SessionToken("axo1.\(accountID.uuidString.lowercased()).AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"))
    let account = AccountSession(store: TestTokenStore(token: token))
    let connection = AccountConnection(transport: NoNetwork(), clientID: .random())
    let workbench = PhoneWorkbench(hosts: hosts, feed: connection, account: account, makeWorkbench: { host in
      HostWorkbenchModel(host: host, connection: HostConnection(account: connection, host: host.reference), feed: connection, account: account)
    })
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "watch-chat-tests-\(UUID())"))
    return (WatchChatModel(accountID: accountID, workbench: workbench, account: account, defaults: defaults), host)
  }

  func testAChosenSessionIsBoundToItsAccountAndHostGeneration() throws {
    let (_, host) = try fixture()
    let target = WatchChatTarget(accountID: accountID, host: host.reference, session: sessionID)
    XCTAssertNotNil(target.resolve(in: [host], account: accountID))
    XCTAssertNil(target.resolve(in: [host], account: UUID()))
    let restarted = RemoteHost(hostId: host.hostId, hostGeneration: UUID(), label: host.label, status: .online, sessions: host.sessions)
    XCTAssertNil(target.resolve(in: [restarted], account: accountID))
    XCTAssertNil(target.resolve(in: [], account: accountID))
    XCTAssertEqual(try JSONDecoder().decode(WatchChatTarget.self, from: JSONEncoder().encode(target)), target)
  }

  func testDictationIsOnlyAReviewableDraftAndNeverAutomaticallySends() throws {
    let (model, host) = try fixture()
    XCTAssertTrue(model.select(host: host, session: host.sessions[0]))
    let target = try XCTUnwrap(model.target)
    XCTAssertTrue(model.acceptTranscript("  hello from my wrist  ", for: target))
    XCTAssertEqual(model.draft?.text, "hello from my wrist")
    XCTAssertFalse(model.canSend, "the account socket has not connected")
    XCTAssertNil(model.workbench.selection?.session == nil ? nil : model.chat?.pending.first)
    model.discardDraft()
    XCTAssertNil(model.draft)
    XCTAssertFalse(model.acceptTranscript("  \n ", for: target))
    model.stop()
  }

  func testDelayedDictationCannotLandInAnotherSession() throws {
    let (model, host) = try fixture()
    XCTAssertTrue(model.select(host: host, session: host.sessions[0]))
    let wrong = WatchChatTarget(accountID: accountID, host: host.reference, session: SessionID(UUID()))
    XCTAssertFalse(model.acceptTranscript("wrong session", for: wrong))
    XCTAssertNil(model.draft)
    let wrongAccount = WatchChatTarget(accountID: UUID(), host: host.reference, session: sessionID)
    XCTAssertFalse(model.acceptTranscript("wrong account", for: wrongAccount))
    model.stop()
  }

  func testSignOutDropsTheDraftAndBlocksFurtherDictation() throws {
    let (model, host) = try fixture()
    XCTAssertTrue(model.select(host: host, session: host.sessions[0]))
    let target = try XCTUnwrap(model.target)
    XCTAssertTrue(model.acceptTranscript("private draft", for: target))
    model.stop()
    XCTAssertNil(model.draft)
    XCTAssertFalse(model.canSend)
    XCTAssertFalse(model.acceptTranscript("late dictation", for: target))
  }

  func testDisappearedSessionCannotBeReplacedByANewChat() async throws {
    let (model, host) = try fixture()
    XCTAssertTrue(model.select(host: host, session: host.sessions[0]))
    let target = try XCTUnwrap(model.target)
    XCTAssertTrue(model.acceptTranscript("do not reroute", for: target))
    model.workbench.hosts.adopt(ClientHello(hosts: [], sessions: []))
    model.reconcile()
    XCTAssertNil(model.selectedSession)
    XCTAssertFalse(model.canSend)
    await model.send()
    XCTAssertEqual(model.target, target)
    XCTAssertEqual(model.draft?.text, "do not reroute")
    model.stop()
  }
}

private struct NoNetwork: AxoTransport {
  func connect() async throws -> any AxoMessageChannel { throw AxoClientError.connectionFailed("Test: no network") }
}
private struct TestProfile: SignedInAccountLoading {
  func signedInAccount() async -> SignedInAccount? { nil }
}
private struct TestTokenStore: SessionTokenStoring {
  let token: SessionToken
  func load() -> SessionToken? { token }
  func save(_ token: SessionToken) throws {}
  func delete() {}
}
