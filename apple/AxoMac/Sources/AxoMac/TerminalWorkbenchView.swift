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
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          Task { await sessions.createSession() }
        } label: {
          Label("New Session", systemImage: "plus")
        }
        .keyboardShortcut("n", modifiers: .command)
        .help("Create a new session (⌘N)")

        Button {
          Task { await sessions.split(.right) }
        } label: {
          Label("Split Right", systemImage: "rectangle.split.2x1")
        }
        .keyboardShortcut("d", modifiers: .command)
        .help("Split right (⌘D)")

        Button {
          Task { await sessions.split(.down) }
        } label: {
          Label("Split Down", systemImage: "rectangle.split.1x2")
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .help("Split down (⌘⇧D)")

        Button(role: .destructive) {
          if let selectedSessionID = sessions.selectedSessionID {
            Task { await sessions.closeSession(selectedSessionID) }
          }
        } label: {
          Label("Close Session", systemImage: "xmark")
        }
        .disabled(sessions.selectedSessionID == nil)
      }
    }
    .frame(minWidth: 760, minHeight: 480)
    .task(id: daemonIsRunning) {
      if daemonIsRunning {
        await sessions.refresh()
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
    case .pane(let sessionID):
      if let session = sessions.session(for: sessionID) {
        TerminalPaneView(
          session: session,
          sessions: sessions
        )
        .id(session.id)
      } else {
        ContentUnavailableViewPlaceholder(
          title: "Session Unavailable",
          message: "This session is no longer open.",
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
  let session: TerminalSession
  let sessions: TerminalSessionsModel
  @EnvironmentObject private var ghostty: GhosttyRuntime
  @State private var terminalStatus = "Starting libghostty…"

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Label("Session \(session.id)", systemImage: "terminal")
          .font(.headline)
        Spacer()
        Text(terminalStatus)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)

      Divider()

      GhosttyTerminalView(
        runtime: ghostty,
        session: session,
        helperURL: sessions.helperURL,
        onFocus: { sessions.focus(session.id) },
        onStatusChange: { terminalStatus = $0 }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color(nsColor: .textBackgroundColor))
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
