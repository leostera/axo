import AppKit
import AxoRPC
import Carbon
import Darwin
import Foundation
import GhosttyKit
import QuartzCore

@MainActor
final class GhosttyRuntime: ObservableObject {
  @Published private(set) var errorMessage: String?
  @Published private(set) var scrollSensitivity: Double
  private(set) var showsScrollbar = true
  /// Shells whose bell or finished command has not yet been seen by focusing the pane.
  @Published private(set) var attentionShellIDs: Set<ShellID> = []
  private(set) var attentionConfig = TerminalAttentionConfig()
  private var secureInputEnabled = false
  private(set) var hasDarkBackground = true

  private struct SurfaceEntry {
    let shell: TerminalShell
    let host: GhosttySurfaceHostNSView
    let view: GhosttySurfaceNSView
  }

  private var config: ghostty_config_t?
  private var app: ghostty_app_t?
  private(set) var focusedShellID: ShellID?
  // Retain each view until its surface is freed: Ghostty passes this unretained per-surface
  // userdata pointer back to the clipboard callbacks, even after SwiftUI pane identities change.
  private var terminalSurfaces: [ShellID: SurfaceEntry] = [:]
  private var notificationTokens: [NSObjectProtocol] = []

  init(initializeGhostty: Bool = true) {
    let storedSensitivity =
      UserDefaults.standard.object(
        forKey: TerminalScrollSensitivity.preferenceKey
      ) as? Double
    scrollSensitivity = TerminalScrollSensitivity.boundedMultiplier(
      storedSensitivity ?? TerminalScrollSensitivity.defaultMultiplier
    )
    if initializeGhostty { initialize() }
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

  func surfacePresentation(
    for shell: TerminalShell,
    helperURL: URL,
    initialSize: CGSize,
    onFocus: @escaping () -> Void,
    onStatusChange: @escaping (String) -> Void,
    onSplit: @escaping (TerminalSplitDirection) -> Void,
    onClose: @escaping () -> Void
  ) -> (host: GhosttySurfaceHostNSView, view: GhosttySurfaceNSView) {
    if let existing = terminalSurfaces[shell.id], existing.shell == shell {
      existing.view.onFocus = onFocus
      existing.view.onStatusChange = onStatusChange
      existing.view.onSplit = onSplit
      existing.view.onClose = onClose
      return (existing.host, existing.view)
    }

    destroySurface(shellID: shell.id)
    let view = GhosttySurfaceNSView(
      runtime: self,
      shellID: shell.id,
      initialFrameSize: Self.seededSurfaceSize(for: initialSize),
      onFocus: onFocus
    )
    let host = GhosttySurfaceHostNSView()
    view.onStatusChange = onStatusChange
    view.onSplit = onSplit
    view.onClose = onClose
    createSurface(in: view, shell: shell, helperURL: helperURL)
    host.attachSurface(view)
    terminalSurfaces[shell.id] = SurfaceEntry(shell: shell, host: host, view: view)
    return (host, view)
  }

  static func seededSurfaceSize(for proposedSize: CGSize) -> CGSize {
    guard proposedSize.width.isFinite, proposedSize.height.isFinite,
      proposedSize.width > 0, proposedSize.height > 0
    else {
      return CGSize(width: 800, height: 600)
    }
    return proposedSize
  }

  func setFocusedShellID(_ shellID: ShellID?) {
    focusedShellID = shellID
    // @Published emits even when Set.remove finds nothing. Focus reconciliation
    // must not invalidate every terminal representable on every render pass.
    if let shellID, attentionShellIDs.contains(shellID) {
      attentionShellIDs.remove(shellID)
    }
    refreshSecureInput()
  }

  /// Ghostty.app enables macOS secure event input only while a surface that requested it is
  /// the focused key responder. Calls stay balanced through `secureInputEnabled`.
  func refreshSecureInput() {
    let wanted = terminalSurfaces.values.contains { $0.view.surfaceStatus.secureInput && $0.view.isFocusedTerminal }
    guard wanted != secureInputEnabled else { return }
    secureInputEnabled = wanted
    if wanted { EnableSecureEventInput() } else { DisableSecureEventInput() }
  }

  func ringBell(for view: GhosttySurfaceNSView) {
    let effects = TerminalAttentionPolicy.bellEffects(attentionConfig.bellFeatures)
    if effects.beep { NSSound.beep() }
    guard effects.requestAttention, !view.isFocusedTerminal else { return }
    attentionShellIDs.insert(view.shellID)
    NSApp.requestUserAttention(.informationalRequest)
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
    let openShells = Dictionary(uniqueKeysWithValues: shells.filter(\.isAvailable).map { ($0.id, $0) })
    let closedShellIDs = terminalSurfaces.compactMap { shellID, entry in
      openShells[shellID] == entry.shell ? nil : shellID
    }
    for shellID in closedShellIDs {
      destroySurface(shellID: shellID)
    }
  }

  private func destroySurface(shellID: ShellID) {
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

  var keyWindowFocusedShellID: ShellID? {
    guard let focusedView = NSApp.keyWindow?.firstResponder as? GhosttySurfaceNSView else {
      return nil
    }
    return terminalSurfaces.first { $0.value.view === focusedView }?.key
  }

  func hasSurface(for shellID: ShellID) -> Bool {
    terminalSurfaces[shellID]?.view.surface != nil
  }

  func focusSurface(for shellID: ShellID) -> Bool {
    guard let view = terminalSurfaces[shellID]?.view,
      let window = view.window,
      window.isKeyWindow
    else { return false }
    if window.firstResponder === view { return true }
    return window.makeFirstResponder(view) && window.firstResponder === view
  }

  @discardableResult
  func insertText(_ text: String, into shellID: ShellID) -> Bool {
    guard let view = terminalSurfaces[shellID]?.view, view.surface != nil else { return false }
    view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    return true
  }

  @discardableResult
  func perform(_ action: GhosttySurfaceAction, on shellID: ShellID? = nil) -> Bool {
    guard let shellID = shellID ?? focusedShellID,
      let surface = terminalSurfaces[shellID]?.view.surface
    else { return false }
    return action.rawValue.withCString {
      ghostty_surface_binding_action(surface, $0, UInt(action.rawValue.utf8.count))
    }
  }

  /// Routes Axo's Find menu to the focused terminal surface only.
  func performFind(_ action: TerminalFindAction) {
    guard let shellID = focusedShellID else { return }
    terminalSurfaces[shellID]?.view.performFind(action)
  }

  func forwardKeyEquivalent(_ event: NSEvent) -> Bool {
    guard let shellID = focusedShellID,
      let view = terminalSurfaces[shellID]?.view,
      view.surface != nil
    else { return false }
    view.forwardKeyEquivalent(event)
    return true
  }

  func copySelection(from shellID: ShellID? = nil) {
    guard let shellID = shellID ?? focusedShellID,
      let surface = terminalSurfaces[shellID]?.view.surface
    else { return }
    var selection = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &selection) else { return }
    defer { ghostty_surface_free_text(surface, &selection) }
    guard let text = selection.text else { return }
    let data = Data(bytes: text, count: Int(selection.text_len))
    let value = String(decoding: data, as: UTF8.self)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  func pasteClipboard(into shellID: ShellID? = nil) {
    guard let shellID = shellID ?? focusedShellID,
      let text = NSPasteboard.general.string(forType: .string)
    else { return }
    pasteText(text, into: shellID)
  }

  func pasteText(_ text: String, into shellID: ShellID) {
    guard !text.isEmpty else { return }
    Task { @MainActor [weak self] in
      for _ in 0..<40 {
        guard let self else { return }
        if let surface = self.terminalSurfaces[shellID]?.view.surface {
          text.withCString { ghostty_surface_paste_text(surface, $0, UInt(text.utf8.count)) }
          return
        }
        try? await Task.sleep(for: .milliseconds(25))
      }
    }
  }

  func updateSurfaceSize(in view: GhosttySurfaceNSView, contentSize: CGSize) {
    // Match Ghostty's AppKit surface bridge: libghostty renders at framebuffer resolution,
    // so Core Animation must not rescale its layer when the window moves between displays.
    if let window = view.window {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      view.layer?.contentsScale = window.backingScaleFactor
      CATransaction.commit()
    }

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
    Self.configureGhosttyResources()

    guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
      errorMessage = "libghostty could not initialize."
      return
    }
    guard let config = ghostty_config_new() else {
      errorMessage = "libghostty could not create its configuration."
      return
    }

    // Load Axo's macOS default first so explicit Ghostty config values can override it.
    if let error = Self.loadAxoConfigDefaults(into: config) { errorMessage = error }
    ghostty_config_load_default_files(config)
    ghostty_config_load_recursive_files(config)
    ghostty_config_finalize(config)
    let appearance = Self.scrollbarAppearance(from: config)
    showsScrollbar = appearance.showsScrollbar
    hasDarkBackground = appearance.hasDarkBackground
    attentionConfig = TerminalAttentionConfig(config: config)

    var runtimeConfig = ghostty_runtime_config_s(
      userdata: Unmanaged.passUnretained(self).toOpaque(),
      supports_selection_clipboard: true,
      wakeup_cb: { userdata in GhosttyRuntime.wakeup(userdata) },
      action_cb: { _, target, action in
        // Axo enters libghostty from MainActor-bound surface calls and ticks, so this callback
        // updates AppKit state synchronously on that same thread.
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated {
          GhosttyRuntime.handleAction(target: target, action: action)
        }
      },
      read_clipboard_cb: { userdata, location, state, mimes, count, list in
        guard Thread.isMainThread else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        return MainActor.assumeIsolated {
          GhosttyRuntime.readClipboard(
            userdata: userdata,
            location: location,
            state: state,
            mimes: mimes,
            count: count,
            list: list
          )
        }
      },
      confirm_read_clipboard_cb: { userdata, confirm, state, request in
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
          GhosttyRuntime.confirmClipboardRead(
            userdata: userdata, confirm: confirm, state: state, request: request)
        }
      },
      write_clipboard_cb: { _, location, content, count, confirm in
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
          GhosttyRuntime.writeClipboard(
            location: location, content: content, count: count, confirm: confirm)
        }
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
    // `NSApp` is nil until NSApplication finishes launching; activation observers catch up.
    ghostty_app_set_focus(app, NSApp?.isActive ?? false)
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
    shellID: ShellID
  ) -> String {
    [
      helperPath,
      "terminal-attach",
      "--attach-socket",
      socketPath,
      "--shell-id",
      shellID.description,
    ]
    .map(shellQuoted)
    .joined(separator: " ")
  }

  private static func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

enum GhosttySurfaceAction: String {
  case selectAll = "select_all"
  case undo
  case redo
}
