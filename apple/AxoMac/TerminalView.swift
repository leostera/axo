import AppKit
import GhosttyKit
import AxoProtocol

/// A small AppKit host for the full Ghostty surface API, not the VT-only library.
final class TerminalView: NSView, NSTextInputClient {
    private let runtime: GhosttyRuntime
    private(set) var surface: ghostty_surface_t?
    let runtimeGeneration = UUID()
    private(set) var focusGeneration = UUID()
    private var marked = NSAttributedString(string: "")
    private var tracking: NSTrackingArea?
    private var keyEvent: NSEvent?
    private var insertedDuringKey = false
    private var windowObservers: [NSObjectProtocol] = []
    var onFocus: (() -> Void)?
    var onClose: ((Bool) -> Void)?
    private(set) var hoveredURL: URL? {
        didSet {
            toolTip = hoveredURL?.absoluteString
            window?.invalidateCursorRects(for: self)
        }
    }
    var workingDirectory: String
    var terminalTitle = "Terminal"
    var childExited = false
    var inputEnabled = true
    private var canSendInput: Bool { inputEnabled && !childExited && surface != nil }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(runtime: GhosttyRuntime, launch: TerminalLaunch, inheriting parent: ghostty_surface_t? = nil) throws {
        self.runtime = runtime
        self.workingDirectory = launch.directory
        var isDirectory: ObjCBool = false
        guard !launch.directory.contains("\u{0}"), FileManager.default.fileExists(atPath: launch.directory, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw LaunchError.missingDirectory }
        super.init(frame: NSRect(x: 0, y: 0, width: 1100, height: 750))
        wantsLayer = true
        registerForDraggedTypes([.string, .fileURL])
        var config = parent.map { ghostty_surface_inherited_config($0, GHOSTTY_SURFACE_CONTEXT_SPLIT) } ?? ghostty_surface_config_new()
        // Carry Ghostty font/context, but not a managed Pi command, input, or binding environment.
        config.command = nil; config.initial_input = nil; config.env_vars = nil; config.env_var_count = 0
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos = ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        // Seed the renderer at screen resolution; attachment below synchronizes
        // both Ghostty's glyph DPI and its layer to the actual owning window.
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 1)
        config.wait_after_command = true
        surface = launch.directory.withCString { directory in
            config.working_directory = directory
            return launch.command.withCString { executable in
                config.command = executable
                return ghostty_surface_new(runtime.app, &config)
            }
        }
        guard surface != nil else { throw LaunchError.surfaceCreation }
    }

    required init?(coder: NSCoder) { fatalError("Programmatic view only") }
    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        if let surface { ghostty_surface_free(surface) }
    }

    override func layout() { super.layout(); resizeSurface() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); resizeSurface() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
                observeWindow(name, object: window)
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                observeWindow(name, object: NSApp)
            }
        }
        resizeSurface()
        updateWindowState()
    }

    private func observeWindow(_ name: Notification.Name, object: AnyObject) {
        windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateWindowState() }
        })
    }
    private func updateWindowState() {
        runtime.setFocus(NSApp.isActive)
        setFocus(NSApp.isActive && window?.isKeyWindow == true && window?.firstResponder === self)
        setVisible(window?.occlusionState.contains(.visible) ?? false)
    }

    private func resizeSurface() {
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? NSScreen.main?.backingScaleFactor ?? 1
        // Match upstream SurfaceView_AppKit: the IOSurface layer is installed by
        // Ghostty at creation. Updating only glyph DPI leaves the compositor at
        // its old scale, causing blurry/rescaled text on Retina or display moves.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        CATransaction.commit()
        ghostty_surface_set_content_scale(surface, scale, scale)
        let width = bounds.width * scale, height = bounds.height * scale
        guard width.isFinite, height.isFinite, width <= CGFloat(UInt32.max), height <= CGFloat(UInt32.max) else { return }
        ghostty_surface_set_size(surface, UInt32(max(1, width)), UInt32(max(1, height)))
        ghostty_surface_refresh(surface)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusGeneration = UUID(); onFocus?(); updateWindowState() }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusGeneration = UUID(); setFocus(false) }
        return result
    }

    /// Releases the frontend surface/attach child only, never the managed runtime.
    func detachPresentation() {
        guard let current = surface else { return }
        surface = nil
        childExited = true
        ghostty_surface_free(current)
    }

    func setVisible(_ visible: Bool) {
        if let surface { ghostty_surface_set_occlusion(surface, visible) }
    }

    func setFocus(_ focused: Bool) {
        if let surface { ghostty_surface_set_focus(surface, focused) }
    }

    override func keyDown(with event: NSEvent) {
        guard canSendInput else { return }
        keyEvent = event
        insertedDuringKey = false
        if !event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.command) { interpretKeyEvents([event]) }
        if !insertedDuringKey { sendKey(event, text: nil) }
        keyEvent = nil
    }

    override func keyUp(with event: NSEvent) { sendKey(event, text: nil, released: true) }
    override func flagsChanged(with event: NSEvent) {
        let flag: NSEvent.ModifierFlags
        switch event.keyCode {
        case 56, 60: flag = .shift
        case 59, 62: flag = .control
        case 58, 61: flag = .option
        case 54, 55: flag = .command
        case 57: flag = .capsLock
        default: return
        }
        sendKey(event, text: nil, released: !event.modifierFlags.contains(flag))
    }

    private func sendKey(_ event: NSEvent, text: String?, released: Bool = false) {
        guard canSendInput, let surface else { return }
        var key = ghostty_input_key_s()
        key.action = released ? GHOSTTY_ACTION_RELEASE : (event.type != .flagsChanged && event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
        key.keycode = UInt32(event.keyCode)
        key.mods = modifiers(event.modifierFlags)
        key.consumed_mods = text == nil ? GHOSTTY_MODS_NONE : modifiers(event.modifierFlags.intersection([.shift, .option]))
        // AppKit character accessors are invalid for modifier-only events.
        key.unshifted_codepoint = event.type == .flagsChanged ? 0 : (event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0)
        key.composing = hasMarkedText()
        if let text { text.withCString { key.text = $0; _ = ghostty_surface_key(surface, key) } }
        else { _ = ghostty_surface_key(surface, key) }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func isAccessibilityEnabled() -> Bool { canSendInput }
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    override func accessibilityLabel() -> String? { "Terminal" }
    override func accessibilityValue() -> Any? {
        // Only the visible viewport, never a transcript/backlog cache. This lets
        // VoiceOver and authorized UI automation read the actual Ghostty plane.
        guard let surface else { return "" }
        var selection = ghostty_selection_s()
        selection.top_left.tag = GHOSTTY_POINT_VIEWPORT
        selection.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT
        selection.bottom_right.tag = GHOSTTY_POINT_VIEWPORT
        selection.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len <= 65536 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: hoveredURL == nil ? .iBeam : .pointingHand)
    }

    func updateHoveredURL(_ value: String?) {
        hoveredURL = value.flatMap(Self.validatedWebURL)
    }

    static func validatedWebURL(_ value: String) -> URL? {
        guard value.utf8.count <= 4_096,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) { mousePosition(event) }
    override func mouseDragged(with event: NSEvent) { mousePosition(event) }
    override func mouseExited(with event: NSEvent) { updateHoveredURL(nil) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mousePosition(event)
        if let url = hoveredURL,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if event.clickCount == 1, !NSWorkspace.shared.open(url) { NSSound.beep() }
            return
        }
        if canSendInput, let surface { _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modifiers(event.modifierFlags)) }
    }
    override func mouseUp(with event: NSEvent) {
        mousePosition(event)
        if canSendInput, let surface { _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modifiers(event.modifierFlags)) }
    }
    override func scrollWheel(with event: NSEvent) {
        if canSendInput, let surface { ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas ? 1 : 0) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canSendInput, let types = sender.draggingPasteboard.types,
              !Set(types).isDisjoint(with: Self.dropTypes) else { return [] }
        return .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard canSendInput, let surface,
              let content = opinionatedDropText(from: sender.draggingPasteboard) else { return false }
        window?.makeFirstResponder(self)
        content.withCString { ghostty_surface_text(surface, $0, UInt(content.utf8.count)) }
        return true
    }
    private func opinionatedDropText(from pasteboard: NSPasteboard) -> String? {
        let items = pasteboard.pasteboardItems ?? []
        let contents = items.compactMap { item -> String? in
            if let propertyList = item.propertyList(forType: .fileURL),
               let fileURL = NSURL(pasteboardPropertyList: propertyList, ofType: .fileURL) as URL?,
               fileURL.isFileURL {
                return Self.escapeTerminalPath(fileURL.path)
            }
            return item.string(forType: .string)
        }
        guard !contents.isEmpty else { return nil }
        return contents.joined(separator: " ")
    }
    private func mousePosition(_ event: NSEvent) {
        guard canSendInput, let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, point.y, modifiers(event.modifierFlags))
    }

    @objc func copy(_ sender: Any?) {
        guard let surface else { return }
        var selection = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &selection) else { return }
        defer { ghostty_surface_free_text(surface, &selection) }
        guard let text = selection.text else { return }
        let value = String(decoding: UnsafeRawBufferPointer(start: text, count: Int(selection.text_len)), as: UTF8.self)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
    @objc func paste(_ sender: Any?) {
        guard canSendInput, let surface, let text = NSPasteboard.general.string(forType: .string) else { return }
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
    }

    func insertVoiceText(_ text: String) -> Bool {
        guard canSendInput, let surface, !text.isEmpty, text.utf8.count <= 32_768,
              !text.contains("\u{0}") else { return false }
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
        return true
    }

    // NSTextInputClient: composed input is forwarded without flattening IME preedit.
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard canSendInput else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        unmarkText()
        if let event = keyEvent { insertedDuringKey = true; sendKey(event, text: text) }
        else if let surface { text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) } }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        if let surface { marked.string.withCString { ghostty_surface_preedit(surface, $0, UInt(marked.string.utf8.count)) } }
    }
    func unmarkText() { marked = NSAttributedString(string: ""); if let surface { ghostty_surface_preedit(surface, nil, 0) } }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        if let surface { ghostty_surface_ime_point(surface, &x, &y, &width, &height) }
        let rect = convert(NSRect(x: x, y: y, width: width, height: height), to: nil)
        return window?.convertToScreen(rect) ?? rect
    }
    override func doCommand(by selector: Selector) {}

    private func modifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }
    private static let dropTypes: Set<NSPasteboard.PasteboardType> = [.string, .fileURL]
    private static let shellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    private static func escapeTerminalPath(_ path: String) -> String {
        shellEscapeCharacters.reduce(path) { escapedPath, character in
            let escapedCharacter = "\\" + String(character)
            return escapedPath.replacingOccurrences(of: String(character), with: escapedCharacter)
        }
    }

}
