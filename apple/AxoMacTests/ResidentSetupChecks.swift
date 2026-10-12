import AppKit
import AxoProtocol
import Carbon
import Foundation

@main struct ResidentSetupChecks {
    @MainActor static func main() throws {
        let target = MachineTarget(machineId: UUID(), hostGeneration: UUID())
        let other = MachineTarget(machineId: target.machineId, hostGeneration: UUID())
        precondition(AxodSetupPolicy.stage(registration: .notRegistered, availability: .unknown, connection: .unavailable) == .enableService)
        precondition(AxodSetupPolicy.stage(registration: .requiresApproval, availability: .unknown, connection: .checking) == .approval)
        precondition(AxodSetupPolicy.stage(registration: .enabled, availability: .unknown, connection: .unavailable) == .unavailable)
        precondition(AxodSetupPolicy.stage(registration: .enabled, availability: .ready(target), connection: .checking) == .checking)
        precondition(AxodSetupPolicy.stage(registration: .enabled, availability: .ready(other), connection: .loaded(target)) == .unavailable)
        precondition(AxodSetupPolicy.stage(registration: .enabled, availability: .ready(target), connection: .loaded(target)) == .ready(target))
        for registration in [AxodServiceLifecycle.Registration.notFound, .unavailable] {
            precondition(AxodSetupPolicy.stage(registration: registration, availability: .ready(target), connection: .loaded(target)) == .unavailable)
        }

        for registration in [AxodServiceLifecycle.Registration.notRegistered, .requiresApproval, .notFound, .unavailable, .enabled] {
            let steps = AxodSetupPolicy.steps(registration: registration)
            precondition(steps.map(\.number) == [1, 2, 3], "Setup is exactly three stable steps")
            precondition(steps.map(\.title) == ["Register background service", "Allow background activity", "Open Axo"])
            precondition(steps[0].complete == (registration == .enabled || registration == .requiresApproval))
            precondition(steps[1].complete == (registration == .enabled), "Confirmed permission is separate from daemon readiness")
            precondition(!steps[2].complete, "Only Finish opens the workbench")
        }
        precondition(!AxodServiceLifecycle.Registration.enabled.message.contains("eligible"))

        let domain = "Axo.ResidentSetupFixture.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let presentation = AxodSetupPresentation(preferences: preferences)
        presentation.restoreIfKnownReady(.ready(target))
        precondition(!presentation.enteredWorkbench && presentation.requestedLoginStartup == nil)
        precondition(!presentation.complete(captured: target, stage: .ready(other)))
        precondition(preferences.object(forKey: AxodSetupPresentation.completionKey) == nil)
        precondition(presentation.complete(captured: target, stage: .ready(target)))
        precondition(preferences.integer(forKey: AxodSetupPresentation.completionKey) == 1)
        let restored = AxodSetupPresentation(preferences: preferences)
        restored.restoreIfKnownReady(.unavailable)
        precondition(!restored.enteredWorkbench, "A hint cannot bypass readiness")
        restored.restoreIfKnownReady(.ready(target))
        precondition(restored.enteredWorkbench)
        restored.restoreIfKnownReady(.unavailable)
        precondition(restored.enteredWorkbench, "Connection loss does not replace an active workbench")
        let unknownValues: [Any] = [true, "opaque", 2]
        for unknown in unknownValues {
            // CFPreferences may coalesce numeric 1 and Boolean true as equal;
            // start with no fixture value to exercise the actual opaque type.
            preferences.removeObject(forKey: AxodSetupPresentation.completionKey)
            preferences.set(unknown, forKey: AxodSetupPresentation.completionKey)
            let future = AxodSetupPresentation(preferences: preferences)
            future.restoreIfKnownReady(.ready(target))
            precondition(!future.enteredWorkbench)
            precondition(future.complete(captured: target, stage: .ready(target)))
            precondition((preferences.object(forKey: AxodSetupPresentation.completionKey) as! NSObject).isEqual(unknown))
        }

        let loginEvent = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEOpenApplication,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        precondition(!AxodResidentPresentation.isLoginLaunch(nil))
        precondition(!AxodResidentPresentation.isLoginLaunch(loginEvent))
        loginEvent.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: keyAELaunchedAsLogInItem)
        precondition(AxodResidentPresentation.isLoginLaunch(loginEvent))

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 250, height: 140),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let settingsWindow = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 180, height: 100),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settingsWindow.isReleasedWhenClosed = false
        precondition(AxodResidentPresentation.activationPolicy(windows: [window]) == .accessory)
        var openCalls = 0, settingsCalls = 0, serviceCalls = 0
        let menu = AxodMenuBarController(status: { "Axo — Fixture" }, open: {
            openCalls += 1; AxodResidentPresentation.show(window)
        }, settings: { settingsCalls += 1 }, service: { serviceCalls += 1 })
        defer { menu.remove(); window.orderOut(nil); settingsWindow.orderOut(nil) }
        let item = menu.fixtureItem
        menu.menuNeedsUpdate(menu.fixtureMenu)
        precondition(menu.fixtureMenu.item(at: 0)?.title == "Axo — Fixture")
        let original = ObjectIdentifier(window)
        menu.fixtureMenu.performActionForItem(at: 2)
        precondition(openCalls == 1 && window.isVisible)
        precondition(AxodResidentPresentation.activationPolicy(windows: [window]) == .regular)
        settingsWindow.orderFront(nil)
        AxodResidentPresentation.hide(window)
        precondition(!window.isVisible && menu.fixtureItem === item)
        precondition(AxodResidentPresentation.activationPolicy(windows: [window, settingsWindow]) == .regular)
        settingsWindow.orderOut(nil)
        precondition(AxodResidentPresentation.activationPolicy(windows: [window, settingsWindow]) == .accessory)
        menu.fixtureMenu.performActionForItem(at: 2)
        precondition(openCalls == 2 && ObjectIdentifier(window) == original && window.isVisible)
        menu.fixtureMenu.performActionForItem(at: 3)
        menu.fixtureMenu.performActionForItem(at: 4)
        precondition(settingsCalls == 1 && serviceCalls == 1)
        precondition(menu.fixtureMenu.item(at: 6)?.action == #selector(NSApplication.terminate(_:)))
        print("PASS: three-step native registration/approval/readiness/epoch gates, preserved opaque/future hints, independent login choice, native status menu, retained hide/reopen and other-window activation; component checks, not installed service/login/authorized UI acceptance")
    }
}
