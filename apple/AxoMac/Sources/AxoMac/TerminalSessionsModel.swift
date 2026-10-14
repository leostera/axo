import AxoDaemonManager
import AxoRPC
import Combine
import Foundation

@MainActor
final class TerminalSessionsModel: ObservableObject {
  @Published private(set) var sessions: [TerminalSession] = []
  @Published var selectedSessionID: Int64?
  @Published private(set) var focusedSessionID: Int64?
  @Published private(set) var layout: TerminalLayout?
  @Published private(set) var errorMessage: String?

  let helperURL: URL

  private let socketPath: UnixSocketPath?
  private let socketPathError: String?

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

  func refresh() async {
    guard let socketPath else {
      errorMessage = socketPathError ?? "The Axo D socket path is unavailable."
      return
    }

    do {
      sessions = try await UnixSocketRPC.listSessions(at: socketPath)
      let openSessionIDs = Set(sessions.map(\.id))
      layout = layout?.pruned(to: openSessionIDs)

      if let selectedSessionID, openSessionIDs.contains(selectedSessionID) {
        if layout == nil {
          layout = .pane(selectedSessionID)
        }
      } else {
        selectedSessionID = sessions.first?.id
        focusedSessionID = selectedSessionID
        layout = selectedSessionID.map(TerminalLayout.pane)
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
      focusedSessionID = session.id
      layout = .pane(session.id)
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
    guard let currentSessionID = focusedSessionID ?? selectedSessionID else {
      errorMessage = "Select a session before splitting the terminal."
      return
    }

    do {
      let session = try await UnixSocketRPC.createSession(at: socketPath)
      add(session)
      if let existingLayout = layout,
        let updatedLayout = existingLayout.inserting(
          sessionID: session.id,
          direction: direction,
          beside: currentSessionID
        )
      {
        layout = updatedLayout
      } else {
        layout = .split(
          id: UUID(),
          direction: direction,
          first: .pane(currentSessionID),
          second: .pane(session.id)
        )
      }
      selectedSessionID = session.id
      focusedSessionID = session.id
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
      _ = try await UnixSocketRPC.closeSession(sessionID, at: socketPath)
      layout = layout?.removing(sessionID: sessionID)
      sessions.removeAll { $0.id == sessionID }
      if selectedSessionID == sessionID {
        selectedSessionID = sessions.first?.id
      }
      if focusedSessionID == sessionID {
        focusedSessionID = selectedSessionID
      }
      if layout == nil, let selectedSessionID {
        layout = .pane(selectedSessionID)
      }
      await refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func showSession(_ sessionID: Int64) {
    guard sessions.contains(where: { $0.id == sessionID }) else { return }
    selectedSessionID = sessionID
    focusedSessionID = sessionID
    layout = .pane(sessionID)
    errorMessage = nil
  }

  func focus(_ sessionID: Int64) {
    guard sessions.contains(where: { $0.id == sessionID }) else { return }
    selectedSessionID = sessionID
    focusedSessionID = sessionID
  }

  func session(for sessionID: Int64) -> TerminalSession? {
    sessions.first(where: { $0.id == sessionID })
  }

  private func add(_ session: TerminalSession) {
    sessions.removeAll { $0.id == session.id }
    sessions.append(session)
    sessions.sort { $0.id < $1.id }
  }
}

enum TerminalSplitDirection: Equatable {
  case right
  case down
}

indirect enum TerminalLayout: Equatable, Identifiable {
  case pane(Int64)
  case split(
    id: UUID, direction: TerminalSplitDirection, first: TerminalLayout, second: TerminalLayout)

  var id: String {
    switch self {
    case .pane(let sessionID): "session-\(sessionID)"
    case .split(let id, _, _, _): "split-\(id.uuidString)"
    }
  }

  func inserting(
    sessionID newSessionID: Int64,
    direction: TerminalSplitDirection,
    beside targetSessionID: Int64
  ) -> TerminalLayout? {
    switch self {
    case .pane(let currentID) where currentID == targetSessionID:
      return .split(
        id: UUID(),
        direction: direction,
        first: self,
        second: .pane(newSessionID)
      )
    case .pane:
      return nil
    case .split(let id, let existingDirection, let first, let second):
      if let updatedFirst = first.inserting(
        sessionID: newSessionID,
        direction: direction,
        beside: targetSessionID
      ) {
        return .split(id: id, direction: existingDirection, first: updatedFirst, second: second)
      }
      if let updatedSecond = second.inserting(
        sessionID: newSessionID,
        direction: direction,
        beside: targetSessionID
      ) {
        return .split(id: id, direction: existingDirection, first: first, second: updatedSecond)
      }
      return nil
    }
  }

  func removing(sessionID: Int64) -> TerminalLayout? {
    switch self {
    case .pane(let currentID):
      return currentID == sessionID ? nil : self
    case .split(let id, let direction, let first, let second):
      let remainingFirst = first.removing(sessionID: sessionID)
      let remainingSecond = second.removing(sessionID: sessionID)
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
          first: remainingFirst,
          second: remainingSecond
        )
      }
    }
  }

  func pruned(to openSessionIDs: Set<Int64>) -> TerminalLayout? {
    switch self {
    case .pane(let sessionID):
      return openSessionIDs.contains(sessionID) ? self : nil
    case .split(let id, let direction, let first, let second):
      let remainingFirst = first.pruned(to: openSessionIDs)
      let remainingSecond = second.pruned(to: openSessionIDs)
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
          first: remainingFirst,
          second: remainingSecond
        )
      }
    }
  }
}
