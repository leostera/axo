import AppKit
import Carbon

@MainActor enum AxodResidentPresentation {
    static func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
            || event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    static func show(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func hide(_ window: NSWindow) {
        window.orderOut(nil)
        NSApp.setActivationPolicy(activationPolicy(windows: NSApp.windows))
    }

    static func activationPolicy(windows: [NSWindow]) -> NSApplication.ActivationPolicy {
        windows.contains { $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized) }
            ? .regular : .accessory
    }
}
