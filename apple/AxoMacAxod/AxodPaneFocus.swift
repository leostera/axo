import AppKit

@MainActor struct AxodPaneFocus {
    let move: AxodPaneLayouts.FocusMove
    let source: TerminalLaunch.Key
    let destination: TerminalLaunch.Key
    let viewportID: UUID
    weak var window: NSWindow?
}
