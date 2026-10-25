import AppKit
import AxoDaemonManager
import AxoProtocol
import AxoRPC
import Darwin
import Foundation

@testable import AxoMac

/// Fixture launch modes, compiled only into `AxoMacTestHost`/`AxoUITestApp`; the shipped app
/// has no self-test, file-driven automation or test-window placement.
extension AxoAppEnvironment {
  private static let uiTestBundleIdentifier = "dev.leostera.axo.ui-tests"

  static func testHost(daemon: DaemonController) -> AxoAppEnvironment {
    if ProcessInfo.processInfo.arguments.contains("--self-test") {
      return selfTest(daemon: daemon)
    }
    if Bundle.main.bundleIdentifier == uiTestBundleIdentifier {
      return uiTest()
    }
    return production(daemon: daemon)
  }

  /// Exercises the bundled app-to-daemon contract against an isolated daemon, then exits.
  private static func selfTest(daemon: DaemonController) -> AxoAppEnvironment {
    Task.detached {
      do {
        try await AxoAppSelfTest.run()
        try? FileHandle.standardOutput.write(contentsOf: Data("AXO_SELF_TEST_OK\n".utf8))
        Darwin.exit(0)
      } catch {
        let message = "AXO_SELF_TEST_FAILED: \(error.localizedDescription)\n"
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
        Darwin.exit(1)
      }
    }
    var environment = production(daemon: daemon)
    environment.startsDaemon = false
    environment.opensTerminalWindow = false
    return environment
  }

  /// Drives the real UI against the isolated daemon prepared by `run_visual_ui_test.sh`.
  private static func uiTest() -> AxoAppEnvironment {
    let environment = ProcessInfo.processInfo.environment
    guard let socket = environment["AXO_UI_TEST_SOCKET"],
      let controlDirectory = environment["AXO_UI_TEST_CONTROL_DIR"],
      FileManager.default.fileExists(atPath: controlDirectory),
      let socketPath = try? UnixSocketPath(socket)
    else {
      fatalError("The Axo UI-test app requires isolated socket and control paths.")
    }
    return AxoAppEnvironment(
      sessions: TerminalSessionsModel(
        socketPath: socketPath),
      daemonIsRunning: { true },
      startsDaemon: false,
      prepareTerminalWindow: { sessions, ghostty in
        NSApp.activate(ignoringOtherApps: true)
        await positionTerminalWindow()
        await sessions.refresh()
        if sessions.sessions.isEmpty {
          await sessions.createSession()
        }
        await TerminalUITestAutomation(sessions: sessions, ghostty: ghostty)
          .run(in: URL(fileURLWithPath: controlDirectory, isDirectory: true))
      })
  }

  /// Places the fixture window on the primary display at a deterministic size.
  private static func positionTerminalWindow() async {
    for _ in 0..<20 {
      if let window = NSApp.windows.first(where: { $0.title == "Axo Terminal" }),
        let screen = NSScreen.main
      {
        let visibleFrame = screen.visibleFrame
        let size = NSSize(
          width: min(1000, visibleFrame.width), height: min(680, visibleFrame.height))
        let origin = NSPoint(
          x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.makeKeyAndOrderFront(nil)
        return
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
  }
}

enum TestHostLaunch: AxoLaunchMode {
  static func environment(daemon: DaemonController) -> AxoAppEnvironment {
    .testHost(daemon: daemon)
  }
}

/// The fixture app's entry: the same compiled `AxoMac` library with test launch modes.
@main
enum AxoTestHostMain {
  @MainActor static func main() {
    AxoApp<TestHostLaunch>.main()
  }
}
