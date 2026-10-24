import AxoDaemonManager
import AxoRPC
import Combine
import Foundation


struct WorkspaceArchiveConfirmation: Equatable, Identifiable {
  let workspaceID: String
  let workspaceName: String
  let sessionID: SessionID

  var id: String { workspaceID }
}

@MainActor
final class TerminalSessionsModel: ObservableObject {
  @Published private(set) var sessions: [TerminalSession] = []
  @Published private(set) var workspaces: [WorkspaceRecord] = []
  @Published var selectedSessionID: SessionID? {
    didSet {
      guard oldValue != selectedSessionID, let selectedSessionDefaults else { return }
      if let selectedSessionID, selectedSessionID > 0 {
        selectedSessionDefaults.set(selectedSessionID.rawValue, forKey: Self.selectedSessionPreferenceKey)
      } else {
        selectedSessionDefaults.removeObject(forKey: Self.selectedSessionPreferenceKey)
      }
    }
  }
  @Published private(set) var focusedShellID: ShellID?
  @Published private(set) var layout: TerminalLayout?
  @Published private(set) var errorMessage: String?
  @Published private(set) var workspaceCreationError: String?
  @Published private(set) var pendingWorkspaceArchiveConfirmation: WorkspaceArchiveConfirmation?
  @Published private(set) var pendingTerminalSplit: PendingTerminalSplit?
  @Published private(set) var automaticallyRestartUnavailablePi: Bool

  let helperURL: URL

  private static let selectedSessionPreferenceKey = AxoPreferenceKey.selectedSession
  private static let automaticPiRestartPreferenceKey = AxoPreferenceKey.automaticPiRestart

  private let client: AxodClient?
  private let clientError: String?

  /// The daemon client, for collaborators such as `TerminalCatalogSync`.
  var catalogClient: AxodClient? { client }
  private let selectedSessionDefaults: UserDefaults?
  private let preferenceDefaults: UserDefaults
  private var hasNegotiatedProtocol = false
  private var layoutsBySession: [SessionID: TerminalLayout] = [:]
  private var recentSessionIDs: [SessionID] = []
  private let layoutWriter: TerminalLayoutWriter
  private let piRestarter: AutomaticPiRestarter

  var sidebarOrderedSessions: [TerminalSession] {
    var sessionsByWorkspace: [String: [TerminalSession]] = [:]
    var standaloneSessions: [TerminalSession] = []
    for session in sessions {
      if let workspaceID = session.workspaceId {
        sessionsByWorkspace[workspaceID, default: []].append(session)
      } else {
        standaloneSessions.append(session)
      }
    }

    return workspaces.flatMap { sessionsByWorkspace[$0.workspaceId] ?? [] } + standaloneSessions
  }

  /// The production model: talks to the installed Axod socket and the bundled helper.
  convenience init() {
    let client: AxodClient?
    let clientError: String?
    do {
      client = UnixSocketAxodClient(socketPath: try DaemonController.socketPath())
      clientError = nil
    } catch {
      client = nil
      clientError = error.localizedDescription
    }
    self.init(
      client: client,
      clientError: clientError,
      helperURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/axod"),
      selectedSessionDefaults: .standard)
  }

  convenience init(
    socketPath: UnixSocketPath,
    helperURL: URL,
    selectedSessionDefaults: UserDefaults? = nil
  ) {
    self.init(
      client: UnixSocketAxodClient(socketPath: socketPath),
      helperURL: helperURL,
      selectedSessionDefaults: selectedSessionDefaults)
  }

  convenience init(
    client: AxodClient,
    helperURL: URL,
    selectedSessionDefaults: UserDefaults? = nil
  ) {
    self.init(
      client: client,
      clientError: nil,
      helperURL: helperURL,
      selectedSessionDefaults: selectedSessionDefaults)
  }

  /// `selectedSessionDefaults == nil` keeps selection in memory only (fixtures); other
  /// preferences then fall back to `.standard`.
  private init(
    client: AxodClient?,
    clientError: String?,
    helperURL: URL,
    selectedSessionDefaults: UserDefaults?
  ) {
    self.client = client
    self.clientError = clientError
    self.helperURL = helperURL
    self.selectedSessionDefaults = selectedSessionDefaults
    let preferenceDefaults = selectedSessionDefaults ?? .standard
    self.preferenceDefaults = preferenceDefaults
    let restartsAutomatically = preferenceDefaults.bool(
      forKey: Self.automaticPiRestartPreferenceKey)
    _selectedSessionID = Published(
      initialValue: Self.storedSelectedSessionID(from: selectedSessionDefaults))
    _automaticallyRestartUnavailablePi = Published(initialValue: restartsAutomatically)
    layoutWriter = TerminalLayoutWriter(client: client)
    piRestarter = AutomaticPiRestarter(isEnabled: restartsAutomatically)

    layoutWriter.isSessionOpen = { [weak self] in self?.session(for: $0) != nil }
    layoutWriter.onError = { [weak self] in self?.errorMessage = $0.localizedDescription }
    piRestarter.needsRestart = { [weak self] shellID in
      guard let shell = self?.sessions.lazy.flatMap(\.shells).first(where: { $0.id == shellID })
      else { return false }
      return shell.role == "pi" && !shell.isAvailable
    }
    piRestarter.restart = { [weak self] shellID in
      try await self?.restartPiSession(shellID, automatically: true)
    }
  }

  private static func storedSelectedSessionID(from defaults: UserDefaults?) -> SessionID? {
    guard let rawValue = defaults?.object(forKey: selectedSessionPreferenceKey) as? Int64,
      rawValue > 0
    else {
      return nil
    }
    return SessionID(rawValue: rawValue)
  }

  /// Full resynchronization: negotiate once, then replace the catalog with a fresh listing.
  /// Used at startup, after a lagged event stream and after commands whose result must be
  /// reconciled. Steady-state updates arrive through `apply(_:)`.
  func refresh() async {
    guard let client else {
      errorMessage = clientError ?? "Axo can’t locate axod’s socket."
      return
    }
    do {
      if !hasNegotiatedProtocol {
        let negotiation = try await client.negotiate()
        guard negotiation.protocolVersion == UnixSocketRPC.protocolVersion,
          Self.requiredMethods.isSubset(of: Set(negotiation.methods))
        else {
          throw UnixSocketRPCError.invalidResponse(
            "daemon does not support the required Axo protocol")
        }
        hasNegotiatedProtocol = true
      }
      async let snapshotTask = client.listSessionSnapshot()
      async let workspacesTask = client.listWorkspaces()
      let snapshot = try await snapshotTask
      let updatedWorkspaces = try await workspacesTask
      if workspaces != updatedWorkspaces { workspaces = updatedWorkspaces }
      applyCatalog(snapshot.sessions, focusing: snapshot.resumeSessionId)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  static let requiredMethods: Set<String> = [
    "axo.session.list", "axo.workspace.list", "axo.workspace.create",
    "axo.workspace.session.create", "axo.session.subscribe", "axo.session.events.next",
    "axo.session.unsubscribe",
  ]

  /// Applies one catalog event. Returns `false` when the stream lagged and the caller must
  /// resynchronize with `refresh()`.
  @discardableResult
  func apply(_ event: TerminalSessionEvent) async -> Bool {
    switch event {
    case .sessionSnapshot(let session):
      var updated = sessions
      if let index = updated.firstIndex(where: { $0.id == session.id }) {
        updated[index] = session
      } else {
        updated.append(session)
        updated.sort { $0.id < $1.id }
      }
      applyCatalog(updated, focusing: nil)
    case .sessionRemoved(let sessionID):
      guard sessions.contains(where: { $0.id == sessionID }) else { return true }
      applyCatalog(sessions.filter { $0.id != sessionID }, focusing: nil)
    case .workspaceChanged:
      guard let client else { return true }
      do {
        let updatedWorkspaces = try await client.listWorkspaces()
        if workspaces != updatedWorkspaces { workspaces = updatedWorkspaces }
      } catch {
        errorMessage = error.localizedDescription
      }
    case .sessionFocus(let sessionID):
      showSession(sessionID)
    case .subscriptionLagged:
      return false
    case .shellActivity, .terminalOutput, .unknown:
      // Session snapshots carry the state the catalog presents; terminal bytes go to Ghostty.
      break
    }
    return true
  }

  /// Replaces the catalog with daemon `daemonSessions`, normalizing layouts and repairing
  /// selection/focus. Pure with respect to I/O apart from scheduling layout persistence.
  private func applyCatalog(_ daemonSessions: [TerminalSession], focusing resumeSessionID: SessionID?) {
    let updatedSessions = daemonSessions
    let previouslySelectedSession = selectedSessionID.flatMap { session(for: $0) }
    let openSessionIDs = Set(updatedSessions.map(\.id))
    layoutsBySession = layoutsBySession.filter { openSessionIDs.contains($0.key) }
    layoutWriter.retain(sessionIDs: openSessionIDs)

    var normalizedSessions: [TerminalSession] = []
    for session in updatedSessions {
      let shellIDs = Set(session.shells.map(\.id))
      let serverLayout = session.layout.map(TerminalLayout.init)
      let sourceLayout = layoutsBySession[session.id] ?? serverLayout
      let normalizedLayout: TerminalLayout?
      let newlyCreatedShellIDs: Set<ShellID>
      if let sourceLayout, let pruned = sourceLayout.pruned(to: shellIDs) {
        newlyCreatedShellIDs = shellIDs.subtracting(pruned.shellIDs)
        normalizedLayout = pruned.adding(newlyCreatedShellIDs)
      } else {
        newlyCreatedShellIDs = []
        normalizedLayout = Self.defaultLayout(for: session.shells)
      }

      layoutsBySession[session.id] = normalizedLayout
      normalizedSessions.append(
        session.replacing(shells: session.shells, layout: normalizedLayout?.sessionLayout)
      )
      if let normalizedLayout, serverLayout != normalizedLayout {
        scheduleLayoutPersistence(for: session.id)
      }
      if selectedSessionID == session.id,
        let newestShellID = session.shells.filter(\.isAvailable).map(\.id)
          .filter(newlyCreatedShellIDs.contains).max()
      {
        focusedShellID = newestShellID
      } else if selectedSessionID == session.id,
        let previousFocus = focusedShellID,
        sourceLayout?.contains(shellID: previousFocus) == true,
        !shellIDs.contains(previousFocus)
      {
        focusedShellID = sourceLayout?.focusTargetAfterClosing(
          previousFocus,
          remainingShellIDs: shellIDs
        ) ?? normalizedLayout?.firstShellID
      }
    }
    if sessions != normalizedSessions {
      sessions = normalizedSessions
    }

    if let resumeSessionID, openSessionIDs.contains(resumeSessionID) {
      selectedSessionID = resumeSessionID
    }

    if let selectedSessionID, openSessionIDs.contains(selectedSessionID) {
      activate(selectedSessionID)
    } else if let previouslySelectedSession {
      selectedSessionID = sessionToSelect(afterClosing: previouslySelectedSession)
      recentSessionIDs.removeAll { $0 == previouslySelectedSession.id }
      if let selectedSessionID {
        activate(selectedSessionID)
      } else {
        layout = nil
        focusedShellID = nil
      }
    } else {
      selectedSessionID = sessions.first?.id
      if let selectedSessionID {
        activate(selectedSessionID)
      } else {
        layout = nil
        focusedShellID = nil
      }
    }
    piRestarter.schedule(for: sessions)
  }

  func setAutomaticPiRestartEnabled(_ enabled: Bool) {
    guard automaticallyRestartUnavailablePi != enabled else { return }
    automaticallyRestartUnavailablePi = enabled
    preferenceDefaults.set(enabled, forKey: Self.automaticPiRestartPreferenceKey)

    piRestarter.isEnabled = enabled
    piRestarter.schedule(for: sessions)
  }

  func createWorkspace(name: String, directoryPath: String, directoryBookmark: String?) async {
    workspaceCreationError = nil
    guard let client else {
      let message = clientError ?? "Axo can’t locate axod’s socket."
      errorMessage = message
      workspaceCreationError = message
      return
    }
    do {
      let created = try await client.createWorkspace(
        name: name, directoryPath: directoryPath, directoryBookmark: directoryBookmark)
      guard created.session.workspaceId == created.workspace.workspaceId else {
        throw UnixSocketRPCError.invalidResponse(
          "Workspace creation did not return its first Session.")
      }
      if !workspaces.contains(where: { $0.id == created.workspace.id }) {
        workspaces.append(created.workspace)
        workspaces.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      }
      add(created.session)
      selectedSessionID = created.session.id
      activate(created.session.id)
      errorMessage = nil
      workspaceCreationError = nil
    } catch {
      errorMessage = error.localizedDescription
      workspaceCreationError = error.localizedDescription
    }
  }

  func dismissWorkspaceCreationError() {
    workspaceCreationError = nil
  }

  func createSession(in workspaceID: String) async {
    guard let client else {
      errorMessage = clientError ?? "Axo can’t locate axod’s socket."
      return
    }
    do {
      let session = try await client.createSession(inWorkspace: workspaceID)
      add(session)
      selectedSessionID = session.id
      activate(session.id)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func createSessionInCurrentContext() async {
    if let selectedSessionID,
      let workspaceID = session(for: selectedSessionID)?.workspaceId
    {
      await createSession(in: workspaceID)
    } else {
      await createSession()
    }
  }

  func createSession() async {
    guard let client else {
      errorMessage = clientError ?? "Axo can’t locate axod’s socket."
      return
    }

    do {
      let session = try await client.createSession()
      add(session)
      selectedSessionID = session.id
      activate(session.id)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func split(_ direction: TerminalSplitDirection) async {
    guard pendingTerminalSplit == nil else { return }
    guard let client else {
      errorMessage = clientError ?? "Axo can’t locate axod’s socket."
      return
    }
    guard let sessionID = selectedSessionID,
      let session = self.session(for: sessionID),
      let anchorShellID = focusedShellID ?? layoutsBySession[sessionID]?.firstShellID
    else {
      errorMessage = "Select a session before splitting the terminal."
      return
    }

    let pending = PendingTerminalSplit(
      id: UUID(),
      sessionID: sessionID,
      sessionUuid: session.sessionUuid,
      anchorShellID: anchorShellID,
      direction: direction,
      ratio: 0.5,
      status: .creating
    )
    pendingTerminalSplit = pending
    errorMessage = nil

    do {
      let shell = try await client.createShell(inSession: sessionID)
      guard pendingTerminalSplit?.id == pending.id,
        let currentSession = self.session(for: sessionID),
        currentSession.sessionUuid == pending.sessionUuid
      else {
        pendingTerminalSplit = nil
        await refresh()
        return
      }

      let currentLayout = layoutsBySession[sessionID]
        ?? currentSession.layout.map(TerminalLayout.init)
        ?? Self.defaultLayout(for: currentSession.shells)
      let updatedLayout = currentLayout?.placing(
        shellID: shell.id,
        direction: direction,
        beside: anchorShellID,
        ratio: pending.ratio
      ) ?? .pane(shell.id)
      let updatedShells = currentSession.shells.contains(where: { $0.id == shell.id })
        ? currentSession.shells
        : currentSession.shells + [shell]

      replace(currentSession, withShells: updatedShells)
      // Clear the optimistic leaf in the same main-actor turn as installing the real one.
      pendingTerminalSplit = nil
      setLayout(updatedLayout, for: sessionID, persist: true)
      if selectedSessionID == sessionID {
        layout = updatedLayout
        focusedShellID = shell.id
      }
      errorMessage = nil
    } catch {
      guard pendingTerminalSplit?.id == pending.id else { return }
      if let rpcError = error as? UnixSocketRPCError, case .serverRejected = rpcError {
        pendingTerminalSplit?.status = .rejected(error.localizedDescription)
        errorMessage = error.localizedDescription
        return
      }

      // A lost response may follow a committed create. Reconcile by reading the catalog; never
      // retry this non-idempotent operation automatically.
      await refresh()
      guard pendingTerminalSplit?.id == pending.id else { return }
      pendingTerminalSplit?.status = .outcomeUnknown(error.localizedDescription)
      errorMessage = "Axo couldn't confirm pane creation. Check the session before trying again."
    }
  }

  func resizePendingTerminalSplit(_ id: UUID, to ratio: Double) {
    guard var pending = pendingTerminalSplit, pending.id == id,
      case .creating = pending.status
    else { return }
    pending.ratio = min(max(ratio, 0.01), 0.99)
    pendingTerminalSplit = pending
  }

  func dismissPendingTerminalSplit(_ id: UUID) {
    guard pendingTerminalSplit?.id == id else { return }
    pendingTerminalSplit = nil
  }

  func closeSession(_ sessionID: SessionID) async {
    do {
      try await archiveSession(sessionID)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func requestCloseSession(_ sessionID: SessionID) async {
    guard let closingSession = session(for: sessionID) else { return }
    errorMessage = nil

    if let workspaceID = closingSession.workspaceId,
      sessions.filter({ $0.workspaceId == workspaceID }).count == 1
    {
      guard let workspace = workspaces.first(where: { $0.workspaceId == workspaceID }) else {
        errorMessage = "The Workspace is unavailable, so the last Session was not closed."
        return
      }
      pendingWorkspaceArchiveConfirmation = WorkspaceArchiveConfirmation(
        workspaceID: workspaceID,
        workspaceName: workspace.name,
        sessionID: sessionID
      )
      return
    }

    await closeSession(sessionID)
  }

  func cancelWorkspaceArchiveConfirmation() {
    pendingWorkspaceArchiveConfirmation = nil
  }

  func confirmWorkspaceArchiveAndCloseSession(
    _ confirmation: WorkspaceArchiveConfirmation
  ) async {
    if pendingWorkspaceArchiveConfirmation == confirmation {
      pendingWorkspaceArchiveConfirmation = nil
    }

    let workspaceSessionIDs = sessions
      .filter { $0.workspaceId == confirmation.workspaceID }
      .map(\.id)
    guard workspaceSessionIDs == [confirmation.sessionID],
      workspaces.contains(where: { $0.workspaceId == confirmation.workspaceID })
    else {
      errorMessage = "The Workspace changed before it could be archived. Please review it again."
      return
    }

    do {
      try await archiveWorkspace(confirmation.workspaceID)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func archiveSession(_ sessionID: SessionID) async throws {
    guard let client else {
      throw UnixSocketRPCError.invalidResponse(
        clientError ?? "Axo can’t locate axod’s socket.")
    }
    let closingSession = session(for: sessionID)
    let closed = try await client.closeSession(sessionID)
    layoutsBySession.removeValue(forKey: sessionID)
    layoutWriter.discard(sessionID: sessionID)
    sessions.removeAll { $0.id == sessionID }
    if let replacement = closed.replacement {
      add(replacement)
    }
    if selectedSessionID == sessionID {
      selectedSessionID = closingSession.map {
        sessionToSelect(afterClosing: $0, replacement: closed.replacement)
      } ?? sessions.first?.id
      recentSessionIDs.removeAll { $0 == sessionID }
    }
    if let selectedSessionID {
      activate(selectedSessionID)
    } else {
      layout = nil
      focusedShellID = nil
    }
    await refresh()
  }

  func renameSession(_ sessionID: SessionID, to name: String) async throws {
    guard let client else {
      throw UnixSocketRPCError.invalidResponse(
        clientError ?? "Axo can’t locate axod’s socket.")
    }
    try await requireMethod("axo.session.rename", using: client)
    let renamed = try await client.renameSession(sessionID, to: name)
    guard renamed.id == sessionID, renamed.manualName == name else {
      throw UnixSocketRPCError.invalidResponse("axod did not apply the Session name.")
    }
    await refresh()
  }

  func renameWorkspace(_ workspaceID: String, to name: String) async throws {
    guard let client else {
      throw UnixSocketRPCError.invalidResponse(
        clientError ?? "Axo can’t locate axod’s socket.")
    }
    try await requireMethod("axo.workspace.rename", using: client)
    let renamed = try await client.renameWorkspace(workspaceID, to: name)
    guard renamed.workspaceId == workspaceID, renamed.name == name else {
      throw UnixSocketRPCError.invalidResponse("axod did not apply the Workspace name.")
    }
    await refresh()
  }

  func archiveWorkspace(_ workspaceID: String) async throws {
    guard let client else {
      throw UnixSocketRPCError.invalidResponse(
        clientError ?? "Axo can’t locate axod’s socket.")
    }
    try await requireMethod("axo.workspace.archive", using: client)
    let archived = try await client.archiveWorkspace(workspaceID)
    guard archived.archivedWorkspaceId == workspaceID else {
      throw UnixSocketRPCError.invalidResponse("axod archived a different Workspace.")
    }

    let archivedSessionIDs = Set(archived.archivedSessionIds)
    for sessionID in archivedSessionIDs {
      layoutsBySession.removeValue(forKey: sessionID)
      layoutWriter.discard(sessionID: sessionID)
    }
    sessions.removeAll { archivedSessionIDs.contains($0.id) }
    workspaces.removeAll { $0.workspaceId == workspaceID }
    if let selectedID = selectedSessionID, archivedSessionIDs.contains(selectedID) {
      selectedSessionID = sessions.first(where: { $0.workspaceId == nil })?.id ?? sessions.first?.id
    }
    if let selectedSessionID {
      activate(selectedSessionID)
    } else {
      layout = nil
      focusedShellID = nil
    }
    await refresh()
  }

  private func requireMethod(_ method: String, using client: AxodClient) async throws {
    let negotiation = try await client.negotiate()
    guard negotiation.protocolVersion == UnixSocketRPC.protocolVersion,
      negotiation.methods.contains(method)
    else {
      throw UnixSocketRPCError.invalidResponse(
        "This action requires a newer Axod. Your Sessions and Workspace are unchanged.")
    }
  }

  func restartPiSession(_ shellID: ShellID) async throws {
    piRestarter.cancel(shellID: shellID)
    try await restartPiSession(shellID, automatically: false)
  }

  private func restartPiSession(_ shellID: ShellID, automatically: Bool) async throws {
    guard let client else {
      throw UnixSocketRPCError.invalidResponse(
        clientError ?? "Axo can’t locate axod’s socket.")
    }
    guard let targetSession = sessions.first(where: { session in
      session.shells.contains(where: { $0.id == shellID })
    }),
      let shell = targetSession.shells.first(where: { $0.id == shellID }),
      shell.role == "pi",
      !shell.isAvailable,
      automatically || selectedSessionID == targetSession.id
    else {
      throw UnixSocketRPCError.invalidResponse("This Pi pane is no longer available to restart.")
    }

    let restartMethod = automatically
      ? "axo.session.pi.restart.auto.v1"
      : "axo.session.pi.restart.force.v2"
    let negotiation = try await client.negotiate()
    guard negotiation.protocolVersion == UnixSocketRPC.protocolVersion,
      negotiation.methods.contains(restartMethod)
    else {
      if automatically { throw AutomaticPiRestarter.Failure.unsupportedAxod }
      throw UnixSocketRPCError.invalidResponse(
        "Pi recovery is not yet supported by the running Axod. Your session history is preserved.")
    }

    let restarted = try await client.restartPi(
      shellID: shellID, inSession: targetSession.id, automatically: automatically)
    guard restarted.id == targetSession.id,
      restarted.shells.contains(where: { $0.id == shellID && $0.isAvailable })
    else {
      throw UnixSocketRPCError.invalidResponse("axod did not restore the requested Pi pane.")
    }
    await refresh()
  }


  func closeFocusedShell() async {
    guard let focusedShellID else { return }
    await closeShell(focusedShellID)
  }

  func closeShell(_ shellID: ShellID) async {
    guard let client,
      let session = sessions.first(where: { $0.shells.contains(where: { $0.id == shellID }) })
    else {
      errorMessage = clientError ?? "The focused shell is no longer open."
      return
    }
    let sessionID = session.id
    let layoutBeforeClose =
      layoutsBySession[sessionID] ?? session.layout.map(TerminalLayout.init)
      ?? Self.defaultLayout(for: session.shells)
    let remainingShellIDs = Set(session.shells.lazy.map(\.id).filter { $0 != shellID })
    let focusAfterClose: ShellID? = {
      guard selectedSessionID == sessionID else { return nil }
      guard let focusedShellID else { return layoutBeforeClose?.firstShellID }
      if focusedShellID == shellID {
        return layoutBeforeClose?.focusTargetAfterClosing(
          shellID,
          remainingShellIDs: remainingShellIDs
        )
      }
      return remainingShellIDs.contains(focusedShellID) ? focusedShellID : nil
    }()

    do {
      let closed = try await client.closeShell(shellID, inSession: sessionID)
      if closed.archivedSessionId != nil {
        layoutsBySession.removeValue(forKey: sessionID)
        layoutWriter.discard(sessionID: sessionID)
        sessions.removeAll { $0.id == sessionID }
        if let replacement = closed.replacement {
          add(replacement)
        }
        if selectedSessionID == sessionID {
          selectedSessionID = sessionToSelect(afterClosing: session, replacement: closed.replacement)
          recentSessionIDs.removeAll { $0 == sessionID }
          if let selectedSessionID {
            activate(selectedSessionID)
          } else {
            layout = nil
            focusedShellID = nil
          }
        }
      } else {
        guard let currentSession = self.session(for: sessionID) else { return }
        let remainingShells = currentSession.shells.filter { $0.id != shellID }
        let remainingShellIDs = Set(remainingShells.map(\.id))
        replace(currentSession, withShells: remainingShells)

        let baseLayout = layoutsBySession[sessionID] ?? layoutBeforeClose
        let updatedLayout = baseLayout?.removing(shellID: shellID)
        if let updatedLayout {
          setLayout(updatedLayout, for: sessionID, persist: true)
        }
        if selectedSessionID == sessionID {
          layout = updatedLayout
          let currentFocus = focusedShellID.flatMap {
            remainingShellIDs.contains($0) ? $0 : nil
          }
          let preferredFocus = focusAfterClose.flatMap {
            remainingShellIDs.contains($0) ? $0 : nil
          }
          focusedShellID = currentFocus ?? preferredFocus ?? updatedLayout?.firstShellID
        }
      }
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func showSession(_ sessionID: SessionID) {
    guard sessions.contains(where: { $0.id == sessionID }) else { return }
    selectedSessionID = sessionID
    activate(sessionID)
    errorMessage = nil
  }

  func focusPreviousPane() {
    focusAdjacentPane(.previous)
  }

  func focusNextPane() {
    focusAdjacentPane(.next)
  }

  func showPreviousSession() {
    showAdjacentSession(.previous)
  }

  func showNextSession() {
    showAdjacentSession(.next)
  }

  func resizeSplit(_ splitID: UUID, to ratio: Double) {
    guard let selectedSessionID,
      let currentLayout = layoutsBySession[selectedSessionID],
      ratio.isFinite,
      let updated = currentLayout.resizing(
        splitID: splitID,
        to: min(max(ratio, 0.01), 0.99)
      )
    else {
      return
    }
    setLayout(updated, for: selectedSessionID, persist: true)
    layout = updated
  }

  func focus(_ shellID: ShellID) {
    guard let session = sessions.first(where: {
      $0.shells.contains(where: { $0.id == shellID && $0.isAvailable })
    }) else {
      return
    }
    selectedSessionID = session.id
    layout = layoutsBySession[session.id]
    focusedShellID = shellID
    rememberSessionFocus(session.id)
  }

  func session(for sessionID: SessionID) -> TerminalSession? {
    sessions.first(where: { $0.id == sessionID })
  }

  func shell(for shellID: ShellID) -> TerminalShell? {
    guard let selectedSessionID else { return nil }
    return session(for: selectedSessionID)?.shells.first(where: { $0.id == shellID })
  }

  private func focusAdjacentPane(_ direction: TerminalNavigationDirection) {
    guard let layout else { return }
    let paneIDs = layout.orderedShellIDs.filter { shell(for: $0)?.isAvailable == true }
    let currentIndex = focusedShellID.flatMap { focusedID in
      paneIDs.firstIndex(of: focusedID)
    }
    guard
      let targetIndex = Self.adjacentIndex(
        from: currentIndex,
        count: paneIDs.count,
        direction: direction
      )
    else {
      return
    }
    focus(paneIDs[targetIndex])
  }

  private func showAdjacentSession(_ direction: TerminalNavigationDirection) {
    let orderedSessions = sidebarOrderedSessions
    let currentIndex = selectedSessionID.flatMap { selectedID in
      orderedSessions.firstIndex { $0.id == selectedID }
    }
    guard
      let targetIndex = Self.adjacentIndex(
        from: currentIndex,
        count: orderedSessions.count,
        direction: direction
      )
    else {
      return
    }
    showSession(orderedSessions[targetIndex].id)
  }

  private static func adjacentIndex(
    from currentIndex: Int?,
    count: Int,
    direction: TerminalNavigationDirection
  ) -> Int? {
    guard count > 0 else { return nil }
    let startingIndex = currentIndex ?? (direction == .next ? count - 1 : 0)
    return (startingIndex + direction.rawValue + count) % count
  }

  private func sessionToSelect(
    afterClosing closedSession: TerminalSession,
    replacement: TerminalSession? = nil
  ) -> SessionID? {
    for recentID in recentSessionIDs where recentID != closedSession.id {
      guard let candidate = session(for: recentID),
        candidate.workspaceId == closedSession.workspaceId
      else {
        continue
      }
      return candidate.id
    }

    if let replacement,
      replacement.workspaceId == closedSession.workspaceId,
      session(for: replacement.id) != nil
    {
      return replacement.id
    }
    return sessions.first(where: { $0.workspaceId == closedSession.workspaceId })?.id
      ?? sessions.first?.id
  }

  private func rememberSessionFocus(_ sessionID: SessionID) {
    recentSessionIDs.removeAll { $0 == sessionID }
    recentSessionIDs.insert(sessionID, at: 0)
    if recentSessionIDs.count > 128 {
      recentSessionIDs.removeLast(recentSessionIDs.count - 128)
    }
  }

  private func activate(_ sessionID: SessionID) {
    guard let session = session(for: sessionID) else {
      layout = nil
      focusedShellID = nil
      return
    }
    rememberSessionFocus(sessionID)
    let currentLayout = layoutsBySession[sessionID] ?? Self.defaultLayout(for: session.shells)
    if layoutsBySession[sessionID] == nil {
      setLayout(currentLayout, for: sessionID, persist: true)
    }
    layout = currentLayout
    guard let currentLayout else {
      focusedShellID = nil
      return
    }
    if let focusedShellID,
      currentLayout.contains(shellID: focusedShellID),
      session.shells.contains(where: { $0.id == focusedShellID && $0.isAvailable })
    {
      return
    }
    focusedShellID = session.shells.filter(\.isAvailable).map(\.id).max()
  }

  private func add(_ session: TerminalSession) {
    sessions.removeAll { $0.id == session.id }
    let layout = session.layout.map(TerminalLayout.init) ?? Self.defaultLayout(for: session.shells)
    sessions.append(
      session.replacing(shells: session.shells, layout: layout?.sessionLayout)
    )
    sessions.sort { $0.id < $1.id }
    setLayout(layout, for: session.id, persist: session.layout == nil)
  }

  private func replace(_ session: TerminalSession, withShells shells: [TerminalShell]) {
    let layout = layoutsBySession[session.id]?.sessionLayout ?? session.layout
    let updated = session.replacing(shells: shells, layout: layout)
    guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
    sessions[index] = updated
  }

  private func setLayout(_ layout: TerminalLayout?, for sessionID: SessionID, persist: Bool) {
    layoutsBySession[sessionID] = layout
    if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
      let session = sessions[index]
      if session.layout.map(TerminalLayout.init) != layout {
        sessions[index] = session.replacing(shells: session.shells, layout: layout?.sessionLayout)
      }
    }
    if persist, layout != nil {
      scheduleLayoutPersistence(for: sessionID)
    }
  }

  private func scheduleLayoutPersistence(for sessionID: SessionID) {
    guard let layout = layoutsBySession[sessionID] else { return }
    layoutWriter.schedule(layout.sessionLayout, for: sessionID)
  }


  private static func defaultLayout(for shells: [TerminalShell]) -> TerminalLayout? {
    guard let first = shells.first else { return nil }
    return shells.dropFirst().reduce(TerminalLayout.pane(first.id)) { layout, shell in
      .split(
        id: UUID(),
        direction: .right,
        ratio: 0.5,
        first: layout,
        second: .pane(shell.id)
      )
    }
  }
}
