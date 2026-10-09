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
        button.binding = binding
        button.isCapturing = isCapturing
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
        isCapturing = true
        onCaptureStateChanged?(true)
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isCapturing else { super.keyDown(with: event); return }
        guard event.keyCode != 53 else { endCapture(); return }
        capture(event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isCapturing, MacVoiceKeyBinding.ModifierKey(keyCode: event.keyCode) != nil else {
            super.flagsChanged(with: event); return
        }
        capture(event)
    }

    private func capture(_ event: NSEvent) {
        let keyName = Self.keyName(for: event)
        guard let binding = MacVoiceKeyBinding.capture(
            keyCode: event.keyCode, modifiers: event.modifierFlags, name: keyName
        ) else { return }
        self.binding = binding
        onCapture?(binding)
        endCapture()
    }

    private func endCapture() {
        isCapturing = false
        onCaptureStateChanged?(false)
        window?.makeFirstResponder(nil)
    }

    private func updateTitle() {
        title = isCapturing ? "Press a key…" : binding.title
        setAccessibilityLabel(isCapturing ? "Press a voice keybinding" : "Voice keybinding: \(binding.title)")
    }

    private static func keyName(for event: NSEvent) -> String {
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
