import AxoRPC
import Foundation

/// The workbench's presentation state: which Session is shown, which pane has focus, and the
/// layout of every open Session. Axod owns Sessions and shells; this owns how they are shown,
/// and keeps itself consistent with whatever catalog it is given.
///
/// A pure value: no I/O and no observation, so every rule is testable on its own.
/// `TerminalSessionsModel` holds one, projects it into observed properties, and persists the
/// layouts collected in `pendingWrites`.
///
/// Rules each mutation preserves:
/// - `layouts` holds exactly the layouts the workbench shows: Axod's stored layout normalized to
///   the Session's shells, plus local edits.
/// - The shown layout is always the selected Session's entry in `layouts`.
/// - Focus stays on its pane while that pane is open; when it closes, focus moves to the pane
///   the layout places next to it, and a newly created pane takes focus.
struct WorkbenchSelection: Equatable {
  private(set) var selectedSessionID: SessionID?
  private(set) var focusedShellID: ShellID?
  private(set) var layouts: [SessionID: TerminalLayout] = [:]
  private(set) var recent = RecentSessions()
  /// Layouts to save to Axod, latest per Session.
  private(set) var pendingWrites: [SessionID: SessionLayout] = [:]

  init(selectedSessionID: SessionID? = nil) {
    self.selectedSessionID = selectedSessionID
  }

  /// The selected Session's layout.
  var layout: TerminalLayout? { selectedSessionID.flatMap { layouts[$0] } }

  mutating func takePendingWrites() -> [SessionID: SessionLayout] {
    defer { pendingWrites = [:] }
    return pendingWrites
  }

  // MARK: - Catalog

  /// Adopts Axod's catalog: normalizes every layout (keeping local edits, dropping closed panes,
  /// appending new ones), repairs focus, and keeps, restores or moves the selection.
  /// - Parameters:
  ///   - previous: the catalog before this one, to find a removed Session's successor.
  ///   - resumeSessionID: a Session Axod asks to show (Pi's `/resume`).
  mutating func applyCatalog(
    _ sessions: [TerminalSession], previous: [TerminalSession], focusing resumeSessionID: SessionID?
  ) {
    let previouslySelected = selectedSessionID.flatMap { id in previous.first { $0.id == id } }
    let openSessionIDs = Set(sessions.map(\.id))

    var normalized: [SessionID: TerminalLayout] = [:]
    for session in sessions {
      let shellIDs = Set(session.shells.map(\.id))
      let serverLayout = session.layout.map(TerminalLayout.init)
      let sourceLayout = layouts[session.id] ?? serverLayout
      let layout: TerminalLayout?
      let newShellIDs: Set<ShellID>
      if let sourceLayout, let pruned = sourceLayout.pruned(to: shellIDs) {
        newShellIDs = shellIDs.subtracting(pruned.shellIDs)
        layout = pruned.adding(newShellIDs)
      } else {
        newShellIDs = []
        layout = TerminalLayout.defaultLayout(for: session.shells.map(\.id))
      }
      normalized[session.id] = layout
      if let layout, serverLayout != layout {
        pendingWrites[session.id] = layout.sessionLayout
      }
      if selectedSessionID == session.id {
        repairFocus(
          newShellIDs: newShellIDs, openShellIDs: shellIDs, previousLayout: sourceLayout,
          layout: layout, shellOrder: session.shells.map(\.id))
      }
    }
    layouts = normalized
    pendingWrites = pendingWrites.filter { openSessionIDs.contains($0.key) }

    if let resumeSessionID, openSessionIDs.contains(resumeSessionID) {
      select(resumeSessionID, in: sessions)
    } else if let selectedSessionID, openSessionIDs.contains(selectedSessionID) {
      activate(selectedSessionID, in: sessions)
    } else if let previouslySelected {
      recent.forget(previouslySelected.id)
      select(
        SessionNavigation.successor(afterClosing: previouslySelected, in: sessions, recent: recent),
        in: sessions)
    } else {
      select(sessions.first?.id, in: sessions)
    }
  }

  /// The newest new pane takes focus; a closed focused pane hands focus to its layout neighbour.
  private mutating func repairFocus(
    newShellIDs: Set<ShellID>, openShellIDs: Set<ShellID>, previousLayout: TerminalLayout?,
    layout: TerminalLayout?, shellOrder: [ShellID]
  ) {
    if let newest = shellOrder.filter(newShellIDs.contains).max() {
      focusedShellID = newest
    } else if let previousFocus = focusedShellID,
      previousLayout?.contains(shellID: previousFocus) == true,
      !openShellIDs.contains(previousFocus)
    {
      focusedShellID =
        previousLayout?.focusTargetAfterClosing(previousFocus, remainingShellIDs: openShellIDs)
        ?? layout?.firstShellID
    }
  }

  /// A Session Axod just created (or returned as a replacement) joins the workbench. Its layout
  /// is saved only when Axod had none.
  mutating func add(_ session: TerminalSession) {
    let layout = session.layout.map(TerminalLayout.init)
      ?? TerminalLayout.defaultLayout(for: session.shells.map(\.id))
    setLayout(layout, for: session.id, persist: session.layout == nil)
  }

  /// Drops Sessions Axod archived and moves the selection away from a removed one: by default
  /// to `closing`'s successor, else to `fallback`'s choice among the remaining `sessions`.
  mutating func remove(
    _ sessionIDs: Set<SessionID>,
    remaining sessions: [TerminalSession],
    closing: TerminalSession?,
    replacement: TerminalSession?,
    fallback: ([TerminalSession]) -> SessionID?
  ) {
    for sessionID in sessionIDs {
      layouts.removeValue(forKey: sessionID)
      pendingWrites.removeValue(forKey: sessionID)
      recent.forget(sessionID)
    }
    guard let selectedSessionID, sessionIDs.contains(selectedSessionID) else {
      if let selectedSessionID { activate(selectedSessionID, in: sessions) }
      return
    }
    let successor = closing.flatMap {
      SessionNavigation.successor(
        afterClosing: $0, in: sessions, recent: recent, replacement: replacement)
    }
    select(successor ?? fallback(sessions), in: sessions)
  }

  // MARK: - Selection and focus

  /// Shows `sessionID` (or nothing), keeping focus if it is still one of its panes, else
  /// focusing its newest pane.
  mutating func select(_ sessionID: SessionID?, in sessions: [TerminalSession]) {
    selectedSessionID = sessionID
    if let sessionID {
      activate(sessionID, in: sessions)
    } else {
      focusedShellID = nil
    }
  }

  private mutating func activate(_ sessionID: SessionID, in sessions: [TerminalSession]) {
    guard let session = sessions.first(where: { $0.id == sessionID }) else {
      focusedShellID = nil
      return
    }
    recent.remember(sessionID)
    let current = currentLayout(of: session)
    if layouts[sessionID] == nil {
      setLayout(current, for: sessionID, persist: true)
    }
    guard let current else {
      focusedShellID = nil
      return
    }
    if let focusedShellID,
      current.contains(shellID: focusedShellID),
      session.shells.contains(where: { $0.id == focusedShellID })
    {
      return
    }
    focusedShellID = session.shells.map(\.id).max()
  }

  /// Focuses a pane of any Session, selecting that Session. Unavailable Pi panes are focusable
  /// too: ⌘W, pane navigation and Restart act on them.
  mutating func focus(_ shellID: ShellID, in sessions: [TerminalSession]) {
    guard let session = sessions.first(where: { $0.shells.contains { $0.id == shellID } })
    else { return }
    selectedSessionID = session.id
    focusedShellID = shellID
    recent.remember(session.id)
  }

  /// The pane one step from the focused one in the shown layout, wrapping.
  func adjacentPane(_ direction: TerminalNavigationDirection, among open: Set<ShellID>) -> ShellID? {
    guard let layout else { return nil }
    let paneIDs = layout.orderedShellIDs.filter(open.contains)
    let currentIndex = focusedShellID.flatMap { paneIDs.firstIndex(of: $0) }
    return SessionNavigation.adjacentIndex(
      from: currentIndex, count: paneIDs.count, direction: direction
    ).map { paneIDs[$0] }
  }

  // MARK: - Layout edits

  /// The pane a new split goes beside: the focused one, else the first of the layout.
  func splitAnchor(in sessionID: SessionID) -> ShellID? {
    (selectedSessionID == sessionID ? focusedShellID : nil) ?? layouts[sessionID]?.firstShellID
  }

  /// A pane Axod just created is placed beside `anchor` and, in the shown Session, focused.
  mutating func place(
    _ shellID: ShellID,
    in session: TerminalSession,
    direction: TerminalSplitDirection,
    beside anchor: ShellID,
    ratio: Double
  ) {
    let layout = currentLayout(of: session)?.placing(
      shellID: shellID, direction: direction, beside: anchor, ratio: ratio
    ) ?? .pane(shellID)
    setLayout(layout, for: session.id, persist: true)
    if selectedSessionID == session.id { focusedShellID = shellID }
  }

  /// Drags the shown layout's divider `splitID` to `ratio` (clamped to 1–99%).
  mutating func resizeSplit(_ splitID: UUID, to ratio: Double) {
    guard let selectedSessionID, ratio.isFinite,
      let updated = layouts[selectedSessionID]?.resizing(
        splitID: splitID, to: min(max(ratio, 0.01), 0.99))
    else { return }
    setLayout(updated, for: selectedSessionID, persist: true)
  }

  /// Where focus should go if `shellID` closes, decided before the close so a racing catalog
  /// update cannot change the answer.
  func focusAfterClosing(_ shellID: ShellID, in session: TerminalSession) -> ShellID? {
    guard selectedSessionID == session.id else { return nil }
    let before = currentLayout(of: session)
    guard let focusedShellID else { return before?.firstShellID }
    let remaining = Set(session.shells.lazy.map(\.id).filter { $0 != shellID })
    if focusedShellID == shellID {
      return before?.focusTargetAfterClosing(shellID, remainingShellIDs: remaining)
    }
    return remaining.contains(focusedShellID) ? focusedShellID : nil
  }

  /// Axod closed one pane of a Session that stays open.
  /// - Parameters:
  ///   - layoutBeforeClose: the layout when the close was requested, if the Session has none now.
  ///   - preferredFocus: `focusAfterClosing`'s answer.
  mutating func paneClosed(
    _ shellID: ShellID,
    in sessionID: SessionID,
    remaining: Set<ShellID>,
    layoutBeforeClose: TerminalLayout?,
    preferredFocus: ShellID?
  ) {
    let updated = (layouts[sessionID] ?? layoutBeforeClose)?.removing(shellID: shellID)
    setLayout(updated, for: sessionID, persist: true)
    guard selectedSessionID == sessionID else { return }
    let currentFocus = focusedShellID.flatMap { remaining.contains($0) ? $0 : nil }
    let preferred = preferredFocus.flatMap { remaining.contains($0) ? $0 : nil }
    focusedShellID = currentFocus ?? preferred ?? updated?.firstShellID
  }

  // MARK: - Helpers

  /// The workbench's layout, else Axod's stored one, else the default for its shells.
  func currentLayout(of session: TerminalSession) -> TerminalLayout? {
    layouts[session.id]
      ?? session.layout.map(TerminalLayout.init)
      ?? TerminalLayout.defaultLayout(for: session.shells.map(\.id))
  }

  private mutating func setLayout(
    _ layout: TerminalLayout?, for sessionID: SessionID, persist: Bool
  ) {
    layouts[sessionID] = layout
    if persist, let layout {
      pendingWrites[sessionID] = layout.sessionLayout
    }
  }
}
