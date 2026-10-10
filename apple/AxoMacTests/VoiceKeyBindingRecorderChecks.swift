import AppKit

/// Owned hidden-window checks; no event injection into another app or Accessibility permissions.
@main
struct VoiceKeyBindingRecorderChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let button = MacVoiceKeyBindingButton(frame: NSRect(x: 20, y: 20, width: 170, height: 30))
        window.contentView?.addSubview(button)
        var captured: MacVoiceKeyBinding?
        var capturing = false
        button.onCapture = { captured = $0 }
        button.onCaptureStateChanged = { capturing = $0 }

        func flags(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code)!
        }
        func begin() {
            captured = nil
            button.performClick(nil)
            precondition(button.isCapturing && capturing && window.firstResponder === button)
        }
        begin()
        precondition(button.handleCaptureEvent(flags(61, []))) // A release is not an approval.
        precondition(captured == nil && button.isCapturing)
        precondition(button.handleCaptureEvent(flags(58, .option))) // Left Option remains unreserved.
        precondition(captured == nil && button.isCapturing)
        precondition(button.handleCaptureEvent(flags(61, .option)))
        precondition(captured == .defaultValue && captured?.title == "Right Option")
        precondition(!button.isCapturing && !capturing)
        precondition(!button.handleCaptureEvent(flags(61, [])))

        begin()
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 53)!
        precondition(button.handleCaptureEvent(escape))
        precondition(captured == nil && !button.isCapturing && !capturing)

        begin()
        window.makeFirstResponder(nil)
        precondition(!button.isCapturing && !capturing && captured == nil)

        begin()
        button.cancelCapture()
        precondition(!button.isCapturing && !capturing && captured == nil)
        print("Voice key recorder: Right Option, releases, Left Option, Escape, focus loss and teardown passed.")
    }
}
