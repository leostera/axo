import AppKit
import AxoCore

/// Draws source-list selection behind the whole row, including the icon gutter.
final class WorkspaceSidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let selection = bounds.insetBy(dx: 0, dy: 1)
        NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: selection, xRadius: 5, yRadius: 5).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        guard isSelected else { return super.interiorBackgroundStyle }
        switch effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
        case .darkAqua: return .emphasized
        case .aqua: return .normal
        default: return super.interiorBackgroundStyle
        }
    }
}

/// Native source-list row. Single-click activation belongs to the outline; rename is an inline editor.
final class WorkspaceSidebarRow: NSTableCellView, NSTextFieldDelegate {
    private let originalName: String
    private let finishRename: (String?) -> Void
    private let canBeginRename: () -> Bool
    private var cancelled = false
    private var editing = false
    init(name: String, workspace: Bool, running: Bool, activity: MacAgentState? = nil, loading: Bool = false,
         voiceRecording: Bool = false, actions: NSMenu, canBeginRename: @escaping () -> Bool = { true }, finishRename: @escaping (String?) -> Void) {
        originalName = name; self.finishRename = finishRename; self.canBeginRename = canBeginRename
        super.init(frame: .zero); menu = actions
        let working = activity == .working, attention = activity == .attention
        let open = running && activity != .detached && !loading
        let description = voiceRecording ? "Recording voice" : loading ? "Loading agent status" : working ? "Agent working" : attention ? "Needs your attention" : activity == .detached ? "Agent status unavailable" : open ? "Open" : "Stopped"
        let symbol = workspace ? "folder" : voiceRecording ? "record.circle.fill" : working ? "hammer.fill" : attention ? "exclamationmark.circle.fill" : open ? "circle.fill" : "circle"
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: workspace ? "Workspace" : description)!)
        icon.contentTintColor = workspace ? .secondaryLabelColor : voiceRecording ? .systemRed : attention ? .systemOrange : working ? .secondaryLabelColor : open ? .systemGreen : .tertiaryLabelColor
        icon.toolTip = workspace ? "Project" : description
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: voiceRecording ? 13 : !workspace && !working && !attention ? 6 : 13, weight: .regular)
        icon.imageScaling = .scaleNone
        let leading: NSView
        if loading && !workspace {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning; spinner.controlSize = .mini; spinner.isIndeterminate = true
            spinner.setAccessibilityLabel("Loading agent status"); spinner.toolTip = description
            spinner.startAnimation(nil); leading = spinner
        } else { imageView = icon; leading = icon }
        let label = NSTextField(labelWithString: name)
        label.textColor = .labelColor
        label.font = workspace ? .systemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail; label.delegate = self
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = label
        let stack = NSStackView(views: [leading, label]); stack.orientation = .horizontal; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading.widthAnchor.constraint(equalToConstant: 14), leading.heightAnchor.constraint(equalToConstant: 14),
        ])
        setAccessibilityLabel(name + (workspace ? ", workspace" : ", " + description))
    }
    required init?(coder: NSCoder) { fatalError("Programmatic view only") }
    @objc func renameFromMenu(_ sender: Any?) { beginRenaming() }
    func beginRenaming() {
        guard window != nil, let label = textField, !editing, canBeginRename() else { return }
        editing = true; cancelled = false
        label.isEditable = true; label.isSelectable = true; label.isBezeled = true; label.drawsBackground = true
        label.selectText(nil)
        if label.currentEditor() == nil { cancelled = true; endRenaming() }
    }
    func controlTextDidEndEditing(_ notification: Notification) { endRenaming() }
    private func endRenaming() {
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

/// A flat source-list group label, not another tree node that would indent its members.
final class WorkspaceSidebarHeading: NSTableCellView {
    init(title: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold); label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label); textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("Programmatic view only") }
}

final class WorkspaceOutlineView: NSOutlineView {
    var itemMenu: ((Any) -> NSMenu)?
    var isStandaloneSession: ((Any) -> Bool)?
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        if let item = item(atRow: row), isStandaloneSession?(item) == true {
            // Root leaves have no disclosure control; reclaim only the reserved gutter.
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
