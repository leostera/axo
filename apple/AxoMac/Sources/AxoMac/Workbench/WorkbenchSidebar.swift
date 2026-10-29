import AxoProtocol
import SwiftUI

/// The Workspace and Session list, expanded or collapsed, with inline renaming.
struct WorkbenchSidebar: View {
  var sessions: TerminalSessionsModel
  @Binding var isPresentingWorkspaceCreation: Bool
  @AppStorage(AxoPreferenceKey.sidebarIsCollapsed) private var isSidebarCollapsed = false
  @State private var collapsedWorkspaceIDs = Set<String>()
  @State private var renameTarget: SidebarRenameTarget?
  @State private var renameDraft = ""
  @State private var hoveredSessionID: SessionID?
  @State private var sidebarActionError: String?

  var body: some View {
    if isSidebarCollapsed {
      collapsedSidebar
    } else {
      expandedSidebar
    }
  }

  private var expandedSidebar: some View {
    let sections = sessions.sidebarSections

    return VStack(spacing: 0) {
      WindowDragStrip()
        .frame(height: WindowDragStrip.height)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          SidebarHeader(
            mode: sessions.sidebarMode,
            topPadding: 4,
            onSelectMode: { mode in
              withAnimation(.easeInOut(duration: 0.15)) { sessions.setSidebarMode(mode) }
            },
            onNewWorkspace: { isPresentingWorkspaceCreation = true })

          switch sessions.sidebarMode {
          case .workspaces: workspaceTree(sections)
          case .recent: recentList
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .overlay {
        if sessions.workspaces.isEmpty && !sessions.hasSessions {
          ContentUnavailableView(
            "No Sessions", systemImage: "terminal",
            description: Text(sessions.errorMessage ?? "Create a Workspace or Session to get started."))
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

  @ViewBuilder
  private func workspaceTree(_ sections: SidebarSections) -> some View {
    ForEach(sessions.workspaces) { workspace in
            VStack(alignment: .leading, spacing: 0) {
              Group {
                if renameTarget?.id == .workspace(workspace.workspaceId) {
                  SidebarInlineRenameEditor(
                    text: $renameDraft,
                    identifier: "rename-workspace-\(workspace.workspaceId)",
                    onSave: commitRename,
                    onCancel: cancelRename
                  )
                  .padding(.horizontal, 8)
                  .frame(minHeight: 28)
                } else {
                  HStack(spacing: 0) {
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
                    Button {
                      Task { await sessions.createSession(in: workspace.workspaceId) }
                    } label: {
                      Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                    .help("New Session in \(workspace.name) (⌘T)")
                    .accessibilityLabel("New Session in \(workspace.name)")
                    .accessibilityIdentifier("new-session-button-\(workspace.workspaceId)")
                  }
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
                if !workspace.isHome {
                  Button("Archive Workspace and Sessions", role: .destructive) {
                    archiveWorkspaceFromMenu(workspace)
                  }
                }
              }

              if !collapsedWorkspaceIDs.contains(workspace.id) {
                ForEach(sections.sessions(in: workspace.workspaceId)) { session in
                  sessionButton(for: session)
                }
              }
            }
    }
  }

  /// Every open Session, latest activity first, without Workspaces: the project keyword at the
  /// front of each title says what it is about. Rows hold still while the pointer is over
  /// the list and move when it leaves.
  private var recentList: some View {
    let shown = sessions.sidebarOrderedSessions
    return VStack(alignment: .leading, spacing: 0) {
      ForEach(shown) { session in
        sessionButton(for: session, showsAge: true)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: shown.map(\.id))
    .onHover { sessions.holdRecentOrder($0) }
  }

  private func sessionButton(for session: TerminalSession, showsAge: Bool = false) -> some View {
    Group {
      if renameTarget?.id == .session(session.id) {
        SidebarInlineRenameEditor(
          text: $renameDraft,
          identifier: "rename-session-\(session.id)",
          onSave: commitRename,
          onCancel: cancelRename
        )
        .padding(.horizontal, 8)
        .frame(minHeight: 36)
      } else {
        HStack(spacing: 0) {
          Button {
            sessions.showSession(session.id)
          } label: {
            SessionSidebarRow(
              session: session,
              isSelected: sessions.selectedSessionID == session.id,
              showsAge: showsAge
            )
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("session-row-\(session.id)")

          if hoveredSessionID == session.id {
            Button { beginRenaming(.session(session)) } label: {
              Image(systemName: "pencil")
                .font(.system(size: 10, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Rename Session")
            .accessibilityLabel("Rename Session")
            .accessibilityIdentifier("rename-session-button-\(session.id)")
          }
        }
        .onHover { hovering in
          withAnimation(.easeOut(duration: 0.12)) {
            if hovering {
              hoveredSessionID = session.id
            } else if hoveredSessionID == session.id {
              hoveredSessionID = nil
            }
          }
        }
        .help(session.displayName)
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
}
