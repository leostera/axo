import AppKit
import AxoDaemonManager
import AxoRPC
import SwiftUI

@main
struct AxoApp: App {
  @State private var daemon: DaemonController
  @State private var sessions: TerminalSessionsModel
  @NSApplicationDelegateAdaptor(AxoURLSchemeDelegate.self) private var urlSchemeDelegate
  @State private var ghostty: GhosttyRuntime
  @State private var sleepPrevention: SleepPreventionController
  @State private var pairingLink = PairingLinkRouter.shared
  @State private var settingsSection = SettingsSection.general
  @State private var isPresentingWorkspaceCreation = false
  @AppStorage(AxoPreferenceKey.appearanceTheme) private var appearanceTheme: AppearanceTheme = .system
  @AppStorage(AxoPreferenceKey.sidebarIsCollapsed) private var isSidebarCollapsed = false
  private let environment: AxoAppEnvironment
  private let workbench: AxoWorkbench

  init() {
    let daemon = DaemonController()
    let environment = AxoAppEnvironment.current(daemon: daemon)
    let ghostty = GhosttyRuntime()
    _daemon = State(initialValue: daemon)
    _sessions = State(initialValue: environment.sessions)
    _ghostty = State(initialValue: ghostty)
    _sleepPrevention = State(initialValue: SleepPreventionController())
    self.environment = environment
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

  var body: some Scene {
    MenuBarExtra {
      AxoMenu(daemon: daemon, settingsSection: $settingsSection)
    } label: {
      AxoMenuBarLabel(
        pairingLink: pairingLink,
        settingsSection: $settingsSection,
        opensTerminalWindow: environment.opensTerminalWindow)
    }
    .menuBarExtraStyle(.menu)

    Window("Axo Terminal", id: "terminal") {
      TerminalAppWindow(
        daemon: daemon,
        sessions: sessions,
        ghostty: ghostty,
        settingsSection: $settingsSection,
        pairingLink: pairingLink,
        isPresentingWorkspaceCreation: $isPresentingWorkspaceCreation,
        isDaemonRunningOverride: environment.startsDaemon ? nil : true
      )
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

      CommandGroup(replacing: .sidebar) {
        Button("Toggle Sidebar") {
          isSidebarCollapsed.toggle()
        }
        .keyboardShortcut("s", modifiers: [.control, .command])
      }

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
        .disabled((sessions.layout?.orderedShellIDs.count ?? 0) < 2)

        Button("Next Pane") {
          sessions.focusNextPane()
        }
        .keyboardShortcut("]", modifiers: .command)
        .disabled((sessions.layout?.orderedShellIDs.count ?? 0) < 2)

        Button("Previous Session") {
          sessions.showPreviousSession()
        }
        .keyboardShortcut("[", modifiers: [.command, .shift])
        .disabled(sessions.sidebarOrderedSessions.count < 2)

        Button("Next Session") {
          sessions.showNextSession()
        }
        .keyboardShortcut("]", modifiers: [.command, .shift])
        .disabled(sessions.sidebarOrderedSessions.count < 2)

        Divider()

        Button("Close Focused Shell", role: .destructive) {
          guard let shellID = sessions.focusedShellID ?? ghostty.keyWindowFocusedShellID else {
            return
          }
          Task { await sessions.requestCloseShell(shellID) }
        }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(sessions.focusedShellID == nil)

        Button("Close Session", role: .destructive) {
          if let sessionID = sessions.selectedSessionID {
            Task { await sessions.requestCloseSession(sessionID) }
          }
        }
        .disabled(sessions.selectedSessionID == nil)
      }
    }

    Window("Axo Settings", id: "settings") {
      SettingsView(
        daemon: daemon,
        sessions: sessions,
        sleepPrevention: sleepPrevention,
        ghostty: ghostty,
        selection: $settingsSection,
        appearanceTheme: $appearanceTheme,
        pairingLink: pairingLink
      )
      .preferredColorScheme(appearanceTheme.colorScheme)
    }
    .windowResizability(.contentSize)
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
  var isDaemonRunningOverride: Bool?

  var body: some View {
    TerminalWorkbenchView(
      daemon: daemon,
      sessions: sessions,
      isPresentingWorkspaceCreation: $isPresentingWorkspaceCreation,
      daemonIsRunningOverride: isDaemonRunningOverride
    )
    .environment(ghostty)
  }
}

private struct AxoMenuBarLabel: View {
  @Environment(\.openWindow) private var openWindow
  var pairingLink: PairingLinkRouter
  @Binding var settingsSection: SettingsSection
  let opensTerminalWindow: Bool
  @State private var didOpenTerminal = false

  var body: some View {
    Label("Axo", systemImage: "command")
      .task {
        if !didOpenTerminal {
          didOpenTerminal = true
          if opensTerminalWindow { openWindow(id: "terminal") }
        }
        if pairingLink.pendingCode != nil {
          openPairingSettings()
        }
      }
      .onChange(of: pairingLink.routeRevision) {
        openPairingSettings()
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
      openWindow(id: "terminal")
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
