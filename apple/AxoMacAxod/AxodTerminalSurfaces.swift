import AppKit
import GhosttyKit
import Observation

/// Presentation cache only. The daemon remains the sole Pi/shell process owner.
@MainActor @Observable
final class AxodTerminalSurfaces {
    @ObservationIgnored private var runtime: GhosttyRuntime?
    @ObservationIgnored private var views: [TerminalLaunch.Key: TerminalView] = [:]
    private(set) var notices: [TerminalLaunch.Key: String] = [:]

    func view(for launch: TerminalLaunch) throws -> TerminalView {
        if let view = views[launch.key] { return view }
        guard views.count < 32 else { throw SurfaceError.capacity }
        let runtime = try requireRuntime()
        let view = try TerminalView(runtime: runtime, launch: launch)
        view.onClose = { [weak self, weak view] _ in
            guard let self, let view, self.views[launch.key] === view else { return }
            // A Ghostty surface-close request only detaches this frontend.
            // It does not authorize pane removal or stopping managed work.
            view.detachPresentation()
            self.notices[launch.key] = "Terminal attachment closed; managed work was not stopped."
        }
        views[launch.key] = view
        return view
    }

    private func requireRuntime() throws -> GhosttyRuntime {
        if let runtime { return runtime }
        let created = try GhosttyRuntime()
        created.onAction = { [weak self] view, action in self?.handle(view: view, action: action) ?? false }
        runtime = created
        return created
    }

    private func handle(view: TerminalView?, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            guard let view else { return false }
            let link = action.action.mouse_over_link
            let value = Self.webString(link.url, count: link.len)
            view.updateHoveredURL(value)
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let request = action.action.open_url
            guard let value = Self.webString(request.url, count: request.len),
                  let url = TerminalView.validatedWebURL(value) else { return true }
            _ = NSWorkspace.shared.open(url)
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            guard let view, let key = views.first(where: { $0.value === view })?.key else { return false }
            view.childExited = true
            notices[key] = "Terminal attachment ended. Managed runtime state is observed separately; no work was replayed."
            return true
        default:
            // Terminal titles/OSC cwd are not routing, naming or file authority.
            // Split/create/stop actions belong to the captured native command path.
            return false
        }
    }

    private static func webString<T: BinaryInteger>(_ pointer: UnsafePointer<CChar>?, count: T) -> String? {
        guard let pointer, count > 0, count <= 4096 else { return nil }
        return String(data: Data(bytes: pointer, count: Int(count)), encoding: .utf8)
    }

    enum SurfaceError: LocalizedError {
        case capacity
        var errorDescription: String? { "The bounded terminal surface cache is full. Managed work was left untouched." }
    }
}
