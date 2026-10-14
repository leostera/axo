import AppKit
import AxoDaemonManager
import Darwin
import SwiftUI

@main
struct AxoApp: App {
  @StateObject private var daemon: DaemonController
  @StateObject private var sessions: TerminalSessionsModel
  @StateObject private var ghostty: GhosttyRuntime

  init() {
    let daemon = DaemonController()
    _daemon = StateObject(wrappedValue: daemon)
    _sessions = StateObject(wrappedValue: TerminalSessionsModel())
    _ghostty = StateObject(wrappedValue: GhosttyRuntime())

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
    } else {
      daemon.startIfNeeded()
    }
  }

  var body: some Scene {
    MenuBarExtra {
      AxoMenu(daemon: daemon)
    } label: {
      Label("Axo", systemImage: "command")
    }
    .menuBarExtraStyle(.menu)

    Window("Axo Terminal", id: "terminal") {
      TerminalWorkbenchView(daemon: daemon, sessions: sessions)
        .environmentObject(ghostty)
    }
    .defaultSize(width: 1000, height: 680)

    Window("Axo Settings", id: "settings") {
      SettingsView(daemon: daemon)
    }
    .windowResizability(.contentSize)
  }
}

private struct AxoMenu: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var daemon: DaemonController

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
    .keyboardShortcut("t", modifiers: .command)

    Button("Settings…") {
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
