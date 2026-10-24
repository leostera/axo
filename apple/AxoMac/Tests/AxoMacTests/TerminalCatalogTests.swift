import AxoRPC
import XCTest

@testable import AxoMac

/// An in-memory Axod for catalog tests: listing returns `sessions`, events come from `events`.
@MainActor
final class FakeAxodClient: AxodClient {
  var sessions: [TerminalSession] = []
  var workspaces: [WorkspaceRecord] = []
  var resumeSessionID: SessionID?
  var methods: [String] = Array(TerminalSessionsModel.requiredMethods) + [
    "axo.session.rename", "axo.workspace.rename", "axo.workspace.archive", "axo.shell.busy",
  ]
  private(set) var listCount = 0
  private(set) var workspaceListCount = 0
  private(set) var subscribeCount = 0
  private(set) var unsubscribed: [TerminalSubscriptionID] = []
  private(set) var layoutWrites: [(SessionID, SessionLayout)] = []
  private var queuedEvents: [TerminalSessionEvent] = []
  private var waiters: [CheckedContinuation<[TerminalSessionEvent], Error>] = []
  /// When set, subscribing fails with this error.
  var subscribeError: Error?

  func push(_ event: TerminalSessionEvent) {
    if waiters.isEmpty {
      queuedEvents.append(event)
    } else {
      waiters.removeFirst().resume(returning: [event])
    }
  }

  func negotiate() async throws -> ProtocolNegotiation {
    ProtocolNegotiation(protocolVersion: UnixSocketRPC.protocolVersion, methods: methods)
  }

  func listSessionSnapshot() async throws -> TerminalSessionListSnapshot {
    listCount += 1
    return TerminalSessionListSnapshot(sessions: sessions, resumeSessionId: resumeSessionID)
  }

  func listWorkspaces() async throws -> [WorkspaceRecord] {
    workspaceListCount += 1
    return workspaces
  }

  func subscribeToCatalog() async throws -> TerminalSubscriptionID {
    subscribeCount += 1
    if let subscribeError { throw subscribeError }
    return TerminalSubscriptionID(subscriptionId: "sub-\(subscribeCount)")
  }

  func nextEvents(for subscription: TerminalSubscriptionID) async throws -> [TerminalSessionEvent] {
    if !queuedEvents.isEmpty {
      defer { queuedEvents.removeAll() }
      return queuedEvents
    }
    return try await withCheckedThrowingContinuation { waiters.append($0) }
  }

  func unsubscribe(_ subscription: TerminalSubscriptionID) async throws {
    unsubscribed.append(subscription)
  }

  func createSession() async throws -> TerminalSession { throw Unsupported() }
  func createSession(inWorkspace workspaceID: String) async throws -> TerminalSession {
    throw Unsupported()
  }
  func createWorkspace(
    name: String, directoryPath: String, directoryBookmark: String?
  ) async throws -> CreatedWorkspace { throw Unsupported() }
  func closeSession(_ sessionID: SessionID) async throws -> ClosedTerminalSession {
    throw Unsupported()
  }
  func renameSession(_ sessionID: SessionID, to name: String) async throws -> TerminalSession {
    throw Unsupported()
  }
  func renameWorkspace(_ workspaceID: String, to name: String) async throws -> WorkspaceRecord {
    throw Unsupported()
  }
  func archiveWorkspace(_ workspaceID: String) async throws -> ArchivedWorkspace {
    throw Unsupported()
  }
  func createShell(inSession sessionID: SessionID) async throws -> TerminalShell { throw Unsupported() }
  var shellBusyResult: Result<TerminalShellBusy, Error> = .success(
    TerminalShellBusy(busy: false, foregroundProcess: nil))
  private(set) var closedShells: [ShellID] = []
  func shellBusy(_ shellID: ShellID, inSession sessionID: SessionID) async throws -> TerminalShellBusy {
    try shellBusyResult.get()
  }
  func closeShell(_ shellID: ShellID, inSession sessionID: SessionID) async throws -> ClosedTerminalShell {
    closedShells.append(shellID)
    throw Unsupported()
  }
  func setLayout(_ layout: SessionLayout, forSession sessionID: SessionID) async throws {
    layoutWrites.append((sessionID, layout))
  }
  private(set) var viewports: [ClientViewport] = []
  func setViewport(_ viewport: ClientViewport) async throws {
    viewports.append(viewport)
  }
  func restartPi(shellID: ShellID, inSession sessionID: SessionID, automatically: Bool) async throws
    -> TerminalSession
  { throw Unsupported() }

  struct Unsupported: Error {}
}

extension RemoteAccessStatus {
  static func fixture(_ state: RemoteAccessConnectionState, error: String? = nil) -> Self {
    RemoteAccessStatus(
      state: state, connectedSinceUnixMillis: state == .connected ? 1 : nil,
      hostName: "Test Mac", hostKind: "macos", lastError: error)
  }
}

/// Settings operations over the same fake; counts status reads to prove there is no polling.
@MainActor
final class FakeSettingsClient: AxodSettingsClient {
  var status = RemoteAccessStatus.fixture(.disconnected)
  private(set) var statusReads = 0
  private(set) var connectRequests = 0

  func configValue(for key: AxoConfigKey) async throws -> AxoConfigValue { throw FakeAxodClient.Unsupported() }
  func setConfigValue(_ value: String, for key: AxoConfigKey) async throws -> AxoConfigValue {
    throw FakeAxodClient.Unsupported()
  }
  func remoteAccessStatus() async throws -> RemoteAccessStatus {
    statusReads += 1
    return status
  }
  func requestRemoteAccessConnection() async throws {
    connectRequests += 1
    status = .fixture(.connecting)
  }
  func linkHost(using code: HostPairingCode) async throws -> HostPairingResult { throw FakeAxodClient.Unsupported() }
}

@MainActor
final class TerminalCatalogTests: XCTestCase {
  private func shell(_ id: ShellID) -> TerminalShell {
    TerminalShell(
      id: id, processId: 1, initialPwd: "/tmp", ptyDevice: "/dev/null",
      attachSocketPath: "/tmp/\(id).sock")
  }

  private func session(_ id: SessionID, shells: [ShellID], name: String? = nil) -> TerminalSession {
    TerminalSession(id: id, initialPwd: "/tmp", shells: shells.map(shell), name: name)
  }

  private func makeModel(_ client: FakeAxodClient) -> TerminalSessionsModel {
    TerminalSessionsModel(client: client)
  }

  func testRefreshListsCatalogAndSelectsFirstSession() async {
    let client = FakeAxodClient()
    client.sessions = [session(1, shells: [10]), session(2, shells: [20])]
    let model = makeModel(client)

    await model.refresh()

    XCTAssertEqual(model.sessions.map(\.id), [1, 2])
    XCTAssertEqual(model.selectedSessionID, 1)
    XCTAssertEqual(model.focusedShellID, 10)
    XCTAssertNil(model.errorMessage)
  }

  func testRefreshRejectsDaemonWithoutSubscriptions() async {
    let client = FakeAxodClient()
    client.methods = ["axo.session.list", "axo.workspace.list"]
    let model = makeModel(client)

    await model.refresh()

    XCTAssertNotNil(model.errorMessage)
    XCTAssertEqual(client.listCount, 0)
  }

  func testSnapshotEventInsertsAndUpdatesSessionsWithoutListing() async {
    let client = FakeAxodClient()
    client.sessions = [session(1, shells: [10])]
    let model = makeModel(client)
    await model.refresh()

    let inserted = await model.apply(.sessionSnapshot(session(3, shells: [30])))
    let updated = await model.apply(.sessionSnapshot(session(1, shells: [10], name: "Renamed")))
    XCTAssertTrue(inserted)
    XCTAssertTrue(updated)

    XCTAssertEqual(model.sessions.map(\.id), [1, 3])
    XCTAssertEqual(model.session(for: 1)?.name, "Renamed")
    XCTAssertEqual(client.listCount, 1)
  }

  func testRemovedSelectedSessionMovesSelection() async {
    let client = FakeAxodClient()
    client.sessions = [session(1, shells: [10]), session(2, shells: [20])]
    let model = makeModel(client)
    await model.refresh()
    model.showSession(2)

    let applied = await model.apply(.sessionRemoved(sessionID: 2))
    XCTAssertTrue(applied)

    XCTAssertEqual(model.sessions.map(\.id), [1])
    XCTAssertEqual(model.selectedSessionID, 1)
  }

  func testWorkspaceChangedRelistsOnlyWorkspaces() async {
    let client = FakeAxodClient()
    let model = makeModel(client)
    await model.refresh()
    client.workspaces = [WorkspaceRecord(workspaceId: "w", name: "Work", directoryPath: "/tmp")]

    let applied = await model.apply(.workspaceChanged(workspaceID: "w"))
    XCTAssertTrue(applied)

    XCTAssertEqual(model.workspaces.map(\.workspaceId), ["w"])
    XCTAssertEqual(client.listCount, 1)
  }

  func testLaggedEventRequestsResync() async {
    let model = makeModel(FakeAxodClient())
    let shouldContinue = await model.apply(.subscriptionLagged)
    XCTAssertFalse(shouldContinue)
  }

  func testSyncSubscribesBeforeListingAndResyncsAfterLag() async throws {
    let client = FakeAxodClient()
    client.sessions = [session(1, shells: [10])]
    let model = makeModel(client)
    let sync = TerminalCatalogSync(
      sessions: model, client: client, minimumBackoff: .milliseconds(1))
    sync.start()
    defer { sync.stop() }

    try await waitUntil { model.sessions.count == 1 }
    XCTAssertEqual(client.subscribeCount, 1)

    client.push(.sessionSnapshot(session(2, shells: [20])))
    try await waitUntil { model.sessions.count == 2 }
    XCTAssertEqual(client.listCount, 1, "events must not trigger full listings")

    client.sessions = [session(1, shells: [10]), session(2, shells: [20]), session(4, shells: [40])]
    client.push(.subscriptionLagged)
    try await waitUntil { model.sessions.count == 3 }
    XCTAssertEqual(client.subscribeCount, 2)
    XCTAssertEqual(client.listCount, 2)
    XCTAssertEqual(client.unsubscribed.map(\.subscriptionId), ["sub-1"])
  }

  func testSyncReportsConnectionLossAndAsksForHealthCheckOnce() async throws {
    let client = FakeAxodClient()
    client.subscribeError = SessionCommandError("axod is gone")
    let model = makeModel(client)
    var unreachableCalls = 0
    let sync = TerminalCatalogSync(
      sessions: model, client: client, minimumBackoff: .milliseconds(1),
      maximumBackoff: .milliseconds(2), onUnreachable: { unreachableCalls += 1 })
    sync.start()
    defer { sync.stop() }

    try await waitUntil { client.subscribeCount > TerminalCatalogSync.unreachableThreshold + 2 }
    XCTAssertEqual(model.catalogConnection, .reconnecting(reason: "axod is gone"))
    XCTAssertEqual(unreachableCalls, 1, "one health check per outage")

    client.subscribeError = nil
    try await waitUntil { model.catalogConnection == .live }
  }

  func testBatchedEventsApplyInOrder() async throws {
    let client = FakeAxodClient()
    let model = makeModel(client)
    let sync = TerminalCatalogSync(sessions: model, client: client)
    client.push(.sessionSnapshot(session(1, shells: [10], name: "old")))
    client.push(.sessionSnapshot(session(1, shells: [10], name: "new")))
    client.push(.sessionSnapshot(session(2, shells: [20])))
    sync.start()
    defer { sync.stop() }
    try await waitUntil { model.sessions.count == 2 }
    XCTAssertEqual(model.session(for: 1)?.name, "new")
  }

  func testIdleShellClosesWithoutConfirmation() async {
    let client = FakeAxodClient()
    client.sessions = [session(1, shells: [10, 11])]
    let model = makeModel(client)
    await model.refresh()
    await model.requestCloseShell(11)
    XCTAssertNil(model.pendingShellCloseConfirmation)
    XCTAssertEqual(client.closedShells, [11])
  }

  func testBusyShellAsksBeforeClosing() async {
    let client = FakeAxodClient()
    client.sessions = [session(1, shells: [10, 11])]
    client.shellBusyResult = .success(TerminalShellBusy(busy: true, foregroundProcess: "sleep"))
    let model = makeModel(client)
    await model.refresh()
    await model.requestCloseShell(11)
    let confirmation = ShellCloseConfirmation(shellID: 11, reason: .runningProcess("sleep"))
    XCTAssertEqual(model.pendingShellCloseConfirmation, confirmation)
    XCTAssertEqual(client.closedShells, [])

    model.cancelShellCloseConfirmation()
    await model.confirmShellClose(confirmation)
    XCTAssertEqual(client.closedShells, [], "a cancelled confirmation cannot close later")

    await model.requestCloseShell(11)
    await model.confirmShellClose(confirmation)
    XCTAssertEqual(client.closedShells, [11])
  }

  func testUnknownBusyStateAsksInsteadOfGuessing() async {
    let client = FakeAxodClient()
    client.sessions = [session(1, shells: [10, 11])]
    client.shellBusyResult = .failure(SessionCommandError("socket closed"))
    let model = makeModel(client)
    await model.refresh()
    await model.requestCloseShell(11)
    XCTAssertEqual(model.pendingShellCloseConfirmation?.reason, .unknown)
    XCTAssertEqual(client.closedShells, [])
  }

  func testRelayStatusEventsUpdateRemoteAccessWithoutPolling() async throws {
    let client = FakeAxodClient()
    let settings = FakeSettingsClient()
    let model = makeModel(client)
    let remoteAccess = RemoteAccessModel(client: settings)
    let sync = TerminalCatalogSync(sessions: model, remoteAccess: remoteAccess, client: client)
    sync.start()
    defer { sync.stop() }

    try await waitUntil { remoteAccess.status == .fixture(.disconnected) }
    XCTAssertEqual(settings.statusReads, 1, "one read when the catalog connects")

    client.push(.relayStatus(.fixture(.connected)))
    try await waitUntil { remoteAccess.status == .fixture(.connected) }
    XCTAssertEqual(settings.statusReads, 1, "pushed changes need no status reads")
    XCTAssertEqual(client.listCount, 1, "relay events never touch the Session catalog")

    remoteAccess.reset()
    XCTAssertNil(remoteAccess.status)
    XCTAssertEqual(remoteAccess.statusError, "axod is not running.")
  }

  func testRemoteAccessConnectRequestsAndRefreshes() async throws {
    let settings = FakeSettingsClient()
    let remoteAccess = RemoteAccessModel(client: settings)
    try await remoteAccess.connect()
    XCTAssertEqual(settings.connectRequests, 1)
    XCTAssertEqual(remoteAccess.status, .fixture(.connecting))
  }

  private func waitUntil(
    timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
      guard ContinuousClock.now < deadline else {
        XCTFail("condition not met before timeout")
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}
