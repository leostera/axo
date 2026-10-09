import AppKit
import AxoCore

/// Native source-list row. Single-click activation belongs to the outline; rename is an inline editor.
final class WorkspaceSidebarRow: NSTableCellView, NSTextFieldDelegate {
    private let originalName: String
    private let finishRename: (String?) -> Void
    private var cancelled = false
    private var editing = false
    init(name: String, workspace: Bool, running: Bool, activity: MacAgentState? = nil,
         actions: NSMenu, finishRename: @escaping (String?) -> Void) {
        originalName = name; self.finishRename = finishRename
        super.init(frame: .zero); menu = actions
        let working = activity == .working, attention = activity == .attention
        let description = working ? "Agent working" : attention ? "Needs your attention" : activity == .detached ? "Agent status unavailable" : running ? "Open" : "Stopped"
        let symbol = workspace ? "folder" : working ? "hammer.fill" : attention ? "exclamationmark.circle.fill" : activity == .detached ? "questionmark.circle" : running ? "circle.fill" : "circle"
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: workspace ? "Workspace" : description)!)
        icon.contentTintColor = workspace ? .secondaryLabelColor : attention ? .systemOrange : working || activity == .detached ? .secondaryLabelColor : running ? .systemGreen : .tertiaryLabelColor
        icon.toolTip = workspace ? "Project" : description
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: !workspace && !working && !attention && activity != .detached ? 6 : 13, weight: .regular)
        icon.imageScaling = .scaleNone
        imageView = icon
        let label = NSTextField(labelWithString: name)
        label.font = workspace ? .systemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail; label.delegate = self
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = label
        let stack = NSStackView(views: [icon, label]); stack.orientation = .horizontal; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14), icon.heightAnchor.constraint(equalToConstant: 14),
        ])
        setAccessibilityLabel(name + (workspace ? ", workspace" : ", " + description))
    }
    required init?(coder: NSCoder) { fatalError("Programmatic view only") }
    func beginRenaming() {
        guard let label = textField, !editing else { return }
        editing = true; cancelled = false
        label.isEditable = true; label.isSelectable = true; label.isBezeled = true; label.drawsBackground = true
        label.selectText(nil)
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard editing, let label = textField else { return }; editing = false
        label.isEditable = false; label.isSelectable = false; label.isBezeled = false; label.drawsBackground = false
        finishRename(cancelled ? nil : label.stringValue)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelled = true; textField?.stringValue = originalName
        window?.makeFirstResponder(nil); return true
    }
}

final class WorkspaceOutlineView: NSOutlineView {
    var itemMenu: ((Any) -> NSMenu)?
    var isStandaloneSession: ((Any) -> Bool)?
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        if let item = item(atRow: row), isStandaloneSession?(item) == true {
            // Root leaves have no disclosure control; reclaim only its reserved gutter.
            let gutter = min(indentationPerLevel, frame.minX)
            frame.origin.x -= gutter; frame.size.width += gutter
        }
        return frame
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let item = item(atRow: row) else { return nil }
        return itemMenu?(item)
    }
}
