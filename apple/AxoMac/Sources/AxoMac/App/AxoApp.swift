import AppKit
import AxoDaemonManager
import AxoProtocol
import SwiftUI

struct AxoApp<Launch: AxoLaunchMode>: App {
  @State private var daemon: DaemonController
  @State private var sessions: TerminalSessionsModel
  @NSApplicationDelegateAdaptor(AxoURLSchemeDelegate.self) private var urlSchemeDelegate
  @State private var ghostty: GhosttyRuntime
  @State private var sleepPrevention: SleepPreventionController
  @State private var mascot: AxoMascot
  @State private var pairingLink = PairingLinkRouter.shared
  @State private var settingsSection = SettingsSection.general
  @State private var isPresentingWorkspaceCreation = false
  @State private var palette = CommandPaletteModel()
  @AppStorage(AxoPreferenceKey.appearanceTheme) private var appearanceTheme: AppearanceTheme = .system
  @AppStorage(AxoPreferenceKey.sidebarIsCollapsed) private var isSidebarCollapsed = false
  private let environment: AxoAppEnvironment
  private let workbench: AxoWorkbench

  init() {
    let daemon = DaemonController()
    let environment = Launch.environment(daemon: daemon)
    let ghostty = GhosttyRuntime()
    _daemon = State(initialValue: daemon)
    _sessions = State(initialValue: environment.sessions)
    _ghostty = State(initialValue: ghostty)
    _sleepPrevention = State(initialValue: SleepPreventionController())
    let mascot = AxoMascot()
    mascot.start(animatesDockIcon: true)
    _mascot = State(initialValue: mascot)
    self.environment = environment
    TerminalWindowOpener.heldForSplash = environment.opensTerminalWindow && environment.showsLaunchSplash
    // App.init runs once per process; the workbench owns the catalog and focus loops.
    workbench = AxoWorkbench(
      sessions: environment.sessions,
      ghostty: ghostty,
      daemonIsRunning: environment.daemonIsRunning,
      daemonUnreachable: environment.daemonUnreachable)
    if environment.startsDaemon {
      daemon.startIfNeeded()
    }
  }

  // Custom SwiftUI menu actions must preserve AppKit editing for non-terminal responders.
  @MainActor
  private func routeTextEditingCommand(
    _ responderAction: Selector,
    terminalAction: () -> Void
  ) {
    guard ghostty.keyWindowFocusedShellID == nil else {
      terminalAction()
      return
    }
    _ = NSApp.sendAction(responderAction, to: nil, from: nil)
  }

  /// Whether the terminal comes up by way of the launch splash.
  private var usesSplash: Bool { environment.opensTerminalWindow && environment.showsLaunchSplash }

  var body: some Scene {
    MenuBarExtra {
      AxoMenu(daemon: daemon, settingsSection: $settingsSection, usesSplash: usesSplash)
    } label: {
      AxoMenuBarLabel(
        mascot: mascot,
        pairingLink: pairingLink,
        settingsSection: $settingsSection,
        opensTerminalWindow: environment.opensTerminalWindow,
        usesSplash: usesSplash)
    }
    .menuBarExtraStyle(.menu)

    Window("Axo", id: LaunchSplashView.windowID) {
      LaunchSplashView(
        daemon: daemon, sessions: sessions, daemonIsRunning: environment.daemonIsRunning,
        enabled: usesSplash)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentSize)
    .defaultPosition(.center)

    Window("Axo Terminal", id: TerminalWindowOpener.windowID) {
      TerminalAppWindow(
        daemon: daemon,
        sessions: sessions,
        ghostty: ghostty,
        settingsSection: $settingsSection,
        pairingLink: pairingLink,
        isPresentingWorkspaceCreation: $isPresentingWorkspaceCreation,
        palette: palette,
        isDaemonRunningOverride: environment.startsDaemon ? nil : true
      )
      .background {
        if usesSplash { SplashHoldOpener(daemonIsRunning: environment.daemonIsRunning) }
      }
      .preferredColorScheme(appearanceTheme.colorScheme)
      .task { await environment.prepareTerminalWindow(sessions, ghostty) }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1000, height: 680)
    .commands {
      AxoApplicationCommands(settingsSection: $settingsSection)

      CommandGroup(replacing: .textEditing) {
        Button("Undo") {
          routeTextEditingCommand(Selector(("undo:"))) { _ = ghostty.perform(.undo) }
        }
        .keyboardShortcut("z", modifiers: .command)

        Button("Redo") {
          routeTextEditingCommand(Selector(("redo:"))) { _ = ghostty.perform(.redo) }
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])

        Divider()

        Button("Select All") {
          routeTextEditingCommand(#selector(NSText.selectAll(_:))) {
            _ = ghostty.perform(.selectAll)
          }
        }
        .keyboardShortcut("a", modifiers: .command)

        Divider()
        Button("Find…") { ghostty.performFind(.start) }
          .keyboardShortcut("f", modifiers: .command)
        Button("Find Next") { ghostty.performFind(.next) }
          .keyboardShortcut("g", modifiers: .command)
        Button("Find Previous") { ghostty.performFind(.previous) }
          .keyboardShortcut("g", modifiers: [.command, .shift])
        Button("Use Selection for Find") { ghostty.performFind(.selection) }
          .keyboardShortcut("e", modifiers: .command)
      }

      CommandGroup(replacing: .pasteboard) {
        Button("Cut") {
          routeTextEditingCommand(#selector(NSText.cut(_:))) {
            ghostty.copySelection()
          }
        }
        .keyboardShortcut("x", modifiers: .command)

        Button("Copy") {
          routeTextEditingCommand(#selector(NSText.copy(_:))) {
            ghostty.copySelection()
          }
        }
        .keyboardShortcut("c", modifiers: .command)

        Button("Paste") {
          routeTextEditingCommand(#selector(NSText.paste(_:))) {
            ghostty.pasteClipboard()
          }
        }
        .keyboardShortcut("v", modifiers: .command)

        Button("Paste and Match Style") {
          routeTextEditingCommand(#selector(NSText.paste(_:))) {
            ghostty.pasteClipboard()
          }
        }
        .keyboardShortcut("v", modifiers: [.command, .option, .shift])
      }

      WorkbenchViewCommands(
        palette: palette, sessions: sessions, isSidebarCollapsed: $isSidebarCollapsed)

      CommandMenu("Terminal") {
        Button("New Workspace…") {
          isPresentingWorkspaceCreation = true
        }
        .keyboardShortcut("n", modifiers: .command)

        Button("New Session") {
          Task { await sessions.createSessionInCurrentContext() }
        }
        .keyboardShortcut("t", modifiers: .command)

        Button("Split Right") {
          Task { await sessions.split(.right) }
        }
        .keyboardShortcut("d", modifiers: .command)

        Button("Split Down") {
          Task { await sessions.split(.down) }
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])

        Divider()

        Button("Previous Pane") {
          sessions.focusPreviousPane()
        }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(!sessions.commandAvailability.canNavigatePanes)

        Button("Next Pane") {
          sessions.focusNextPane()
        }
        .keyboardShortcut("]", modifiers: .command)
        .disabled(!sessions.commandAvailability.canNavigatePanes)

        Button("Previous Session") {
          sessions.showPreviousSession()
        }
        .keyboardShortcut("[", modifiers: [.command, .shift])
        .disabled(!sessions.commandAvailability.canNavigateSessions)

        Button("Next Session") {
          sessions.showNextSession()
        }
        .keyboardShortcut("]", modifiers: [.command, .shift])
        .disabled(!sessions.commandAvailability.canNavigateSessions)

        Divider()

        Button("Close Focused Shell", role: .destructive) {
          guard let shellID = sessions.focusedShellID ?? ghostty.keyWindowFocusedShellID else {
            AxoTrace.commands.notice("event=shell.close_key_ignored reason=no_focused_shell")
            return
          }
          AxoTrace.commands.notice("event=shell.close_key shell_id=\(shellID.rawValue)")
          Task { await sessions.requestCloseShell(shellID) }
        }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(!sessions.commandAvailability.hasFocusedShell)

        Button("Close Session", role: .destructive) {
          if let sessionID = sessions.selectedSessionID {
            Task { await sessions.requestCloseSession(sessionID) }
          }
        }
        .disabled(!sessions.commandAvailability.hasSelectedSession)
      }
    }

    Window("Axo Settings", id: "settings") {
      SettingsView(
        daemon: daemon,
        sessions: sessions,
        sleepPrevention: sleepPrevention,
        ghostty: ghostty,
        settingsClient: sessions.settingsClient,
        remoteAccess: workbench.remoteAccess,
        selection: $settingsSection,
        appearanceTheme: $appearanceTheme,
        pairingLink: pairingLink
      )
      .preferredColorScheme(appearanceTheme.colorScheme)
    }
    .windowResizability(.contentSize)
  }
}

/// Hands `TerminalSplashHold` Axod's state and a way to open the splash.
private struct SplashHoldOpener: View {
  @Environment(\.openWindow) private var openWindow
  var daemonIsRunning: @MainActor () -> Bool

  var body: some View {
    TerminalSplashHold(daemonRunning: daemonIsRunning()) { openWindow(id: LaunchSplashView.windowID) }
  }
}

private struct TerminalAppWindow: View {
  @Environment(\.openWindow) private var openWindow
  var daemon: DaemonController
  var sessions: TerminalSessionsModel
  var ghostty: GhosttyRuntime
  @Binding var settingsSection: SettingsSection
  var pairingLink: PairingLinkRouter
  @Binding var isPresentingWorkspaceCreation: Bool
  var palette: CommandPaletteModel
  var isDaemonRunningOverride: Bool?
  @AppStorage(AxoPreferenceKey.sidebarIsCollapsed) private var isSidebarCollapsed = false
  @State private var isCloningRepository = false
  @State private var repositoryCloneError: String?

  var body: some View {
    TerminalWorkbenchView(
      daemon: daemon,
      sessions: sessions,
      isPresentingWorkspaceCreation: $isPresentingWorkspaceCreation,
      daemonIsRunningOverride: isDaemonRunningOverride
    )
    .overlay { CommandPaletteOverlay(palette: palette, onChoose: perform) }
    .overlay(alignment: .top) {
      if isCloningRepository {
        Label("Cloning GitHub repository…", systemImage: "arrow.down.circle")
          .padding(.horizontal, 14)
          .padding(.vertical, 9)
          .background(.regularMaterial, in: Capsule())
          .padding(.top, 16)
          .accessibilityIdentifier("github-clone-progress")
      }
    }
    .alert(
      "Couldn’t open GitHub repository",
      isPresented: Binding(
        get: { repositoryCloneError != nil },
        set: { if !$0 { repositoryCloneError = nil } }
      )
    ) {
      Button("OK", role: .cancel) { repositoryCloneError = nil }
    } message: {
      Text(repositoryCloneError ?? "")
    }
    .onChange(of: palette.isPresented) { _, isPresented in
      // Back to the pane typing went to; a chosen Session or pane takes focus itself.
      if !isPresented, let shellID = sessions.focusedShellID {
        ghostty.surfaces.requestFocus(for: shellID)
      }
    }
    .environment(ghostty)
  }

  private func perform(_ action: CommandPaletteAction) {
    CommandPalettePerformer(
      sessions: sessions,
      toggleSidebar: { isSidebarCollapsed.toggle() },
      newWorkspace: { isPresentingWorkspaceCreation = true },
      cloneGitHubRepository: cloneGitHubRepository,
      openSettings: {
        settingsSection = .general
        openWindow(id: "settings")
      }
    ).perform(action)
  }

  private func cloneGitHubRepository(_ repository: GitHubRepository) {
    guard !isCloningRepository else { return }
    sessions.dismissWorkspaceCreationError()
    repositoryCloneError = nil
    isCloningRepository = true
    Task {
      defer { isCloningRepository = false }
      do {
        let directory = try await GitHubWorkspaceCloner.clone(repository)
        if let workspace = sessions.workspaces.first(where: {
          URL(fileURLWithPath: $0.directoryPath).standardizedFileURL.path
            == directory.standardizedFileURL.path
        }) {
          if let session = sessions.sessions.first(where: { $0.workspaceId == workspace.workspaceId }) {
            sessions.showSession(session.id)
          } else {
            await sessions.createSession(in: workspace.workspaceId)
          }
          return
        }

        let bookmark = try? directory.bookmarkData(
          options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
        ).base64EncodedString()
        await sessions.createWorkspace(
          name: repository.name, directoryPath: directory.path, directoryBookmark: bookmark)
        repositoryCloneError = sessions.workspaceCreationError
      } catch {
        repositoryCloneError = error.localizedDescription
      }
    }
  }
}

/// The View menu: the sidebar and the command palette.
private struct WorkbenchViewCommands: Commands {
  var palette: CommandPaletteModel
  var sessions: TerminalSessionsModel
  @Binding var isSidebarCollapsed: Bool
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .sidebar) {
      Button("Command Palette…") {
        if palette.isPresented {
          palette.dismiss()
        } else {
          openWindow(id: "terminal")
          palette.present(CommandPaletteCatalog.items(sessions.commandPaletteContext()))
        }
      }
      .keyboardShortcut("p", modifiers: [.command, .shift])

      Button("Toggle Sidebar") {
        isSidebarCollapsed.toggle()
      }
      .keyboardShortcut("s", modifiers: [.control, .command])
    }
  }
}

private struct AxoMenuBarLabel: View {
  @Environment(\.openWindow) private var openWindow
  var mascot: AxoMascot
  var pairingLink: PairingLinkRouter
  @Binding var settingsSection: SettingsSection
  let opensTerminalWindow: Bool
  let usesSplash: Bool
  @State private var didOpenTerminal = false
  private var reopenRequests = TerminalReopenRequests.shared

  var body: some View {
    Label {
      Text("Axo")
    } icon: {
      if let image = mascot.menuBarImage {
        Image(nsImage: image)
      } else {
        Image(systemName: "command")
      }
    }
      .task {
        if !didOpenTerminal {
          didOpenTerminal = true
          if opensTerminalWindow { TerminalWindowOpener.open(openWindow, viaSplash: usesSplash) }
        }
        if pairingLink.pendingCode != nil {
          openPairingSettings()
        }
      }
      .onChange(of: pairingLink.routeRevision) {
        openPairingSettings()
      }
      .onChange(of: reopenRequests.revision) {
        TerminalWindowOpener.open(openWindow, viaSplash: usesSplash)
      }
  }

  private func openPairingSettings() {
    settingsSection = .remoteAccess
    openWindow(id: "settings")
  }
}

private struct AxoMenu: View {
  @Environment(\.openWindow) private var openWindow
  var daemon: DaemonController
  @Binding var settingsSection: SettingsSection
  let usesSplash: Bool

  var body: some View {
    Group {
      if case .running = daemon.status {
        Label {
          Text(daemon.status.menuTitle)
        } icon: {
          Circle()
            .fill(Color.green)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
        }
      } else {
        Text(daemon.status.menuTitle)
      }
    }
    .disabled(true)

    Divider()

    Button("Open Terminal") {
      TerminalWindowOpener.open(openWindow, viaSplash: usesSplash)
    }

    Button("Settings…") {
      settingsSection = .general
      openWindow(id: "settings")
    }
    .keyboardShortcut(",")

    Divider()

    Button("Quit Axo") {
      // The daemon intentionally outlives the menu-bar app.
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }

}

private struct AxoApplicationCommands: Commands {
  @Binding var settingsSection: SettingsSection
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button("About Axo") {
        showSettings(section: .about)
      }
    }

    CommandGroup(replacing: .appSettings) {
      Button("Settings…") {
        showSettings(section: .general)
      }
      .keyboardShortcut(",")
    }
  }

  private func showSettings(section: SettingsSection) {
    settingsSection = section
    openWindow(id: "settings")
  }
}
