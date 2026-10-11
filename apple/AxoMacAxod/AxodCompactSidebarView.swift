import AppKit

/// Collapsed navigation is a usable icon rail, not a hidden sidebar.
@MainActor
final class AxodCompactSidebarView: NSView {
    static let width: CGFloat = 56

    enum Destination: Equatable {
        case workspace(UUID)
        case session(UUID)
    }

    struct Item: Equatable {
        let destination: Destination
        let name: String
        let selected: Bool
    }

    private let navigation = NSStackView()
    private let onSelect: (Destination) -> Void
    private var items: [Item] = []

    init(onSelect: @escaping (Destination) -> Void, onExpand: @escaping () -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)
        setAccessibilityLabel("Compact workspace and session sidebar")

        let expand = actionButton(symbol: "sidebar.left", label: "Expand sidebar", action: onExpand)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        navigation.orientation = .vertical
        navigation.alignment = .centerX
        navigation.spacing = 6
        navigation.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = navigation

        for child in [scroll, expand] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            expand.centerXAnchor.constraint(equalTo: centerXAnchor),
            expand.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: expand.topAnchor, constant: -12),
            navigation.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            navigation.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            navigation.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Programmatic view only") }

    func update(items: [Item]) {
        guard self.items != items else { return }
        self.items = items
        for view in navigation.arrangedSubviews { navigation.removeArrangedSubview(view); view.removeFromSuperview() }
        for item in items {
            let button = AxodRailButton(action: { [weak self] in self?.onSelect(item.destination) })
            switch item.destination {
            case .workspace:
                button.title = String(item.name.prefix(1)).uppercased()
                button.font = .systemFont(ofSize: 14, weight: .semibold)
                button.setAccessibilityLabel("Workspace: \(item.name)")
            case .session:
                button.image = NSImage(systemSymbolName: "hammer", accessibilityDescription: item.name)
                button.setAccessibilityLabel("Session: \(item.name)")
            }
            button.toolTip = item.name
            button.selected = item.selected
            navigation.addArrangedSubview(button)
        }
    }

    private func actionButton(symbol: String, label: String, action: @escaping () -> Void) -> NSButton {
        let button = AxodRailButton(action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }
}

@MainActor
private final class AxodRailButton: NSButton {
    var selected = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(selected ? 1 : 0)
        }
    }
    private let onPress: () -> Void

    init(action: @escaping () -> Void) {
        self.onPress = action
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        imageScaling = .scaleProportionallyDown
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        target = self
        self.action = #selector(press(_:))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    // Borderless glyph targets fill their 36-point boxes. Bezel alignment
    // insets otherwise enlarge frames into neighboring rail controls.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }

    required init?(coder: NSCoder) { fatalError("Programmatic control only") }
    @objc private func press(_ sender: Any?) { onPress() }

    override func draw(_ dirtyRect: NSRect) {
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }
}
