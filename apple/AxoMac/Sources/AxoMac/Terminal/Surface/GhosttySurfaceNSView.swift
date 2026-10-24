import AppKit
import AxoRPC
import GhosttyKit

// AppKit invokes local key monitors synchronously on the main event thread. The wrapper lets
// the monitor's sendable callback hand the same event to its MainActor-isolated surface view.
private struct MainActorNSEvent: @unchecked Sendable {
  let value: NSEvent
}

/// One libghostty surface. Input concerns live in the `GhosttySurfaceNSView+*.swift` extensions;
/// stored state stays here so its lifetime and ownership are visible in one place.
@MainActor
final class GhosttySurfaceNSView: NSView, @MainActor NSTextInputClient,
  @MainActor NSServicesMenuRequestor
{
  private(set) var surface: ghostty_surface_t?
  let shellID: ShellID
  /// Increments per attach attempt so a slow, superseded attach never installs its surface.
  var attachGeneration = 0
  var connection = TerminalSurfaceConnection.starting {
    didSet {
      guard connection != oldValue else { return }
      reportStatus()
    }
  }
  // Surface creation can happen inside makeNSView. Deliver state callbacks only
  // after that SwiftUI update, using the latest callback/status for this view.
  func reportStatus() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.onStatusChange?(self.connection)
    }
  }

  var onFocus: (() -> Void)?
  var onStatusChange: ((TerminalSurfaceConnection) -> Void)?
  var onSplit: ((TerminalSplitDirection) -> Void)?
  var onClose: (() -> Void)?
  var onScrollbarChange: (() -> Void)?
  var onHoveredLinkChange: (() -> Void)?
  private(set) var scrollbarState: TerminalScrollbarState?
  private(set) var hoveredLink: String?
  private(set) var surfaceStatus = TerminalSurfaceStatus()
  var onSurfaceStatusChange: (() -> Void)?
  var isFocusedTerminal: Bool { isFocusedKeyResponder }

  func apply(_ event: TerminalSurfaceStatus.Event) {
    let previous = surfaceStatus
    surfaceStatus.apply(event)
    if surfaceStatus != previous { onSurfaceStatusChange?() }
  }
  private let windowStateObserver = TerminalWindowStateObserver()

  func updateHoveredLink(_ link: String?) {
    guard hoveredLink != link else { return }
    hoveredLink = link
    onHoveredLinkChange?()
  }

  private(set) weak var runtime: GhosttyRuntime?
  private var localEventMonitor: Any?
  private var cursor = NSCursor.iBeam
  private var cursorIsVisible = true

  // Input state owned here and mutated only by the +Keyboard/+TextInput/+Mouse extensions.
  // Swift's `private` is file-scoped, so these are module-internal by necessity.
  var markedText = NSMutableAttributedString()
  var committedText: [String]?
  var committedTextDecoder = TerminalCommittedText()
  var suppressNextLeftMouseUp = false
  var previousPressureStage = 0
  var lastPerformKeyEvent: TimeInterval?
  private var shouldRequestFocus = false
  private var focusTask: Task<Void, Never>?
  private var trackingArea: NSTrackingArea?
  private(set) var contentSize: CGSize?

  init(
    runtime: GhosttyRuntime,
    shellID: ShellID,
    initialFrameSize: CGSize,
    onFocus: @escaping () -> Void
  ) {
    self.runtime = runtime
    self.shellID = shellID
    self.onFocus = onFocus
    super.init(frame: CGRect(origin: .zero, size: initialFrameSize))
    setAccessibilityIdentifier("axo-terminal-surface")
    registerForDraggedTypes([.string, .fileURL])
    localEventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyUp, .leftMouseDown]
    ) { [weak self] event in
      guard let self else { return event }
      let actorEvent = MainActorNSEvent(value: event)
      let shouldConsume = MainActor.assumeIsolated {
        let event = actorEvent.value
        switch event.type {
        case .keyUp:
          guard TerminalKeyEquivalentPolicy.shouldForwardCommandKeyUp(event),
            self.isFocusedKeyResponder,
            self.surface != nil
          else { return false }
          self.keyUp(with: event)
          return true
        case .leftMouseDown:
          return self.handleFocusOnlyLeftClick(event)
        default:
          return false
        }
      }
      return shouldConsume ? nil : event
    }
  }

  deinit {
    if let localEventMonitor {
      NSEvent.removeMonitor(localEventMonitor)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for GhosttySurfaceNSView")
  }

  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateTrackingAreas()
    syncSurfaceSize()
    updateSurfaceFocus()
    updateSurfaceOcclusion()
    windowStateObserver.observe(
      window,
      onOcclusionChange: { [weak self] in self?.updateSurfaceOcclusion() },
      onKeyChange: { [weak self] in self?.updateSurfaceFocus() })
    if shouldRequestFocus {
      requestFocus()
    }
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    syncSurfaceSize()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    syncSurfaceSize()
  }

  override func setBoundsSize(_ newSize: NSSize) {
    super.setBoundsSize(newSize)
    syncSurfaceSize()
  }

  override func layout() {
    super.layout()
    syncSurfaceSize()
  }

  override func becomeFirstResponder() -> Bool {
    cancelFocusRequest()
    onFocus?()
    updateSurfaceFocus(true)
    return true
  }

  override func resignFirstResponder() -> Bool {
    updateSurfaceFocus(false)
    return true
  }

  override func updateTrackingAreas() {
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
    super.updateTrackingAreas()
  }

  func requestFocus() {
    if window?.firstResponder === self {
      shouldRequestFocus = false
      return
    }
    shouldRequestFocus = true
    guard focusTask == nil else { return }
    focusTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard !Task.isCancelled, let self else { return }
      self.focusTask = nil
      guard self.shouldRequestFocus, let window = self.window else { return }
      if window.firstResponder !== self {
        _ = window.makeFirstResponder(self)
      }
    }
  }

  func cancelFocusRequest() {
    shouldRequestFocus = false
    focusTask?.cancel()
    focusTask = nil
  }

  func attach(_ surface: ghostty_surface_t) {
    self.surface = surface
    syncSurfaceSize()
  }

  func detach() -> ghostty_surface_t? {
    let surface = self.surface
    self.surface = nil
    return surface
  }

  /// The single path from AppKit geometry to libghostty. Runs on attach, window and backing
  /// changes and every frame/bounds/layout pass, and always reads this view's own final bounds
  /// (never a SwiftUI proposal or a former host's size).
  func syncSurfaceSize() {
    let size = bounds.size
    // Ignore transient zero-sized detach/reparent passes; never shrink the PTY
    // to an invalid viewport while waiting for the new host's final layout.
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
    contentSize = size
    runtime?.updateSurfaceSize(in: self, contentSize: size)
  }

  /// Ghostty's cell height in points, used to map scrollback rows onto the overlay scroller.
  var cellHeight: CGFloat {
    guard let surface else { return 0 }
    let backingScale = max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1, 1)
    return CGFloat(ghostty_surface_size(surface).cell_height_px) / backingScale
  }

  var showsScrollbar: Bool { runtime?.showsScrollbar ?? true }
  var hasDarkBackground: Bool { runtime?.hasDarkBackground ?? true }

  func updateScrollbar(_ state: TerminalScrollbarState?) {
    scrollbarState = state
    onScrollbarChange?()
  }

  func cellSizeDidChange() {
    onScrollbarChange?()
  }

  func performFind(_ action: TerminalFindAction) {
    guard let surface else { return }
    let binding = action.bindingAction
    _ = binding.withCString { ghostty_surface_binding_action(surface, $0, UInt(binding.utf8.count)) }
  }

  @objc func performFindPanelAction(_ sender: Any?) {
    let tag = (sender as? NSMenuItem)?.tag ?? Int(NSFindPanelAction.showFindPanel.rawValue)
    switch NSFindPanelAction(rawValue: UInt(tag)) {
    case .next: performFind(.next)
    case .previous: performFind(.previous)
    case .setFindString: performFind(.selection)
    default: performFind(.start)
    }
  }

  func scrollToRow(_ row: Int) {
    guard let surface, row >= 0 else { return }
    let action = "scroll_to_row:\(row)"
    _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    guard cursorIsVisible else { return }
    addCursorRect(bounds, cursor: cursor)
  }

  func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
    guard let cursor = TerminalCursorPolicy.cursor(for: shape) else { return }
    self.cursor = cursor
    window?.invalidateCursorRects(for: self)
  }

  func setCursorVisibility(_ visible: Bool) {
    cursorIsVisible = visible
    NSCursor.setHiddenUntilMouseMoves(!visible)
    window?.invalidateCursorRects(for: self)
  }

  var isFocusedKeyResponder: Bool {
    guard let window else { return false }
    return NSApp.isActive && window.isKeyWindow && window.firstResponder === self
  }

  private func updateSurfaceFocus(_ focused: Bool? = nil) {
    guard let surface else { return }
    let hasFocus = focused ?? (window?.isKeyWindow == true && window?.firstResponder === self)
    ghostty_surface_set_focus(surface, hasFocus)
    runtime?.refreshSecureInput()
  }

  private func updateSurfaceOcclusion() {
    guard let surface else { return }
    ghostty_surface_set_occlusion(surface, window?.occlusionState.contains(.visible) == true)
  }


  static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var value = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { value |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { value |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { value |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { value |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { value |= GHOSTTY_MODS_CAPS.rawValue }
    let rawFlags = flags.rawValue
    if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { value |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { value |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { value |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { value |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
    return ghostty_input_mods_e(value)
  }
}
