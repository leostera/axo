import AppKit

/// Native source-list row with a separate status indicator and a visible action menu.
final class WorkspaceSidebarRow: NSTableCellView {
    private let actions: NSMenu
    private let actionButton = NSButton()

    init(name: String, workspace: Bool, running: Bool, actions: NSMenu) {
        self.actions = actions
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: workspace ? "folder" : "bubble.left",
                                             accessibilityDescription: workspace ? "Workspace" : "Session")!)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: name)
        label.font = workspace ? .systemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = label
        actionButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Rename actions")
        actionButton.isBordered = false
        actionButton.target = self; actionButton.action = #selector(showActions(_:))
        actionButton.toolTip = workspace ? "Workspace actions" : "Session actions"
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal; stack.spacing = 8
        if !workspace {
            let status = NSImageView(image: NSImage(systemSymbolName: running ? "circle.fill" : "circle",
                                                   accessibilityDescription: running ? "Running" : "Stopped")!)
            status.contentTintColor = running ? .systemGreen : .tertiaryLabelColor
            status.toolTip = running ? "Process running" : "Stopped — select to resume explicitly"
            stack.addArrangedSubview(status)
            status.widthAnchor.constraint(equalToConstant: 6).isActive = true
            status.heightAnchor.constraint(equalToConstant: 6).isActive = true
        }
        stack.addArrangedSubview(actionButton)
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14), icon.heightAnchor.constraint(equalToConstant: 14),
            actionButton.widthAnchor.constraint(equalToConstant: 20), actionButton.heightAnchor.constraint(equalToConstant: 20),
        ])
        setAccessibilityLabel(name + (workspace ? ", workspace" : running ? ", running session" : ", stopped session"))
    }
    required init?(coder: NSCoder) { fatalError("Programmatic view only") }
    @objc private func showActions(_ sender: Any?) {
        actions.popUp(positioning: nil, at: NSPoint(x: 0, y: actionButton.bounds.height + 4), in: actionButton)
    }
}
