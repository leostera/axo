import AppKit
import AxoProtocol
import GhosttyKit

private final class BackingScaleWindow: NSWindow {
    var simulatedScale: CGFloat = 2
    override var backingScaleFactor: CGFloat { simulatedScale }
}

/// Owned offscreen-window smoke checks; not full native-workbench acceptance.
@main
struct TerminalSurfaceChecks {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        guard CommandLine.arguments.count == 2 else { fatalError("Expected owned helper argument") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axo-'terminal-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let machineID = UUID()
        let runtime = TerminalRuntime(hostGeneration: UUID(), target: .init(sessionId: UUID(), paneId: UUID()), runtimeGeneration: UUID())
        let launch = try TerminalLaunch.attachment(root: root, machineID: machineID, runtime: runtime,
                                                  helper: URL(fileURLWithPath: CommandLine.arguments[1]))
        precondition(launch.command.contains("terminal-attach"))
        precondition(launch.command.contains("'\\''"), "Private root arguments must be shell-quoted")
        let surfaces = AxodTerminalSurfaces()
        let terminal = try surfaces.view(for: launch)
        let sameSurface = try surfaces.view(for: launch)
        precondition(sameSurface === terminal, "Viewport reconstruction duplicated the frontend surface")
        let window = BackingScaleWindow(contentRect: NSRect(x: -2000, y: -2000, width: 700, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = terminal
        terminal.layoutSubtreeIfNeeded()
        precondition(terminal.surface != nil, "Full Ghostty surface unavailable")
        for scale in [CGFloat(2), 1, 2] {
            window.simulatedScale = scale
            terminal.viewDidChangeBackingProperties()
            precondition(terminal.layer?.contentsScale == scale, "Glyph DPI and compositor scale diverged")
            let size = ghostty_surface_size(terminal.surface!)
            precondition(size.width_px == UInt32(terminal.bounds.width * scale))
            precondition(size.height_px == UInt32(terminal.bounds.height * scale))
        }
        window.simulatedScale = 1
        terminal.viewDidChangeBackingProperties()
        window.contentView = NSView()
        terminal.layoutSubtreeIfNeeded()
        precondition(terminal.window == nil && terminal.layer?.contentsScale == 1, "Detached reflow reset retained scale")
        window.simulatedScale = 2
        window.contentView = terminal
        precondition(terminal.layer?.contentsScale == 2, "Attachment did not adopt the owning window scale")
        _ = window.makeFirstResponder(terminal)
        if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.option], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 61) {
            terminal.flagsChanged(with: event)
        }
        terminal.setMarkedText("日本語", selectedRange: NSRange(location: 0, length: 3), replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(terminal.hasMarkedText())
        terminal.unmarkText()
        precondition(!terminal.hasMarkedText())
        let deadline = Date().addingTimeInterval(4)
        while let surface = terminal.surface, !ghostty_surface_process_exited(surface), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        // This fixture deliberately has no daemon discovery. The frontend fails,
        // without a Pi/shell fallback, while the native surface stays inspectable.
        precondition(terminal.surface.map { ghostty_surface_process_exited($0) } == true)
        precondition(TerminalView.validatedWebURL("https://example.invalid/path") != nil)
        for rejected in ["javascript:alert(1)", "file:///etc/passwd", "https://user:password@example.invalid", "https://example.invalid/\n"] {
            precondition(TerminalView.validatedWebURL(rejected) == nil)
        }
        terminal.detachPresentation()
        precondition(terminal.surface == nil)
        window.close()
        print("PASS: owned Ghostty surface/cache, modifier and IME preedit, missing-discovery failure, safe URL parsing and non-destructive surface disposal (not workbench acceptance)")
    }
}
