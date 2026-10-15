import AppKit
import AxoRPC
import Foundation
import GhosttyKit
import SwiftUI

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
  private var shouldRequestFocus = false
  private var focusTask: Task<Void, Never>?
  private var trackingArea: NSTrackingArea?
  private var contentSize: CGSize?

  init(runtime: GhosttyRuntime, onFocus: @escaping () -> Void) {
    self.runtime = runtime
    self.onFocus = onFocus
    super.init(frame: .zero)
    registerForDraggedTypes([.string, .fileURL])
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

  override func keyDown(with event: NSEvent) {
    guard surface != nil else { return }
    committedText = []
    interpretKeyEvents([event])

    let text: String?
    if let committedText, !committedText.isEmpty {
      text = committedText.joined()
    } else {
      text = Self.ghosttyCharacters(for: event)
    }
    committedText = nil
    sendKey(
      event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS, text: text)
  }

  override func keyUp(with event: NSEvent) {
    sendKey(event, action: GHOSTTY_ACTION_RELEASE, text: nil)
  }

  override func flagsChanged(with event: NSEvent) {
    let modifier: UInt32
    switch event.keyCode {
    case 0x39: modifier = GHOSTTY_MODS_CAPS.rawValue
    case 0x38, 0x3C: modifier = GHOSTTY_MODS_SHIFT.rawValue
    case 0x3B, 0x3E: modifier = GHOSTTY_MODS_CTRL.rawValue
    case 0x3A, 0x3D: modifier = GHOSTTY_MODS_ALT.rawValue
    case 0x37, 0x36: modifier = GHOSTTY_MODS_SUPER.rawValue
    default: return
    }
    let action: ghostty_input_action_e =
      Self.ghosttyMods(event.modifierFlags).rawValue & modifier == 0
      ? GHOSTTY_ACTION_RELEASE : GHOSTTY_ACTION_PRESS
    sendKey(event, action: action, text: nil)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown,
      event.modifierFlags.contains(.command),
      let runtime
    else { return super.performKeyEquivalent(with: event) }

    switch event.charactersIgnoringModifiers?.lowercased() {
    case "c":
      runtime.copySelection()
      return true
    case "v":
      runtime.pasteClipboard()
      return true
    case "a", "x", "z":
      return runtime.forwardKeyEquivalent(event)
    default:
      return super.performKeyEquivalent(with: event)
    }
  }

  func forwardKeyEquivalent(_ event: NSEvent) {
    sendKey(event, action: GHOSTTY_ACTION_PRESS, text: nil)
    sendKey(event, action: GHOSTTY_ACTION_RELEASE, text: nil)
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

  override func doCommand(by selector: Selector) {}

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

  private func sendKey(_ event: NSEvent, action: ghostty_input_action_e, text: String?) {
    guard let surface else { return }
    var keyEvent = ghostty_input_key_s()
    keyEvent.action = action
    keyEvent.keycode = UInt32(event.keyCode)
    keyEvent.composing = hasMarkedText()
    keyEvent.mods = Self.ghosttyMods(event.modifierFlags)
    keyEvent.consumed_mods = Self.ghosttyMods(
      event.modifierFlags.subtracting([.control, .command]))
    if let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
      keyEvent.unshifted_codepoint = scalar.value
    }

    if let text {
      text.withCString { pointer in
        keyEvent.text = pointer
        _ = ghostty_surface_key(surface, keyEvent)
      }
    } else {
      keyEvent.text = nil
      _ = ghostty_surface_key(surface, keyEvent)
    }
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

  private static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var value = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { value |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { value |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { value |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { value |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { value |= GHOSTTY_MODS_CAPS.rawValue }
    return ghostty_input_mods_e(value)
  }
}
