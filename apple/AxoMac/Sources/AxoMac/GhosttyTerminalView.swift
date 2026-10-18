import AppKit
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

  func makeNSView(context: Context) -> GhosttySurfaceHostNSView {
    let surfaceView = runtime.surfaceView(
      for: shell,
      helperURL: helperURL,
      onFocus: {
        runtime.setFocusedShellID(shell.id)
        onFocus()
      },
      onStatusChange: onStatusChange
    )
    guard let host = runtime.surfaceHost(for: shell.id) else {
      preconditionFailure("Ghostty runtime did not retain a host for shell \(shell.id).")
    }
    host.attachSurface(surfaceView)
    surfaceView.updateContentSize(size)
    if isFocused {
      runtime.setFocusedShellID(shell.id)
      surfaceView.requestFocus()
    }
    return host
  }

  func updateNSView(_ host: GhosttySurfaceHostNSView, context: Context) {
    let surfaceView = runtime.surfaceView(
      for: shell,
      helperURL: helperURL,
      onFocus: {
        runtime.setFocusedShellID(shell.id)
        onFocus()
      },
      onStatusChange: onStatusChange
    )
    host.attachSurface(surfaceView)
    if host.bounds.size != size {
      host.needsLayout = true
    }
    surfaceView.updateContentSize(size)
    if isFocused {
      runtime.setFocusedShellID(shell.id)
      surfaceView.requestFocus()
    } else {
      surfaceView.cancelFocusRequest()
    }
  }

}

@MainActor
final class GhosttySurfaceHostNSView: NSView {
  private var terminalView: NSView?

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
  }

  func detachSurface() {
    guard let terminalView else { return }
    releaseSurface(terminalView)
  }

  fileprivate func releaseSurface(_ view: NSView) {
    guard terminalView === view else { return }
    terminalView = nil
    if view.superview === self {
      view.removeFromSuperview()
    }
  }

  override func layout() {
    super.layout()
    guard let terminalView, terminalView.superview === self else { return }
    terminalView.frame = bounds
  }
}

@MainActor
final class GhosttySurfaceNSView: NSView, @preconcurrency NSTextInputClient {
  private(set) var surface: ghostty_surface_t?
  var status = "Starting Ghostty surface…" {
    didSet { onStatusChange?(status) }
  }
  var onFocus: (() -> Void)?
  var onStatusChange: ((String) -> Void)?

  private weak var runtime: GhosttyRuntime?
  private var markedText = NSMutableAttributedString()
  private var committedText: [String]?
  private var keyUpEventMonitor: Any?
  private var lastPerformKeyEvent: TimeInterval?
  private var shouldRequestFocus = false
  private var focusTask: Task<Void, Never>?
  private var trackingArea: NSTrackingArea?
  private var contentSize: CGSize?

  init(runtime: GhosttyRuntime, onFocus: @escaping () -> Void) {
    self.runtime = runtime
    self.onFocus = onFocus
    super.init(frame: .zero)
    registerForDraggedTypes([.string, .fileURL])
    keyUpEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
      guard let self else { return event }
      let actorEvent = MainActorNSEvent(value: event)
      let shouldConsume = MainActor.assumeIsolated {
        let event = actorEvent.value
        guard TerminalKeyEquivalentPolicy.shouldForwardCommandKeyUp(event),
          self.isFocusedKeyResponder,
          self.surface != nil
        else { return false }
        self.keyUp(with: event)
        return true
      }
      return shouldConsume ? nil : event
    }
  }

  deinit {
    if let keyUpEventMonitor {
      NSEvent.removeMonitor(keyUpEventMonitor)
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
    if shouldRequestFocus {
      requestFocus()
    }
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateSurfaceScaleAndSize()
  }

  override func layout() {
    super.layout()
    updateSurfaceScaleAndSize()
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
      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
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
    guard size.width > 0, size.height > 0 else { return }
    contentSize = size
    runtime?.updateSurfaceSize(in: self, contentSize: size)
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    onFocus?()
    sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
  }

  override func mouseUp(with event: NSEvent) {
    sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
  }

  override func rightMouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    onFocus?()
    sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
  }

  override func rightMouseUp(with event: NSEvent) {
    sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
  }

  override func otherMouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    let button = event.buttonNumber == 2 ? GHOSTTY_MOUSE_MIDDLE : GHOSTTY_MOUSE_UNKNOWN
    sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: button)
  }

  override func otherMouseUp(with event: NSEvent) {
    let button = event.buttonNumber == 2 ? GHOSTTY_MOUSE_MIDDLE : GHOSTTY_MOUSE_UNKNOWN
    sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: button)
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

  override func scrollWheel(with event: NSEvent) {
    guard let surface else { return }
    let deviceMultiplier = event.hasPreciseScrollingDeltas ? 1.5 : 1.0
    let sensitivity = runtime?.scrollSensitivity ?? TerminalScrollSensitivity.defaultMultiplier
    let multiplier = sensitivity * deviceMultiplier
    ghostty_surface_mouse_scroll(
      surface,
      event.scrollingDeltaX * multiplier,
      event.scrollingDeltaY * multiplier,
      0
    )
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

    // Give Axo's application menu first refusal so its commands win shortcut collisions.
    let appMenuHandled = super.performKeyEquivalent(with: event)
      || (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
    let terminalFocused = isFocusedKeyResponder && surface != nil
    if !appMenuHandled, terminalFocused, performAxoFallbackKeyEquivalent(event) {
      return true
    }
    let bindingMatched = terminalFocused && matchesGhosttyKeyBinding(event)
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
      guard terminalFocused else {
        lastPerformKeyEvent = nil
        return false
      }
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

  func insertText(_ string: Any, replacementRange: NSRange) {
    let text: String
    switch string {
    case let value as NSAttributedString:
      text = value.string
    case let value as String:
      text = value
    default:
      return
    }

    if committedText != nil {
      committedText?.append(text)
    } else if let surface {
      text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
    }
    clearMarkedText()
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
    guard let surface else { return }
    markedText.string.withCString {
      ghostty_surface_preedit(surface, $0, UInt(markedText.string.utf8.count))
    }
  }

  func unmarkText() {
    clearMarkedText()
  }

  func hasMarkedText() -> Bool {
    markedText.length > 0
  }

  func markedRange() -> NSRange {
    markedText.length > 0
      ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
  }

  func selectedRange() -> NSRange {
    NSRange(location: NSNotFound, length: 0)
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    []
  }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    nil
  }

  func characterIndex(for point: NSPoint) -> Int {
    NSNotFound
  }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let surface, let window else { return .zero }
    var x = 0.0
    var y = 0.0
    var width = 0.0
    var height = 0.0
    ghostty_surface_ime_point(surface, &x, &y, &width, &height)
    let localRect = NSRect(x: x, y: bounds.height - y - height, width: width, height: height)
    return window.convertToScreen(convert(localRect, to: nil))
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

  private func sendMouseButton(
    _ event: NSEvent,
    state: ghostty_input_mouse_state_e,
    button: ghostty_input_mouse_button_e
  ) {
    guard let surface else { return }
    _ = ghostty_surface_mouse_button(surface, state, button, Self.ghosttyMods(event.modifierFlags))
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
    if appMenuHandled { return .axoMenu }
    if !terminalFocused { return .appKit }
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
