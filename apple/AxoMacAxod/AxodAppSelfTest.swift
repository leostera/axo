#if DEBUG
import AppKit
import AxoProtocol
import Foundation
import GhosttyKit

/// Runs inside the packaged application, through its actual delegate/window/run loop.
/// Rust prepares private configuration and an owned model peer; the app starts axod.
@MainActor struct AxodAppSelfTest {
    let root: URL
    private let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    var state: URL { root.appendingPathComponent("state") }
    var home: URL { root.appendingPathComponent("home") }
    var preferences: UserDefaults { UserDefaults(suiteName: "Axo.AppSelfTest.\(root.lastPathComponent)")! }
    init(root: URL) throws {
        _ = try AxodStateDirectory.openExisting(root: root)
        _ = try AxodStateDirectory.openExisting(root: root.appendingPathComponent("state"))
        _ = try AxodStateDirectory.openExisting(root: root.appendingPathComponent("home"))
        guard try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("state").path).isEmpty,
              try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("home").path).isEmpty else {
            throw Failure.failed("fixture must have empty owned state and HOME")
        }
        self.root = root
    }
    enum Failure: Error { case failed(String) }
    func run(coordinator: AxodWorkbenchCoordinator, window: NSWindow) async {
        var status: Int32 = 1
        var failureStage = "setup or protocol failure"
        do {
            try await wait("automatic empty startup and independent shell") {
                coordinator.sessions.count == 1 && coordinator.workspaces.isEmpty &&
                coordinator.selectedSession?.shellPanes.first?.terminal != nil
            }
            guard let session = coordinator.selectedSession,
                  let shell = session.shellPanes.first?.terminal else { throw Failure.failed("missing default shell") }
            let shellLaunch = try coordinator.terminalLaunch(for: shell, sessionID: session.sessionId)
            try await wait("existing shell surface, helper version and initial keyboard focus") {
                coordinator.terminalSurfaces.presentation(for: shellLaunch.key)?.view === window.firstResponder &&
                coordinator.hostStatus?.daemonVersion == Bundle.main.infoDictionary?["AxoBundledAxodVersion"] as? String
            }
            guard let right = coordinator.terminalSurfaces.presentation(for: shellLaunch.key),
                  window.isVisible, NSApp.isActive, NSApp.keyWindow === window else {
                throw Failure.failed("actual app window/helper version")
            }
            // No manual first-responder assignment: this tests default app keyboard routing.
            type("axo_app_test=1; pwd > \"$HOME/app-shell-cwd\"; printf app-shell-input > \"$HOME/app-shell-input\"; printf '\\101PP_SHELL_RESPONSE\\n'", in: window)
            enter(in: window)
            try await wait("actual shell input effect") {
                (try? Data(contentsOf: home.appendingPathComponent("app-shell-input"))) == Data("app-shell-input".utf8)
            }
            try await wait("shell response on presented Ghostty viewport") { visibleText(right.view).contains("APP_SHELL_RESPONSE") }
            guard (try? String(contentsOf: home.appendingPathComponent("app-shell-cwd"), encoding: .utf8)) == home.path + "\n" else {
                throw Failure.failed("captured standalone HOME cwd")
            }
            guard coordinator.selectedSessionID == session.sessionId else { throw Failure.failed("letter navigated sidebar") }
            try await wait("Pi admission after independent shell input") { coordinator.selectedSession?.pi.admission == .ready }
            guard let admitted = coordinator.selectedSession, admitted.sessionId == session.sessionId,
                  let pi = coordinator.presentationSnapshot(for: admitted) else { throw Failure.failed("missing admitted Pi") }
            let piLaunch = try coordinator.terminalLaunch(for: pi, sessionID: session.sessionId)
            try await wait("existing Pi surface") { coordinator.terminalSurfaces.presentation(for: piLaunch.key) != nil }
            guard let left = coordinator.terminalSurfaces.presentation(for: piLaunch.key) else { throw Failure.failed("missing Pi surface") }
            let leftFrame = left.view.convert(left.view.bounds, to: window.contentView)
            let rightFrame = right.view.convert(right.view.bounds, to: window.contentView)
            guard leftFrame.width > 0, rightFrame.width > 0, leftFrame.minX < rightFrame.minX else {
                throw Failure.failed("Pi-left/shell-right geometry")
            }
            // A real window mouse event selects the Pi pane before normal typing.
            let point = left.view.convert(NSPoint(x: 20, y: 20), to: nil)
            let click = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(click)
            guard window.firstResponder === left.view else { throw Failure.failed("Pi pane mouse focus") }
            type("APP_STARTUP_TYPED_MESSAGE", in: window)
            enter(in: window)
            try await wait("actual Pi user message and model response in canonical history") {
                coordinator.chatEntries.filter { $0.role == "user" && $0.text.contains("APP_STARTUP_TYPED_MESSAGE") }.count == 1 &&
                coordinator.chatEntries.contains { $0.role == "assistant" && $0.text.contains("Actual app Pi response") }
            }
            try await wait("Pi response on presented Ghostty viewport") { visibleText(left.view).contains("Actual app Pi response") }
            try await wait("complete exact two-runtime catalog") { coordinator.runtimes.count == 2 && coordinator.nextRuntimeID == nil }
            guard coordinator.sessions.count == 1, coordinator.workspaces.isEmpty,
                  coordinator.nextSessionCursor == nil, coordinator.nextWorkspaceCursor == nil,
                  coordinator.selectedSession?.runtime?.runtime == pi.runtime,
                  coordinator.selectedSession?.shellPanes.first?.terminal?.runtime == shell.runtime else {
                throw Failure.failed("default identity changed or duplicate work")
            }
            print("PASS: packaged Axo.app delegate/window, app-launched bundled axod, automatic single empty-startup session, Pi-left/shell-right, default A-key routing, shell effect and actual Pi canonical user/model response")
            status = 0
        } catch {
            // Only closed synthetic stage names, never terminal or model bodies.
            if case Failure.failed(let stage) = error { failureStage = stage; fputs("Axo app self-test failed: \(stage)\n", stderr) }
            else { fputs("Axo app self-test failed: setup or protocol failure\n", stderr) }
        }
        coordinator.disconnect()
        await coordinator.stopSelfTestDaemon()
        preferences.removePersistentDomain(forName: "Axo.AppSelfTest.\(root.lastPathComponent)")
        // LaunchServices does not propagate the app's exit code to `open -W`.
        // An exclusive private result is required; absence never counts as success.
        let descriptor = open(root.appendingPathComponent("result").path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if descriptor >= 0 {
            let value = status == 0 ? "PASS\n" : "FAIL: \(failureStage)\n"
            let bytes = Array(value.utf8)
            let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if written != bytes.count { status = 1; _ = unlink(root.appendingPathComponent("result").path) }
            close(descriptor)
        } else { status = 1 }
        fflush(stdout); fflush(stderr)
        exit(status)
    }
    private func wait(_ stage: String, _ condition: () -> Bool) async throws {
        let deadline = min(self.deadline, ContinuousClock.now.advanced(by: .seconds(45)))
        while !condition() {
            if ContinuousClock.now >= deadline { throw Failure.failed(stage) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    private func visibleText(_ view: TerminalView) -> String {
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
    private func type(_ text: String, in window: NSWindow) {
        for character in text {
            let value = String(character)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: value, charactersIgnoringModifiers: value,
                isARepeat: false, keyCode: value == "a" ? 0 : 0xffff)!
            NSApp.sendEvent(event)
        }
    }
    private func enter(in window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        NSApp.sendEvent(event)
    }
}
#endif
