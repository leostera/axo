import AppKit
import SwiftUI

struct AxodTerminalHost: NSViewRepresentable {
    let launch: TerminalLaunch
    let surfaces: AxodTerminalSurfaces
    let inputEnabled: Bool
    let viewportID: UUID
    let onFocus: () -> Void
    var onAvailable: ((NSWindow) -> Void)? = nil

    func makeNSView(context: Context) -> AxodTerminalHostView { AxodTerminalHostView() }
    func updateNSView(_ host: AxodTerminalHostView, context: Context) {
        host.install(launch: launch, surfaces: surfaces, inputEnabled: inputEnabled, viewportID: viewportID, onFocus: onFocus, onAvailable: onAvailable)
    }
    static func dismantleNSView(_ host: AxodTerminalHostView, coordinator: ()) { host.releaseViewport() }
}

/// The viewport owns containment, not the surface, execution or work records.
@MainActor
final class AxodTerminalHostView: NSView {
    private var key: TerminalLaunch.Key?
    private weak var terminal: TerminalView?
    private var viewportID: UUID?
    private weak var restoreFocusWindow: NSWindow?
    private var onAvailable: ((NSWindow) -> Void)?
    private var availabilityScheduled = false
    private let failure = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        failure.textColor = .secondaryLabelColor
        failure.font = .systemFont(ofSize: 12)
        failure.translatesAutoresizingMaskIntoConstraints = false
        addSubview(failure)
        NSLayoutConstraint.activate([
            failure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            failure.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            failure.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        ])
        failure.isHidden = true
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Programmatic terminal viewport") }

    func install(launch: TerminalLaunch, surfaces: AxodTerminalSurfaces, inputEnabled: Bool,
                 viewportID: UUID, onFocus: @escaping () -> Void, onAvailable: ((NSWindow) -> Void)? = nil) {
        self.onAvailable = onAvailable
        if key == launch.key, self.viewportID == viewportID, let terminal {
            terminal.inputEnabled = inputEnabled; terminal.onFocus = onFocus; notifyAvailability(); return
        }
        releaseViewport()
        do {
            let view = try surfaces.view(for: launch)
            if let previous = view.superview, previous !== self {
                // Only one scene's structural split reflow may move its own
                // retained surface. Another scene remains a competing viewport.
                guard let host = previous as? AxodTerminalHostView, host.viewportID == viewportID else {
                    showFailure("This pane already has an interactive viewport. No second process or silent transfer was created.")
                    return
                }
                if view.window?.firstResponder === view { restoreFocusWindow = view.window }
                host.releaseViewport()
            }
            key = launch.key
            self.viewportID = viewportID
            terminal = view
            view.inputEnabled = inputEnabled
            view.onFocus = onFocus
            failure.isHidden = true
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            view.setVisible(window?.occlusionState.contains(.visible) ?? false)
            restoreFocusIfAttached()
            notifyAvailability()
        } catch {
            showFailure(error.localizedDescription)
        }
    }
    func viewport(for view: TerminalView, key: TerminalLaunch.Key) -> UUID? {
        guard terminal === view, self.key == key, view.superview === self else { return nil }
        return viewportID
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); restoreFocusIfAttached(); notifyAvailability() }
    private func notifyAvailability() {
        guard !availabilityScheduled, let key, let window, let terminal, onAvailable != nil else { return }
        availabilityScheduled = true
        DispatchQueue.main.async { [weak self, weak terminal, weak window] in
            guard let self else { return }
            self.availabilityScheduled = false
            guard let terminal, let window, self.key == key, self.terminal === terminal,
                  terminal.window === window, self.window === window else { return }
            self.onAvailable?(window)
        }
    }
    private func restoreFocusIfAttached() {
        guard let window, let original = restoreFocusWindow else { return }
        if window === original, let terminal { window.makeFirstResponder(terminal) }
        restoreFocusWindow = nil
    }
    private func showFailure(_ message: String) { failure.stringValue = message; failure.isHidden = false }
    func releaseViewport() {
        terminal?.onFocus = nil
        terminal?.setFocus(false)
        terminal?.setVisible(false)
        terminal?.removeFromSuperview()
        terminal = nil
        key = nil
        viewportID = nil
        restoreFocusWindow = nil
    }
}
