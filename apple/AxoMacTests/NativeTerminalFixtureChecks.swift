import AppKit
import AxoProtocol
import GhosttyKit

/// Launched only by the Rust-owned daemon/PTY fixture, never against live app state.
@main
struct NativeTerminalFixtureChecks {
    @MainActor static func main() {
        do { try check() } catch {
            fputs("Native component fixture: \(error)\n", stderr)
            exit(1)
        }
    }
    @MainActor private static func check() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let arguments = CommandLine.arguments
        precondition(arguments.count == 8)
        let runtime = TerminalRuntime(hostGeneration: UUID(uuidString: arguments[4])!,
                                      target: .init(sessionId: UUID(uuidString: arguments[5])!, paneId: UUID(uuidString: arguments[6])!),
                                      runtimeGeneration: UUID(uuidString: arguments[7])!)
        let launch = try TerminalLaunch.attachment(namespace: .nativeHarness, root: URL(fileURLWithPath: arguments[2]), machineID: UUID(uuidString: arguments[3])!,
                                                  runtime: runtime, helper: URL(fileURLWithPath: arguments[1]))
        let pool = AxodTerminalSurfaces()
        let view = try pool.view(for: launch)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 700, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        _ = window.makeFirstResponder(view)
        do { try wait("initial output") { screen(view).contains("surface-ready") } }
        catch {
            let state = view.surface.map { ghostty_surface_process_exited($0) } ?? true
            let text = screen(view)
            let known = ["InvalidDiscovery", "Offline", "Protocol", "Capacity", "requires a frontend TTY", "geometry exceeds", "handshake", "No such file", "command not found", "Rejected", "screen recovery", "Invalid argument", "Operation not permitted", "Permission denied", "Interrupted", "Resource temporarily unavailable", "Input/output error", "Unexpected", "Timeout", "deadline"].filter { text.contains($0) }
            fputs("Native surface diagnostic: frontendExited=\(state), visibleTextBytes=\(text.utf8.count), staticClasses=\(known)\n", stderr)
            throw error
        }
        view.insertText("日本語 🦀\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        try wait("Unicode output") { screen(view).contains("日本語 🦀") }
        window.setContentSize(NSSize(width: 950, height: 600))
        view.layoutSubtreeIfNeeded()
        let surface = view.surface!
        let size = ghostty_surface_size(surface)
        precondition(size.rows > 0 && size.columns > 0)
        // Ghostty applies outer-PTY geometry asynchronously. Each distinct probe
        // is observed back on the surface before another is submitted; this is
        // not a resend of an uncertain input packet or an assumed resize barrier.
        let geometryFile = URL(fileURLWithPath: arguments[2]).appendingPathComponent("geometry.txt")
        let deadline = Date().addingTimeInterval(6)
        var probe = 0
        while true {
            let marker = "geometry-probe-\(probe)"
            view.insertText(marker + "\n", replacementRange: NSRange(location: NSNotFound, length: 0))
            try wait("post-resize probe output") { screen(view).contains(marker) }
            let value = try? String(contentsOf: geometryFile, encoding: .utf8)
            if value?.trimmingCharacters(in: .whitespacesAndNewlines) == "\(size.rows) \(size.columns)" { break }
            guard Date() < deadline else { throw FixtureError.deadline("geometry") }
            probe += 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let same = try pool.view(for: launch)
        precondition(same === view)
        view.detachPresentation()
        window.close()
        print("PASS: actual Ghostty full surface -> transport child -> owned daemon PTY Unicode input/output, geometry and presentation disposal (isolated component fixture)")
    }
    @MainActor private static func screen(_ view: TerminalView) -> String {
        guard let surface = view.surface else { return "" }
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
    @MainActor private static func wait(_ stage: String, _ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(6)
        while !predicate() {
            guard Date() < deadline else { throw FixtureError.deadline(stage) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
    private enum FixtureError: Error { case deadline(String) }
}
