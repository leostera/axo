import AppKit
import GhosttyKit

/// Pointer, scroll, pressure, Quick Look and drag-and-drop input.
extension GhosttySurfaceNSView {
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

  static func fileURLs(from pasteboard: NSPasteboard) -> [URL]? {
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

  func handleFocusOnlyLeftClick(_ event: NSEvent) -> Bool {
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

  @discardableResult
  func sendMouseButton(
    _ event: NSEvent,
    state: ghostty_input_mouse_state_e,
    button: ghostty_input_mouse_button_e
  ) -> Bool {
    guard let surface else { return false }
    return ghostty_surface_mouse_button(
      surface, state, button, Self.ghosttyMods(event.modifierFlags))
  }

  func sendMousePosition(_ event: NSEvent) {
    guard let surface else { return }
    let point = convert(event.locationInWindow, from: nil)
    ghostty_surface_mouse_pos(
      surface,
      point.x,
      bounds.height - point.y,
      Self.ghosttyMods(event.modifierFlags)
    )
  }
}
