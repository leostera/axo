import AppKit
import SwiftUI

struct AxodTerminalHost: NSViewRepresentable {
    let launch: TerminalLaunch
    let surfaces: AxodTerminalSurfaces
    let inputEnabled: Bool

    func makeNSView(context: Context) -> AxodTerminalHostView { AxodTerminalHostView() }
    func updateNSView(_ host: AxodTerminalHostView, context: Context) {
        host.install(launch: launch, surfaces: surfaces, inputEnabled: inputEnabled)
    }
    static func dismantleNSView(_ host: AxodTerminalHostView, coordinator: ()) { host.releaseViewport() }
}

/// The viewport owns containment, not the surface, execution or work records.
@MainActor
final class AxodTerminalHostView: NSView {
    private var key: TerminalLaunch.Key?
    private weak var terminal: TerminalView?
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

    func install(launch: TerminalLaunch, surfaces: AxodTerminalSurfaces, inputEnabled: Bool) {
        if key == launch.key, let terminal { terminal.inputEnabled = inputEnabled; return }
        releaseViewport()
        do {
            let view = try surfaces.view(for: launch)
            guard view.superview == nil || view.superview === self else {
                showFailure("This pane already has an interactive viewport. No second process or silent transfer was created.")
                return
            }
            key = launch.key
            terminal = view
            view.inputEnabled = inputEnabled
            failure.isHidden = true
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            view.setVisible(window?.occlusionState.contains(.visible) ?? false)
        } catch {
            showFailure(error.localizedDescription)
        }
    }
    private func showFailure(_ message: String) { failure.stringValue = message; failure.isHidden = false }
    func releaseViewport() {
        terminal?.setFocus(false)
        terminal?.setVisible(false)
        terminal?.removeFromSuperview()
        terminal = nil
        key = nil
    }
}
