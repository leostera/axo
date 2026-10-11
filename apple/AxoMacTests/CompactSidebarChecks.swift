import AppKit

@main
struct CompactSidebarChecks {
    enum Failure: Error { case failed(String) }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        var expanded = false
        var selected: AxodCompactSidebarView.Destination?
        let workspace = UUID(), session = UUID()
        let rail = AxodCompactSidebarView(onSelect: { selected = $0 }, onExpand: { expanded = true })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 56, height: 520),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = rail
        rail.update(items: [
            .init(destination: .workspace(workspace), name: "Axo", selected: true),
            .init(destination: .session(session), name: "Fix sidebar", selected: true),
        ])
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw Failure.failed(message) }
        }
        func click(_ label: String) throws {
            guard let button = buttons(in: rail).first(where: { $0.accessibilityLabel() == label }) else {
                throw Failure.failed("Missing control: \(label)")
            }
            button.performClick(nil)
        }
        for height: CGFloat in [520, 760, 520] {
            window.setContentSize(NSSize(width: AxodCompactSidebarView.width, height: height))
            rail.layoutSubtreeIfNeeded()
            try check(!rail.isHidden && rail.bounds.width == 56, "Collapsed rail must remain visible and nonzero")
            for button in buttons(in: rail) {
                let rect = button.convert(button.bounds, to: rail)
                try check(rect.width >= 36 && rect.height >= 36 && rect.height <= 44 && rail.bounds.contains(rect), "Rail control \(button.accessibilityLabel() ?? "unknown"): \(rect), viewport \(rail.bounds)")
            }
        }
        try click("Workspace: Axo")
        try check(selected == .workspace(workspace), "Wrong workspace destination")
        try click("Session: Fix sidebar")
        try check(selected == .session(session), "Wrong session destination")
        try click("Expand sidebar")
        try check(expanded, "Expand must remain functional")
        try check(!buttons(in: rail).contains { $0.accessibilityLabel() == "Create workspace or session" }, "Creation belongs in menus/shortcuts")
        try check(!buttons(in: rail).contains { $0.accessibilityLabel() == "Settings" }, "Settings belongs in the app menu")
        let expand = buttons(in: rail).first { $0.accessibilityLabel() == "Expand sidebar" }!
        try check(expand.convert(expand.bounds, to: rail).minY < 20, "Expand control belongs at the bottom")

        rail.update(items: (0..<100).map { .init(destination: .session(UUID()), name: "Session \($0)", selected: false) })
        rail.layoutSubtreeIfNeeded()
        try check(buttons(in: rail).count == 101, "Navigation must not be truncated")
        guard let scroll = rail.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView,
              let document = scroll.documentView else { throw Failure.failed("Missing scrollable navigation") }
        try check(document.bounds.height > scroll.contentView.bounds.height, "Long navigation must scroll")
        try click("Expand sidebar") // The footer remains outside the scrolling navigation.
        print("Compact sidebar: visible 56pt rail, resized controls, exact navigation and persistent actions passed.")
    }
}
