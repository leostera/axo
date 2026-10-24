import AppKit
import GhosttyKit
import Carbon

// Keyboard translation, key equivalents and command routing.
extension GhosttySurfaceNSView {
  // Keep native key translation and IME handling aligned with Ghostty's AppKit surface bridge
  // at 81598385d608dda4946093d6d6a234d204a2f225; Axo keeps its own command-key routing below.
  /// How long a key event may wait for the main thread before it is reported.
  static let keyDeliveryReportThreshold: TimeInterval = 0.05

  /// Logs key events the main thread delivered late: typing lag that happened before Axo or
  /// libghostty saw the key.
  private static func reportDelayedDelivery(of event: NSEvent) {
    let waited = ProcessInfo.processInfo.systemUptime - event.timestamp
    guard waited > keyDeliveryReportThreshold else { return }
    AxoTrace.latency.notice(
      "event=key.delivery_delayed waited_ms=\(String(format: "%.1f", waited * 1_000), privacy: .public)")
  }

  override func keyDown(with event: NSEvent) {
    let signpost = AxoTrace.signposter.beginInterval("key.down")
    defer { AxoTrace.signposter.endInterval("key.down", signpost) }
    Self.reportDelayedDelivery(of: event)
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

  func performAxoFallbackKeyEquivalent(_ event: NSEvent) -> Bool {
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

  @objc func splitRight(_ sender: Any?) {
    onSplit?(.right)
  }

  @objc func splitDown(_ sender: Any?) {
    onSplit?(.down)
  }

  @objc func closePane(_ sender: Any?) {
    onClose?()
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

  func sendKeyEquivalent(_ event: NSEvent, characters: String) {
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

  func matchesGhosttyKeyBinding(_ event: NSEvent) -> Bool {
    guard let surface else { return false }
    var keyEvent = makeKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
    let text = event.characters ?? ""
    return text.withCString { pointer in
      keyEvent.text = pointer
      var flags = ghostty_binding_flags_e(0)
      return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
    }
  }

  func translationEvent(for event: NSEvent) -> NSEvent {
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

  func sendKey(
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

  func makeKeyEvent(
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


  static var keyboardLayoutID: String? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
      let sourceID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    else { return nil }
    return unsafeBitCast(sourceID, to: CFString.self) as String
  }

  static func keyEventText(_ text: String?) -> String? {
    guard let text, !text.isEmpty, let scalar = text.unicodeScalars.first else { return nil }
    guard scalar.value >= 0x20, scalar.value != 0x7F else { return nil }
    return text
  }

  static func shouldSuppressComposingControlInput(
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

  static func shouldReplayCommittedPreeditKey(_ event: NSEvent) -> Bool {
    switch event.keyCode {
    case 0x7D, 0x7C, 0x7E:
      return true
    case 0x7B:
      return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
    default:
      return false
    }
  }

  static func ghosttyCharacters(for event: NSEvent) -> String? {
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

  static func eventModifierFlags(
    _ modifiers: ghostty_input_mods_e
  ) -> NSEvent.ModifierFlags {
    var flags = NSEvent.ModifierFlags(rawValue: 0)
    if modifiers.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
    if modifiers.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
    if modifiers.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
    if modifiers.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
    return flags
  }
}
