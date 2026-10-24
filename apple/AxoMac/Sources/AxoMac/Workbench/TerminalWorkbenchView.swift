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
  @AppStorage(AxoPreferenceKey.sidebarIsCollapsed) private var isSidebarCollapsed = false
  @State private var collapsedWorkspaceIDs = Set<String>()
  @State private var renameTarget: SidebarRenameTarget?
  @State private var renameDraft = ""
  @State private var sidebarActionError: String?

  private var daemonIsRunning: Bool {
    if let daemonIsRunningOverride { return daemonIsRunningOverride }
    if case .running = daemon.status { return true }
    return false
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
        .onGeometryChange(for: CGSize.self, of: \.size) { terminalAreaSize = $0 }
        .safeAreaInset(edge: .top, spacing: 0) {
          if daemonIsRunning, case .reconnecting(let reason) = sessions.catalogConnection {
            CatalogReconnectingBanner(reason: reason)
          }
        }
    }
    .onChange(of: OffscreenSizing(area: terminalAreaSize, scale: displayScale, layouts: openLayouts), initial: true) {
      _, sizing in
      ghostty.sizeOffscreenSurfaces(
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

  private var expandedSidebar: some View {
    let orderedSessions = sessions.sidebarOrderedSessions

    return VStack(spacing: 0) {
      WindowDragStrip()
        .frame(height: WindowDragStrip.height)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          SidebarSectionHeader(
            title: "Workspaces",
            buttonLabel: "New Workspace",
            helpText: "Create a Workspace (⌘N)",
            accessibilityIdentifier: "new-workspace-button",
            topPadding: 4
          ) {
            isPresentingWorkspaceCreation = true
          }

          ForEach(sessions.workspaces) { workspace in
            VStack(alignment: .leading, spacing: 0) {
              Group {
                if renameTarget?.id == "workspace-\(workspace.workspaceId)" {
                  SidebarInlineRenameEditor(
                    text: $renameDraft,
                    identifier: "rename-workspace-\(workspace.workspaceId)",
                    onSave: commitRename,
                    onCancel: cancelRename
                  )
                  .padding(.horizontal, 8)
                  .frame(minHeight: 28)
                } else {
                  Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                      if collapsedWorkspaceIDs.contains(workspace.id) {
                        collapsedWorkspaceIDs.remove(workspace.id)
                      } else {
                        collapsedWorkspaceIDs.insert(workspace.id)
                      }
                    }
                  } label: {
                    HStack(spacing: 6) {
                      Image(systemName: collapsedWorkspaceIDs.contains(workspace.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                      Text(workspace.name)
                        .font(.system(size: 13, weight: .medium))
                      Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel(workspace.name)
                  .accessibilityValue(collapsedWorkspaceIDs.contains(workspace.id) ? "Collapsed" : "Expanded")
                  .accessibilityIdentifier("workspace-row-\(workspace.workspaceId)")
                }
              }
              .contextMenu {
                Button("New Session in Workspace") {
                  Task { await sessions.createSession(in: workspace.workspaceId) }
                }
                Divider()
                Button("Rename Workspace") {
                  beginRenaming(.workspace(workspace))
                }
                Button("Archive Workspace and Sessions", role: .destructive) {
                  archiveWorkspaceFromMenu(workspace)
                }
              }

              if !collapsedWorkspaceIDs.contains(workspace.id) {
                ForEach(
                  orderedSessions.filter { $0.workspaceId == workspace.workspaceId }
                ) { session in
                  sessionButton(for: session)
                }
              }
            }
          }

          SidebarSectionHeader(
            title: "Sessions",
            buttonLabel: "New Session",
            helpText: "Create a Session in the selected Workspace, or in your home directory (⌘T)",
            accessibilityIdentifier: "new-session-button",
            topPadding: 8
          ) {
            Task { await sessions.createSession() }
          }

          ForEach(orderedSessions.filter { $0.workspaceId == nil }) { session in
            sessionButton(for: session)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .overlay {
        if sessions.workspaces.isEmpty && sessions.sessions.isEmpty {
          ContentUnavailableView(
            daemonIsRunning ? "No Sessions" : "axod is not running",
            systemImage: "terminal",
            description: Text(
              sessions.errorMessage
                ?? (daemonIsRunning
                  ? "Create a Workspace or Session to get started."
                  : daemon.status.settingsTitle))
          )
        }
      }

      if let error = sidebarActionError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .accessibilityIdentifier("sidebar-action-error")
      }

      if let error = sessions.workspaceCreationError {
        HStack(alignment: .top, spacing: 8) {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button {
            sessions.dismissWorkspaceCreationError()
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Dismiss Workspace creation error")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .accessibilityIdentifier("workspace-creation-error")
      }

      sidebarToggle(isCollapsed: false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
    .frame(width: 220)
    .frame(maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func sessionButton(for session: TerminalSession) -> some View {
    Group {
      if renameTarget?.id == "session-\(session.id)" {
        SidebarInlineRenameEditor(
          text: $renameDraft,
          identifier: "rename-session-\(session.id)",
          onSave: commitRename,
          onCancel: cancelRename
        )
        .padding(.horizontal, 8)
        .frame(minHeight: 36)
      } else {
        Button {
          sessions.showSession(session.id)
        } label: {
          SessionSidebarRow(
            session: session,
            isSelected: sessions.selectedSessionID == session.id
          )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("session-row-\(session.id)")
      }
    }
    .contextMenu {
      sessionContextMenu(for: session)
    }
  }

  @ViewBuilder
  private func sessionContextMenu(for session: TerminalSession) -> some View {
    Button("Rename Session") {
      beginRenaming(.session(session))
    }
    Divider()
    Button("Archive Session", role: .destructive) {
      archiveSessionFromMenu(session)
    }
  }

  private func beginRenaming(_ target: SidebarRenameTarget) {
    sidebarActionError = nil
    if isSidebarCollapsed { isSidebarCollapsed = false }
    renameDraft = target.name
    renameTarget = target
  }

  private func cancelRename() {
    renameTarget = nil
    renameDraft = ""
  }

  private func commitRename() {
    guard let target = renameTarget else { return }
    let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.utf16.count <= 80 else {
      sidebarActionError = "Names must contain 1–80 characters."
      return
    }

    Task {
      do {
        switch target {
        case .session(let session):
          try await sessions.renameSession(session.id, to: name)
        case .workspace(let workspace):
          try await sessions.renameWorkspace(workspace.workspaceId, to: name)
        }
        cancelRename()
        sidebarActionError = nil
      } catch {
        sidebarActionError = error.localizedDescription
      }
    }
  }

  private func archiveSessionFromMenu(_ session: TerminalSession) {
    Task {
      await sessions.requestCloseSession(session.id)
      sidebarActionError = sessions.errorMessage
    }
  }

  private func archiveWorkspaceFromMenu(_ workspace: WorkspaceRecord) {
    Task {
      do {
        try await sessions.archiveWorkspace(workspace.workspaceId)
        sidebarActionError = nil
      } catch {
        sidebarActionError = error.localizedDescription
      }
    }
  }

  private var collapsedSidebar: some View {
    VStack(spacing: 0) {
      WindowDragStrip()
        .frame(height: WindowDragStrip.height)
      ScrollView {
        VStack(spacing: 4) {
          ForEach(sessions.sidebarOrderedSessions) { session in
            CollapsedSessionButton(
              session: session,
              isSelected: sessions.selectedSessionID == session.id,
              onSelect: { sessions.showSession(session.id) }
            )
            .contextMenu {
              sessionContextMenu(for: session)
            }
          }
        }
        .padding(.horizontal, 8)
      }

      if let sidebarActionError {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .help(sidebarActionError)
          .accessibilityLabel(sidebarActionError)
      }
      Spacer(minLength: 0)
      sidebarToggle(isCollapsed: true)
    }
    .padding(.bottom, 6)
    .frame(width: WindowDragStrip.minimumSidebarWidth)
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

  private var openLayouts: [SessionLayout] { sessions.sessions.compactMap(\.layout) }

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
    if let message = sessions.errorMessage, sessions.sessions.isEmpty {
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
