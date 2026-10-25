import AppKit
import AxoDaemonManager
import AxoRPC
import SwiftUI

struct TerminalWorkbenchView: View {
  var daemon: DaemonController
  var sessions: TerminalSessionsModel
  @Binding var isPresentingWorkspaceCreation: Bool
  var daemonIsRunningOverride: Bool? = nil
  @Environment(GhosttyRuntime.self) private var ghostty
  @Environment(\.displayScale) private var displayScale
  @State private var terminalAreaSize: CGSize = .zero

  private var daemonIsRunning: Bool {
    if let daemonIsRunningOverride { return daemonIsRunningOverride }
    if case .running = daemon.status { return true }
    return false
  }

  var body: some View {
    HStack(spacing: 0) {
      // Its own view: Session status and names change on every Pi turn, and only the sidebar
      // presents them. The terminal area reads pane-level projections that those leave alone.
      WorkbenchSidebar(
        daemon: daemon,
        sessions: sessions,
        isPresentingWorkspaceCreation: $isPresentingWorkspaceCreation,
        daemonIsRunning: daemonIsRunning)

      Divider()

      terminalContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self, of: \.size) { terminalAreaSize = $0 }
        .safeAreaInset(edge: .top, spacing: 0) {
          if daemonIsRunning, case .reconnecting(let reason) = sessions.catalogConnection {
            CatalogReconnectingBanner(reason: reason)
          }
        }
    }
    .onChange(of: OffscreenSizing(area: terminalAreaSize, scale: displayScale, layouts: sessions.sessionLayouts), initial: true) {
      _, sizing in
      ghostty.surfaces.scheduleOffscreenSizing(
        layouts: sizing.layouts.map(TerminalLayout.init),
        terminalAreaSize: sizing.area,
        backingScale: sizing.scale)
    }
    .onChange(of: ViewportReport(area: terminalAreaSize, scale: displayScale, cell: ghostty.cellPixelSize), initial: true) {
      _, report in
      if let viewport = ghostty.viewport(terminalAreaSize: report.area, backingScale: report.scale) {
        sessions.reportViewport(viewport)
      }
    }
    // Full-height content: the terminal reaches the window's top edge; the sidebar's
    // WindowDragStrip stands in for the hidden title bar.
    .ignoresSafeArea(.container, edges: .top)
    .frame(minWidth: 760, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
    .sheet(isPresented: $isPresentingWorkspaceCreation) {
      WorkspaceCreationSheet(sessions: sessions)
    }
    .confirmationDialog(
      "Archive \(sessions.pendingWorkspaceArchiveConfirmation?.workspaceName ?? "Workspace")?",
      isPresented: Binding(
        get: { sessions.pendingWorkspaceArchiveConfirmation != nil },
        set: { isPresented in
          if !isPresented { sessions.cancelWorkspaceArchiveConfirmation() }
        }
      ),
      titleVisibility: .visible
    ) {
      Button("Archive Workspace and Sessions", role: .destructive) {
        guard let confirmation = sessions.pendingWorkspaceArchiveConfirmation else { return }
        Task { await sessions.confirmWorkspaceArchiveAndCloseSession(confirmation) }
      }
      .accessibilityIdentifier("confirm-archive-workspace-last-session")

      Button("Cancel", role: .cancel) {
        sessions.cancelWorkspaceArchiveConfirmation()
      }
    } message: {
      if let confirmation = sessions.pendingWorkspaceArchiveConfirmation {
        Text(
          "This is the last Session in “\(confirmation.workspaceName)”. "
            + "Archiving this Workspace will close its Sessions and preserve their histories."
        )
      }
    }
    .confirmationDialog(
      "Close this pane?",
      isPresented: Binding(
        get: { sessions.pendingShellCloseConfirmation != nil },
        set: { isPresented in
          if !isPresented { sessions.cancelShellCloseConfirmation() }
        }
      ),
      titleVisibility: .visible,
      presenting: sessions.pendingShellCloseConfirmation
    ) { confirmation in
      Button("Close Pane", role: .destructive) {
        Task { await sessions.confirmShellClose(confirmation) }
      }
      .keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("confirm-close-busy-shell")
      Button("Cancel", role: .cancel) {
        sessions.cancelShellCloseConfirmation()
      }
    } message: { confirmation in
      Text(confirmation.reason.message)
    }
  }

  /// What offscreen panes are sized from: the terminal area, its scale, and every Session's layout.
  private struct OffscreenSizing: Equatable {
    var area: CGSize
    var scale: CGFloat
    var layouts: [SessionLayout]
  }

  /// What Axod sizes unshown panes from: the terminal area, its scale, and the cell size.
  private struct ViewportReport: Equatable {
    var area: CGSize
    var scale: CGFloat
    var cell: ClientViewport.PixelSize?
  }

  private var presentedTerminalLayout: TerminalLayoutPresentation? {
    guard let layout = sessions.layout else { return nil }
    let presentation = TerminalLayoutPresentation(layout)
    guard let pending = sessions.pendingTerminalSplit,
      pending.sessionID == sessions.selectedSessionID
    else { return presentation }
    return presentation.inserting(pending) ?? presentation
  }

  @ViewBuilder
  private var terminalContent: some View {
    if let message = sessions.errorMessage, !sessions.hasSessions {
      ContentUnavailableView(
        "Couldn’t Load Sessions", systemImage: "exclamationmark.triangle",
        description: Text(message))
    } else if let layout = presentedTerminalLayout {
      TerminalLayoutView(layout: layout, sessions: sessions)
        .id(layout.structuralIdentity)
    } else {
      ContentUnavailableView(
        daemonIsRunning ? "No Session Selected" : daemon.status.menuTitle,
        systemImage: "terminal",
        description: Text(
          daemonIsRunning
            ? "Choose a session in the sidebar or create a new one."
            : daemon.status.settingsTitle))
    }
  }
}

/// Shown while the catalog stream is down, so stale Sessions never look live.
private struct CatalogReconnectingBanner: View {
  let reason: String

  var body: some View {
    Label {
      Text("Lost connection to axod. Reconnecting… (\(reason))")
        .lineLimit(1)
        .truncationMode(.tail)
    } icon: {
      ProgressView().controlSize(.small)
    }
    .font(.caption)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.yellow.opacity(0.18))
    .accessibilityIdentifier("catalog-reconnecting")
  }
}

extension ShellCloseConfirmation.Reason {
  var message: String {
    switch self {
    case .runningProcess(let name?):
      "“\(name)” is still running in this pane. Closing it will terminate the process."
    case .runningProcess(nil):
      "A process is still running in this pane. Closing it will terminate the process."
    case .piWorking:
      "Pi is working on a turn. Closing this pane stops it; the conversation history is preserved."
    case .unknown:
      "Axo couldn’t check whether this pane is running something. Closing it will terminate anything still running."
    }
  }
}
