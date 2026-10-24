import AppKit
import CoreText
import AxoRPC
import Carbon
import Foundation
import GhosttyKit
import SwiftUI

// AppKit invokes local key monitors synchronously on the main event thread. The wrapper lets
// the monitor's sendable callback hand the same event to its MainActor-isolated surface view.
private struct MainActorNSEvent: @unchecked Sendable {
  let value: NSEvent
}

struct GhosttyTerminalView: NSViewRepresentable {
  let runtime: GhosttyRuntime
  let shell: TerminalShell
  let helperURL: URL
  let size: CGSize
  let isFocused: Bool
  let onFocus: () -> Void
  let onStatusChange: (String) -> Void
  let onSplit: (TerminalSplitDirection) -> Void
  let onClose: () -> Void

  func makeNSView(context: Context) -> GhosttySurfaceHostNSView {
    let presentation = makeSurfacePresentation()
    presentation.host.attachSurface(presentation.view)
    presentation.view.reportStatus()
    updateFocus(of: presentation.view)
    return presentation.host
  }

  func updateNSView(_ host: GhosttySurfaceHostNSView, context: Context) {
    let presentation = makeSurfacePresentation()
    host.attachSurface(presentation.view)
    // GeometryReader supplies a creation seed, not the final AppKit viewport.
    // Reparenting after a close may settle the native bounds after this update.
    host.needsLayout = true
    updateFocus(of: presentation.view)
  }

  @MainActor
  private func makeSurfacePresentation() -> (
    host: GhosttySurfaceHostNSView,
    view: GhosttySurfaceNSView
  ) {
    runtime.surfacePresentation(
      for: shell,
      helperURL: helperURL,
      initialSize: size,
      onFocus: {
        runtime.setFocusedShellID(shell.id)
        onFocus()
      },
      onStatusChange: onStatusChange,
      onSplit: onSplit,
      onClose: onClose
    )
  }

  @MainActor
  private func updateFocus(of view: GhosttySurfaceNSView) {
    guard isFocused else {
      view.cancelFocusRequest()
      return
    }
    // Actual responder acquisition reports focus outside the representable update.
    view.requestFocus()
  }

}

@MainActor
final class GhosttySurfaceHostNSView: NSView {
  private var terminalView: NSView?
  // Created only for Ghostty surfaces; it mirrors Ghostty.app's native overlay scrollbar.
  private var scrollbarOverlay: TerminalScrollbarOverlayView?
  private var linkHover: TerminalLinkHoverView?
  private var statusBadge: TerminalStatusBadgeView?
  private var findBar: TerminalFindBarView?

  override var wantsDefaultClipping: Bool { true }

  func attachSurface(_ view: NSView) {
    guard terminalView !== view || view.superview !== self else { return }
    if let terminalView, terminalView !== view {
      terminalView.removeFromSuperview()
    }
    if let previousHost = view.superview as? GhosttySurfaceHostNSView {
      previousHost.releaseSurface(view)
    } else {
      view.removeFromSuperview()
    }
    terminalView = view
    view.frame = bounds
    view.autoresizingMask = [.width, .height]
    addSubview(view)
    if let surfaceView = view as? GhosttySurfaceNSView {
      attachScrollbar(to: surfaceView)
    }
  }

  private func attachScrollbar(to surfaceView: GhosttySurfaceNSView) {
    let overlay = scrollbarOverlay ?? TerminalScrollbarOverlayView(frame: bounds)
    scrollbarOverlay = overlay
    overlay.frame = bounds
    overlay.autoresizingMask = [.width, .height]
    overlay.wheelTarget = surfaceView
    overlay.onScrollToRow = { [weak surfaceView] row in surfaceView?.scrollToRow(row) }
    if overlay.superview !== self {
      addSubview(overlay, positioned: .above, relativeTo: surfaceView)
    }
    surfaceView.onScrollbarChange = { [weak self, weak surfaceView] in
      guard let self, let surfaceView, self.terminalView === surfaceView else { return }
      self.synchronizeScrollbar(with: surfaceView)
    }
    let hover = linkHover ?? TerminalLinkHoverView()
    linkHover = hover
    if hover.superview !== self { addSubview(hover, positioned: .above, relativeTo: overlay) }
    surfaceView.onHoveredLinkChange = { [weak self, weak surfaceView] in
      guard let self, let surfaceView, self.terminalView === surfaceView else { return }
      self.linkHover?.show(surfaceView.hoveredLink, in: self.bounds)
    }
    hover.show(surfaceView.hoveredLink, in: bounds)
    let badge = statusBadge ?? TerminalStatusBadgeView()
    statusBadge = badge
    if badge.superview !== self { addSubview(badge, positioned: .above, relativeTo: overlay) }
    let find = findBar ?? TerminalFindBarView()
    findBar = find
    if find.superview !== self { addSubview(find, positioned: .above, relativeTo: badge) }
    find.onAction = { [weak surfaceView] action in
      surfaceView?.performFind(action)
    }
    surfaceView.onSurfaceStatusChange = { [weak self, weak surfaceView] in
      guard let self, let surfaceView, self.terminalView === surfaceView else { return }
      self.statusBadge?.show(surfaceView.surfaceStatus, in: self.bounds)
      let wasSearching = self.findBar?.isHidden == false
      self.findBar?.show(surfaceView.surfaceStatus.search, in: self.bounds)
      if wasSearching, surfaceView.surfaceStatus.search == nil {
        self.window?.makeFirstResponder(surfaceView)
      }
    }
    badge.show(surfaceView.surfaceStatus, in: bounds)
    find.show(surfaceView.surfaceStatus.search, in: bounds)
    synchronizeScrollbar(with: surfaceView)
  }

  private func synchronizeScrollbar(with surfaceView: GhosttySurfaceNSView) {
    guard let scrollbarOverlay else { return }
    scrollbarOverlay.isHidden = !surfaceView.showsScrollbar
    scrollbarOverlay.setAppearance(darkBackground: surfaceView.hasDarkBackground)
    scrollbarOverlay.update(state: surfaceView.scrollbarState, cellHeight: surfaceView.cellHeight)
  }

  private func removeScrollbar() {
    scrollbarOverlay?.removeFromSuperview()
    scrollbarOverlay?.onScrollToRow = nil
    scrollbarOverlay?.wheelTarget = nil
    scrollbarOverlay = nil
    linkHover?.removeFromSuperview()
    linkHover = nil
    statusBadge?.removeFromSuperview()
    statusBadge = nil
    findBar?.onAction = nil
    findBar?.removeFromSuperview()
    findBar = nil
  }

  func detachSurface() {
    guard let terminalView else { return }
    releaseSurface(terminalView)
  }

  fileprivate func releaseSurface(_ view: NSView) {
    guard terminalView === view else { return }
    terminalView = nil
    removeScrollbar()
    if view.superview === self {
      view.removeFromSuperview()
    }
  }

  override func layout() {
    super.layout()
    guard let terminalView, terminalView.superview === self else { return }
    terminalView.frame = bounds
    (terminalView as? GhosttySurfaceNSView)?.updateContentSize(terminalView.bounds.size)
    scrollbarOverlay?.frame = bounds
  }
}

@MainActor
final class GhosttySurfaceNSView: NSView, @preconcurrency NSTextInputClient,
  @preconcurrency NSServicesMenuRequestor
{
  private(set) var surface: ghostty_surface_t?
  let shellID: Int64
  var status = "Starting Ghostty surface…" {
    didSet {
      guard status != oldValue else { return }
      reportStatus()
    }
  }
  // Surface creation can happen inside makeNSView. Deliver state callbacks only
  // after that SwiftUI update, using the latest callback/status for this view.
  func reportStatus() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.onStatusChange?(self.status)
    }
  }

  var onFocus: (() -> Void)?
  var onStatusChange: ((String) -> Void)?
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
  private var markedText = NSMutableAttributedString()
  private var committedText: [String]?
  private var committedTextDecoder = TerminalCommittedText()
  private var localEventMonitor: Any?
  private var suppressNextLeftMouseUp = false
  private var previousPressureStage = 0
  private var cursor = NSCursor.iBeam
  private var cursorIsVisible = true
  private var lastPerformKeyEvent: TimeInterval?
  private var shouldRequestFocus = false
  private var focusTask: Task<Void, Never>?
  private var trackingArea: NSTrackingArea?
  private(set) var contentSize: CGSize?

  init(
    runtime: GhosttyRuntime,
    shellID: Int64,
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
    updateSurfaceScaleAndSize()
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
    updateSurfaceScaleAndSize()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateContentSize(bounds.size)
  }

  override func setBoundsSize(_ newSize: NSSize) {
    super.setBoundsSize(newSize)
    updateContentSize(bounds.size)
  }

  override func layout() {
    super.layout()
    updateContentSize(bounds.size)
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
    updateSurfaceScaleAndSize()
  }

  func detach() -> ghostty_surface_t? {
    let surface = self.surface
    self.surface = nil
    return surface
  }

  func updateContentSize(_ size: CGSize) {
    // Ignore transient zero-sized detach/reparent passes; never shrink the PTY
    // to an invalid viewport while waiting for the new host's final layout.
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
    contentSize = size
    runtime?.updateSurfaceSize(in: self, contentSize: size)
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    onFocus?()
    sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
  }

  override func mouseUp(with event: NSEvent) {
    if suppressNextLeftMouseUp {
      suppressNextLeftMouseUp = false
      return
    }
    previousPressureStage = 0
    sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    if let surface {
      ghostty_surface_mouse_pressure(surface, 0, 0)
    }
  }

  override func rightMouseDown(with event: NSEvent) {
    guard surface != nil else { return super.rightMouseDown(with: event) }
    window?.makeFirstResponder(self)
    onFocus?()
    if sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT) { return }
    super.rightMouseDown(with: event)
  }

  override func rightMouseUp(with event: NSEvent) {
    guard surface != nil else { return super.rightMouseUp(with: event) }
    if sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT) { return }
    super.rightMouseUp(with: event)
  }

  override func otherMouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    let button = TerminalMouseInput.button(forEventButtonNumber: event.buttonNumber)
    sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: button)
  }

  override func otherMouseUp(with event: NSEvent) {
    let button = TerminalMouseInput.button(forEventButtonNumber: event.buttonNumber)
    sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: button)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    TerminalDropInput.accepts(sender.draggingPasteboard.types ?? []) ? .copy : []
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingEntered(sender)
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    TerminalDropInput.accepts(sender.draggingPasteboard.types ?? [])
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let pasteboard = sender.draggingPasteboard
    let hasFileURLs = pasteboard.pasteboardItems?.contains { $0.types.contains(.fileURL) } ?? false
    let plainText = hasFileURLs ? nil : pasteboard.string(forType: .string)
    let fileURLs = hasFileURLs ? Self.fileURLs(from: pasteboard) : nil
    guard !hasFileURLs || fileURLs != nil,
      let text = TerminalDropInput.text(plainText: plainText, fileURLs: fileURLs)
    else { return false }
    runtime?.pasteText(text, into: shellID)
    return true
  }

  override func mouseMoved(with event: NSEvent) {
    sendMousePosition(event)
  }

  override func mouseDragged(with event: NSEvent) {
    sendMousePosition(event)
  }

  override func rightMouseDragged(with event: NSEvent) {
    sendMousePosition(event)
  }

  override func otherMouseDragged(with event: NSEvent) {
    sendMousePosition(event)
  }

  override func mouseEntered(with event: NSEvent) {
    sendMousePosition(event)
  }

  override func mouseExited(with event: NSEvent) {
    guard NSEvent.pressedMouseButtons == 0 else { return }
    guard let surface else { return }
    ghostty_surface_mouse_pos(surface, -1, -1, Self.ghosttyMods(event.modifierFlags))
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

  override func scrollWheel(with event: NSEvent) {
    guard let surface else { return }
    let deviceMultiplier = TerminalMouseInput.scrollDeviceMultiplier(
      isPrecise: event.hasPreciseScrollingDeltas)
    let sensitivity = runtime?.scrollSensitivity ?? TerminalScrollSensitivity.defaultMultiplier
    let multiplier = sensitivity * deviceMultiplier
    ghostty_surface_mouse_scroll(
      surface,
      event.scrollingDeltaX * multiplier,
      event.scrollingDeltaY * multiplier,
      TerminalMouseInput.scrollFlags(
        isPrecise: event.hasPreciseScrollingDeltas,
        momentumPhase: event.momentumPhase
      )
    )
  }

  override func pressureChange(with event: NSEvent) {
    guard let surface else { return }
    ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    let shouldShowQuickLook = TerminalPressurePolicy.shouldShowQuickLook(
      previousStage: previousPressureStage,
      currentStage: event.stage,
      forceClickEnabled: UserDefaults.standard.bool(forKey: "com.apple.trackpad.forceClick")
    )
    if previousPressureStage < 2 {
      previousPressureStage = event.stage
    }
    guard shouldShowQuickLook else { return }
    quickLook(with: event)
  }

  override func quickLook(with event: NSEvent) {
    guard let surface else { return super.quickLook(with: event) }
    var text = ghostty_text_s()
    guard ghostty_surface_quicklook_word(surface, &text) else {
      return super.quickLook(with: event)
    }
    defer { ghostty_surface_free_text(surface, &text) }
    guard text.text_len > 0, let textPointer = text.text else {
      return super.quickLook(with: event)
    }

    var attributes: [NSAttributedString.Key: Any] = [:]
    if let fontRaw = ghostty_surface_quicklook_font(surface) {
      let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
      attributes[.font] = font.takeUnretainedValue()
      font.release()
    }
    let bytes = Data(bytes: textPointer, count: Int(text.text_len))
    let word = NSAttributedString(
      string: String(decoding: bytes, as: UTF8.self), attributes: attributes)
    let point = NSPoint(x: text.tl_px_x, y: frame.size.height - text.tl_px_y)
    showDefinition(for: word, at: point)
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

  // Keep native key translation and IME handling aligned with Ghostty's AppKit surface bridge
  // at 81598385d608dda4946093d6d6a234d204a2f225; Axo keeps its own command-key routing below.
  override func keyDown(with event: NSEvent) {
    lastPerformKeyEvent = nil
    guard surface != nil else {
      interpretKeyEvents([event])
      return
    }

    let translationEvent = translationEvent(for: event)
    let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
    let markedTextBefore = hasMarkedText()
    let keyboardLayoutBefore = markedTextBefore ? nil : Self.keyboardLayoutID

    committedText = []
    interpretKeyEvents([translationEvent])

    guard markedTextBefore || keyboardLayoutBefore == Self.keyboardLayoutID else {
      committedText = nil
      return
    }

    syncPreedit(clearIfNeeded: markedTextBefore)
    let composing = hasMarkedText() || markedTextBefore
    let inputText = committedText
    committedText = nil

    if markedTextBefore, let inputText, !inputText.isEmpty {
      for text in inputText where !Self.shouldSuppressComposingControlInput(
        text, composing: composing)
      {
        sendCommittedText(action, text: text)
      }

      if Self.shouldReplayCommittedPreeditKey(translationEvent) {
        sendKey(
          event,
          action: action,
          text: nil,
          translationEvent: translationEvent
        )
      }
      return
    }

    if let inputText, !inputText.isEmpty {
      for text in inputText where !Self.shouldSuppressComposingControlInput(
        text, composing: composing)
      {
        sendKey(
          event,
          action: action,
          text: text,
          translationEvent: translationEvent
        )
      }
      return
    }

    guard !Self.shouldSuppressComposingControlInput(event.characters, composing: composing) else {
      return
    }
    sendKey(
      event,
      action: action,
      text: Self.ghosttyCharacters(for: translationEvent),
      translationEvent: translationEvent,
      composing: composing
    )
  }

  override func keyUp(with event: NSEvent) {
    sendKey(event, action: GHOSTTY_ACTION_RELEASE, text: nil)
  }

  override func flagsChanged(with event: NSEvent) {
    guard !hasMarkedText() else { return }

    let modifier: UInt32
    switch event.keyCode {
    case 0x39: modifier = GHOSTTY_MODS_CAPS.rawValue
    case 0x38, 0x3C: modifier = GHOSTTY_MODS_SHIFT.rawValue
    case 0x3B, 0x3E: modifier = GHOSTTY_MODS_CTRL.rawValue
    case 0x3A, 0x3D: modifier = GHOSTTY_MODS_ALT.rawValue
    case 0x37, 0x36: modifier = GHOSTTY_MODS_SUPER.rawValue
    default: return
    }

    let modifiers = Self.ghosttyMods(event.modifierFlags)
    var action = GHOSTTY_ACTION_RELEASE
    if modifiers.rawValue & modifier != 0 {
      let sidePressed: Bool
      switch event.keyCode {
      case 0x3C:
        sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
      case 0x3E:
        sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
      case 0x3D:
        sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
      case 0x36:
        sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
      default:
        sidePressed = true
      }
      if sidePressed {
        action = GHOSTTY_ACTION_PRESS
      }
    }
    sendKey(event, action: action, text: nil)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }

    // A non-terminal first responder, such as a settings field or sheet, owns its editing
    // shortcuts. Let AppKit deliver them instead of invoking the terminal-oriented app menu.
    let terminalFocused = isFocusedKeyResponder && surface != nil
    guard terminalFocused else {
      lastPerformKeyEvent = nil
      return false
    }

    // Give Axo's application menu first refusal so its commands win Ghostty binding collisions.
    let appMenuHandled = super.performKeyEquivalent(with: event)
      || (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
    if !appMenuHandled, performAxoFallbackKeyEquivalent(event) {
      return true
    }
    let bindingMatched = matchesGhosttyKeyBinding(event)
    switch TerminalKeyEquivalentPolicy.route(
      appMenuHandled: appMenuHandled,
      terminalFocused: terminalFocused,
      ghosttyBindingMatched: bindingMatched
    ) {
    case .axoMenu:
      lastPerformKeyEvent = nil
      return true
    case .ghosttyBinding:
      lastPerformKeyEvent = nil
      keyDown(with: event)
      return true
    case .appKit:
      break
    }

    if let equivalent = TerminalKeyEquivalentPolicy.normalizedControlEquivalent(for: event) {
      sendKeyEquivalent(event, characters: equivalent)
      return true
    }

    guard TerminalKeyEquivalentPolicy.shouldRedispatchThroughAppKit(event) else {
      lastPerformKeyEvent = nil
      return false
    }

    if TerminalKeyEquivalentPolicy.matchesRedispatch(
      eventTimestamp: event.timestamp,
      previousTimestamp: lastPerformKeyEvent
    ) {
      lastPerformKeyEvent = nil
      sendKeyEquivalent(event, characters: event.characters ?? "")
      return true
    }

    // AppKit may divert a Command/control key through doCommand before keyDown. Keep the event
    // timestamp so doCommand can redispatch this exact event if that happens.
    lastPerformKeyEvent = event.timestamp
    return false
  }

  func forwardKeyEquivalent(_ event: NSEvent) {
    sendKey(event, action: GHOSTTY_ACTION_PRESS, text: nil)
    sendKey(event, action: GHOSTTY_ACTION_RELEASE, text: nil)
  }

  private func performAxoFallbackKeyEquivalent(_ event: NSEvent) -> Bool {
    guard event.modifierFlags.contains(.command), let runtime else { return false }
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "c":
      lastPerformKeyEvent = nil
      runtime.copySelection()
      return true
    case "v":
      lastPerformKeyEvent = nil
      runtime.pasteClipboard()
      return true
    case "x":
      lastPerformKeyEvent = nil
      runtime.copySelection()
      return true
    case "a", "z":
      lastPerformKeyEvent = nil
      return runtime.forwardKeyEquivalent(event)
    default:
      return false
    }
  }

  @IBAction override func selectAll(_ sender: Any?) {
    _ = runtime?.perform(.selectAll)
  }

  @objc func copy(_ sender: Any?) {
    runtime?.copySelection()
  }

  @objc func paste(_ sender: Any?) {
    runtime?.pasteClipboard()
  }

  @objc private func splitRight(_ sender: Any?) {
    onSplit?(.right)
  }

  @objc private func splitDown(_ sender: Any?) {
    onSplit?(.down)
  }

  @objc private func closePane(_ sender: Any?) {
    onClose?()
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard let surface else { return nil }
    switch event.type {
    case .rightMouseDown:
      break
    case .leftMouseDown:
      guard event.modifierFlags.contains(.control), !ghostty_surface_mouse_captured(surface) else {
        return nil
      }
      sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    default:
      return nil
    }

    window?.makeFirstResponder(self)
    onFocus?()
    let menu = NSMenu()
    menu.autoenablesItems = false
    for item in TerminalContextMenuPolicy.items(
      hasSelection: ghostty_surface_has_selection(surface))
    {
      let title: String
      let action: Selector
      switch item {
      case .copy:
        title = "Copy"
        action = #selector(copy(_:))
      case .paste:
        title = "Paste"
        action = #selector(paste(_:))
      case .separator:
        menu.addItem(.separator())
        continue
      case .splitRight:
        title = "Split Right"
        action = #selector(splitRight(_:))
      case .splitDown:
        title = "Split Down"
        action = #selector(splitDown(_:))
      case .closePane:
        title = "Close Pane"
        action = #selector(closePane(_:))
      }
      menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
    }
    return menu
  }

  override func isAccessibilityElement() -> Bool { true }

  override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

  override func accessibilityLabel() -> String? { "Terminal" }

  override func accessibilityHelp() -> String? {
    "Terminal content area. Only visible screen text is exposed."
  }

  override func accessibilityValue() -> Any? { accessibilityVisibleText() }

  override func accessibilitySelectedTextRange() -> NSRange {
    TerminalAccessibilitySnapshot.selectedRange(
      selectedRange(), visibleText: accessibilityVisibleText())
  }

  override func accessibilitySelectedText() -> String? {
    let visibleText = accessibilityVisibleText()
    let range = TerminalAccessibilitySnapshot.selectedRange(selectedRange(), visibleText: visibleText)
    guard range.location != NSNotFound, range.length > 0 else { return nil }
    return TerminalAccessibilitySnapshot.string(visibleText, in: range)
  }

  override func accessibilityNumberOfCharacters() -> Int {
    (accessibilityVisibleText() as NSString).length
  }

  override func accessibilityVisibleCharacterRange() -> NSRange {
    NSRange(location: 0, length: accessibilityNumberOfCharacters())
  }

  override func accessibilityLine(for index: Int) -> Int {
    TerminalAccessibilitySnapshot.line(for: index, in: accessibilityVisibleText())
  }

  override func accessibilityString(for range: NSRange) -> String? {
    TerminalAccessibilitySnapshot.string(accessibilityVisibleText(), in: range)
  }

  override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
    guard let surface, let value = accessibilityString(for: range) else { return nil }
    var attributes: [NSAttributedString.Key: Any] = [:]
    if let fontRaw = ghostty_surface_quicklook_font(surface) {
      let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
      attributes[.font] = font.takeUnretainedValue()
      font.release()
    }
    return NSAttributedString(string: value, attributes: attributes)
  }

  override func validRequestor(
    forSendType sendType: NSPasteboard.PasteboardType?,
    returnType: NSPasteboard.PasteboardType?
  ) -> Any? {
    guard let surface,
      TerminalServicesPolicy.canServe(
        sendType: sendType,
        returnType: returnType,
        hasSelection: ghostty_surface_has_selection(surface))
    else {
      return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    return self
  }

  func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
    guard !types.isEmpty, types.allSatisfy(TerminalServicesPolicy.textTypes.contains),
      let surface
    else { return false }
    var selection = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &selection) else { return false }
    defer { ghostty_surface_free_text(surface, &selection) }
    guard let text = selection.text else { return false }
    let value = String(decoding: Data(bytes: text, count: Int(selection.text_len)), as: UTF8.self)
    pasteboard.declareTypes([.string], owner: nil)
    return pasteboard.setString(value, forType: .string)
  }

  func readSelection(from pasteboard: NSPasteboard) -> Bool {
    guard let text = TerminalServicesPolicy.textTypes.lazy.compactMap({
      pasteboard.string(forType: $0)
    }).first else { return false }
    runtime?.pasteText(text, into: shellID)
    return true
  }

  func insertText(_ string: Any, replacementRange: NSRange) {
    guard NSApp.currentEvent != nil,
      let text = committedTextDecoder.decode(string)
    else { return }

    unmarkText()
    if committedText != nil {
      committedText?.append(text)
    } else if !text.isEmpty {
      sendCommittedText(GHOSTTY_ACTION_PRESS, text: text)
    }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    switch string {
    case let value as NSAttributedString:
      markedText = NSMutableAttributedString(attributedString: value)
    case let value as String:
      markedText = NSMutableAttributedString(string: value)
    default:
      return
    }
    if committedText == nil {
      syncPreedit(clearIfNeeded: true)
    }
  }

  func unmarkText() {
    guard hasMarkedText() else { return }
    clearMarkedText()
  }

  func hasMarkedText() -> Bool {
    markedText.length > 0
  }

  func markedRange() -> NSRange {
    markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
  }

  func selectedRange() -> NSRange {
    guard let surface else { return NSRange() }
    var selection = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &selection) else { return NSRange() }
    defer { ghostty_surface_free_text(surface, &selection) }
    return NSRange(location: Int(selection.offset_start), length: Int(selection.offset_len))
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    []
  }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    guard let surface, range.length > 0 else { return nil }
    var selection = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &selection) else { return nil }
    defer { ghostty_surface_free_text(surface, &selection) }

    let bytes = selection.text.map {
      Data(bytes: $0, count: Int(selection.text_len))
    } ?? Data()
    var attributes: [NSAttributedString.Key: Any] = [:]
    if let fontRaw = ghostty_surface_quicklook_font(surface) {
      let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
      attributes[.font] = font.takeUnretainedValue()
      font.release()
    }
    return NSAttributedString(
      string: String(decoding: bytes, as: UTF8.self), attributes: attributes)
  }

  func characterIndex(for point: NSPoint) -> Int {
    0
  }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let surface else {
      return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
    }

    let size = ghostty_surface_size(surface)
    let selectionRange = selectedRange()
    let backingScale = max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1, 1)
    let cellSize = CGSize(
      width: CGFloat(size.cell_width_px) / backingScale,
      height: CGFloat(size.cell_height_px) / backingScale
    )
    var x = 0.0
    var y = 0.0
    var width = Double(cellSize.width)
    var height = Double(cellSize.height)
    var selectionTopLeft: CGPoint?

    if range.length > 0, range != selectionRange {
      var selection = ghostty_text_s()
      if ghostty_surface_read_selection(surface, &selection) {
        selectionTopLeft = CGPoint(x: selection.tl_px_x, y: selection.tl_px_y)
        ghostty_surface_free_text(surface, &selection)
      } else {
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
      }
    } else {
      ghostty_surface_ime_point(surface, &x, &y, &width, &height)
    }

    let viewRect = TerminalIMEGeometry.viewRect(
      requestedRange: range,
      selectionRange: selectionRange,
      selectionTopLeft: selectionTopLeft,
      imePoint: CGRect(x: x, y: y, width: width, height: height),
      cellSize: cellSize,
      viewSize: bounds.size
    )
    let windowRect = convert(viewRect, to: nil)
    guard let window else { return windowRect }
    return window.convertToScreen(windowRect)
  }

  override func doCommand(by selector: Selector) {
    guard let lastPerformKeyEvent else { return }
    guard isFocusedKeyResponder, surface != nil,
      let currentEvent = NSApp.currentEvent,
      currentEvent.timestamp == lastPerformKeyEvent
    else {
      self.lastPerformKeyEvent = nil
      return
    }
    NSApp.sendEvent(currentEvent)
  }

  private var isFocusedKeyResponder: Bool {
    guard let window else { return false }
    return NSApp.isActive && window.isKeyWindow && window.firstResponder === self
  }

  private func accessibilityVisibleText() -> String {
    guard let surface else { return "" }
    var visible = ghostty_text_s()
    let viewport = ghostty_selection_s(
      top_left: ghostty_point_s(
        tag: GHOSTTY_POINT_VIEWPORT,
        coord: GHOSTTY_POINT_COORD_TOP_LEFT,
        x: 0,
        y: 0),
      bottom_right: ghostty_point_s(
        tag: GHOSTTY_POINT_VIEWPORT,
        coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
        x: 0,
        y: 0),
      rectangle: false)
    guard ghostty_surface_read_text(surface, viewport, &visible) else { return "" }
    defer { ghostty_surface_free_text(surface, &visible) }
    guard let pointer = visible.text else { return "" }
    let byteCount = min(Int(visible.text_len), TerminalAccessibilitySnapshot.maximumUTF8Bytes)
    let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(pointer), count: byteCount)
    return TerminalAccessibilitySnapshot.bounded(String(decoding: bytes, as: UTF8.self))
  }

  private static func fileURLs(from pasteboard: NSPasteboard) -> [URL]? {
    let fileItems = (pasteboard.pasteboardItems ?? []).filter { $0.types.contains(.fileURL) }
    guard !fileItems.isEmpty else { return nil }
    let fileURLs = fileItems.compactMap { item -> URL? in
      guard let propertyList = item.propertyList(forType: .fileURL),
        let url = NSURL(pasteboardPropertyList: propertyList, ofType: .fileURL) as URL?,
        url.isFileURL
      else { return nil }
      return url
    }
    guard fileURLs.count == fileItems.count else { return nil }
    return fileURLs
  }

  private func handleFocusOnlyLeftClick(_ event: NSEvent) -> Bool {
    guard let window, event.window === window, let contentView = window.contentView else {
      return false
    }
    let location = contentView.convert(event.locationInWindow, from: nil)
    guard contentView.hitTest(location) === self else { return false }

    suppressNextLeftMouseUp = false
    let surfaceIsFirstResponder = window.firstResponder === self
    guard !surfaceIsFirstResponder else { return false }
    let shouldConsume = TerminalMouseInput.shouldConsumeFocusOnlyClick(
      surfaceIsFirstResponder: surfaceIsFirstResponder,
      applicationIsActive: NSApp.isActive,
      windowIsKey: window.isKeyWindow
    )
    _ = window.makeFirstResponder(self)
    guard shouldConsume else { return false }
    suppressNextLeftMouseUp = true
    return true
  }

  private func sendKeyEquivalent(_ event: NSEvent, characters: String) {
    guard let translatedEvent = NSEvent.keyEvent(
      with: .keyDown,
      location: event.locationInWindow,
      modifierFlags: event.modifierFlags,
      timestamp: event.timestamp,
      windowNumber: event.windowNumber,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: event.isARepeat,
      keyCode: event.keyCode
    ) else { return }
    lastPerformKeyEvent = nil
    keyDown(with: translatedEvent)
  }

  private func matchesGhosttyKeyBinding(_ event: NSEvent) -> Bool {
    guard let surface else { return false }
    var keyEvent = makeKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
    let text = event.characters ?? ""
    return text.withCString { pointer in
      keyEvent.text = pointer
      var flags = ghostty_binding_flags_e(0)
      return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
    }
  }

  private func translationEvent(for event: NSEvent) -> NSEvent {
    guard let surface else { return event }
    let translatedModifiers = Self.eventModifierFlags(
      ghostty_surface_key_translation_mods(surface, Self.ghosttyMods(event.modifierFlags))
    )

    var modifierFlags = event.modifierFlags
    for flag: NSEvent.ModifierFlags in [.shift, .control, .option, .command] {
      if translatedModifiers.contains(flag) {
        modifierFlags.insert(flag)
      } else {
        modifierFlags.remove(flag)
      }
    }
    guard modifierFlags != event.modifierFlags else { return event }

    return NSEvent.keyEvent(
      with: event.type,
      location: event.locationInWindow,
      modifierFlags: modifierFlags,
      timestamp: event.timestamp,
      windowNumber: event.windowNumber,
      context: nil,
      characters: event.characters(byApplyingModifiers: modifierFlags) ?? "",
      charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
      isARepeat: event.isARepeat,
      keyCode: event.keyCode
    ) ?? event
  }

  private func syncPreedit(clearIfNeeded: Bool) {
    guard let surface else { return }
    if hasMarkedText() {
      markedText.string.withCString {
        ghostty_surface_preedit(surface, $0, UInt(markedText.string.utf8.count))
      }
    } else if clearIfNeeded {
      ghostty_surface_preedit(surface, nil, 0)
    }
  }

  private func sendCommittedText(_ action: ghostty_input_action_e, text: String) {
    guard let surface else { return }
    var keyEvent = ghostty_input_key_s()
    keyEvent.action = action
    keyEvent.keycode = 0
    keyEvent.text = nil
    keyEvent.composing = false
    keyEvent.mods = GHOSTTY_MODS_NONE
    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
    keyEvent.unshifted_codepoint = 0
    text.withCString {
      keyEvent.text = $0
      _ = ghostty_surface_key(surface, keyEvent)
    }
  }

  private func clearMarkedText() {
    markedText = NSMutableAttributedString()
    if let surface {
      ghostty_surface_preedit(surface, nil, 0)
    }
  }

  private func updateSurfaceScaleAndSize() {
    runtime?.updateSurfaceSize(in: self, contentSize: contentSize ?? bounds.size)
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

  private func sendKey(
    _ event: NSEvent,
    action: ghostty_input_action_e,
    text: String?,
    translationEvent: NSEvent? = nil,
    composing: Bool? = nil
  ) {
    guard let surface else { return }
    var keyEvent = makeKeyEvent(
      event,
      action: action,
      translationEvent: translationEvent,
      composing: composing
    )

    guard let text = Self.keyEventText(text) else {
      keyEvent.text = nil
      _ = ghostty_surface_key(surface, keyEvent)
      return
    }
    text.withCString { pointer in
      keyEvent.text = pointer
      _ = ghostty_surface_key(surface, keyEvent)
    }
  }

  private func makeKeyEvent(
    _ event: NSEvent,
    action: ghostty_input_action_e,
    translationEvent: NSEvent? = nil,
    composing: Bool? = nil
  ) -> ghostty_input_key_s {
    var keyEvent = ghostty_input_key_s()
    keyEvent.action = action
    keyEvent.keycode = UInt32(event.keyCode)
    keyEvent.text = nil
    keyEvent.composing = composing ?? hasMarkedText()
    keyEvent.mods = Self.ghosttyMods(event.modifierFlags)
    keyEvent.consumed_mods = Self.ghosttyMods(
      (translationEvent?.modifierFlags ?? event.modifierFlags)
        .subtracting([.control, .command])
    )
    if event.type == .keyDown || event.type == .keyUp,
      let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first
    {
      keyEvent.unshifted_codepoint = scalar.value
    }
    return keyEvent
  }

  @discardableResult
  private func sendMouseButton(
    _ event: NSEvent,
    state: ghostty_input_mouse_state_e,
    button: ghostty_input_mouse_button_e
  ) -> Bool {
    guard let surface else { return false }
    return ghostty_surface_mouse_button(
      surface, state, button, Self.ghosttyMods(event.modifierFlags))
  }

  private func sendMousePosition(_ event: NSEvent) {
    guard let surface else { return }
    let point = convert(event.locationInWindow, from: nil)
    ghostty_surface_mouse_pos(
      surface,
      point.x,
      bounds.height - point.y,
      Self.ghosttyMods(event.modifierFlags)
    )
  }

  private static var keyboardLayoutID: String? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
      let sourceID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    else { return nil }
    return unsafeBitCast(sourceID, to: CFString.self) as String
  }

  private static func keyEventText(_ text: String?) -> String? {
    guard let text, !text.isEmpty, let scalar = text.unicodeScalars.first else { return nil }
    guard scalar.value >= 0x20, scalar.value != 0x7F else { return nil }
    return text
  }

  private static func shouldSuppressComposingControlInput(
    _ text: String?,
    composing: Bool
  ) -> Bool {
    guard composing, let text else { return false }
    let scalars = text.unicodeScalars
    guard let scalar = scalars.first,
      scalars.index(after: scalars.startIndex) == scalars.endIndex
    else { return false }
    return scalar.value < 0x20
  }

  private static func shouldReplayCommittedPreeditKey(_ event: NSEvent) -> Bool {
    switch event.keyCode {
    case 0x7D, 0x7C, 0x7E:
      return true
    case 0x7B:
      return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
    default:
      return false
    }
  }

  private static func ghosttyCharacters(for event: NSEvent) -> String? {
    guard let characters = event.characters else { return nil }
    if let scalar = characters.unicodeScalars.first, characters.unicodeScalars.count == 1 {
      if scalar.value < 0x20 {
        return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
      }
      if (0xF700...0xF8FF).contains(scalar.value) {
        return nil
      }
    }
    return characters
  }

  private static func eventModifierFlags(
    _ modifiers: ghostty_input_mods_e
  ) -> NSEvent.ModifierFlags {
    var flags = NSEvent.ModifierFlags(rawValue: 0)
    if modifiers.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
    if modifiers.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
    if modifiers.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
    if modifiers.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
    return flags
  }

  private static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
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

enum TerminalKeyEquivalentPolicy {
  enum Route: Equatable {
    case axoMenu
    case ghosttyBinding
    case appKit
  }

  static func route(
    appMenuHandled: Bool,
    terminalFocused: Bool,
    ghosttyBindingMatched: Bool
  ) -> Route {
    guard terminalFocused else { return .appKit }
    if appMenuHandled { return .axoMenu }
    if ghosttyBindingMatched { return .ghosttyBinding }
    return .appKit
  }

  static func normalizedControlEquivalent(for event: NSEvent) -> String? {
    switch event.charactersIgnoringModifiers {
    case "\r":
      return event.modifierFlags.contains(.control) ? "\r" : nil
    case "/":
      guard event.modifierFlags.contains(.control),
        event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
      else { return nil }
      return "_"
    default:
      return nil
    }
  }

  static func shouldRedispatchThroughAppKit(_ event: NSEvent) -> Bool {
    event.timestamp != 0 && !event.modifierFlags.isDisjoint(with: [.command, .control])
  }

  static func shouldForwardCommandKeyUp(_ event: NSEvent) -> Bool {
    event.type == .keyUp && event.modifierFlags.contains(.command)
  }

  static func matchesRedispatch(eventTimestamp: TimeInterval, previousTimestamp: TimeInterval?) -> Bool {
    previousTimestamp == eventTimestamp
  }
}
