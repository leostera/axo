import AxoDaemonManager
import AxoProtocol
import AxoClient
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
  /// Every open Session, sorted by ID; projected from `catalog`. Pi turns change Session
  /// status, names and emoji often; views that only need panes read the narrower projections
  /// below, which change only when their part does.
  private(set) var sessions: [TerminalSession] = []
  /// Every open shell by id, across Sessions. Unchanged by Session status or name updates.
  private(set) var shellsByID: [ShellID: TerminalShell] = [:]
  /// Every Session's current layout (including local edits not yet persisted), for sizing panes
  /// that are not shown. Projected from `selection`.
  private(set) var sessionLayouts: [SessionLayout] = []
  private(set) var hasSessions = false
  /// Which menu commands apply. The menus read only this, so Session updates and switches that
  /// leave every command's availability alone do not re-evaluate the App scene and its menus.
  private(set) var commandAvailability = TerminalCommandAvailability()
  private(set) var workspaces: [WorkspaceRecord] = [] {
    didSet { projectCommandAvailability() }
  }
  // Projected from `selection`; see `projectSelection()`.
  private(set) var selectedSessionID: SessionID? {
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
  /// How the sidebar lists Sessions; Previous/Next Session follow the same order.
  private(set) var sidebarMode: SidebarMode
  /// The recent list's order frozen while the pointer is over the sidebar, so rows don't move
  /// under a click and Previous/Next Session step through the rows as shown.
  private(set) var heldRecentOrder: [SessionID]?

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
  /// What the connected Axod offers; `nil` without a client.
  private let capabilities: AxodCapabilities?
  /// The open Sessions: the single source of truth for `sessions` and its projections.
  @ObservationIgnored private var catalog = SessionCatalog() {
    didSet { projectCatalog() }
  }
  /// Selection, focus and layouts: the single source of truth, projected into the observed
  /// properties above whenever it changes. `sessions` keeps Axod's records as sent, so dividing
  /// a pane never touches what the sidebar reads.
  @ObservationIgnored private var selection: WorkbenchSelection {
    didSet {
      // Taken here: a write to `selection` inside its own observer does not re-enter it.
      let writes = selection.takePendingWrites()
      projectSelection(persisting: writes)
    }
  }

  // MARK: - Initialization

  /// The production model: talks to the installed Axod socket.
  convenience init() {
    let client: AxodClient?
    let clientError: String?
    do {
      client = AxodConnection(socketPath: try DaemonController.socketPath())
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
      client: AxodConnection(socketPath: socketPath),
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
    capabilities = client.map(AxodCapabilities.init(client:))
    self.selectedSessionDefaults = selectedSessionDefaults
    let preferenceDefaults = selectedSessionDefaults ?? .standard
    self.preferenceDefaults = preferenceDefaults
    let restartsAutomatically = preferenceDefaults.bool(forKey: AxoPreferenceKey.automaticPiRestart)
    let storedSelection = Self.storedSelectedSessionID(from: selectedSessionDefaults)
    selection = WorkbenchSelection(selectedSessionID: storedSelection)
    selectedSessionID = storedSelection
    automaticallyRestartUnavailablePi = restartsAutomatically
    sidebarMode =
      preferenceDefaults.string(forKey: AxoPreferenceKey.sidebarMode).flatMap(SidebarMode.init)
      ?? .workspaces
    layoutWriter = TerminalLayoutWriter(client: client)
    piRestarter = AutomaticPiRestarter(isEnabled: restartsAutomatically)
    viewportReporter = ViewportReporter(client: client)

    layoutWriter.isSessionOpen = { [weak self] in self?.session(for: $0) != nil }
    layoutWriter.onError = { [weak self] in self?.errorMessage = $0.localizedDescription }
    piRestarter.needsRestart = { [weak self] shellID in
      guard let shell = self?.shell(for: shellID) else { return false }
      return shell.isPi && !shell.isAvailable
    }
    viewportReporter.isSupported = { [weak self] in
      guard let capabilities = self?.capabilities else { return false }
      return try await capabilities.supports(.clientViewportSet)
    }
    piRestarter.restart = { [weak self] shellID in
      try await self?.restartPiSession(shellID, automatically: true)
    }
  }

  /// The Session selected when the app last ran. Before Session IDs were UUIDs (RFD0017) this
  /// was an integer; such a value names no Session now, so it is removed and the default Session
  /// is selected.
  private static func storedSelectedSessionID(from defaults: UserDefaults?) -> SessionID? {
    guard let defaults, let stored = defaults.object(forKey: AxoPreferenceKey.selectedSession)
    else { return nil }
    if let rawValue = stored as? String, let sessionID = SessionID(rawValue: rawValue) {
      return sessionID
    }
    defaults.removeObject(forKey: AxoPreferenceKey.selectedSession)
    return nil
  }

  // MARK: - Queries

  var sidebarSections: SidebarSections {
    SidebarSections(sessions: sessions, workspaces: workspaces)
  }

  /// Every open Session in the order the sidebar lists it.
  var sidebarOrderedSessions: [TerminalSession] {
    switch sidebarMode {
    case .workspaces: sidebarSections.ordered
    case .recent:
      SessionActivityOrder.holding(heldRecentOrder, live: SessionActivityOrder.sorted(sessions))
    }
  }

  /// Freezes the recent list's current order, or releases it so rows move to their places.
  func holdRecentOrder(_ isHeld: Bool) {
    if !isHeld {
      assign(\.heldRecentOrder, nil)
    } else if heldRecentOrder == nil {
      heldRecentOrder = SessionActivityOrder.sorted(sessions).map(\.id)
    }
  }

  /// Sessions most recently shown first. Not observed: read when needed, as by the palette.
  var recentSessionIDs: [SessionID] { selection.recent.ids }

  func session(for sessionID: SessionID) -> TerminalSession? {
    catalog.session(for: sessionID)
  }

  /// An open shell of any Session.
  func shell(for shellID: ShellID) -> TerminalShell? {
    shellsByID[shellID]
  }

  /// The open Session a shell belongs to.
  func session(containing shellID: ShellID) -> TerminalSession? {
    catalog.session(containing: shellID)
  }

  /// Updates the projections of `catalog`, writing (and so invalidating observers) only those
  /// that changed.
  private func projectCatalog() {
    assign(\.sessions, catalog.sessions)
    assign(\.shellsByID, catalog.shellsByID)
    assign(\.hasSessions, !catalog.isEmpty)
    projectCommandAvailability()
  }

  /// Writes the observed selection, focus and layouts (only those that changed) and hands new
  /// layout writes to the writer.
  private func projectSelection(persisting writes: [SessionID: SessionLayout]) {
    for (sessionID, layout) in writes { layoutWriter.schedule(layout, for: sessionID) }
    assign(\.selectedSessionID, selection.selectedSessionID)
    assign(\.focusedShellID, selection.focusedShellID)
    assign(\.layout, selection.layout)
    assign(
      \.sessionLayouts, selection.layouts.sorted { $0.key.rawValue < $1.key.rawValue }.map(\.value.sessionLayout))
    projectCommandAvailability()
  }

  private func projectCommandAvailability() {
    assign(
      \.commandAvailability,
      TerminalCommandAvailability(
        canNavigatePanes: (layout?.orderedShellIDs.count ?? 0) >= 2,
        // Every open Session is listed in the sidebar (see `SidebarSections`).
        canNavigateSessions: sessions.count >= 2,
        hasFocusedShell: focusedShellID != nil,
        hasSelectedSession: selectedSessionID != nil))
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
    capabilities?.forget()
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
    try await requireCapabilities().negotiate()
    async let snapshotTask = client.listSessionSnapshot()
    async let workspacesTask = client.listWorkspaces()
    let snapshot = try await snapshotTask
    assign(\.workspaces, try await workspacesTask)
    applyCatalog(SessionCatalog(snapshot.sessions), focusing: snapshot.resumeSessionId)
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
      applyCatalog(catalog.removing([sessionID]), focusing: nil)
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
    applyCatalog(catalog.upserting(session), focusing: nil)
  }

  /// Replaces the catalog with Axod's; `WorkbenchSelection` normalizes layouts and repairs
  /// selection and focus.
  private func applyCatalog(_ next: SessionCatalog, focusing resumeSessionID: SessionID?) {
    layoutWriter.retain(sessionIDs: Set(next.sessions.map(\.id)))
    selection.applyCatalog(next.sessions, previous: catalog.sessions, focusing: resumeSessionID)
    catalog = next
    piRestarter.schedule(for: catalog.sessions)
  }

  // MARK: - Preferences

  func setSidebarMode(_ mode: SidebarMode) {
    guard sidebarMode != mode else { return }
    sidebarMode = mode
    heldRecentOrder = nil
    preferenceDefaults.set(mode.rawValue, forKey: AxoPreferenceKey.sidebarMode)
  }

  func setAutomaticPiRestartEnabled(_ enabled: Bool) {
    guard automaticallyRestartUnavailablePi != enabled else { return }
    automaticallyRestartUnavailablePi = enabled
    preferenceDefaults.set(enabled, forKey: AxoPreferenceKey.automaticPiRestart)
    piRestarter.isEnabled = enabled
    piRestarter.schedule(for: sessions)
  }

  // MARK: - Sessions and Workspaces

  func createWorkspace(name: String, directoryPath: String, directoryBookmark: String?) async {
    let interval = AxoTrace.beginInterval("command.workspace.create")
    defer { AxoTrace.endInterval(interval) }
    workspaceCreationError = nil
    do {
      let created = try await requireClient().createWorkspace(
        name: name, directoryPath: directoryPath, directoryBookmark: directoryBookmark)
      guard created.session.workspaceId == created.workspace.workspaceId else {
        throw SessionCommandError(
          "Workspace creation did not return its first Session.")
      }
      if !workspaces.contains(where: { $0.id == created.workspace.id }) {
        // As Axod lists them: Home first, the rest by name.
        workspaces = (workspaces + [created.workspace]).sorted {
          if $0.isHome != $1.isHome { return $0.isHome }
          return $0.name.localizedStandardCompare($1.name) == .orderedAscending
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
    let interval = AxoTrace.beginInterval("command.session.create")
    defer { AxoTrace.endInterval(interval) }
    do {
      adopt(try await requireClient().createSession(inWorkspace: workspaceID))
    } catch {
      report(error)
    }
  }

  func createSession() async {
    let interval = AxoTrace.beginInterval("command.session.create")
    defer { AxoTrace.endInterval(interval) }
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

  /// Brings back the Session most recently closed (⌘W on its Pi pane or last pane, or Close
  /// Session) and shows it. Repeating it reopens the one closed before that.
  @discardableResult
  func reopenClosedSession() async -> ClosedSessionReopen {
    do {
      let client = try requireClient()
      try await requireCapabilities().require(.sessionReopen)
      let session = try await client.reopenClosedSession()
      adopt(session)
      return .reopened(session.id)
    } catch AxoClientError.serverRejected(code: AxodConnection.sessionNotReopenedCode, _) {
      return .nothingToReopen
    } catch {
      report(error)
      return .failed
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
    switch SessionClosePlan(closing: closingSession, sessions: sessions, workspaces: workspaces) {
    case .close:
      await closeSession(sessionID)
    case .confirmArchive(let confirmation):
      pendingWorkspaceArchiveConfirmation = confirmation
    case .workspaceUnavailable:
      errorMessage = "The Workspace is unavailable, so the last Session was not closed."
    }
  }

  func cancelWorkspaceArchiveConfirmation() {
    pendingWorkspaceArchiveConfirmation = nil
  }

  func confirmWorkspaceArchiveAndCloseSession(_ confirmation: WorkspaceArchiveConfirmation) async {
    if pendingWorkspaceArchiveConfirmation == confirmation {
      pendingWorkspaceArchiveConfirmation = nil
    }
    guard confirmation.stillApplies(sessions: sessions, workspaces: workspaces) else {
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
    let interval = AxoTrace.beginInterval("command.session.close")
    defer { AxoTrace.endInterval(interval) }
    let closingSession = session(for: sessionID)
    let closed = try await requireClient().closeSession(sessionID)
    removeSessions([sessionID], closing: closingSession, replacement: closed.replacement)
  }

  func renameSession(_ sessionID: SessionID, to name: String) async throws {
    let client = try requireClient()
    try await requireCapabilities().require(.sessionRename)
    let renamed = try await client.renameSession(sessionID, to: name)
    guard renamed.id == sessionID, renamed.manualName == name else {
      throw SessionCommandError("axod did not apply the Session name.")
    }
    upsert(renamed)
  }

  func renameWorkspace(_ workspaceID: String, to name: String) async throws {
    let client = try requireClient()
    try await requireCapabilities().require(.workspaceRename)
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
    try await requireCapabilities().require(.workspaceArchive)
    let archived = try await client.archiveWorkspace(workspaceID)
    guard archived.archivedWorkspaceId == workspaceID else {
      throw SessionCommandError("axod archived a different Workspace.")
    }
    workspaces.removeAll { $0.workspaceId == workspaceID }
    // With the Workspace gone, prefer a Session in Home over another Workspace's.
    let homeWorkspaceID = workspaces.first(where: \.isHome)?.workspaceId
    removeSessions(
      Set(archived.archivedSessionIds), closing: nil, replacement: nil,
      fallback: { $0.first(where: { $0.workspaceId == homeWorkspaceID })?.id ?? $0.first?.id })
  }

  // MARK: - Panes

  /// Adds a pane beside the focused one. The new pane is shown optimistically
  /// (`pendingTerminalSplit`) until Axod confirms it; an unconfirmed outcome is reconciled from
  /// the catalog and never retried, because shell creation is not idempotent.
  func split(_ direction: TerminalSplitDirection) async {
    let interval = AxoTrace.beginInterval("command.pane.split")
    defer { AxoTrace.endInterval(interval) }
    guard pendingTerminalSplit == nil else { return }
    let client: AxodClient
    do { client = try requireClient() } catch { return report(error) }
    guard let sessionID = selectedSessionID,
      session(for: sessionID) != nil,
      let anchorShellID = selection.splitAnchor(in: sessionID)
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

      if !currentSession.shells.contains(where: { $0.id == shell.id }) {
        replace(currentSession, withShells: currentSession.shells + [shell])
      }
      // Clear the optimistic leaf in the same main-actor turn as installing the real one.
      pendingTerminalSplit = nil
      selection.place(
        shell.id, in: currentSession, direction: direction, beside: anchorShellID,
        ratio: pending.ratio)
      errorMessage = nil
    } catch {
      guard pendingTerminalSplit?.id == pending.id else { return }
      if let rpcError = error as? AxoClientError, case .serverRejected = rpcError {
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
    guard var pending = pendingTerminalSplit, pending.id == id else { return }
    pending.resize(to: ratio)
    if pending != pendingTerminalSplit { pendingTerminalSplit = pending }
  }

  func dismissPendingTerminalSplit(_ id: UUID) {
    guard pendingTerminalSplit?.id == id else { return }
    pendingTerminalSplit = nil
  }

  func resizeSplit(_ splitID: UUID, to ratio: Double) {
    selection.resizeSplit(splitID, to: ratio)
  }

  /// User-initiated close (⌘W): closes an idle shell at once, but asks first when it is running
  /// a foreground job or a Pi turn. When Axod cannot tell, it asks rather than guess.
  func requestCloseShell(_ shellID: ShellID) async {
    let interval = AxoTrace.beginInterval("command.pane.close")
    defer { AxoTrace.endInterval(interval) }
    let start = ContinuousClock.now
    AxoTrace.commands.notice("event=shell.close_requested shell_id=\(shellID.rawValue)")
    guard let client, let capabilities,
      let session = session(containing: shellID),
      let shell = shellsByID[shellID]
    else {
      errorMessage = clientError ?? "The focused shell is no longer open."
      return
    }
    // An unavailable Pi pane has no live process to interrupt.
    if shell.isPi, !shell.isAvailable {
      await closeShell(shellID)
      AxoTrace.commands.notice(
        "event=shell.close_done shell_id=\(shellID.rawValue) path=unavailable elapsed_ms=\(AxoTrace.elapsed(since: start), privacy: .public)")
      return
    }
    let busy: TerminalShellBusy?
    do {
      busy = try await capabilities.supports(.shellBusy)
        ? try await client.shellBusy(shellID, inSession: session.id)
        : nil
    } catch {
      busy = nil
    }
    AxoTrace.commands.notice(
      "event=shell.close_busy_checked shell_id=\(shellID.rawValue) busy=\(busy?.busy.description ?? "unknown", privacy: .public) elapsed_ms=\(AxoTrace.elapsed(since: start), privacy: .public)")
    guard let reason = ShellCloseConfirmation.Reason(closing: shell.role, busy: busy) else {
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
      let session = session(containing: shellID)
    else {
      errorMessage = clientError ?? "The focused shell is no longer open."
      return
    }
    let sessionID = session.id
    let layoutBeforeClose = selection.currentLayout(of: session)
    let focusAfterClose = selection.focusAfterClosing(shellID, in: session)

    do {
      let rpcStart = ContinuousClock.now
      let closed = try await client.closeShell(shellID, inSession: sessionID)
      AxoTrace.commands.notice(
        "event=shell.close_rpc_returned shell_id=\(shellID.rawValue) elapsed_ms=\(AxoTrace.elapsed(since: rpcStart), privacy: .public)")
      if closed.archivedSessionId != nil {
        removeSessions([sessionID], closing: session, replacement: closed.replacement)
      } else if let currentSession = self.session(for: sessionID) {
        let remainingShells = currentSession.shells.filter { $0.id != shellID }
        replace(currentSession, withShells: remainingShells)
        selection.paneClosed(
          shellID, in: sessionID, remaining: Set(remainingShells.map(\.id)),
          layoutBeforeClose: layoutBeforeClose, preferredFocus: focusAfterClose)
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
    let interval = AxoTrace.beginInterval("command.pi.restart")
    defer { AxoTrace.endInterval(interval) }
    let client = try requireClient()
    guard let targetSession = session(containing: shellID),
      let shell = shellsByID[shellID],
      shell.isPi,
      !shell.isAvailable,
      automatically || selectedSessionID == targetSession.id
    else {
      throw SessionCommandError("This Pi pane is no longer available to restart.")
    }

    let restartMethod: AxodMethodName = automatically ? .piRestartAuto : .piRestartForce
    guard try await requireCapabilities().supports(restartMethod) else {
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
    let interval = AxoTrace.beginInterval("command.session.show")
    defer { AxoTrace.endInterval(interval) }
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
    selection.focus(shellID, in: sessions)
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
    guard let target = selection.adjacentPane(direction, among: Set(shellsByID.keys)) else { return }
    focus(target)
  }

  // MARK: - State helpers

  private func requireClient() throws -> AxodClient {
    guard let client else { throw missingClient }
    return client
  }

  private func requireCapabilities() throws -> AxodCapabilities {
    guard let capabilities else { throw missingClient }
    return capabilities
  }

  private var missingClient: SessionCommandError {
    SessionCommandError(clientError ?? "Axo can’t locate axod’s socket.")
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
    for sessionID in sessionIDs { layoutWriter.discard(sessionID: sessionID) }
    catalog.remove(sessionIDs)
    if let replacement { add(replacement) }
    selection.remove(
      sessionIDs, remaining: sessions, closing: closing, replacement: replacement,
      fallback: fallback)
  }

  /// Selects `sessionID` (or nothing) and shows its layout and focus.
  private func select(_ sessionID: SessionID?) {
    selection.select(sessionID, in: sessions)
  }

  private func add(_ session: TerminalSession) {
    catalog.upsert(session)
    selection.add(session)
  }

  private func replace(_ session: TerminalSession, withShells shells: [TerminalShell]) {
    catalog.replaceShells(of: session.id, with: shells)
  }
}

/// What reopening a closed Session did.
enum ClosedSessionReopen: Equatable {
  case reopened(SessionID)
  /// No closed Session was left to reopen.
  case nothingToReopen
  /// Reported through `errorMessage`.
  case failed
}

/// Whether each menu command applies; see `TerminalSessionsModel.commandAvailability`.
struct TerminalCommandAvailability: Equatable {
  var canNavigatePanes = false
  var canNavigateSessions = false
  var hasFocusedShell = false
  var hasSelectedSession = false
}
