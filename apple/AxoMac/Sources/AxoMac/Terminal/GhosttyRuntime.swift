import AppKit
import AxoRPC
import Carbon
import Darwin
import Foundation
import GhosttyKit
import QuartzCore

@MainActor
@Observable
final class GhosttyRuntime {
  private(set) var errorMessage: String?
  private(set) var scrollSensitivity: Double
  private(set) var showsScrollbar = true
  /// Shells whose bell or finished command has not yet been seen by focusing the pane.
  private(set) var attentionShellIDs: Set<ShellID> = []
  private(set) var attentionConfig = TerminalAttentionConfig()
  @ObservationIgnored private var secureInputEnabled = false
  private(set) var hasDarkBackground = true
  /// One cell of the most recently sized surface, in device pixels; `nil` before any surface.
  private(set) var cellPixelSize: ClientViewport.PixelSize?

  private struct SurfaceEntry {
    let shell: TerminalShell
    let host: GhosttySurfaceHostNSView
    let view: GhosttySurfaceNSView
  }

  @ObservationIgnored private var config: ghostty_config_t?
  @ObservationIgnored private var app: ghostty_app_t?
  private(set) var focusedShellID: ShellID?
  // Retain each view until its surface is freed: Ghostty passes this unretained per-surface
  // userdata pointer back to the clipboard callbacks, even after SwiftUI pane identities change.
  @ObservationIgnored private var terminalSurfaces: [ShellID: SurfaceEntry] = [:]
  @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
  @ObservationIgnored private var lastReattach: [ShellID: ContinuousClock.Instant] = [:]
  /// Where every open pane would be if its Session were shown; see `sizeOffscreenSurfaces`.
  @ObservationIgnored private var offscreenPaneSizes: [ShellID: CGSize] = [:]
  @ObservationIgnored private var offscreenBackingScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2

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
    initialSize: CGSize,
    onFocus: @escaping () -> Void,
    onStatusChange: @escaping (TerminalSurfaceConnection) -> Void,
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
    createSurface(in: view, shell: shell)
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
    // Observation notifies on every write, even an unchanged value or a Set.remove that finds
    // nothing; focus reconciliation must not invalidate every terminal view on each pass.
    if focusedShellID != shellID { focusedShellID = shellID }
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
    if !attentionShellIDs.contains(view.shellID) { attentionShellIDs.insert(view.shellID) }
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
    lastReattach[shellID] = nil
    guard let entry = terminalSurfaces.removeValue(forKey: shellID) else { return }
    entry.view.removeFromSuperview()
    if let surface = entry.view.detach() {
      let start = ContinuousClock.now
      ghostty_surface_free(surface)
      AxoTrace.surfaces.notice(
        "event=surface.freed shell_id=\(shellID.rawValue) elapsed_ms=\(AxoTrace.elapsed(since: start), privacy: .public)")
    }
  }

  /// Attaches to the shell off the main thread, then creates (or replaces) the view's surface.
  /// Axod owns the PTY and is its only reader: the surface reads the attach stream and uses the
  /// PTY descriptor only for input, resizing and termios queries (Ghostty external I/O patch).
  private func createSurface(in view: GhosttySurfaceNSView, shell: TerminalShell) {
    guard app != nil else {
      view.connection = .failed(errorMessage ?? "libghostty is unavailable.")
      return
    }
    let socketPath: UnixSocketPath
    do {
      socketPath = try UnixSocketPath(shell.attachSocketPath)
    } catch {
      view.connection = .failed("axod reported an invalid terminal socket path.")
      return
    }
    view.attachGeneration += 1
    let generation = view.attachGeneration
    let shellID = shell.id
    let start = ContinuousClock.now
    Task.detached(priority: .userInitiated) { [weak self, weak view] in
      let result = Result { try TerminalAttachment.open(socketPath: socketPath, shellID: shellID) }
      AxoTrace.surfaces.notice(
        "event=surface.attach_opened shell_id=\(shellID.rawValue) ok=\((try? result.get()) != nil) elapsed_ms=\(AxoTrace.elapsed(since: start), privacy: .public)")
      await MainActor.run {
        AxoTrace.surfaces.notice(
          "event=surface.attach_on_main shell_id=\(shellID.rawValue) elapsed_ms=\(AxoTrace.elapsed(since: start), privacy: .public)")
        guard let self, let view else {
          if case .success(let attachment) = result { attachment.close() }
          return
        }
        self.adopt(result, in: view, shell: shell, generation: generation)
      }
    }
  }

  private func adopt(
    _ result: Result<TerminalAttachment, Error>,
    in view: GhosttySurfaceNSView,
    shell: TerminalShell,
    generation: Int
  ) {
    let attachment: TerminalAttachment
    switch result {
    case .success(let opened):
      attachment = opened
    case .failure(let error):
      guard view.attachGeneration == generation else { return }
      // A replacement attempt for an exited shell keeps the final screen; the catalog
      // removes the pane.
      if view.surface != nil, case TerminalAttachmentError.rejected(.shellNotOpen) = error { return }
      view.connection = .failed("Could not attach to the terminal: \(error)")
      return
    }
    // Ghostty duplicates both descriptors, so ours close whatever happens below.
    defer { attachment.close() }
    guard view.attachGeneration == generation,
      terminalSurfaces[shell.id]?.view === view,
      let app
    else { return }

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
    surfaceConfig.external_io = true
    surfaceConfig.external_output_fd = attachment.outputDescriptor
    surfaceConfig.external_pty_fd = attachment.ptyDescriptor

    let surfaceStart = ContinuousClock.now
    let createdSurface = shell.initialPwd.withCString { workingDirectory in
      surfaceConfig.working_directory = workingDirectory
      return ghostty_surface_new(app, &surfaceConfig)
    }
    AxoTrace.surfaces.notice(
      "event=surface.created shell_id=\(shell.id.rawValue) replay_bytes=\(attachment.replayByteCount) surface_new_ms=\(AxoTrace.elapsed(since: surfaceStart), privacy: .public)")
    guard let createdSurface else {
      view.connection = .failed("Ghostty could not create a terminal surface.")
      return
    }
    if let previous = view.detach() {
      ghostty_surface_free(previous)
    }
    view.attach(createdSurface, ptyDescriptor: attachment.ptyDescriptor)
    view.connection = .connected
    updateSurfaceSize(in: view, contentSize: view.bounds.size)
    view.reportPTYSize()
  }

  /// Axod ended a surface's output stream. If the shell still runs (the client fell behind, or
  /// axod restarted the attachment) reattach; if it exited, the reattach is rejected and the
  /// catalog closes the pane. Reattaching is rate-limited so a failing stream cannot spin.
  func surfaceOutputEnded(_ view: GhosttySurfaceNSView) {
    guard let entry = terminalSurfaces[view.shellID], entry.view === view else { return }
    let now = ContinuousClock.now
    if let last = lastReattach[view.shellID], now - last < .seconds(2) { return }
    lastReattach[view.shellID] = now
    createSurface(in: view, shell: entry.shell)
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

  /// Asks the shell's surface, if it exists, to become first responder once it is in a window.
  func requestFocus(for shellID: ShellID) {
    terminalSurfaces[shellID]?.view.requestFocus()
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

  /// Pastes into an existing surface; callers act on a live surface, so there is no retry.
  @discardableResult
  func pasteText(_ text: String, into shellID: ShellID) -> Bool {
    guard !text.isEmpty, let surface = terminalSurfaces[shellID]?.view.surface else { return false }
    text.withCString { ghostty_surface_paste_text(surface, $0, UInt(text.utf8.count)) }
    return true
  }

  /// Keeps surfaces of Sessions that are not shown sized as if they were, so their programs lay
  /// out for the current window and switching to them needs no resize. Sizing the libghostty
  /// surface (not just the PTY) keeps its grid and the PTY in step; a hidden grid left at the old
  /// size would wrap output written for the new one.
  func sizeOffscreenSurfaces(layouts: [TerminalLayout], terminalAreaSize: CGSize, backingScale: CGFloat) {
    guard terminalAreaSize.width > 0, terminalAreaSize.height > 0, backingScale > 0 else { return }
    offscreenBackingScale = backingScale
    offscreenPaneSizes = layouts.reduce(into: [:]) { sizes, layout in
      sizes.merge(TerminalPaneGeometry.paneSizes(for: layout, in: terminalAreaSize)) { _, new in new }
    }
    for entry in terminalSurfaces.values where entry.view.window == nil {
      sizeOffscreenSurface(entry.view)
    }
  }

  private func sizeOffscreenSurface(_ view: GhosttySurfaceNSView) {
    guard let surface = view.surface, let size = offscreenPaneSizes[view.shellID] else { return }
    let scale = offscreenBackingScale
    let width = UInt32(max(0, size.width * scale))
    let height = UInt32(max(0, size.height * scale))
    guard width > 0, height > 0 else { return }
    ghostty_surface_set_content_scale(surface, scale, scale)
    ghostty_surface_set_size(surface, width, height)
    recordCellSize(of: surface)
    view.didApplySurfaceSize()
  }

  private func recordCellSize(of surface: ghostty_surface_t) {
    let size = ghostty_surface_size(surface)
    guard size.cell_width_px > 0, size.cell_height_px > 0 else { return }
    let cell = ClientViewport.PixelSize(width: size.cell_width_px, height: size.cell_height_px)
    if cellPixelSize != cell { cellPixelSize = cell }
  }

  /// Where this window draws terminals, for Axod to size panes no surface shows yet; `nil`
  /// until a surface has measured its cells.
  func viewport(terminalAreaSize: CGSize, backingScale: CGFloat) -> ClientViewport? {
    guard let cellPixelSize else { return nil }
    return ClientViewport(
      terminalArea: .init(width: terminalAreaSize.width, height: terminalAreaSize.height),
      backingScale: backingScale,
      cell: cellPixelSize,
      padding: Self.axoWindowPadding,
      dividerThickness: TerminalPaneGeometry.dividerThickness)
  }

  func updateSurfaceSize(in view: GhosttySurfaceNSView, contentSize: CGSize) {
    // Without a window AppKit has no backing scale to convert with; an offscreen surface (a
    // hidden Session's pane, or one reattached while hidden) takes its size from the layout.
    guard view.window != nil else {
      sizeOffscreenSurface(view)
      return
    }
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
    recordCellSize(of: surface)
    view.didApplySurfaceSize()
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

    var runtimeConfig = Self.makeRuntimeConfig(
      userdata: Unmanaged.passUnretained(self).toOpaque())

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
}

enum GhosttySurfaceAction: String {
  case selectAll = "select_all"
  case undo
  case redo
}
