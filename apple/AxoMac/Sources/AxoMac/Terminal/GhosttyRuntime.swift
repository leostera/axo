import AppKit
import AxoProtocol
import Carbon
import Darwin
import Foundation
import GhosttyKit
import QuartzCore

/// The libghostty app: its configuration, ticks and callbacks, the terminal preferences derived
/// from them, focus, attention and secure input, and routing of menu commands to the focused
/// surface. The surfaces themselves live in `surfaces`.
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
  /// The padding libghostty draws around every grid, in points; see `windowPadding(from:)`.
  @ObservationIgnored private(set) var windowPadding = GhosttyRuntime.axoWindowPadding
  /// One cell of the most recently sized surface, in device pixels; `nil` before any surface.
  private(set) var cellPixelSize: ClientViewport.PixelSize?

  @ObservationIgnored private var config: ghostty_config_t?
  /// The libghostty app every surface belongs to; `nil` if libghostty failed to start.
  @ObservationIgnored private(set) var app: ghostty_app_t?
  private(set) var focusedShellID: ShellID?
  /// Every terminal surface; see `TerminalSurfaceRegistry`.
  @ObservationIgnored let surfaces = TerminalSurfaceRegistry()
  @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []

  init(initializeGhostty: Bool = true) {
    let storedSensitivity =
      UserDefaults.standard.object(
        forKey: TerminalScrollSensitivity.preferenceKey
      ) as? Double
    scrollSensitivity = TerminalScrollSensitivity.boundedMultiplier(
      storedSensitivity ?? TerminalScrollSensitivity.defaultMultiplier
    )
    surfaces.runtime = self
    if initializeGhostty { initialize() }
  }

  deinit {
    notificationTokens.forEach(NotificationCenter.default.removeObserver)
    // Surfaces belong to the app: free them first.
    MainActor.assumeIsolated { surfaces.freeAll() }
    if let app {
      ghostty_app_free(app)
    }
    if let config {
      ghostty_config_free(config)
    }
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
    let wanted = surfaces.views.contains { $0.surfaceStatus.secureInput && $0.isFocusedTerminal }
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

  func setScrollSensitivity(_ multiplier: Double) {
    let multiplier = TerminalScrollSensitivity.boundedMultiplier(multiplier)
    guard multiplier != scrollSensitivity else { return }
    scrollSensitivity = multiplier
    UserDefaults.standard.set(multiplier, forKey: TerminalScrollSensitivity.preferenceKey)
  }

  func reconcileSurfaces(with shells: [TerminalShell]) {
    let openShells = Dictionary(uniqueKeysWithValues: shells.filter(\.isAvailable).map { ($0.id, $0) })
    surfaces.reconcile(with: openShells)
    let staleAttention = attentionShellIDs.filter { openShells[$0] == nil }
    if !staleAttention.isEmpty { attentionShellIDs.subtract(staleAttention) }
  }

  /// How long libghostty may wait for the main thread to tick before it is reported.
  static let tickDelayReportThreshold: Duration = .milliseconds(50)

  /// Runs libghostty's main-thread work (surface messages, frame presentation). `requestedAt`
  /// is when libghostty asked for it; the wait is how long a busy main thread held it back.
  func tick(requestedAt: ContinuousClock.Instant? = nil) {
    guard let app else { return }
    let started = ContinuousClock.now
    let state = AxoTrace.signposter.beginInterval("ghostty.tick")
    ghostty_app_tick(app)
    AxoTrace.signposter.endInterval("ghostty.tick", state)
    guard let requestedAt else { return }
    let waited = started - requestedAt
    if waited > Self.tickDelayReportThreshold {
      AxoTrace.latency.notice(
        "event=ghostty.tick_delayed waited_ms=\(AxoTrace.milliseconds(waited), privacy: .public) tick_ms=\(AxoTrace.elapsed(since: started), privacy: .public)")
    }
  }

  func updateFocus(_ focused: Bool) {
    guard let app else { return }
    ghostty_app_set_focus(app, focused)
  }

  var keyWindowFocusedShellID: ShellID? {
    guard let focusedView = NSApp.keyWindow?.firstResponder as? GhosttySurfaceNSView else {
      return nil
    }
    return surfaces.views.contains { $0 === focusedView } ? focusedView.shellID : nil
  }

  @discardableResult
  func insertText(_ text: String, into shellID: ShellID) -> Bool {
    guard let view = surfaces.view(for: shellID), view.surface != nil else { return false }
    view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    return true
  }

  @discardableResult
  func perform(_ action: GhosttySurfaceAction, on shellID: ShellID? = nil) -> Bool {
    guard let shellID = shellID ?? focusedShellID,
      let surface = surfaces.view(for: shellID)?.surface
    else { return false }
    return action.rawValue.withCString {
      ghostty_surface_binding_action(surface, $0, UInt(action.rawValue.utf8.count))
    }
  }

  /// Routes Axo's Find menu to the focused terminal surface only.
  func performFind(_ action: TerminalFindAction) {
    guard let shellID = focusedShellID else { return }
    surfaces.view(for: shellID)?.performFind(action)
  }

  func forwardKeyEquivalent(_ event: NSEvent) -> Bool {
    guard let shellID = focusedShellID,
      let view = surfaces.view(for: shellID),
      view.surface != nil
    else { return false }
    view.forwardKeyEquivalent(event)
    return true
  }

  func copySelection(from shellID: ShellID? = nil) {
    guard let shellID = shellID ?? focusedShellID,
      let surface = surfaces.view(for: shellID)?.surface
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
    guard !text.isEmpty, let surface = surfaces.view(for: shellID)?.surface else { return false }
    text.withCString { ghostty_surface_paste_text(surface, $0, UInt(text.utf8.count)) }
    return true
  }

  /// Records one cell of the most recently sized surface.
  func noteCellPixelSize(_ cell: ClientViewport.PixelSize) {
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
      padding: windowPadding,
      dividerThickness: TerminalPaneGeometry.dividerThickness)
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
    windowPadding = Self.windowPadding(from: config)
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
