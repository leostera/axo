import AppKit

@main struct SidebarRowChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        guard let content = window.contentView else { preconditionFailure("Missing owned fixture content view") }

        let readOnly = WorkspaceSidebarRow(name: "Read-only", workspace: true, running: false, actions: NSMenu())
        content.addSubview(readOnly)
        precondition(readOnly.window === window)
        readOnly.beginRenaming()
        readOnly.renameFromMenu(nil)
        precondition(readOnly.textField?.isEditable == false)
        precondition(readOnly.textField?.isSelectable == false)
        precondition(readOnly.textField?.stringValue == "Read-only")

        var admissions = 0
        var completions = 0
        let refused = WorkspaceSidebarRow(name: "Captured row", workspace: false, running: false,
            actions: NSMenu(), rename: .init(begin: { admissions += 1; return false },
                finish: { _ in completions += 1 }))
        content.addSubview(refused)
        refused.beginRenaming()
        precondition(admissions == 1 && completions == 0)
        precondition(refused.textField?.isEditable == false)
        refused.controlTextDidEndEditing(Notification(name: NSText.didEndEditingNotification))
        precondition(completions == 0 && refused.textField?.stringValue == "Captured row")

        var submitted: String?
        let editable = WorkspaceSidebarRow(name: "Authoritative name", workspace: true, running: false,
            actions: NSMenu(), rename: .init(begin: { true }, finish: { submitted = $0 }))
        content.addSubview(editable)
        editable.beginRenaming()
        precondition(editable.textField?.isEditable == true)
        editable.textField?.stringValue = "Uncommitted name"
        editable.controlTextDidEndEditing(Notification(name: NSText.didEndEditingNotification))
        precondition(submitted == "Uncommitted name", "The captured edit is delivered to the authority")
        precondition(editable.textField?.stringValue == "Authoritative name",
            "An unacknowledged name never appears as a successful sidebar value")

        // Detached rows cannot borrow permission from a later window or selection.
        refused.removeFromSuperview()
        refused.beginRenaming()
        precondition(admissions == 1 && completions == 0)
        print("PASS sidebar row rename availability: no-policy, refused admission, detached row and no fabricated completion")
    }
}
