import AxoDaemonManager
import AxoRPC
import Combine
import Foundation

@MainActor
final class TerminalSessionsModel: ObservableObject {
  @Published private(set) var sessions: [TerminalSession] = []
  @Published var selectedSessionID: Int64?
  @Published private(set) var focusedShellID: Int64?
  @Published private(set) var layout: TerminalLayout?
  @Published private(set) var errorMessage: String?

  let helperURL: URL

  private let socketPath: UnixSocketPath?
  private let socketPathError: String?
  private var layoutsBySession: [Int64: TerminalLayout] = [:]

  init() {
    helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/axod")
    do {
      socketPath = try DaemonController.socketPath()
      socketPathError = nil
    } catch {
      socketPath = nil
      socketPathError = error.localizedDescription
    }
  }

  init(socketPath: UnixSocketPath, helperURL: URL) {
    self.socketPath = socketPath
    socketPathError = nil
    self.helperURL = helperURL
  }

  func refresh() async {
    guard let socketPath else {
      errorMessage = socketPathError ?? "The Axo D socket path is unavailable."
      return
    }

    do {
      let updatedSessions = try await UnixSocketRPC.listSessions(at: socketPath)
      if sessions != updatedSessions {
        sessions = updatedSessions
      }
      let openSessionIDs = Set(sessions.map(\.id))
      layoutsBySession = layoutsBySession.filter { openSessionIDs.contains($0.key) }

      for session in sessions {
        let shellIDs = Set(session.shells.map(\.id))
        if let current = layoutsBySession[session.id]?.pruned(to: shellIDs) {
          let newlyCreatedShellIDs = shellIDs.subtracting(current.shellIDs)
          layoutsBySession[session.id] = current.adding(newlyCreatedShellIDs)
          if selectedSessionID == session.id, let newestShellID = newlyCreatedShellIDs.max() {
            focusedShellID = newestShellID
          }
        } else {
          layoutsBySession[session.id] = Self.defaultLayout(for: session.shells)
        }
      }

      if let selectedSessionID, openSessionIDs.contains(selectedSessionID) {
        activate(selectedSessionID)
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
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func createSession() async {
    guard let socketPath else {
      errorMessage = socketPathError ?? "The Axo D socket path is unavailable."
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
      errorMessage = socketPathError ?? "The Axo D socket path is unavailable."
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
    guard let socketPath else {
      errorMessage = socketPathError ?? "The Axo D socket path is unavailable."
      return
    }

    do {
      let closed = try await UnixSocketRPC.closeSession(sessionID, at: socketPath)
      layoutsBySession.removeValue(forKey: sessionID)
      sessions.removeAll { $0.id == sessionID }
      if let replacement = closed.replacement {
        add(replacement)
      }
      if selectedSessionID == sessionID {
        selectedSessionID = sessions.first?.id
      }
      if let selectedSessionID {
        activate(selectedSessionID)
      } else {
        layout = nil
        focusedShellID = nil
      }
      await refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func closeFocusedShell() async {
    guard let focusedShellID else { return }
    await closeShell(focusedShellID)
  }

  func closeShell(_ shellID: Int64) async {
    guard let socketPath,
      let sessionID = sessions.first(where: { $0.shells.contains(where: { $0.id == shellID }) })?.id
    else {
      errorMessage = socketPathError ?? "The focused shell is no longer open."
      return
    }

    do {
      let closed = try await UnixSocketRPC.closeShell(shellID, in: sessionID, at: socketPath)
      if closed.archivedSessionId != nil {
        layoutsBySession.removeValue(forKey: sessionID)
        sessions.removeAll { $0.id == sessionID }
        if let replacement = closed.replacement {
          add(replacement)
        }
        if selectedSessionID == sessionID {
          selectedSessionID = sessions.first?.id
          if let selectedSessionID {
            activate(selectedSessionID)
          } else {
            layout = nil
            focusedShellID = nil
          }
        }
      } else {
        guard let session = self.session(for: sessionID) else { return }
        let remainingShells = session.shells.filter { $0.id != shellID }
        replace(session, withShells: remainingShells)
        if let currentLayout = layoutsBySession[sessionID] {
          layoutsBySession[sessionID] = currentLayout.removing(shellID: shellID)
        }
        if selectedSessionID == sessionID {
          layout = layoutsBySession[sessionID]
          focusedShellID = layout?.firstShellID
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
    layoutsBySession[selectedSessionID] = updated
    layout = updated
  }

  func focus(_ shellID: Int64) {
    guard let session = sessions.first(where: { $0.shells.contains(where: { $0.id == shellID }) })
    else {
      return
    }
    selectedSessionID = session.id
    layout = layoutsBySession[session.id]
    focusedShellID = shellID
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
    let paneIDs = layout.orderedShellIDs
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
    let currentIndex = selectedSessionID.flatMap { selectedID in
      sessions.firstIndex { $0.id == selectedID }
    }
    guard
      let targetIndex = Self.adjacentIndex(
        from: currentIndex,
        count: sessions.count,
        direction: direction
      )
    else {
      return
    }
    showSession(sessions[targetIndex].id)
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

  private func activate(_ sessionID: Int64) {
    guard let session = session(for: sessionID) else {
      layout = nil
      focusedShellID = nil
      return
    }
    let currentLayout = layoutsBySession[sessionID] ?? Self.defaultLayout(for: session.shells)
    layoutsBySession[sessionID] = currentLayout
    layout = currentLayout
    guard let currentLayout else {
      focusedShellID = nil
      return
    }
    if let focusedShellID, currentLayout.contains(shellID: focusedShellID) {
      return
    }
    focusedShellID = session.shells.map(\.id).max() ?? currentLayout.firstShellID
  }

  private func add(_ session: TerminalSession) {
    sessions.removeAll { $0.id == session.id }
    sessions.append(session)
    sessions.sort { $0.id < $1.id }
    layoutsBySession[session.id] = Self.defaultLayout(for: session.shells)
  }

  private func replace(_ session: TerminalSession, withShells shells: [TerminalShell]) {
    let updated = TerminalSession(id: session.id, initialPwd: session.initialPwd, shells: shells)
    guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
    sessions[index] = updated
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
      layoutsBySession[sessionID] = updated
    } else {
      layoutsBySession[sessionID] = .split(
        id: UUID(),
        direction: direction,
        ratio: 0.5,
        first: .pane(anchorShellID),
        second: .pane(shellID)
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
