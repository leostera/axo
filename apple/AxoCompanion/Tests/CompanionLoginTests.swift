import Foundation
import XCTest
@testable import AxoCompanion

private let fixtureID = UUID(uuidString: "6b0f0e0e-2c43-4b8e-9d0a-0d8f7b2b9c11")!
private let fixtureToken = "axo1.6b0f0e0e-2c43-4b8e-9d0a-0d8f7b2b9c11.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
private func credential() throws -> CompanionSession { try CompanionSession(token: fixtureToken) }
private func account(_ id: UUID = fixtureID) throws -> CompanionAccount {
  try JSONDecoder().decode(CompanionAccount.self, from: Data("{\"accountId\":\"\(id)\",\"profile\":{\"name\":\"Test account\",\"email\":null}}".utf8))
}

final class CompanionLoginTests: XCTestCase {
  func testSessionParsesCanonicalNativeTokenOnly() throws {
    XCTAssertEqual(try credential().accountID, fixtureID)
    for token in ["", fixtureToken + "\n", fixtureToken.replacingOccurrences(of: "axo1", with: "axo2"), fixtureToken + "=",
      fixtureToken.replacingOccurrences(of: "Hh8", with: "Hh9")] {
      XCTAssertThrowsError(try CompanionSession(token: token))
    }
  }

  func testDecodingRejectsTokenAccountMismatchAndInvalidRevision() throws {
    let source = try JSONEncoder().encode(credential())
    let text = String(decoding: source, as: UTF8.self).replacingOccurrences(of: fixtureID.uuidString, with: UUID().uuidString)
    XCTAssertThrowsError(try JSONDecoder().decode(CompanionSession.self, from: Data(text.utf8)))
    XCTAssertThrowsError(try CompanionSnapshot(authority: UUID(), revision: 0, authentication: .signedOut))
  }

  func testQueuedContextsCannotEstablishANewPhoneIdentity() throws {
    var state = CompanionLoginState()
    let snapshot = try CompanionSnapshot(authority: UUID(), revision: 1, authentication: .signedIn(credential()))
    XCTAssertFalse(state.receive(snapshot, authoritative: false))
    XCTAssertNil(state.session)
    XCTAssertTrue(state.receive(snapshot, authoritative: true))
    XCTAssertEqual(state.session, try credential())
    let otherPhone = try CompanionSnapshot(authority: UUID(), revision: 999, authentication: .signedIn(credential()))
    XCTAssertFalse(state.receive(otherPhone, authoritative: false))
    XCTAssertEqual(state.snapshot, snapshot)
    XCTAssertTrue(state.receive(otherPhone, authoritative: true))
  }

  func testDelayedSignInCannotUndoSignOutEvenAfterRestart() throws {
    let phone = UUID()
    let signedIn = try CompanionSnapshot(authority: phone, revision: 1, authentication: .signedIn(credential()))
    let signedOut = try CompanionSnapshot(authority: phone, revision: 2, authentication: .signedOut)
    var state = CompanionLoginState()
    XCTAssertTrue(state.receive(signedIn, authoritative: true))
    XCTAssertTrue(state.receive(signedOut, authoritative: false))
    state = try JSONDecoder().decode(CompanionLoginState.self, from: JSONEncoder().encode(state))
    XCTAssertFalse(state.receive(signedIn, authoritative: true))
    XCTAssertFalse(state.receive(signedOut, authoritative: true))
    XCTAssertNil(state.session)
  }

  @MainActor func testPhoneSnapshotOrderingSurvivesRestartsWithoutSavingTokenInDefaults() throws {
    let suite = "axo-companion-tests-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let first = try CompanionSnapshotPublisher(defaults: defaults).snapshot(for: .signedIn(credential()))
    let repeated = try CompanionSnapshotPublisher(defaults: defaults).snapshot(for: .signedIn(credential()))
    XCTAssertEqual(first, repeated)
    let signedOut = try CompanionSnapshotPublisher(defaults: defaults).snapshot(for: .signedOut)
    XCTAssertEqual(signedOut.authority, first.authority)
    XCTAssertEqual(signedOut.revision, first.revision + 1)
    let values = String(describing: defaults.persistentDomain(forName: suite))
    XCTAssertFalse(values.contains(fixtureToken))
  }

  @MainActor func testWatchChecksRealAccountBeforeReportingConnected() async throws {
    let store = MemoryLoginStore()
    let model = WatchCompanionModel(store: store, checkAccount: { _ in try account() })
    model.setActive(true)
    await model.refresh()
    XCTAssertEqual(model.status, .waitingForPhone)
    let snapshot = try CompanionSnapshot(authority: UUID(), revision: 1, authentication: .signedIn(credential()))
    await model.receive(snapshot, authoritative: false)
    XCTAssertEqual(model.status, .waitingForPhone)
    await model.receive(snapshot, authoritative: true)
    XCTAssertEqual(model.status, .verified(try account()))
    XCTAssertEqual(try store.load().session, try credential())
    model.setActive(false)
    XCTAssertEqual(model.status, .inactive)
  }

  @MainActor func testUnknownPhoneContextSuspendsCachedAccountUntilALiveReply() async throws {
    let model = WatchCompanionModel(store: MemoryLoginStore(), checkAccount: { _ in try account() })
    model.setActive(true)
    let current = try CompanionSnapshot(authority: UUID(), revision: 1, authentication: .signedIn(credential()))
    await model.receive(current, authoritative: true)
    await model.receive(try CompanionSnapshot(authority: UUID(), revision: 1, authentication: .signedOut), authoritative: false)
    await model.refresh()
    XCTAssertEqual(model.status, .waitingForPhone)
    await model.receive(current, authoritative: true)
    XCTAssertEqual(model.status, .verified(try account()))
  }

  @MainActor func testRevocationClearsCachedCredentialAndNeverReportsConnected() async throws {
    let store = MemoryLoginStore()
    let model = WatchCompanionModel(store: store, checkAccount: { _ in throw CompanionError.unauthorized })
    model.setActive(true)
    let snapshot = try CompanionSnapshot(authority: UUID(), revision: 1, authentication: .signedIn(credential()))
    await model.receive(snapshot, authoritative: true)
    XCTAssertEqual(model.status, .signedOut)
    XCTAssertNil(model.login.session)
    XCTAssertNil(try store.load().session)
  }

  @MainActor func testStorageFailureDoesNotUseAnUnstoredCredential() async throws {
    let store = MemoryLoginStore(failSave: true)
    let model = WatchCompanionModel(store: store, checkAccount: { _ in XCTFail("No request before secure storage"); return try account() })
    model.setActive(true)
    await model.receive(try CompanionSnapshot(authority: UUID(), revision: 1, authentication: .signedIn(credential())), authoritative: true)
    XCTAssertNil(model.login.session)
    guard case .offline = model.status else { return XCTFail("Storage failure must be visible") }
  }

  @MainActor func testSignOutWinsOverAnInflightAccountReply() async throws {
    let gate = AccountGate()
    let model = WatchCompanionModel(store: MemoryLoginStore(), checkAccount: { _ in try await gate.check() })
    model.setActive(true)
    let phone = UUID()
    let signedIn = try CompanionSnapshot(authority: phone, revision: 1, authentication: .signedIn(credential()))
    let checking = Task { await model.receive(signedIn, authoritative: true) }
    await gate.started()
    await model.receive(try CompanionSnapshot(authority: phone, revision: 2, authentication: .signedOut), authoritative: false)
    await gate.finish(try account())
    await checking.value
    XCTAssertEqual(model.status, .signedOut)
    XCTAssertNil(model.login.session)
  }

  @MainActor func testNetworkFailureIsNotPresentedAsASignOut() async throws {
    let store = MemoryLoginStore()
    let model = WatchCompanionModel(store: store, checkAccount: { _ in throw URLError(.notConnectedToInternet) })
    model.setActive(true)
    await model.receive(try CompanionSnapshot(authority: UUID(), revision: 1, authentication: .signedIn(credential())), authoritative: true)
    guard case .offline = model.status else { return XCTFail("Expected offline state") }
    XCTAssertNotNil(model.login.session)
  }
}

private final class MemoryLoginStore: CompanionLoginStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var state = CompanionLoginState()
  private let failSave: Bool
  init(failSave: Bool = false) { self.failSave = failSave }
  func load() throws -> CompanionLoginState { lock.lock(); defer { lock.unlock() }; return state }
  func save(_ state: CompanionLoginState) throws {
    lock.lock(); defer { lock.unlock() }
    if failSave { throw CompanionError.storage(-1) }
    self.state = state
  }
}

private actor AccountGate {
  private var continuation: CheckedContinuation<CompanionAccount, Error>?
  private var waiter: CheckedContinuation<Void, Never>?
  func check() async throws -> CompanionAccount {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      waiter?.resume(); waiter = nil
    }
  }
  func started() async {
    if continuation != nil { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func finish(_ account: CompanionAccount) { continuation?.resume(returning: account); continuation = nil }
}
