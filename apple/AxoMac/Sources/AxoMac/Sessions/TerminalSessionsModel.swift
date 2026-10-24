import AxoDaemonManager
import AxoRPC
import Foundation
import Observation

/// A Session command that failed for an app-level reason (no daemon, unsupported Axod, or an
/// unexpected result), worded for the user.
struct SessionCommandError: LocalizedError, Equatable {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

/// Health of the catalog event stream, shown so a lost daemon never looks like a live one.
enum CatalogConnection: Equatable {
  case connecting
  case live
  /// The stream failed and is retrying; `reason` is the latest failure, worded for the user.
  case reconnecting(reason: String)
}

/// A pane close the user must confirm because it would interrupt running work.
struct ShellCloseConfirmation: Equatable, Identifiable {
  enum Reason: Equatable {
    /// A foreground job other than the shell, named when Axod could tell.
    case runningProcess(String?)
    case piWorking
    /// Axod could not say whether the shell is idle.
    case unknown
  }

  let shellID: ShellID
  let reason: Reason

  var id: ShellID { shellID }
}

struct WorkspaceArchiveConfirmation: Equatable, Identifiable {
  let workspaceID: String
  let workspaceName: String
  let sessionID: SessionID

  var id: String { workspaceID }
}

/// The app's view of Axod's Session catalog plus local presentation state (selection, focus,
/// pane layouts). Axod remains authoritative for Sessions and shells: commands apply the record
/// Axod returns (relisting only when the outcome is ambiguous), and `TerminalCatalogSync` streams
/// every other change in via `apply(_:)`.
///
/// Observed properties are assigned only when their value changes: Observation notifies on every
/// write, even an equal one.
@MainActor
@Observable
final class TerminalSessionsModel {
  private(set) var sessions: [TerminalSession] = []
  private(set) var workspaces: [WorkspaceRecord] = []
  var selectedSessionID: SessionID? {
    didSet {
      guard oldValue != selectedSessionID, let selectedSessionDefaults else { return }
      if let selectedSessionID {
        selectedSessionDefaults.set(selectedSessionID.rawValue, forKey: AxoPreferenceKey.selectedSession)
      } else {
        selectedSessionDefaults.removeObject(forKey: AxoPreferenceKey.selectedSession)
      }
    }
  }
  private(set) var focusedShellID: ShellID?
  private(set) var layout: TerminalLayout?
  private(set) var errorMessage: String?
  private(set) var catalogConnection = CatalogConnection.connecting
  private(set) var workspaceCreationError: String?
  private(set) var pendingWorkspaceArchiveConfirmation: WorkspaceArchiveConfirmation?
  private(set) var pendingShellCloseConfirmation: ShellCloseConfirmation?
  private(set) var pendingTerminalSplit: PendingTerminalSplit?
  private(set) var automaticallyRestartUnavailablePi: Bool

  /// Methods every supported Axod must offer; checked once per connection.
  static let requiredMethods: Set<String> = [
    "axo.session.list", "axo.workspace.list", "axo.workspace.create",
    "axo.workspace.session.create", "axo.session.subscribe", "axo.session.events.next",
    "axo.session.unsubscribe",
  ]

  /// The daemon client, for collaborators such as `TerminalCatalogSync`.
  var catalogClient: AxodClient? { client }
  /// The same daemon connection, for Settings (nil for in-memory test clients).
  var settingsClient: AxodSettingsClient? { client as? AxodSettingsClient }

  private let client: AxodClient?
  private let clientError: String?
  private let selectedSessionDefaults: UserDefaults?
  private let preferenceDefaults: UserDefaults
  private let layoutWriter: TerminalLayoutWriter
  private let piRestarter: AutomaticPiRestarter
  private let viewportReporter: ViewportReporter
  /// Methods offered by the connected Axod; `nil` until negotiated on this connection.
  @ObservationIgnored private var daemonMethods: Set<String>?
  @ObservationIgnored private var layoutsBySession: [SessionID: TerminalLayout] = [:]
  @ObservationIgnored private var recentSessions = RecentSessions()

  // MARK: - Initialization

  /// The production model: talks to the installed Axod socket.
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
      selectedSessionDefaults: .standard)
  }

  convenience init(
    socketPath: UnixSocketPath,
    selectedSessionDefaults: UserDefaults? = nil
  ) {
    self.init(
      client: UnixSocketAxodClient(socketPath: socketPath),
      selectedSessionDefaults: selectedSessionDefaults)
  }

  convenience init(
    client: AxodClient,
    selectedSessionDefaults: UserDefaults? = nil
  ) {
    self.init(
      client: client,
      clientError: nil,
      selectedSessionDefaults: selectedSessionDefaults)
  }

  /// `selectedSessionDefaults == nil` keeps selection in memory only (fixtures); other
  /// preferences then fall back to `.standard`.
  private init(
    client: AxodClient?,
    clientError: String?,
    selectedSessionDefaults: UserDefaults?
  ) {
    self.client = client
    self.clientError = clientError
    self.selectedSessionDefaults = selectedSessionDefaults
    let preferenceDefaults = selectedSessionDefaults ?? .standard
    self.preferenceDefaults = preferenceDefaults
    let restartsAutomatically = preferenceDefaults.bool(forKey: AxoPreferenceKey.automaticPiRestart)
    selectedSessionID = Self.storedSelectedSessionID(from: selectedSessionDefaults)
    automaticallyRestartUnavailablePi = restartsAutomatically
    layoutWriter = TerminalLayoutWriter(client: client)
    piRestarter = AutomaticPiRestarter(isEnabled: restartsAutomatically)
    viewportReporter = ViewportReporter(client: client)

    layoutWriter.isSessionOpen = { [weak self] in self?.session(for: $0) != nil }
    layoutWriter.onError = { [weak self] in self?.errorMessage = $0.localizedDescription }
    piRestarter.needsRestart = { [weak self] shellID in
      guard let shell = self?.sessions.lazy.flatMap(\.shells).first(where: { $0.id == shellID })
      else { return false }
      return shell.role == "pi" && !shell.isAvailable
    }
    viewportReporter.isSupported = { [weak self] in
      guard let self, let client = self.client else { return false }
      return try await self.supports(UnixSocketRPC.viewportMethod, using: client)
    }
    piRestarter.restart = { [weak self] shellID in
      try await self?.restartPiSession(shellID, automatically: true)
    }
  }

  private static func storedSelectedSessionID(from defaults: UserDefaults?) -> SessionID? {
    guard let rawValue = defaults?.object(forKey: AxoPreferenceKey.selectedSession) as? Int64,
      rawValue > 0
    else { return nil }
    return SessionID(rawValue: rawValue)
  }

  // MARK: - Queries

  var sidebarOrderedSessions: [TerminalSession] {
    SessionNavigation.sidebarOrder(sessions, workspaces: workspaces)
  }

  func session(for sessionID: SessionID) -> TerminalSession? {
    sessions.first(where: { $0.id == sessionID })
  }

  /// A shell of the selected Session.
  func shell(for shellID: ShellID) -> TerminalShell? {
    guard let selectedSessionID else { return nil }
    return session(for: selectedSessionID)?.shells.first(where: { $0.id == shellID })
  }

  // MARK: - Synchronization

  /// Re-reads the whole catalog. Used after commands whose outcome must be reconciled; the
  /// connection-level resync is `resynchronize()`.
  func refresh() async {
    do {
      try await reloadCatalog()
    } catch {
      report(error)
    }
  }

  /// Renegotiates (Axod may have been upgraded or restarted) and re-reads the catalog. Called by
  /// `TerminalCatalogSync` whenever it (re)subscribes; failures go back to it for retry.
  func resynchronize() async throws {
    daemonMethods = nil
    try await reloadCatalog()
    viewportReporter.reconnected()
  }

  /// Where this window draws terminals; Axod sizes panes no surface shows from the latest one.
  func reportViewport(_ viewport: ClientViewport) {
    viewportReporter.report(viewport)
  }

  func setCatalogConnection(_ connection: CatalogConnection) {
    assign(\.catalogConnection, connection)
  }

  private func reloadCatalog() async throws {
    let client = try requireClient()
    try await negotiateIfNeeded(using: client)
    async let snapshotTask = client.listSessionSnapshot()
    async let workspacesTask = client.listWorkspaces()
    let snapshot = try await snapshotTask
    assign(\.workspaces, try await workspacesTask)
    applyCatalog(snapshot.sessions, focusing: snapshot.resumeSessionId)
    assign(\.errorMessage, nil)
  }

  /// Applies one catalog event. Returns `false` when the stream lagged and the caller must
  /// resubscribe and resynchronize.
  @discardableResult
  func apply(_ event: TerminalSessionEvent) async -> Bool {
    switch event {
    case .sessionSnapshot(let session):
      upsert(session)
    case .sessionRemoved(let sessionID):
      guard session(for: sessionID) != nil else { return true }
      applyCatalog(sessions.filter { $0.id != sessionID }, focusing: nil)
    case .workspaceChanged:
      guard let client else { return true }
      do {
        assign(\.workspaces, try await client.listWorkspaces())
      } catch {
        report(error)
      }
    case .sessionFocus(let sessionID):
      showSession(sessionID)
    case .subscriptionLagged:
      return false
    case .shellActivity, .terminalOutput, .relayStatus, .unknown:
      // Session snapshots carry the state the catalog presents; terminal bytes go to Ghostty.
      break
    }
    return true
  }

  /// Inserts or replaces one Session from an authoritative Axod record.
  private func upsert(_ session: TerminalSession) {
    var updated = sessions
    if let index = updated.firstIndex(where: { $0.id == session.id }) {
      updated[index] = session
    } else {
      updated.append(session)
      updated.sort { $0.id < $1.id }
    }
    applyCatalog(updated, focusing: nil)
  }

  /// Replaces the catalog with Axod's `daemonSessions`, normalizing layouts (keeping local edits,
  /// dropping closed panes, appending new ones) and repairing selection and focus.
  private func applyCatalog(_ daemonSessions: [TerminalSession], focusing resumeSessionID: SessionID?) {
    let previouslySelectedSession = selectedSessionID.flatMap(session(for:))
    let openSessionIDs = Set(daemonSessions.map(\.id))
    layoutsBySession = layoutsBySession.filter { openSessionIDs.contains($0.key) }
    layoutWriter.retain(sessionIDs: openSessionIDs)

    var normalizedSessions: [TerminalSession] = []
    for session in daemonSessions {
      let shellIDs = Set(session.shells.map(\.id))
      let serverLayout = session.layout.map(TerminalLayout.init)
      let sourceLayout = layoutsBySession[session.id] ?? serverLayout
      let normalizedLayout: TerminalLayout?
      let newShellIDs: Set<ShellID>
      if let sourceLayout, let pruned = sourceLayout.pruned(to: shellIDs) {
        newShellIDs = shellIDs.subtracting(pruned.shellIDs)
        normalizedLayout = pruned.adding(newShellIDs)
      } else {
        newShellIDs = []
        normalizedLayout = TerminalLayout.defaultLayout(for: session.shells.map(\.id))
      }

      layoutsBySession[session.id] = normalizedLayout
      normalizedSessions.append(
        session.replacing(shells: session.shells, layout: normalizedLayout?.sessionLayout))
      if let normalizedLayout, serverLayout != normalizedLayout {
        layoutWriter.schedule(normalizedLayout.sessionLayout, for: session.id)
      }

      guard selectedSessionID == session.id else { continue }
      if let newestShellID = session.shells.map(\.id).filter(newShellIDs.contains).max()
      {
        assign(\.focusedShellID, newestShellID)
      } else if let previousFocus = focusedShellID,
        sourceLayout?.contains(shellID: previousFocus) == true,
        !shellIDs.contains(previousFocus)
      {
        assign(
          \.focusedShellID,
          sourceLayout?.focusTargetAfterClosing(previousFocus, remainingShellIDs: shellIDs)
            ?? normalizedLayout?.firstShellID)
      }
    }
    assign(\.sessions, normalizedSessions)

    if let resumeSessionID, openSessionIDs.contains(resumeSessionID) {
      select(resumeSessionID)
    } else if let selectedSessionID, openSessionIDs.contains(selectedSessionID) {
      activate(selectedSessionID)
    } else if let previouslySelectedSession {
      recentSessions.forget(previouslySelectedSession.id)
      select(
        SessionNavigation.successor(
          afterClosing: previouslySelectedSession, in: sessions, recent: recentSessions))
    } else {
      select(sessions.first?.id)
    }
    piRestarter.schedule(for: sessions)
  }

  // MARK: - Preferences

  func setAutomaticPiRestartEnabled(_ enabled: Bool) {
    guard automaticallyRestartUnavailablePi != enabled else { return }
    automaticallyRestartUnavailablePi = enabled
    preferenceDefaults.set(enabled, forKey: AxoPreferenceKey.automaticPiRestart)
    piRestarter.isEnabled = enabled
    piRestarter.schedule(for: sessions)
  }

  // MARK: - Sessions and Workspaces

  func createWorkspace(name: String, directoryPath: String, directoryBookmark: String?) async {
    workspaceCreationError = nil
    do {
      let created = try await requireClient().createWorkspace(
        name: name, directoryPath: directoryPath, directoryBookmark: directoryBookmark)
      guard created.session.workspaceId == created.workspace.workspaceId else {
        throw SessionCommandError(
          "Workspace creation did not return its first Session.")
      }
      if !workspaces.contains(where: { $0.id == created.workspace.id }) {
        workspaces = (workspaces + [created.workspace]).sorted {
          $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
      }
      adopt(created.session)
    } catch {
      report(error)
      workspaceCreationError = error.localizedDescription
    }
  }

  func dismissWorkspaceCreationError() {
    workspaceCreationError = nil
  }

  func createSession(in workspaceID: String) async {
    do {
      adopt(try await requireClient().createSession(inWorkspace: workspaceID))
    } catch {
      report(error)
    }
  }

  func createSession() async {
    let start = ContinuousClock.now
    do {
      let session = try await requireClient().createSession()
      AxoTrace.commands.notice(
        "event=session.create_returned session_id=\(session.id.rawValue) elapsed_ms=\(AxoTrace.elapsed(since: start), privacy: .public)")
      adopt(session)
    } catch {
      report(error)
    }
  }

  func createSessionInCurrentContext() async {
    if let workspaceID = selectedSessionID.flatMap(session(for:))?.workspaceId {
      await createSession(in: workspaceID)
    } else {
      await createSession()
    }
  }

  func closeSession(_ sessionID: SessionID) async {
    do {
      try await archiveSession(sessionID)
    } catch {
      report(error)
    }
  }

  /// Closes a Session, first asking for confirmation when it is the last one in its Workspace
  /// (closing it archives the Workspace).
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
        workspaceID: workspaceID, workspaceName: workspace.name, sessionID: sessionID)
      return
    }

    await closeSession(sessionID)
  }

  func cancelWorkspaceArchiveConfirmation() {
    pendingWorkspaceArchiveConfirmation = nil
  }

  func confirmWorkspaceArchiveAndCloseSession(_ confirmation: WorkspaceArchiveConfirmation) async {
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
      report(error)
    }
  }

  func archiveSession(_ sessionID: SessionID) async throws {
    let closingSession = session(for: sessionID)
    let closed = try await requireClient().closeSession(sessionID)
    removeSessions([sessionID], closing: closingSession, replacement: closed.replacement)
  }

  func renameSession(_ sessionID: SessionID, to name: String) async throws {
    let client = try requireClient()
    try await requireMethod("axo.session.rename", using: client)
    let renamed = try await client.renameSession(sessionID, to: name)
    guard renamed.id == sessionID, renamed.manualName == name else {
      throw SessionCommandError("axod did not apply the Session name.")
    }
    upsert(renamed)
  }

  func renameWorkspace(_ workspaceID: String, to name: String) async throws {
    let client = try requireClient()
    try await requireMethod("axo.workspace.rename", using: client)
    let renamed = try await client.renameWorkspace(workspaceID, to: name)
    guard renamed.workspaceId == workspaceID, renamed.name == name else {
      throw SessionCommandError("axod did not apply the Workspace name.")
    }
    if let index = workspaces.firstIndex(where: { $0.workspaceId == workspaceID }) {
      workspaces[index] = renamed
    }
  }

  func archiveWorkspace(_ workspaceID: String) async throws {
    let client = try requireClient()
    try await requireMethod("axo.workspace.archive", using: client)
    let archived = try await client.archiveWorkspace(workspaceID)
    guard archived.archivedWorkspaceId == workspaceID else {
      throw SessionCommandError("axod archived a different Workspace.")
    }
    workspaces.removeAll { $0.workspaceId == workspaceID }
    // With the Workspace gone, prefer a standalone Session over another Workspace's.
    removeSessions(
      Set(archived.archivedSessionIds), closing: nil, replacement: nil,
      fallback: { $0.first(where: { $0.workspaceId == nil })?.id ?? $0.first?.id })
  }

  // MARK: - Panes

  /// Adds a pane beside the focused one. The new pane is shown optimistically
  /// (`pendingTerminalSplit`) until Axod confirms it; an unconfirmed outcome is reconciled from
  /// the catalog and never retried, because shell creation is not idempotent.
  func split(_ direction: TerminalSplitDirection) async {
    guard pendingTerminalSplit == nil else { return }
    let client: AxodClient
    do { client = try requireClient() } catch { return report(error) }
    guard let sessionID = selectedSessionID,
      session(for: sessionID) != nil,
      let anchorShellID = focusedShellID ?? layoutsBySession[sessionID]?.firstShellID
    else {
      errorMessage = "Select a session before splitting the terminal."
      return
    }

    let pending = PendingTerminalSplit(
      id: UUID(),
      sessionID: sessionID,
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
        let currentSession = self.session(for: sessionID)
      else {
        pendingTerminalSplit = nil
        await refresh()
        return
      }

      let updatedLayout = currentLayout(of: currentSession)?.placing(
        shellID: shell.id, direction: direction, beside: anchorShellID, ratio: pending.ratio
      ) ?? .pane(shell.id)
      if !currentSession.shells.contains(where: { $0.id == shell.id }) {
        replace(currentSession, withShells: currentSession.shells + [shell])
      }
      // Clear the optimistic leaf in the same main-actor turn as installing the real one.
      pendingTerminalSplit = nil
      setLayout(updatedLayout, for: sessionID, persist: true)
      if selectedSessionID == sessionID {
        assign(\.layout, updatedLayout)
        assign(\.focusedShellID, shell.id)
      }
      errorMessage = nil
    } catch {
      guard pendingTerminalSplit?.id == pending.id else { return }
      if let rpcError = error as? UnixSocketRPCError, case .serverRejected = rpcError {
        pendingTerminalSplit?.status = .rejected(error.localizedDescription)
        errorMessage = error.localizedDescription
        return
      }
      // A lost response may follow a committed create. Reconcile by reading the catalog.
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

  func resizeSplit(_ splitID: UUID, to ratio: Double) {
    guard let selectedSessionID,
      let currentLayout = layoutsBySession[selectedSessionID],
      ratio.isFinite,
      let updated = currentLayout.resizing(splitID: splitID, to: min(max(ratio, 0.01), 0.99))
    else { return }
    setLayout(updated, for: selectedSessionID, persist: true)
    assign(\.layout, updated)
  }

  /// User-initiated close (⌘W): closes an idle shell at once, but asks first when it is running
  /// a foreground job or a Pi turn. When Axod cannot tell, it asks rather than guess.
  func requestCloseShell(_ shellID: ShellID) async {
    let start = ContinuousClock.now
    AxoTrace.commands.notice("event=shell.close_requested shell_id=\(shellID.rawValue)")
    guard let client,
      let session = sessions.first(where: { $0.shells.contains(where: { $0.id == shellID }) }),
      let shell = session.shells.first(where: { $0.id == shellID })
    else {
      errorMessage = clientError ?? "The focused shell is no longer open."
      return
    }
    // An unavailable Pi pane has no live process to interrupt.
    if shell.role == "pi", !shell.isAvailable {
      await closeShell(shellID)
      AxoTrace.commands.notice(
        "event=shell.close_done shell_id=\(shellID.rawValue) path=unavailable elapsed_ms=\(AxoTrace.elapsed(since: start), privacy: .public)")
      return
    }
    let busy: TerminalShellBusy?
    do {
      busy = try await supports("axo.shell.busy", using: client)
        ? try await client.shellBusy(shellID, inSession: session.id)
        : nil
    } catch {
      busy = nil
    }
    AxoTrace.commands.notice(
      "event=shell.close_busy_checked shell_id=\(shellID.rawValue) busy=\(busy?.busy.description ?? "unknown", privacy: .public) elapsed_ms=\(AxoTrace.elapsed(since: start), privacy: .public)")
    let reason: ShellCloseConfirmation.Reason? =
      switch (busy, shell.role) {
      case (nil, _): .unknown
      case (let busy?, _) where !busy.busy: nil
      case (_, "pi"): .piWorking
      case (let busy?, _): .runningProcess(busy.foregroundProcess)
      }
    guard let reason else {
      await closeShell(shellID)
      AxoTrace.commands.notice(
        "event=shell.close_done shell_id=\(shellID.rawValue) elapsed_ms=\(AxoTrace.elapsed(since: start), privacy: .public)")
      return
    }
    pendingShellCloseConfirmation = ShellCloseConfirmation(shellID: shellID, reason: reason)
  }

  func cancelShellCloseConfirmation() {
    pendingShellCloseConfirmation = nil
  }

  func confirmShellClose(_ confirmation: ShellCloseConfirmation) async {
    guard pendingShellCloseConfirmation == confirmation else { return }
    pendingShellCloseConfirmation = nil
    await closeShell(confirmation.shellID)
  }

  /// Closes one pane. Closing a Session's last pane archives the Session (Axod may return a
  /// replacement); otherwise focus moves to the pane the layout places next to the closed one.
  func closeShell(_ shellID: ShellID) async {
    guard let client,
      let session = sessions.first(where: { $0.shells.contains(where: { $0.id == shellID }) })
    else {
      errorMessage = clientError ?? "The focused shell is no longer open."
      return
    }
    let sessionID = session.id
    let layoutBeforeClose = currentLayout(of: session)
    let remainingShellIDs = Set(session.shells.lazy.map(\.id).filter { $0 != shellID })
    let focusAfterClose: ShellID? = {
      guard selectedSessionID == sessionID else { return nil }
      guard let focusedShellID else { return layoutBeforeClose?.firstShellID }
      if focusedShellID == shellID {
        return layoutBeforeClose?.focusTargetAfterClosing(
          shellID, remainingShellIDs: remainingShellIDs)
      }
      return remainingShellIDs.contains(focusedShellID) ? focusedShellID : nil
    }()

    do {
      let rpcStart = ContinuousClock.now
      let closed = try await client.closeShell(shellID, inSession: sessionID)
      AxoTrace.commands.notice(
        "event=shell.close_rpc_returned shell_id=\(shellID.rawValue) elapsed_ms=\(AxoTrace.elapsed(since: rpcStart), privacy: .public)")
      if closed.archivedSessionId != nil {
        removeSessions([sessionID], closing: session, replacement: closed.replacement)
      } else if let currentSession = self.session(for: sessionID) {
        let remainingShells = currentSession.shells.filter { $0.id != shellID }
        let remainingShellIDs = Set(remainingShells.map(\.id))
        replace(currentSession, withShells: remainingShells)

        let updatedLayout = (layoutsBySession[sessionID] ?? layoutBeforeClose)?
          .removing(shellID: shellID)
        if let updatedLayout {
          setLayout(updatedLayout, for: sessionID, persist: true)
        }
        if selectedSessionID == sessionID {
          assign(\.layout, updatedLayout)
          let currentFocus = focusedShellID.flatMap { remainingShellIDs.contains($0) ? $0 : nil }
          let preferredFocus = focusAfterClose.flatMap {
            remainingShellIDs.contains($0) ? $0 : nil
          }
          assign(\.focusedShellID, currentFocus ?? preferredFocus ?? updatedLayout?.firstShellID)
        }
      }
      errorMessage = nil
    } catch {
      report(error)
    }
  }

  /// Explicit, user-requested Pi recovery for the selected Session's unavailable Pi pane.
  func restartPiSession(_ shellID: ShellID) async throws {
    piRestarter.cancel(shellID: shellID)
    try await restartPiSession(shellID, automatically: false)
  }

  private func restartPiSession(_ shellID: ShellID, automatically: Bool) async throws {
    let client = try requireClient()
    guard let targetSession = sessions.first(where: { session in
      session.shells.contains(where: { $0.id == shellID })
    }),
      let shell = targetSession.shells.first(where: { $0.id == shellID }),
      shell.role == "pi",
      !shell.isAvailable,
      automatically || selectedSessionID == targetSession.id
    else {
      throw SessionCommandError("This Pi pane is no longer available to restart.")
    }

    let restartMethod = automatically
      ? "axo.session.pi.restart.auto.v1"
      : "axo.session.pi.restart.force.v2"
    guard try await supports(restartMethod, using: client) else {
      if automatically { throw AutomaticPiRestarter.Failure.unsupportedAxod }
      throw SessionCommandError(
        "Pi recovery is not yet supported by the running Axod. Your session history is preserved.")
    }

    let restarted = try await client.restartPi(
      shellID: shellID, inSession: targetSession.id, automatically: automatically)
    guard restarted.id == targetSession.id,
      restarted.shells.contains(where: { $0.id == shellID && $0.isAvailable })
    else {
      throw SessionCommandError("axod did not restore the requested Pi pane.")
    }
    upsert(restarted)
  }

  // MARK: - Navigation

  func showSession(_ sessionID: SessionID) {
    guard session(for: sessionID) != nil else { return }
    select(sessionID)
    assign(\.errorMessage, nil)
  }

  func showPreviousSession() { showAdjacentSession(.previous) }
  func showNextSession() { showAdjacentSession(.next) }
  func focusPreviousPane() { focusAdjacentPane(.previous) }
  func focusNextPane() { focusAdjacentPane(.next) }

  /// Focuses an available pane in any Session, selecting that Session.
  func focus(_ shellID: ShellID) {
    // Unavailable Pi panes are focusable too: ⌘W, pane navigation and Restart act on them.
    guard let session = sessions.first(where: {
      $0.shells.contains(where: { $0.id == shellID })
    }) else { return }
    selectedSessionID = session.id
    assign(\.layout, layoutsBySession[session.id])
    assign(\.focusedShellID, shellID)
    recentSessions.remember(session.id)
  }

  private func showAdjacentSession(_ direction: TerminalNavigationDirection) {
    let ordered = sidebarOrderedSessions
    let currentIndex = selectedSessionID.flatMap { id in ordered.firstIndex { $0.id == id } }
    guard
      let target = SessionNavigation.adjacentIndex(
        from: currentIndex, count: ordered.count, direction: direction)
    else { return }
    showSession(ordered[target].id)
  }

  private func focusAdjacentPane(_ direction: TerminalNavigationDirection) {
    guard let layout else { return }
    let paneIDs = layout.orderedShellIDs.filter { shell(for: $0) != nil }
    let currentIndex = focusedShellID.flatMap { paneIDs.firstIndex(of: $0) }
    guard
      let target = SessionNavigation.adjacentIndex(
        from: currentIndex, count: paneIDs.count, direction: direction)
    else { return }
    focus(paneIDs[target])
  }

  // MARK: - State helpers

  private func requireClient() throws -> AxodClient {
    guard let client else {
      throw SessionCommandError(clientError ?? "Axo can’t locate axod’s socket.")
    }
    return client
  }

  private func report(_ error: Error) {
    assign(\.errorMessage, error.localizedDescription)
  }

  /// Assigns a published property only when the value changes.
  private func assign<Value: Equatable>(
    _ keyPath: ReferenceWritableKeyPath<TerminalSessionsModel, Value>, _ value: Value
  ) {
    if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
  }

  private func negotiateIfNeeded(using client: AxodClient) async throws {
    guard daemonMethods == nil else { return }
    let negotiation = try await client.negotiate()
    let methods = Set(negotiation.methods)
    guard negotiation.protocolVersion == UnixSocketRPC.protocolVersion,
      Self.requiredMethods.isSubset(of: methods)
    else {
      throw SessionCommandError(
        "The running axod is incompatible with this version of Axo. Restart axod from the menu bar.")
    }
    daemonMethods = methods
  }

  private func supports(_ method: String, using client: AxodClient) async throws -> Bool {
    try await negotiateIfNeeded(using: client)
    return daemonMethods?.contains(method) == true
  }

  private func requireMethod(_ method: String, using client: AxodClient) async throws {
    guard try await supports(method, using: client) else {
      throw SessionCommandError(
        "This action requires a newer Axod. Your Sessions and Workspace are unchanged.")
    }
  }

  /// Inserts a Session Axod just created and shows it.
  private func adopt(_ session: TerminalSession) {
    add(session)
    select(session.id)
    assign(\.errorMessage, nil)
    workspaceCreationError = nil
  }

  /// Drops Sessions Axod archived, installs any replacement, and moves selection away from a
  /// removed Session: by default to `closing`'s successor, else to `fallback`'s choice.
  private func removeSessions(
    _ sessionIDs: Set<SessionID>,
    closing: TerminalSession?,
    replacement: TerminalSession?,
    fallback: ([TerminalSession]) -> SessionID? = { $0.first?.id }
  ) {
    for sessionID in sessionIDs {
      layoutsBySession.removeValue(forKey: sessionID)
      layoutWriter.discard(sessionID: sessionID)
      recentSessions.forget(sessionID)
    }
    sessions.removeAll { sessionIDs.contains($0.id) }
    if let replacement { add(replacement) }

    guard let selectedSessionID, sessionIDs.contains(selectedSessionID) else {
      if let selectedSessionID { activate(selectedSessionID) }
      return
    }
    let successor = closing.flatMap {
      SessionNavigation.successor(
        afterClosing: $0, in: sessions, recent: recentSessions, replacement: replacement)
    }
    select(successor ?? fallback(sessions))
  }

  /// Selects `sessionID` (or nothing) and shows its layout and focus.
  private func select(_ sessionID: SessionID?) {
    selectedSessionID = sessionID
    if let sessionID {
      activate(sessionID)
    } else {
      assign(\.layout, nil)
      assign(\.focusedShellID, nil)
    }
  }

  /// Presents `sessionID`'s layout, keeping focus if it is still a valid pane, else focusing the
  /// newest pane.
  private func activate(_ sessionID: SessionID) {
    guard let session = session(for: sessionID) else {
      assign(\.layout, nil)
      assign(\.focusedShellID, nil)
      return
    }
    recentSessions.remember(sessionID)
    let currentLayout = currentLayout(of: session)
    if layoutsBySession[sessionID] == nil {
      setLayout(currentLayout, for: sessionID, persist: true)
    }
    assign(\.layout, currentLayout)
    guard let currentLayout else {
      assign(\.focusedShellID, nil)
      return
    }
    if let focusedShellID,
      currentLayout.contains(shellID: focusedShellID),
      session.shells.contains(where: { $0.id == focusedShellID })
    {
      return
    }
    assign(\.focusedShellID, session.shells.map(\.id).max())
  }

  /// The local layout, else Axod's stored one, else the default for its shells.
  private func currentLayout(of session: TerminalSession) -> TerminalLayout? {
    layoutsBySession[session.id]
      ?? session.layout.map(TerminalLayout.init)
      ?? TerminalLayout.defaultLayout(for: session.shells.map(\.id))
  }

  private func add(_ session: TerminalSession) {
    let layout = session.layout.map(TerminalLayout.init)
      ?? TerminalLayout.defaultLayout(for: session.shells.map(\.id))
    var updated = sessions.filter { $0.id != session.id }
    updated.append(session.replacing(shells: session.shells, layout: layout?.sessionLayout))
    updated.sort { $0.id < $1.id }
    sessions = updated
    setLayout(layout, for: session.id, persist: session.layout == nil)
  }

  private func replace(_ session: TerminalSession, withShells shells: [TerminalShell]) {
    guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
    let layout = layoutsBySession[session.id]?.sessionLayout ?? session.layout
    sessions[index] = session.replacing(shells: shells, layout: layout)
  }

  private func setLayout(_ layout: TerminalLayout?, for sessionID: SessionID, persist: Bool) {
    layoutsBySession[sessionID] = layout
    if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
      let session = sessions[index]
      if session.layout.map(TerminalLayout.init) != layout {
        sessions[index] = session.replacing(shells: session.shells, layout: layout?.sessionLayout)
      }
    }
    if persist, let layout {
      layoutWriter.schedule(layout.sessionLayout, for: sessionID)
    }
  }
}
