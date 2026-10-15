import AxoDaemonManager
import AxoRPC
import SwiftUI

struct TerminalWorkbenchView: View {
  @ObservedObject var daemon: DaemonController
  @ObservedObject var sessions: TerminalSessionsModel
  var daemonIsRunningOverride: Bool? = nil
  @EnvironmentObject private var ghostty: GhosttyRuntime
  @AppStorage("terminalSidebarIsCollapsed") private var isSidebarCollapsed = true

  private var daemonIsRunning: Bool {
    if let daemonIsRunningOverride { return daemonIsRunningOverride }
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
    HStack(spacing: 0) {
      if isSidebarCollapsed {
        collapsedSidebar
      } else {
        expandedSidebar
      }

      Divider()

      terminalContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 760, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
    .task(id: daemonIsRunning) {
      guard daemonIsRunning else {
        ghostty.reconcileSurfaces(with: [])
        return
      }
      while !Task.isCancelled {
        await sessions.refresh()
        ghostty.reconcileSurfaces(with: sessions.sessions.flatMap(\.shells))
        try? await Task.sleep(for: .seconds(1))
      }
    }
    .task(id: sessions.focusedShellID) {
      guard let focusedShellID = sessions.focusedShellID else {
        ghostty.setFocusedShellID(nil)
        return
      }
      ghostty.setFocusedShellID(focusedShellID)
      for _ in 0..<40 {
        if ghostty.focusSurface(for: focusedShellID) { return }
        try? await Task.sleep(for: .milliseconds(25))
      }
    }
  }

  private var expandedSidebar: some View {
    VStack(spacing: 0) {
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

      sidebarToggle(isCollapsed: false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
    .frame(width: 220)
    .frame(maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var collapsedSidebar: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(spacing: 8) {
          ForEach(sessions.sessions) { session in
            Button {
              sessions.showSession(session.id)
            } label: {
              Image(systemName: "terminal")
                .frame(width: 36, height: 36)
                .background(
                  sessions.selectedSessionID == session.id
                    ? Color.accentColor.opacity(0.18)
                    : Color.clear,
                  in: RoundedRectangle(cornerRadius: 8)
                )
            }
            .buttonStyle(.plain)
            .help("Session \(session.id)")
            .accessibilityLabel("Session \(session.id)")
            .contextMenu {
              Button("Close Session", role: .destructive) {
                Task { await sessions.closeSession(session.id) }
              }
            }
          }
        }
        .padding(.horizontal, 10)
      }

      Spacer(minLength: 0)
      sidebarToggle(isCollapsed: true)
    }
    .padding(.vertical, 8)
    .frame(width: 56)
    .frame(maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func sidebarToggle(isCollapsed: Bool) -> some View {
    Button {
      withAnimation(.easeInOut(duration: 0.18)) {
        isSidebarCollapsed.toggle()
      }
    } label: {
      Image(systemName: isCollapsed ? "sidebar.right" : "sidebar.left")
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
    .accessibilityLabel(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
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
        .id(layout.structuralIdentity)
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
    case .split(let id, let direction, let ratio, let first, let second):
      TerminalSplitView(
        id: id,
        direction: direction,
        ratio: ratio,
        onRatioChange: { sessions.resizeSplit(id, to: $0) },
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

private struct TerminalPaneView: View {
  let shell: TerminalShell
  let sessions: TerminalSessionsModel
  @EnvironmentObject private var ghostty: GhosttyRuntime
  @State private var terminalError: String?

  var body: some View {
    GeometryReader { geometry in
      GhosttyTerminalView(
        runtime: ghostty,
        shell: shell,
        helperURL: sessions.helperURL,
        size: geometry.size,
        isFocused: sessions.focusedShellID == shell.id,
        onFocus: { sessions.focus(shell.id) },
        onStatusChange: { status in
          terminalError = status.hasPrefix("Connected to ") ? nil : status
        }
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
