import AppKit
import AxoDaemonManager
import SwiftUI

@main
struct AxoApp: App {
  @StateObject private var daemon = DaemonController()

  var body: some Scene {
    MenuBarExtra {
      AxoMenu(daemon: daemon)
    } label: {
      Label("Axo", systemImage: "command")
        .task {
          daemon.startIfNeeded()
        }
    }
    .menuBarExtraStyle(.menu)

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
    Text(daemon.status.menuTitle)
      .disabled(true)

    Divider()

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
