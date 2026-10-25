import AppKit
import AxoRPC
import SwiftUI

struct TerminalLayoutView: View {
  let layout: TerminalLayoutPresentation
  var sessions: TerminalSessionsModel

  @ViewBuilder
  var body: some View {
    switch layout {
    case .pane(let shellID):
      if let shell = sessions.shell(for: shellID) {
        TerminalPaneView(
          shell: shell,
          sessions: sessions
        )
        .id(shell.id)
      } else {
        ContentUnavailableView(
          "Shell Unavailable", systemImage: "terminal",
          description: Text("This shell is no longer open."))
      }
    case .pending(let pending):
      PendingTerminalPaneView(pending: pending, sessions: sessions)
        .id(pending.id)
    case .split(let id, let direction, let ratio, let isPending, let first, let second):
      TerminalSplitView(
        id: id,
        direction: direction,
        ratio: ratio,
        onRatioChange: { ratio in
          if isPending {
            sessions.resizePendingTerminalSplit(id, to: ratio)
          } else {
            sessions.resizeSplit(id, to: ratio)
          }
        },
        first: {
          TerminalLayoutView(layout: first, sessions: sessions)
        },
        second: {
          TerminalLayoutView(layout: second, sessions: sessions)
        }
      )
    }
  }
}

struct PendingTerminalPaneView: View {
  /// Creation normally completes in a few milliseconds; only a slow daemon shows progress.
  static let progressDelay: Duration = .milliseconds(150)

  let pending: PendingTerminalSplit
  var sessions: TerminalSessionsModel
  @State private var showsProgress = false

  var body: some View {
    VStack(spacing: 10) {
      switch pending.status {
      case .creating:
        if showsProgress {
          ProgressView()
            .controlSize(.small)
          Text("Creating pane…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      case .rejected(let message):
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
        Text(message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Button("Dismiss") { sessions.dismissPendingTerminalSplit(pending.id) }
          .controlSize(.small)
      case .outcomeUnknown:
        Image(systemName: "questionmark.circle")
          .foregroundStyle(.secondary)
        Text("Creation outcome is unknown. Check the session before retrying.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Button("Dismiss") { sessions.dismissPendingTerminalSplit(pending.id) }
          .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .textBackgroundColor))
    .accessibilityIdentifier("pending-terminal-pane")
    .task(id: pending.id) {
      try? await Task.sleep(for: Self.progressDelay)
      showsProgress = true
    }
  }
}

struct TerminalPaneView: View {
  let shell: TerminalShell
  let sessions: TerminalSessionsModel
  @Environment(GhosttyRuntime.self) private var ghostty
  @State private var terminalError: String?
  @State private var piRestartError: String?
  @State private var isRestartingPi = false

  @ViewBuilder
  var body: some View {
    if case .unavailable(let reason) = shell.availability {
      VStack(spacing: 12) {
        ContentUnavailableView(
          "Pi Session Unavailable", systemImage: "exclamationmark.triangle",
          description: Text(reason))
          .fixedSize(horizontal: false, vertical: true)
        Text("Restarting stops the Pi process attached to this pane and starts it again from its existing conversation history.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 400)
        if sessions.automaticallyRestartUnavailablePi {
          Label(
            "Auto-restart will retry when Pi is idle or its transcript is unowned.",
            systemImage: "arrow.clockwise"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 400)
        }
        Button("Restart Pi") {
          guard !isRestartingPi else { return }
          isRestartingPi = true
          piRestartError = nil
          Task {
            defer { isRestartingPi = false }
            do {
              try await sessions.restartPiSession(shell.id)
            } catch {
              piRestartError = error.localizedDescription
            }
          }
        }
        .disabled(isRestartingPi)
        .accessibilityIdentifier("restart-pi-\(shell.id)")
        if isRestartingPi {
          ProgressView("Restarting Pi…")
            .controlSize(.small)
        }
        if let piRestartError {
          Text(piRestartError)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 400)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .textBackgroundColor))
      .contentShape(.rect)
      // No terminal surface takes first responder here, so a click selects the pane for ⌘W.
      .onTapGesture { sessions.focus(shell.id) }
    } else {
      GeometryReader { geometry in
        GhosttyTerminalView(
          runtime: ghostty,
          shell: shell,
          size: geometry.size,
          isFocused: sessions.focusedShellID == shell.id,
          onFocus: { sessions.focus(shell.id) },
          onStatusChange: { connection in
            terminalError = connection.failureMessage
          },
          onSplit: { direction in Task { await sessions.split(direction) } },
          onClose: { Task { await sessions.closeShell(shell.id) } }
        )
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .textBackgroundColor))
      .overlay(alignment: .topLeading) {
        if let terminalError {
          Text(terminalError)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
        }
      }
    }
  }
}
