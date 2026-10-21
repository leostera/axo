import AppKit
import AxoDaemonManager
import AxoRPC
import SwiftUI
import UniformTypeIdentifiers

struct TerminalWorkbenchView: View {
  @ObservedObject var daemon: DaemonController
  @ObservedObject var sessions: TerminalSessionsModel
  @Binding var isPresentingWorkspaceCreation: Bool
  var daemonIsRunningOverride: Bool? = nil
  @EnvironmentObject private var ghostty: GhosttyRuntime
  @AppStorage("terminalSidebarIsCollapsed.v2") private var isSidebarCollapsed = false
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
    }
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
    let orderedSessions = sessions.sidebarOrderedSessions

    return VStack(spacing: 0) {
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
          ContentUnavailableViewPlaceholder(
            title: daemonIsRunning ? "No Sessions" : "axod is not running",
            message: sessions.errorMessage
              ?? (daemonIsRunning
                ? "Create a Workspace or Session to get started."
                : daemon.status.settingsTitle)
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
      ScrollView {
        VStack(spacing: 4) {
          ForEach(sessions.sidebarOrderedSessions) { session in
            Button {
              sessions.showSession(session.id)
            } label: {
              ZStack(alignment: .bottomTrailing) {
                sessionGlyph(for: session, size: 15)
                Image(systemName: sidebarStatus(for: session).symbolName)
                  .font(.system(size: 8, weight: .bold))
                  .foregroundStyle(sidebarStatus(for: session).color)
                  .background(Color(nsColor: .windowBackgroundColor), in: Circle())
              }
              .frame(width: 36, height: 36)
              .background(
                sessions.selectedSessionID == session.id
                  ? Color.accentColor.opacity(0.18)
                  : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
              )
            }
            .buttonStyle(.plain)
            .help(session.displayName)
            .accessibilityLabel("\(session.displayName), \(sidebarStatus(for: session).accessibilityDescription)")
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
    .padding(.vertical, 6)
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

private enum SidebarRenameTarget: Identifiable {
  case session(TerminalSession)
  case workspace(WorkspaceRecord)

  var id: String {
    switch self {
    case .session(let session): "session-\(session.id)"
    case .workspace(let workspace): "workspace-\(workspace.workspaceId)"
    }
  }

  var name: String {
    switch self {
    case .session(let session): session.displayName
    case .workspace(let workspace): workspace.name
    }
  }
}

private struct SidebarInlineRenameEditor: View {
  @Binding var text: String
  let identifier: String
  let onSave: () -> Void
  let onCancel: () -> Void
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 6) {
      TextField("Name", text: $text)
        .textFieldStyle(.plain)
        .lineLimit(1)
        .focused($isFocused)
        .onSubmit(onSave)
        .onExitCommand(perform: onCancel)
        .accessibilityIdentifier(identifier)

      Button(action: onSave) {
        Image(systemName: "checkmark")
      }
      .buttonStyle(.plain)
      .help("Save name")
      .accessibilityLabel("Save name")
      .accessibilityIdentifier("inline-rename-save")

      Button(action: onCancel) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .help("Cancel rename")
      .accessibilityLabel("Cancel rename")
      .accessibilityIdentifier("inline-rename-cancel")
    }
    .onAppear { isFocused = true }
  }
}

private struct WorkspaceCreationSheet: View {
  @ObservedObject var sessions: TerminalSessionsModel
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var directoryURL: URL?
  @State private var isChoosingDirectory = false
  @State private var isCreating = false
  @State private var directorySelectionError: String?

  private var normalizedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New Workspace")
        .font(.title2.weight(.semibold))

      TextField("Workspace name", text: $name)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("workspace-name-field")

      VStack(alignment: .leading, spacing: 8) {
        Text("Directory")
          .font(.headline)
        HStack(spacing: 10) {
          Text(directoryURL?.path ?? "Choose a folder for this Workspace.")
            .font(.callout)
            .foregroundStyle(directoryURL == nil ? .secondary : .primary)
            .lineLimit(2)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button("Choose Directory…") {
            isChoosingDirectory = true
          }
          .accessibilityIdentifier("workspace-choose-directory-button")
        }
      }

      if let error = sessions.workspaceCreationError ?? directorySelectionError {
        VStack(alignment: .leading, spacing: 8) {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("workspace-creation-form-error")
        }
      }

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button(isCreating ? "Creating…" : "Create Workspace") {
          createWorkspace()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isCreating || normalizedName.isEmpty || directoryURL == nil)
      }
    }
    .padding(20)
    .frame(width: 440)
    .fileImporter(
      isPresented: $isChoosingDirectory,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        directoryURL = urls.first?.standardizedFileURL
        directorySelectionError = nil
      case .failure(let error):
        directorySelectionError = error.localizedDescription
      }
    }
    .onAppear {
      sessions.dismissWorkspaceCreationError()
    }
  }

  private func createWorkspace() {
    guard let directoryURL else { return }
    Task {
      isCreating = true
      let hasScopedAccess = directoryURL.startAccessingSecurityScopedResource()
      defer {
        if hasScopedAccess { directoryURL.stopAccessingSecurityScopedResource() }
        isCreating = false
      }
      let directoryBookmark = try? directoryURL.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      ).base64EncodedString()
      await sessions.createWorkspace(
        name: normalizedName,
        directoryPath: directoryURL.path,
        directoryBookmark: directoryBookmark
      )
      if sessions.workspaceCreationError == nil {
        dismiss()
      }
    }
  }
}

private struct SidebarSectionHeader: View {
  let title: String
  let buttonLabel: String
  let helpText: String
  let accessibilityIdentifier: String
  let topPadding: CGFloat
  let action: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
      Button(action: action) {
        Image(systemName: "plus")
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 18, height: 18)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(helpText)
      .accessibilityLabel(buttonLabel)
      .accessibilityIdentifier(accessibilityIdentifier)
    }
    .padding(.horizontal, 8)
    .padding(.top, topPadding)
    .padding(.bottom, 2)
    .frame(height: 22 + topPadding)
  }
}

private struct SessionSidebarRow: View {
  let session: TerminalSession
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: sidebarStatus(for: session).symbolName)
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(sidebarStatus(for: session).color)
        .frame(width: 9)
      sessionGlyph(for: session, size: 12)
        .frame(width: 14)
      Text(session.displayName)
        .font(.system(size: 12))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .padding(.leading, 6)
    .padding(.trailing, 8)
    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
    .background(
      isSelected ? Color.accentColor.opacity(0.16) : .clear,
      in: RoundedRectangle(cornerRadius: 4)
    )
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(session.displayName), \(sidebarStatus(for: session).accessibilityDescription)")
  }
}

private func sidebarStatus(for session: TerminalSession) -> TerminalSessionStatus {
  session.status ?? (session.shells.contains(where: { $0.role == "pi" }) ? .starting : .ready)
}

@ViewBuilder
private func sessionGlyph(for session: TerminalSession, size: CGFloat) -> some View {
  if let emoji = session.emoji {
    Text(emoji)
      .font(.system(size: size))
  } else {
    Image(systemName: session.shells.contains(where: { $0.role == "pi" }) ? "sparkle" : "terminal")
      .font(.system(size: size))
      .foregroundStyle(.secondary)
  }
}

private extension TerminalSessionStatus {
  var symbolName: String {
    switch self {
    case .starting, .unavailable: "circle.dotted"
    case .ready: "circle.fill"
    case .working: "hammer.fill"
    case .needsAttention: "exclamationmark.triangle.fill"
    }
  }

  var color: Color {
    switch self {
    case .starting, .unavailable: .secondary
    case .ready: .green
    case .working: .accentColor
    case .needsAttention: .yellow
    }
  }

  var accessibilityDescription: String {
    switch self {
    case .starting: "starting"
    case .ready: "ready"
    case .working: "working"
    case .needsAttention: "needs attention"
    case .unavailable: "unavailable"
    }
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
  @State private var piRestartError: String?
  @State private var isRestartingPi = false

  @ViewBuilder
  var body: some View {
    if !shell.isAvailable {
      VStack(spacing: 12) {
        ContentUnavailableViewPlaceholder(
          title: "Pi Session Unavailable",
          message: shell.availabilityReason
            ?? "Axo could not recover this Pi session. Its conversation history is preserved.",
          systemImage: "exclamationmark.triangle"
        )
        Text("Restarting stops the Pi process attached to this pane and starts it again from its existing conversation history.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 400)
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
    } else {
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
