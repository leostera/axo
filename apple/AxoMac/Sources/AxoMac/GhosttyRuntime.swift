import AppKit
import AxoRPC
import Darwin
import Foundation
import GhosttyKit

@MainActor
final class GhosttyRuntime: ObservableObject {
  @Published private(set) var errorMessage: String?
  @Published private(set) var scrollSensitivity: Double

  private struct SurfaceEntry {
    let shell: TerminalShell
    let host: GhosttySurfaceHostNSView
    let view: GhosttySurfaceNSView
  }

  private var config: ghostty_config_t?
  private var app: ghostty_app_t?
  // A Ghostty surface and its platform NSView outlive SwiftUI's pane view identities.
  private var terminalSurfaces: [Int64: SurfaceEntry] = [:]
  private var notificationTokens: [NSObjectProtocol] = []

  init() {
    let storedSensitivity =
      UserDefaults.standard.object(
        forKey: TerminalScrollSensitivity.preferenceKey
      ) as? Double
    scrollSensitivity = TerminalScrollSensitivity.boundedMultiplier(
      storedSensitivity ?? TerminalScrollSensitivity.defaultMultiplier
    )
    initialize()
  }

  deinit {
    notificationTokens.forEach(NotificationCenter.default.removeObserver)
    MainActor.assumeIsolated {
      for entry in terminalSurfaces.values {
        entry.view.removeFromSuperview()
        if let surface = entry.view.detach() {
          ghostty_surface_free(surface)
        }
      }
    }
    if let app {
      ghostty_app_free(app)
    }
    if let config {
      ghostty_config_free(config)
    }
  }

  func surfaceView(
    for shell: TerminalShell,
    helperURL: URL,
    onFocus: @escaping () -> Void,
    onStatusChange: @escaping (String) -> Void
  ) -> GhosttySurfaceNSView {
    if let existing = terminalSurfaces[shell.id], existing.shell == shell {
      existing.view.onFocus = onFocus
      existing.view.onStatusChange = onStatusChange
      onStatusChange(existing.view.status)
      return existing.view
    }

    destroySurface(shellID: shell.id)
    let view = GhosttySurfaceNSView(runtime: self, onFocus: onFocus)
    let host = GhosttySurfaceHostNSView()
    view.onStatusChange = onStatusChange
    createSurface(in: view, shell: shell, helperURL: helperURL)
    host.attachSurface(view)
    terminalSurfaces[shell.id] = SurfaceEntry(shell: shell, host: host, view: view)
    return view
  }

  func surfaceHost(for shellID: Int64) -> GhosttySurfaceHostNSView? {
    terminalSurfaces[shellID]?.host
  }

  func detachSurface(from host: GhosttySurfaceHostNSView) {
    host.detachSurface()
  }

  func setScrollSensitivity(_ multiplier: Double) {
    let multiplier = TerminalScrollSensitivity.boundedMultiplier(multiplier)
    guard multiplier != scrollSensitivity else { return }
    scrollSensitivity = multiplier
    UserDefaults.standard.set(multiplier, forKey: TerminalScrollSensitivity.preferenceKey)
  }

  func reconcileSurfaces(with shells: [TerminalShell]) {
    let openShells = Dictionary(uniqueKeysWithValues: shells.map { ($0.id, $0) })
    let closedShellIDs = terminalSurfaces.compactMap { shellID, entry in
      openShells[shellID] == entry.shell ? nil : shellID
    }
    for shellID in closedShellIDs {
      destroySurface(shellID: shellID)
    }
  }

  private func destroySurface(shellID: Int64) {
    guard let entry = terminalSurfaces.removeValue(forKey: shellID) else { return }
    entry.view.removeFromSuperview()
    if let surface = entry.view.detach() {
      ghostty_surface_free(surface)
    }
  }

  private func createSurface(
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
    updateSurfaceSize(in: view, contentSize: view.bounds.size)
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

  var surfaceCount: Int { terminalSurfaces.count }

  func hasSurface(for shellID: Int64) -> Bool {
    terminalSurfaces[shellID]?.view.surface != nil
  }

  func focusSurface(for shellID: Int64) -> Bool {
    guard let view = terminalSurfaces[shellID]?.view,
      let window = view.window,
      window.isKeyWindow
    else { return false }
    if window.firstResponder === view { return true }
    return window.makeFirstResponder(view) && window.firstResponder === view
  }

  @discardableResult
  func insertText(_ text: String, into shellID: Int64) -> Bool {
    guard let view = terminalSurfaces[shellID]?.view, view.surface != nil else { return false }
    view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    return true
  }

  func updateSurfaceSize(in view: GhosttySurfaceNSView, contentSize: CGSize) {
    guard let surface = view.surface else { return }
    let fallbackScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    let frameSize = view.frame.size
    let backingFrame = view.convertToBacking(view.frame)
    let scaleX = frameSize.width > 0 ? backingFrame.width / frameSize.width : fallbackScale
    let scaleY = frameSize.height > 0 ? backingFrame.height / frameSize.height : fallbackScale
    ghostty_surface_set_content_scale(surface, scaleX, scaleY)
    let backingSize = view.convertToBacking(contentSize)
    let width = UInt32(max(0, backingSize.width))
    let height = UInt32(max(0, backingSize.height))
    guard width > 0, height > 0 else { return }
    ghostty_surface_set_size(surface, width, height)
  }

  private func initialize() {
    configureGhosttyResources()

    guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
      errorMessage = "libghostty could not initialize."
      return
    }
    guard let config = ghostty_config_new() else {
      errorMessage = "libghostty could not create its configuration."
      return
    }

    // Load Axo's macOS default first so explicit Ghostty config values can override it.
    loadAxoConfigDefaults(into: config)
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
      write_clipboard_cb: { _, location, content, count, confirm in
        GhosttyRuntime.writeClipboard(
          location: location,
          content: content,
          count: count,
          confirm: confirm
        )
      },
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

  private func configureGhosttyResources() {
    if let configuredDirectory = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"],
      !configuredDirectory.isEmpty
    {
      return
    }

    let installedAppURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: "com.mitchellh.ghostty"
    )
    let bundledResourcesURL = Bundle.main.resourceURL?.appendingPathComponent(
      "ghostty-resources", isDirectory: true
    )
    guard
      let resourceDirectory = GhosttyResourceLocator.resolve(
        installedGhosttyAppURL: installedAppURL,
        bundledResourcesURL: bundledResourcesURL
      )
    else {
      return
    }
    setenv("GHOSTTY_RESOURCES_DIR", resourceDirectory.path, 1)
  }

  private func loadAxoConfigDefaults(into config: ghostty_config_t) {
    let configURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("axo-ghostty-default-\(UUID().uuidString).ghostty")
    do {
      try "copy-on-select = clipboard\n".write(to: configURL, atomically: true, encoding: .utf8)
    } catch {
      errorMessage = "Axo could not enable copy-on-select: \(error.localizedDescription)"
      return
    }
    defer { try? FileManager.default.removeItem(at: configURL) }
    configURL.path.withCString { ghostty_config_load_file(config, $0) }
  }

  private static func writeClipboard(
    location: ghostty_clipboard_e,
    content: UnsafePointer<ghostty_clipboard_content_s>?,
    count: Int,
    confirm: Bool
  ) {
    // Confirmed writes need a prompt, which Axo does not provide yet; fail closed.
    guard location == GHOSTTY_CLIPBOARD_STANDARD, !confirm, let content, count > 0 else { return }

    // The callback owns this C buffer only for its duration; copy it before hopping to AppKit.
    for index in 0..<count {
      guard let mime = content[index].mime,
        String(cString: mime) == "text/plain",
        let bytes = content[index].data
      else {
        continue
      }
      let data = Data(bytes: bytes, count: Int(content[index].len))
      let text = String(decoding: data, as: UTF8.self)
      DispatchQueue.main.async {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
      }
      return
    }
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
