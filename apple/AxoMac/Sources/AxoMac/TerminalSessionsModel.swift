import AxoDaemonManager
import AxoRPC
import Combine
import Foundation

private enum AutomaticPiRestartError: Error {
  case unsupportedAxod
}

struct WorkspaceArchiveConfirmation: Equatable, Identifiable {
  let workspaceID: String
  let workspaceName: String
  let sessionID: Int64

  var id: String { workspaceID }
}

@MainActor
final class TerminalSessionsModel: ObservableObject {
  @Published private(set) var sessions: [TerminalSession] = []
  @Published private(set) var workspaces: [WorkspaceRecord] = []
  @Published var selectedSessionID: Int64? {
    didSet {
      guard oldValue != selectedSessionID, let selectedSessionDefaults else { return }
      if let selectedSessionID, selectedSessionID > 0 {
        selectedSessionDefaults.set(selectedSessionID, forKey: Self.selectedSessionPreferenceKey)
      } else {
        selectedSessionDefaults.removeObject(forKey: Self.selectedSessionPreferenceKey)
      }
    }
  }
  @Published private(set) var focusedShellID: Int64?
  @Published private(set) var layout: TerminalLayout?
  @Published private(set) var errorMessage: String?
  @Published private(set) var workspaceCreationError: String?
  @Published private(set) var pendingWorkspaceArchiveConfirmation: WorkspaceArchiveConfirmation?
  @Published private(set) var automaticallyRestartUnavailablePi: Bool

  let helperURL: URL

  private static let selectedSessionPreferenceKey = "terminalSelectedSession.v1"
  private static let automaticPiRestartPreferenceKey = "agent.autoRestartUnavailablePi.v1"

  private let socketPath: UnixSocketPath?
  private let socketPathError: String?
  private let selectedSessionDefaults: UserDefaults?
  private let preferenceDefaults: UserDefaults
  private var negotiatedSocketPath: UnixSocketPath?
  private var layoutsBySession: [Int64: TerminalLayout] = [:]
  private var recentSessionIDs: [Int64] = []
  private var pendingLayoutWrites: [Int64: SessionLayout] = [:]
  private var layoutWriteTasks: [Int64: Task<Void, Never>] = [:]
  private var automaticPiRestartTasks: [Int64: Task<Void, Never>] = [:]
  private var automaticPiRestartTaskIDs: [Int64: UUID] = [:]

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

  init() {
    let defaults = UserDefaults.standard
    selectedSessionDefaults = defaults
    preferenceDefaults = defaults
    _selectedSessionID = Published(initialValue: Self.storedSelectedSessionID(from: defaults))
    _automaticallyRestartUnavailablePi = Published(
      initialValue: defaults.bool(forKey: Self.automaticPiRestartPreferenceKey)
    )
    helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/axod")
    do {
      socketPath = try DaemonController.socketPath()
      socketPathError = nil
    } catch {
      socketPath = nil
      socketPathError = error.localizedDescription
    }
  }

  init(
    socketPath: UnixSocketPath,
    helperURL: URL,
    selectedSessionDefaults: UserDefaults? = nil
  ) {
    self.socketPath = socketPath
    socketPathError = nil
    self.helperURL = helperURL
    self.selectedSessionDefaults = selectedSessionDefaults
    let preferenceDefaults = selectedSessionDefaults ?? .standard
    self.preferenceDefaults = preferenceDefaults
    _selectedSessionID = Published(
      initialValue: Self.storedSelectedSessionID(from: selectedSessionDefaults)
    )
    _automaticallyRestartUnavailablePi = Published(
      initialValue: preferenceDefaults.bool(forKey: Self.automaticPiRestartPreferenceKey)
    )
  }

  private static func storedSelectedSessionID(from defaults: UserDefaults?) -> Int64? {
    guard let sessionID = defaults?.object(forKey: selectedSessionPreferenceKey) as? Int64,
      sessionID > 0
    else {
      return nil
    }
    return sessionID
  }

  func refresh() async {
    guard let socketPath else {
      errorMessage = socketPathError ?? "The axod socket path is unavailable."
      return
    }

    let previouslySelectedSession = selectedSessionID.flatMap { session(for: $0) }
    do {
      if negotiatedSocketPath != socketPath {
        let negotiation = try await UnixSocketRPC.negotiate(at: socketPath)
        let requiredMethods: Set<String> = [
          "axo.session.list", "axo.workspace.list", "axo.workspace.create",
          "axo.workspace.session.create", "axo.session.subscribe", "axo.session.events.next",
          "axo.session.unsubscribe", "axo.terminal.input", "axo.terminal.resize",
        ]
        guard negotiation.protocolVersion == UnixSocketRPC.protocolVersion,
          requiredMethods.isSubset(of: Set(negotiation.methods))
        else {
          throw UnixSocketRPCError.invalidResponse(
            "daemon does not support the required Axo protocol")
        }
        negotiatedSocketPath = socketPath
      }
      async let updatedSessionsTask = UnixSocketRPC.listSessions(at: socketPath)
      async let updatedWorkspacesTask = UnixSocketRPC.listWorkspaces(at: socketPath)
      let updatedSessions = try await updatedSessionsTask
      let updatedWorkspaces = try await updatedWorkspacesTask
      workspaces = updatedWorkspaces
      let openSessionIDs = Set(updatedSessions.map(\.id))
      layoutsBySession = layoutsBySession.filter { openSessionIDs.contains($0.key) }
      pendingLayoutWrites = pendingLayoutWrites.filter { openSessionIDs.contains($0.key) }
      for sessionID in Array(layoutWriteTasks.keys) where !openSessionIDs.contains(sessionID) {
        layoutWriteTasks.removeValue(forKey: sessionID)?.cancel()
      }

      var normalizedSessions: [TerminalSession] = []
      for session in updatedSessions {
        let shellIDs = Set(session.shells.map(\.id))
        let serverLayout = session.layout.map(TerminalLayout.init)
        let sourceLayout = layoutsBySession[session.id] ?? serverLayout
        let normalizedLayout: TerminalLayout?
        let newlyCreatedShellIDs: Set<Int64>
        if let sourceLayout, let pruned = sourceLayout.pruned(to: shellIDs) {
          newlyCreatedShellIDs = shellIDs.subtracting(pruned.shellIDs)
          normalizedLayout = pruned.adding(newlyCreatedShellIDs)
        } else {
          newlyCreatedShellIDs = []
          normalizedLayout = Self.defaultLayout(for: session.shells)
        }

        layoutsBySession[session.id] = normalizedLayout
        normalizedSessions.append(
          TerminalSession(
            id: session.id,
            initialPwd: session.initialPwd,
            shells: session.shells,
            layout: normalizedLayout?.sessionLayout,
            sessionUuid: session.sessionUuid,
            piSessionFile: session.piSessionFile,
            piSessionId: session.piSessionId,
            workspaceId: session.workspaceId,
            workspaceName: session.workspaceName,
            name: session.name,
            manualName: session.manualName,
            emoji: session.emoji,
            status: session.status
          )
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
      errorMessage = nil
      scheduleAutomaticPiRestarts()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func setAutomaticPiRestartEnabled(_ enabled: Bool) {
    guard automaticallyRestartUnavailablePi != enabled else { return }
    automaticallyRestartUnavailablePi = enabled
    preferenceDefaults.set(enabled, forKey: Self.automaticPiRestartPreferenceKey)

    if enabled {
      scheduleAutomaticPiRestarts()
    } else {
      for task in automaticPiRestartTasks.values { task.cancel() }
      automaticPiRestartTasks.removeAll()
      automaticPiRestartTaskIDs.removeAll()
    }
  }

  func createWorkspace(name: String, directoryPath: String, directoryBookmark: String?) async {
    workspaceCreationError = nil
    guard let socketPath else {
      let message = socketPathError ?? "The axod socket path is unavailable."
      errorMessage = message
      workspaceCreationError = message
      return
    }
    do {
      let created = try await UnixSocketRPC.createWorkspace(
        name: name,
        directoryPath: directoryPath,
        directoryBookmark: directoryBookmark,
        at: socketPath
      )
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
    guard let socketPath else {
      errorMessage = socketPathError ?? "The axod socket path is unavailable."
      return
    }
    do {
      let session = try await UnixSocketRPC.createSession(in: workspaceID, at: socketPath)
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
    guard let socketPath else {
      errorMessage = socketPathError ?? "The axod socket path is unavailable."
      return
    }

    do {
      let session = try await UnixSocketRPC.createSession(at: socketPath)
      add(session)
      selectedSessionID = session.id
      activate(session.id)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func split(_ direction: TerminalSplitDirection) async {
    guard let socketPath else {
      errorMessage = socketPathError ?? "The axod socket path is unavailable."
      return
    }
    guard let sessionID = selectedSessionID,
      let session = self.session(for: sessionID),
      let anchorShellID = focusedShellID ?? layoutsBySession[sessionID]?.firstShellID
    else {
      errorMessage = "Select a session before splitting the terminal."
      return
    }

    do {
      let shell = try await UnixSocketRPC.createShell(in: sessionID, at: socketPath)
      replace(session, withShells: session.shells + [shell])
      if let currentLayout = layoutsBySession[sessionID] ?? Self.defaultLayout(for: session.shells),
        !currentLayout.contains(shellID: shell.id)
      {
        layoutBySession(
          sessionID, inserting: shell.id, direction: direction, beside: anchorShellID,
          fallback: currentLayout)
      }
      if selectedSessionID == sessionID {
        layout = layoutsBySession[sessionID]
        focusedShellID = shell.id
      }
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func closeSession(_ sessionID: Int64) async {
    do {
      try await archiveSession(sessionID)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func requestCloseSession(_ sessionID: Int64) async {
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

  func archiveSession(_ sessionID: Int64) async throws {
    guard let socketPath else {
      throw UnixSocketRPCError.invalidResponse(
        socketPathError ?? "The axod socket path is unavailable.")
    }
    let closingSession = session(for: sessionID)
    let closed = try await UnixSocketRPC.closeSession(sessionID, at: socketPath)
    layoutsBySession.removeValue(forKey: sessionID)
    discardPendingLayoutWrite(for: sessionID)
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

  func renameSession(_ sessionID: Int64, to name: String) async throws {
    guard let socketPath else {
      throw UnixSocketRPCError.invalidResponse(
        socketPathError ?? "The axod socket path is unavailable.")
    }
    try await requireMethod("axo.session.rename", at: socketPath)
    let renamed = try await UnixSocketRPC.renameSession(sessionID, to: name, at: socketPath)
    guard renamed.id == sessionID, renamed.manualName == name else {
      throw UnixSocketRPCError.invalidResponse("axod did not apply the Session name.")
    }
    await refresh()
  }

  func renameWorkspace(_ workspaceID: String, to name: String) async throws {
    guard let socketPath else {
      throw UnixSocketRPCError.invalidResponse(
        socketPathError ?? "The axod socket path is unavailable.")
    }
    try await requireMethod("axo.workspace.rename", at: socketPath)
    let renamed = try await UnixSocketRPC.renameWorkspace(workspaceID, to: name, at: socketPath)
    guard renamed.workspaceId == workspaceID, renamed.name == name else {
      throw UnixSocketRPCError.invalidResponse("axod did not apply the Workspace name.")
    }
    await refresh()
  }

  func archiveWorkspace(_ workspaceID: String) async throws {
    guard let socketPath else {
      throw UnixSocketRPCError.invalidResponse(
        socketPathError ?? "The axod socket path is unavailable.")
    }
    try await requireMethod("axo.workspace.archive", at: socketPath)
    let archived = try await UnixSocketRPC.archiveWorkspace(workspaceID, at: socketPath)
    guard archived.archivedWorkspaceId == workspaceID else {
      throw UnixSocketRPCError.invalidResponse("axod archived a different Workspace.")
    }

    let archivedSessionIDs = Set(archived.archivedSessionIds)
    for sessionID in archivedSessionIDs {
      layoutsBySession.removeValue(forKey: sessionID)
      discardPendingLayoutWrite(for: sessionID)
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

  private func requireMethod(_ method: String, at socketPath: UnixSocketPath) async throws {
    let negotiation = try await UnixSocketRPC.negotiate(at: socketPath)
    guard negotiation.protocolVersion == UnixSocketRPC.protocolVersion,
      negotiation.methods.contains(method)
    else {
      throw UnixSocketRPCError.invalidResponse(
        "This action requires a newer Axod. Your Sessions and Workspace are unchanged.")
    }
  }

  func restartPiSession(_ shellID: Int64) async throws {
    automaticPiRestartTasks[shellID]?.cancel()
    automaticPiRestartTasks.removeValue(forKey: shellID)
    automaticPiRestartTaskIDs.removeValue(forKey: shellID)
    try await restartPiSession(shellID, automatically: false)
  }

  private func restartPiSession(_ shellID: Int64, automatically: Bool) async throws {
    guard let socketPath else {
      throw UnixSocketRPCError.invalidResponse(
        socketPathError ?? "The axod socket path is unavailable.")
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
    let negotiation = try await UnixSocketRPC.negotiate(at: socketPath)
    guard negotiation.protocolVersion == UnixSocketRPC.protocolVersion,
      negotiation.methods.contains(restartMethod)
    else {
      if automatically { throw AutomaticPiRestartError.unsupportedAxod }
      throw UnixSocketRPCError.invalidResponse(
        "Pi recovery is not yet supported by the running Axod. Your session history is preserved.")
    }

    let restarted: TerminalSession
    if automatically {
      restarted = try await UnixSocketRPC.automaticallyRestartPiSession(
        shellID: shellID,
        in: targetSession.id,
        at: socketPath
      )
    } else {
      restarted = try await UnixSocketRPC.restartPiSession(
        shellID: shellID,
        in: targetSession.id,
        at: socketPath
      )
    }
    guard restarted.id == targetSession.id,
      restarted.shells.contains(where: { $0.id == shellID && $0.isAvailable })
    else {
      throw UnixSocketRPCError.invalidResponse("axod did not restore the requested Pi pane.")
    }
    await refresh()
  }

  private func scheduleAutomaticPiRestarts() {
    guard automaticallyRestartUnavailablePi else { return }
    for shell in sessions.flatMap(\.shells)
    where shell.role == "pi" && !shell.isAvailable && automaticPiRestartTasks[shell.id] == nil {
      let taskID = UUID()
      automaticPiRestartTaskIDs[shell.id] = taskID
      automaticPiRestartTasks[shell.id] = Task { [weak self] in
        await self?.retryAutomaticPiRestart(shellID: shell.id, taskID: taskID)
      }
    }
  }

  private func retryAutomaticPiRestart(shellID: Int64, taskID: UUID) async {
    defer {
      if automaticPiRestartTaskIDs[shellID] == taskID {
        automaticPiRestartTaskIDs.removeValue(forKey: shellID)
        automaticPiRestartTasks.removeValue(forKey: shellID)
      }
    }

    var delaySeconds = 1
    while !Task.isCancelled && automaticallyRestartUnavailablePi {
      guard let shell = shell(for: shellID), shell.role == "pi", !shell.isAvailable else {
        return
      }

      do {
        try await restartPiSession(shellID, automatically: true)
        return
      } catch AutomaticPiRestartError.unsupportedAxod {
        try? await Task.sleep(for: .seconds(30))
      } catch {
        try? await Task.sleep(for: .seconds(delaySeconds))
        delaySeconds = min(delaySeconds * 2, 30)
      }
    }
  }

  func closeFocusedShell() async {
    guard let focusedShellID else { return }
    await closeShell(focusedShellID)
  }

  func closeShell(_ shellID: Int64) async {
    guard let socketPath,
      let session = sessions.first(where: { $0.shells.contains(where: { $0.id == shellID }) })
    else {
      errorMessage = socketPathError ?? "The focused shell is no longer open."
      return
    }
    let sessionID = session.id
    let layoutBeforeClose =
      layoutsBySession[sessionID] ?? session.layout.map(TerminalLayout.init)
      ?? Self.defaultLayout(for: session.shells)
    let remainingShellIDs = Set(session.shells.lazy.map(\.id).filter { $0 != shellID })
    let focusAfterClose: Int64? = {
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
      let closed = try await UnixSocketRPC.closeShell(shellID, in: sessionID, at: socketPath)
      if closed.archivedSessionId != nil {
        layoutsBySession.removeValue(forKey: sessionID)
        discardPendingLayoutWrite(for: sessionID)
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

  func showSession(_ sessionID: Int64) {
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

  func focus(_ shellID: Int64) {
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

  func session(for sessionID: Int64) -> TerminalSession? {
    sessions.first(where: { $0.id == sessionID })
  }

  func shell(for shellID: Int64) -> TerminalShell? {
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
  ) -> Int64? {
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

  private func rememberSessionFocus(_ sessionID: Int64) {
    recentSessionIDs.removeAll { $0 == sessionID }
    recentSessionIDs.insert(sessionID, at: 0)
    if recentSessionIDs.count > 128 {
      recentSessionIDs.removeLast(recentSessionIDs.count - 128)
    }
  }

  private func activate(_ sessionID: Int64) {
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
      TerminalSession(
        id: session.id,
        initialPwd: session.initialPwd,
        shells: session.shells,
        layout: layout?.sessionLayout,
        sessionUuid: session.sessionUuid,
        piSessionFile: session.piSessionFile,
        piSessionId: session.piSessionId,
        workspaceId: session.workspaceId,
        workspaceName: session.workspaceName,
        name: session.name,
        manualName: session.manualName,
        emoji: session.emoji,
        status: session.status
      )
    )
    sessions.sort { $0.id < $1.id }
    setLayout(layout, for: session.id, persist: session.layout == nil)
  }

  private func replace(_ session: TerminalSession, withShells shells: [TerminalShell]) {
    let layout = layoutsBySession[session.id]?.sessionLayout ?? session.layout
    let updated = TerminalSession(
      id: session.id,
      initialPwd: session.initialPwd,
      shells: shells,
      layout: layout,
      sessionUuid: session.sessionUuid,
      piSessionFile: session.piSessionFile,
      piSessionId: session.piSessionId,
      workspaceId: session.workspaceId,
      workspaceName: session.workspaceName,
      name: session.name,
      manualName: session.manualName,
      emoji: session.emoji,
      status: session.status
    )
    guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
    sessions[index] = updated
  }

  private func setLayout(_ layout: TerminalLayout?, for sessionID: Int64, persist: Bool) {
    layoutsBySession[sessionID] = layout
    if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
      let session = sessions[index]
      if session.layout.map(TerminalLayout.init) != layout {
        sessions[index] = TerminalSession(
          id: session.id,
          initialPwd: session.initialPwd,
          shells: session.shells,
          layout: layout?.sessionLayout,
          sessionUuid: session.sessionUuid,
          piSessionFile: session.piSessionFile,
          piSessionId: session.piSessionId,
          workspaceId: session.workspaceId,
          workspaceName: session.workspaceName,
          name: session.name,
          manualName: session.manualName,
          emoji: session.emoji,
          status: session.status
        )
      }
    }
    if persist, layout != nil {
      scheduleLayoutPersistence(for: sessionID)
    }
  }

  private func scheduleLayoutPersistence(for sessionID: Int64) {
    guard let socketPath, let layout = layoutsBySession[sessionID] else { return }
    pendingLayoutWrites[sessionID] = layout.sessionLayout
    guard layoutWriteTasks[sessionID] == nil else { return }

    layoutWriteTasks[sessionID] = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .milliseconds(150))
        } catch {
          break
        }
        guard let pendingLayout = pendingLayoutWrites.removeValue(forKey: sessionID) else {
          break
        }
        do {
          try await UnixSocketRPC.setLayout(
            pendingLayout,
            for: sessionID,
            at: socketPath
          )
        } catch {
          if !Task.isCancelled, session(for: sessionID) != nil {
            pendingLayoutWrites[sessionID] = pendingLayoutWrites[sessionID] ?? pendingLayout
            errorMessage = error.localizedDescription
          }
          break
        }
      }
      layoutWriteTasks[sessionID] = nil
    }
  }

  private func discardPendingLayoutWrite(for sessionID: Int64) {
    pendingLayoutWrites.removeValue(forKey: sessionID)
    layoutWriteTasks.removeValue(forKey: sessionID)?.cancel()
  }

  private func layoutBySession(
    _ sessionID: Int64,
    inserting shellID: Int64,
    direction: TerminalSplitDirection,
    beside anchorShellID: Int64,
    fallback: TerminalLayout?
  ) {
    if let currentLayout = fallback,
      let updated = currentLayout.inserting(
        shellID: shellID,
        direction: direction,
        beside: anchorShellID
      )
    {
      setLayout(updated, for: sessionID, persist: true)
    } else {
      setLayout(
        .split(
          id: UUID(),
          direction: direction,
          ratio: 0.5,
          first: .pane(anchorShellID),
          second: .pane(shellID)
        ),
        for: sessionID,
        persist: true
      )
    }
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

enum TerminalSplitDirection: Hashable {
  case right
  case down
}

enum TerminalNavigationDirection: Int, Equatable {
  case previous = -1
  case next = 1
}

indirect enum TerminalLayout: Equatable, Identifiable {
  case pane(Int64)
  case split(
    id: UUID,
    direction: TerminalSplitDirection,
    ratio: Double,
    first: TerminalLayout,
    second: TerminalLayout
  )

  var id: String {
    switch self {
    case .pane(let shellID): "shell-\(shellID)"
    case .split(let id, _, _, _, _): "split-\(id.uuidString)"
    }
  }

  var shellIDs: Set<Int64> {
    switch self {
    case .pane(let shellID): [shellID]
    case .split(_, _, _, let first, let second): first.shellIDs.union(second.shellIDs)
    }
  }

  var orderedShellIDs: [Int64] {
    switch self {
    case .pane(let shellID): [shellID]
    case .split(_, _, _, let first, let second):
      first.orderedShellIDs + second.orderedShellIDs
    }
  }

  func adding(_ shellIDs: Set<Int64>) -> TerminalLayout {
    shellIDs.sorted().reduce(self) { layout, shellID in
      guard !layout.contains(shellID: shellID) else { return layout }
      return .split(
        id: UUID(),
        direction: .right,
        ratio: 0.5,
        first: layout,
        second: .pane(shellID)
      )
    }
  }

  var firstShellID: Int64? {
    switch self {
    case .pane(let shellID): shellID
    case .split(_, _, _, let first, _): first.firstShellID
    }
  }

  func contains(shellID: Int64) -> Bool {
    switch self {
    case .pane(let currentID): currentID == shellID
    case .split(_, _, _, let first, let second):
      first.contains(shellID: shellID) || second.contains(shellID: shellID)
    }
  }

  func inserting(
    shellID newShellID: Int64,
    direction: TerminalSplitDirection,
    beside targetShellID: Int64
  ) -> TerminalLayout? {
    switch self {
    case .pane(let currentID) where currentID == targetShellID:
      return .split(
        id: UUID(),
        direction: direction,
        ratio: 0.5,
        first: self,
        second: .pane(newShellID)
      )
    case .pane:
      return nil
    case .split(let id, let existingDirection, let ratio, let first, let second):
      if let updatedFirst = first.inserting(
        shellID: newShellID,
        direction: direction,
        beside: targetShellID
      ) {
        return .split(
          id: id, direction: existingDirection, ratio: ratio, first: updatedFirst, second: second
        )
      }
      if let updatedSecond = second.inserting(
        shellID: newShellID,
        direction: direction,
        beside: targetShellID
      ) {
        return .split(
          id: id, direction: existingDirection, ratio: ratio, first: first, second: updatedSecond
        )
      }
      return nil
    }
  }

  func focusTargetAfterClosing(
    _ shellID: Int64,
    remainingShellIDs: Set<Int64>
  ) -> Int64? {
    let orderedIDs = orderedShellIDs
    guard let index = orderedIDs.firstIndex(of: shellID) else { return nil }

    let candidates: [Int64]
    if index == 0 {
      candidates = Array(orderedIDs.dropFirst())
    } else {
      candidates = Array(orderedIDs[..<index].reversed())
        + Array(orderedIDs.dropFirst(index + 1))
    }
    return candidates.first(where: remainingShellIDs.contains)
  }

  func removing(shellID: Int64) -> TerminalLayout? {
    switch self {
    case .pane(let currentID):
      return currentID == shellID ? nil : self
    case .split(let id, let direction, let ratio, let first, let second):
      let remainingFirst = first.removing(shellID: shellID)
      let remainingSecond = second.removing(shellID: shellID)
      switch (remainingFirst, remainingSecond) {
      case (nil, nil):
        return nil
      case (let remaining?, nil):
        return remaining
      case (nil, let remaining?):
        return remaining
      case (let remainingFirst?, let remainingSecond?):
        return .split(
          id: id,
          direction: direction,
          ratio: ratio,
          first: remainingFirst,
          second: remainingSecond
        )
      }
    }
  }

  func pruned(to openShellIDs: Set<Int64>) -> TerminalLayout? {
    switch self {
    case .pane(let shellID):
      return openShellIDs.contains(shellID) ? self : nil
    case .split(let id, let direction, let ratio, let first, let second):
      let remainingFirst = first.pruned(to: openShellIDs)
      let remainingSecond = second.pruned(to: openShellIDs)
      switch (remainingFirst, remainingSecond) {
      case (nil, nil):
        return nil
      case (let remaining?, nil):
        return remaining
      case (nil, let remaining?):
        return remaining
      case (let remainingFirst?, let remainingSecond?):
        return .split(
          id: id,
          direction: direction,
          ratio: ratio,
          first: remainingFirst,
          second: remainingSecond
        )
      }
    }
  }

  // Ratios are excluded so divider drags don't replace terminal pane views.
  var structuralIdentity: StructuralIdentity {
    StructuralIdentity(self)
  }

  func resizing(splitID: UUID, to newRatio: Double) -> TerminalLayout? {
    switch self {
    case .pane:
      return nil
    case .split(let id, let direction, let ratio, let first, let second):
      if id == splitID {
        return .split(
          id: id, direction: direction, ratio: newRatio, first: first, second: second
        )
      }
      if let updatedFirst = first.resizing(splitID: splitID, to: newRatio) {
        return .split(
          id: id, direction: direction, ratio: ratio, first: updatedFirst, second: second
        )
      }
      if let updatedSecond = second.resizing(splitID: splitID, to: newRatio) {
        return .split(
          id: id, direction: direction, ratio: ratio, first: first, second: updatedSecond
        )
      }
      return nil
    }
  }

  struct StructuralIdentity: Hashable {
    private let representation: Representation

    init(_ layout: TerminalLayout) {
      switch layout {
      case .pane(let shellID):
        representation = .pane(shellID)
      case .split(_, let direction, _, let first, let second):
        representation = .split(direction, first.structuralIdentity, second.structuralIdentity)
      }
    }

    private indirect enum Representation: Hashable {
      case pane(Int64)
      case split(TerminalSplitDirection, StructuralIdentity, StructuralIdentity)
    }
  }
}
