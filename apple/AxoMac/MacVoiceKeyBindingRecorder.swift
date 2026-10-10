import AppKit
import SwiftUI

struct MacVoiceKeyBindingRecorder: NSViewRepresentable {
    @Binding var binding: MacVoiceKeyBinding
    @Binding var isCapturing: Bool

    func makeNSView(context: Context) -> MacVoiceKeyBindingButton {
        let button = MacVoiceKeyBindingButton()
        button.onCapture = { binding = $0 }
        button.onCaptureStateChanged = { isCapturing = $0 }
        button.binding = binding
        button.isCapturing = isCapturing
        return button
    }

    func updateNSView(_ button: MacVoiceKeyBindingButton, context: Context) {
        button.onCapture = { binding = $0 }
        button.onCaptureStateChanged = { isCapturing = $0 }
        button.binding = binding
        button.isCapturing = isCapturing
    }

    static func dismantleNSView(_ button: MacVoiceKeyBindingButton, coordinator: ()) {
        button.cancelCapture()
    }
}

@MainActor
final class MacVoiceKeyBindingButton: NSButton {
    var binding = MacVoiceKeyBinding.defaultValue { didSet { updateTitle() } }
    var isCapturing = false { didSet { updateTitle() } }
    var onCapture: ((MacVoiceKeyBinding) -> Void)?
    var onCaptureStateChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginCapture)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("Programmatic control only") }
    override var acceptsFirstResponder: Bool { true }

    @objc private func beginCapture() {
        guard let window, window.makeFirstResponder(self) else { return }
        isCapturing = true
        onCaptureStateChanged?(true)
    }

    override func resignFirstResponder() -> Bool {
        if isCapturing { finishCapture(releaseFocus: false) }
        return super.resignFirstResponder()
    }

    func cancelCapture() { finishCapture(releaseFocus: false) }

    override func keyDown(with event: NSEvent) {
        guard isCapturing else { super.keyDown(with: event); return }
        _ = handleCaptureEvent(event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isCapturing else { super.flagsChanged(with: event); return }
        _ = handleCaptureEvent(event)
    }

    @discardableResult
    func handleCaptureEvent(_ event: NSEvent) -> Bool {
        guard isCapturing else { return false }
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 { finishCapture(); return true }
            capture(event)
            return true
        case .flagsChanged:
            guard let modifier = MacVoiceKeyBinding.ModifierKey(keyCode: event.keyCode),
                  event.modifierFlags.contains(modifier.modifierFlag) else { return true }
            capture(event) // Only the press, never a modifier release.
            return true
        default: return false
        }
    }

    private func capture(_ event: NSEvent) {
        let keyName = Self.keyName(for: event)
        guard let binding = MacVoiceKeyBinding.capture(
            keyCode: event.keyCode, modifiers: event.modifierFlags, name: keyName
        ) else { return }
        self.binding = binding
        onCapture?(binding)
        finishCapture()
    }

    private func finishCapture(releaseFocus: Bool = true) {
        guard isCapturing else { return }
        isCapturing = false
        onCaptureStateChanged?(false)
        if releaseFocus, window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    private func updateTitle() {
        title = isCapturing ? "Press a key…" : binding.title
        setAccessibilityLabel(isCapturing ? "Press a voice keybinding" : "Voice keybinding: \(binding.title)")
    }

    private static func keyName(for event: NSEvent) -> String {
        // Character accessors are invalid for flagsChanged and raise an AppKit exception.
        if event.type == .flagsChanged {
            return MacVoiceKeyBinding.ModifierKey(keyCode: event.keyCode)?.title ?? ""
        }
        let characters = event.charactersIgnoringModifiers ?? ""
        return switch event.keyCode {
        case 36: "Return"
        case 48: "Tab"
        case 49: "Space"
        case 51: "Delete"
        case 53: "Escape"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: characters.isEmpty ? "Key \(event.keyCode)" : characters.uppercased()
        }
    }
}
