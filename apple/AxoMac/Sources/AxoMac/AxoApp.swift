import AppKit
import AxoDaemonManager
import AxoRPC
import Darwin
import SwiftUI

@main
struct AxoApp: App {
  private static let uiTestBundleIdentifier = "dev.leostera.axo.ui-tests"

  @StateObject private var daemon: DaemonController
  @StateObject private var sessions: TerminalSessionsModel
  @StateObject private var ghostty: GhosttyRuntime
  @State private var settingsSection = SettingsSection.general
  private let isUITestApp: Bool
  @AppStorage("terminalSidebarIsCollapsed") private var isSidebarCollapsed = true

  init() {
    let daemon = DaemonController()
    let isUITestApp = Bundle.main.bundleIdentifier == Self.uiTestBundleIdentifier
    _daemon = StateObject(wrappedValue: daemon)
    _sessions = StateObject(wrappedValue: Self.makeSessions(isUITestApp: isUITestApp))
    _ghostty = StateObject(wrappedValue: GhosttyRuntime())
    self.isUITestApp = isUITestApp

    if ProcessInfo.processInfo.arguments.contains("--self-test") {
      Task.detached {
        do {
          try await AxoAppSelfTest.run()
          try? FileHandle.standardOutput.write(
            contentsOf: Data("AXO_SELF_TEST_OK\n".utf8)
          )
          Darwin.exit(0)
        } catch {
          let message = "AXO_SELF_TEST_FAILED: \(error.localizedDescription)\n"
          try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
          Darwin.exit(1)
        }
      }
    } else if !isUITestApp {
      daemon.startIfNeeded()
    }
  }

  @MainActor
  private static func positionUITestWindow() async {
    for _ in 0..<20 {
      if let window = NSApp.windows.first(where: { $0.title == "Axo Terminal" }),
        let screen = NSScreen.main
      {
        let visibleFrame = screen.visibleFrame
        let size = NSSize(
          width: min(1000, visibleFrame.width),
          height: min(680, visibleFrame.height)
        )
        let origin = NSPoint(
          x: visibleFrame.midX - size.width / 2,
          y: visibleFrame.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.makeKeyAndOrderFront(nil)
        return
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  private static func makeSessions(isUITestApp: Bool) -> TerminalSessionsModel {
    guard isUITestApp else { return TerminalSessionsModel() }
    let environment = ProcessInfo.processInfo.environment
    guard let socket = environment["AXO_UI_TEST_SOCKET"],
      let helper = environment["AXO_UI_TEST_HELPER"],
      let controlDirectory = environment["AXO_UI_TEST_CONTROL_DIR"],
      FileManager.default.fileExists(atPath: controlDirectory)
    else {
      fatalError("The Axo UI-test app requires isolated socket, helper, and control paths.")
    }
    do {
      return TerminalSessionsModel(
        socketPath: try UnixSocketPath(socket),
        helperURL: URL(fileURLWithPath: helper)
      )
    } catch {
      fatalError("The Axo UI-test socket path is invalid: \(error)")
    }
  }

  var body: some Scene {
    MenuBarExtra {
      AxoMenu(daemon: daemon, settingsSection: $settingsSection)
    } label: {
      AxoMenuBarLabel()
    }
    .menuBarExtraStyle(.menu)

    Window("Axo Terminal", id: "terminal") {
      TerminalWorkbenchView(
        daemon: daemon,
        sessions: sessions,
        daemonIsRunningOverride: isUITestApp ? true : nil
      )
      .environmentObject(ghostty)
      .task {
        guard isUITestApp else { return }
        NSApp.activate(ignoringOtherApps: true)
        await Self.positionUITestWindow()
        guard let path = ProcessInfo.processInfo.environment["AXO_UI_TEST_CONTROL_DIR"] else {
          return
        }
        await TerminalUITestAutomation(sessions: sessions, ghostty: ghostty)
          .run(in: URL(fileURLWithPath: path, isDirectory: true))
      }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1000, height: 680)
    .commands {
      AxoApplicationCommands(settingsSection: $settingsSection)

      CommandGroup(replacing: .sidebar) {
        Button("Toggle Sidebar") {
          isSidebarCollapsed.toggle()
        }
        .keyboardShortcut("s", modifiers: .command)
      }

      CommandMenu("Terminal") {
        Button("New Session") {
          Task { await sessions.createSession() }
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
        .disabled(sessions.sessions.count < 2)

        Button("Next Session") {
          sessions.showNextSession()
        }
        .keyboardShortcut("]", modifiers: [.command, .shift])
        .disabled(sessions.sessions.count < 2)

        Divider()

        Button("Close Focused Shell", role: .destructive) {
          Task { await sessions.closeFocusedShell() }
        }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(sessions.focusedShellID == nil)

        Button("Close Session", role: .destructive) {
          if let sessionID = sessions.selectedSessionID {
            Task { await sessions.closeSession(sessionID) }
          }
        }
        .disabled(sessions.selectedSessionID == nil)
      }
    }

    Window("Axo Settings", id: "settings") {
      SettingsView(daemon: daemon, selection: $settingsSection)
    }
    .windowResizability(.contentSize)
  }
}

private struct AxoMenuBarLabel: View {
  @Environment(\.openWindow) private var openWindow
  @State private var didOpenTerminal = false

  var body: some View {
    Label("Axo", systemImage: "command")
      .task {
        guard !didOpenTerminal else { return }
        didOpenTerminal = true
        guard !ProcessInfo.processInfo.arguments.contains("--self-test") else { return }
        openWindow(id: "terminal")
      }
  }
}

private struct AxoMenu: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var daemon: DaemonController
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

    Button("Check for Updates…", action: showUpdateNotice)

    Divider()

    Button("Quit Axo") {
      // The daemon intentionally outlives the menu-bar app.
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }

  private func showUpdateNotice() {
    let alert = NSAlert()
    alert.messageText = "Axo updates are not configured yet"
    alert.informativeText = "The update action will be connected when Axo has a release channel."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.runModal()
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
