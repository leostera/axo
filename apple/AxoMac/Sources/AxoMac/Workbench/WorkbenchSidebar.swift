import AxoProtocol
import SwiftUI

/// The Session list, latest activity first, of this Mac, another Mac, or all of them (RFD0024);
/// expanded or collapsed, with inline renaming.
struct WorkbenchSidebar: View {
  var sessions: TerminalSessionsModel
  @Binding var isPresentingWorkspaceCreation: Bool
  @AppStorage(AxoPreferenceKey.sidebarIsCollapsed) private var isSidebarCollapsed = false
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
    VStack(spacing: 0) {
      WindowDragStrip()
        .frame(height: WindowDragStrip.height)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          SidebarHeader(
            title: sessions.sidebarMacsTitle,
            selection: sessions.sidebarMacs,
            hosts: sessions.peerHosts,
            topPadding: 4,
            onSelect: { macs in
              withAnimation(.easeInOut(duration: 0.15)) { sessions.setSidebarMacs(macs) }
            },
            onNewWorkspace: { isPresentingWorkspaceCreation = true })

          recentList
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .overlay {
        if sessions.sidebarOrderedSessions.isEmpty {
          ContentUnavailableView(
            "No Sessions", systemImage: "terminal",
            description: Text(
              sessions.errorMessage
                ?? (sessions.sidebarMacs == .thisMac
                  ? "Create a Workspace or Session to get started."
                  : "No Sessions on \(sessions.sidebarMacsTitle).")))
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

  /// Every listed Session, latest activity first, without Workspaces: the project keyword at the
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
              showsAge: showsAge,
              hostLabel: sessions.sidebarMacs == .all ? sessions.hostLabel(for: session.id) : nil
            )
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("session-row-\(session.id)")

          let isPinned = sessions.isPinned(session.id)
          if isPinned || hoveredSessionID == session.id {
            SessionPinButton(sessionID: session.id, isPinned: isPinned) {
              withAnimation(.easeInOut(duration: 0.2)) { sessions.togglePin(session.id) }
            }
          }

          if hoveredSessionID == session.id, !sessions.isPeerSession(session.id) {
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
    Button(sessions.isPinned(session.id) ? "Unpin Session" : "Pin Session") {
      withAnimation(.easeInOut(duration: 0.2)) { sessions.togglePin(session.id) }
    }
    Button("Copy Session Info") {
      SessionInfo.copy(session, hostLabel: sessions.hostLabel(for: session.id))
    }
    Divider()
    if let host = sessions.hostLabel(for: session.id) {
      // Another Mac's Session: only this Mac's pane on it is this Mac's to close.
      Text("Runs on \(host)")
      if !session.shells.isEmpty {
        Button("Close on This Mac") {
          Task { await sessions.closePeerPane(session.id) }
        }
      }
    } else {
      Button("Rename Session") {
        beginRenaming(.session(session))
      }
      Divider()
      Button("Archive Session", role: .destructive) {
        archiveSessionFromMenu(session)
      }
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

  private var collapsedSidebar: some View {
    VStack(spacing: 0) {
      WindowDragStrip()
        .frame(height: WindowDragStrip.height)
      ScrollView {
        VStack(spacing: 0) {
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
        .padding(.horizontal, 4)
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
