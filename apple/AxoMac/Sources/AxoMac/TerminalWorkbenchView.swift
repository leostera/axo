import AxoDaemonManager
import AxoRPC
import SwiftUI

struct TerminalWorkbenchView: View {
  @ObservedObject var daemon: DaemonController
  @ObservedObject var sessions: TerminalSessionsModel

  private var daemonIsRunning: Bool {
    if case .running = daemon.status { return true }
    return false
  }

  private var sidebarSelection: Binding<Int64?> {
    Binding(
      get: { sessions.selectedSessionID },
      set: { if let sessionID = $0 { sessions.showSession(sessionID) } }
    )
  }

  var body: some View {
    NavigationSplitView {
      sessionSidebar
    } detail: {
      terminalContent
    }
    .frame(minWidth: 760, minHeight: 480)
    .task(id: daemonIsRunning) {
      guard daemonIsRunning else { return }
      while !Task.isCancelled {
        await sessions.refresh()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private var sessionSidebar: some View {
    List(selection: sidebarSelection) {
      Section("Sessions") {
        ForEach(sessions.sessions) { session in
          SessionSidebarRow(session: session)
            .tag(session.id)
            .contextMenu {
              Button("Close Session", role: .destructive) {
                Task { await sessions.closeSession(session.id) }
              }
            }
        }
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("Axo")
    .navigationSplitViewColumnWidth(min: 170, ideal: 220, max: 300)
    .overlay {
      if sessions.sessions.isEmpty {
        ContentUnavailableViewPlaceholder(
          title: daemonIsRunning ? "No Sessions" : "Axo D Is Not Running",
          message: sessions.errorMessage
            ?? (daemonIsRunning
              ? "Create a session to open a shell."
              : daemon.status.settingsTitle)
        )
      }
    }
  }

  @ViewBuilder
  private var terminalContent: some View {
    if let message = sessions.errorMessage, sessions.sessions.isEmpty {
      ContentUnavailableViewPlaceholder(
        title: "Couldn’t Load Sessions",
        message: message,
        systemImage: "exclamationmark.triangle"
      )
    } else if let layout = sessions.layout {
      TerminalLayoutView(layout: layout, sessions: sessions)
    } else {
      ContentUnavailableViewPlaceholder(
        title: daemonIsRunning ? "No Session Selected" : daemon.status.menuTitle,
        message: daemonIsRunning
          ? "Choose a session in the sidebar or create a new one."
          : daemon.status.settingsTitle,
        systemImage: "terminal"
      )
    }
  }
}

private struct SessionSidebarRow: View {
  let session: TerminalSession

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Label("Session \(session.id)", systemImage: "terminal")
      Text(session.initialPwd)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.leading, 22)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct TerminalLayoutView: View {
  let layout: TerminalLayout
  @ObservedObject var sessions: TerminalSessionsModel

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
        ContentUnavailableViewPlaceholder(
          title: "Shell Unavailable",
          message: "This shell is no longer open.",
          systemImage: "terminal"
        )
      }
    case .split(_, let direction, let first, let second):
      switch direction {
      case .right:
        HSplitView {
          TerminalLayoutView(layout: first, sessions: sessions)
            .frame(minWidth: 260)
          TerminalLayoutView(layout: second, sessions: sessions)
            .frame(minWidth: 260)
        }
      case .down:
        VSplitView {
          TerminalLayoutView(layout: first, sessions: sessions)
            .frame(minHeight: 180)
          TerminalLayoutView(layout: second, sessions: sessions)
            .frame(minHeight: 180)
        }
      }
    }
  }
}

private struct TerminalPaneView: View {
  let shell: TerminalShell
  let sessions: TerminalSessionsModel
  @EnvironmentObject private var ghostty: GhosttyRuntime
  @State private var terminalError: String?

  var body: some View {
    GhosttyTerminalView(
      runtime: ghostty,
      shell: shell,
      helperURL: sessions.helperURL,
      onFocus: { sessions.focus(shell.id) },
      onStatusChange: { status in
        terminalError = status.hasPrefix("Connected to ") ? nil : status
      }
    )
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

private struct ContentUnavailableViewPlaceholder: View {
  let title: String
  let message: String
  var systemImage = "terminal"

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 28))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(title)
        .font(.headline)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
    }
    .padding(24)
  }
}
