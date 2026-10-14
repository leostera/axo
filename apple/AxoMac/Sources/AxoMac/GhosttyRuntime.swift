import AppKit
import AxoRPC
import Darwin
import Foundation
import GhosttyKit

@MainActor
final class GhosttyRuntime: ObservableObject {
  @Published private(set) var errorMessage: String?

  private var config: ghostty_config_t?
  private var app: ghostty_app_t?
  private var notificationTokens: [NSObjectProtocol] = []

  init() {
    initialize()
  }

  deinit {
    notificationTokens.forEach(NotificationCenter.default.removeObserver)
    if let app {
      ghostty_app_free(app)
    }
    if let config {
      ghostty_config_free(config)
    }
  }

  func createSurface(
    in view: GhosttySurfaceNSView,
    shell: TerminalShell,
    helperURL: URL
  ) {
    guard let app else {
      view.status = errorMessage ?? "libghostty is unavailable."
      return
    }
    guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
      view.status = "The bundled axod terminal-attach helper is missing."
      return
    }

    var surfaceConfig = ghostty_surface_config_new()
    surfaceConfig.userdata = Unmanaged.passUnretained(view).toOpaque()
    surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
    surfaceConfig.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque())
    )
    surfaceConfig.scale_factor = Double(
      view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    )
    surfaceConfig.font_size = 0
    surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

    let command = Self.terminalAttachCommand(
      helperPath: helperURL.path,
      socketPath: shell.attachSocketPath,
      shellID: shell.id
    )

    let createdSurface = shell.initialPwd.withCString { workingDirectory in
      command.withCString { command in
        surfaceConfig.working_directory = workingDirectory
        surfaceConfig.command = command
        return ghostty_surface_new(app, &surfaceConfig)
      }
    }

    guard let createdSurface else {
      view.status = "Ghostty could not create a terminal surface."
      return
    }

    view.attach(createdSurface)
    view.status = "Connected to shell \(shell.id)"
    updateSurfaceSize(in: view)
  }

  func destroySurface(in view: GhosttySurfaceNSView) {
    guard let surface = view.detach() else { return }
    ghostty_surface_free(surface)
  }

  func tick() {
    guard let app else { return }
    ghostty_app_tick(app)
  }

  func updateFocus(_ focused: Bool) {
    guard let app else { return }
    ghostty_app_set_focus(app, focused)
  }

  func updateSurfaceSize(in view: GhosttySurfaceNSView) {
    guard let surface = view.surface else { return }
    let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    ghostty_surface_set_content_scale(surface, scale, scale)
    let backingSize = view.convertToBacking(view.bounds).size
    let width = UInt32(max(0, backingSize.width.rounded()))
    let height = UInt32(max(0, backingSize.height.rounded()))
    guard width > 0, height > 0 else { return }
    ghostty_surface_set_size(surface, width, height)
  }

  private func initialize() {
    if let resourceDirectory = Bundle.main.resourceURL?.appendingPathComponent(
      "ghostty-resources", isDirectory: true
    ) {
      setenv("GHOSTTY_RESOURCES_DIR", resourceDirectory.path, 1)
    }

    guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
      errorMessage = "libghostty could not initialize."
      return
    }
    guard let config = ghostty_config_new() else {
      errorMessage = "libghostty could not create its configuration."
      return
    }

    ghostty_config_load_default_files(config)
    ghostty_config_load_recursive_files(config)
    ghostty_config_finalize(config)

    var runtimeConfig = ghostty_runtime_config_s(
      userdata: Unmanaged.passUnretained(self).toOpaque(),
      supports_selection_clipboard: false,
      wakeup_cb: { userdata in GhosttyRuntime.wakeup(userdata) },
      action_cb: { _, _, _ in false },
      read_clipboard_cb: { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNSUPPORTED },
      confirm_read_clipboard_cb: { _, _, _, _ in },
      write_clipboard_cb: { _, _, _, _, _ in },
      close_surface_cb: { _, _ in }
    )

    guard let app = ghostty_app_new(&runtimeConfig, config) else {
      ghostty_config_free(config)
      errorMessage = "libghostty could not create its terminal app."
      return
    }

    self.config = config
    self.app = app
    ghostty_app_set_focus(app, NSApp.isActive)
    observeApplicationState()
  }

  private func observeApplicationState() {
    let center = NotificationCenter.default
    notificationTokens.append(
      center.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.updateFocus(true) }
      }
    )
    notificationTokens.append(
      center.addObserver(
        forName: NSApplication.didResignActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.updateFocus(false) }
      }
    )
    notificationTokens.append(
      center.addObserver(
        forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let app = self?.app else { return }
          ghostty_app_keyboard_changed(app)
        }
      }
    )
  }

  private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
      MainActor.assumeIsolated { runtime.tick() }
    }
  }

  private static func terminalAttachCommand(
    helperPath: String,
    socketPath: String,
    shellID: Int64
  ) -> String {
    [
      helperPath,
      "terminal-attach",
      "--attach-socket",
      socketPath,
      "--shell-id",
      String(shellID),
    ]
    .map(shellQuoted)
    .joined(separator: " ")
  }

  private static func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
