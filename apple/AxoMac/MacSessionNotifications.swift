import AppKit
import AxoCore
import UserNotifications

struct MacSessionBinding {
    let sessionID: AxoSessionID
    let paneID: PaneID
    let generation: UUID
    let path: String
}

/// Bounded read-only polling. Captured bindings are checked again by the owner after every async read.
final class MacSessionObserver {
    private let queue = DispatchQueue(label: "dev.leostera.axo.agent-state", qos: .utility)
    private let timer = DispatchSource.makeTimerSource(queue: .main)
    private var reading = false
    private let bindings: () -> [MacSessionBinding]
    private let receive: (MacSessionBinding, MacSessionState?) -> Void
    init(bindings: @escaping () -> [MacSessionBinding], receive: @escaping (MacSessionBinding, MacSessionState?) -> Void) {
        self.bindings = bindings; self.receive = receive
        timer.schedule(deadline: .now() + 0.3, repeating: 0.4)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
    }
    private func poll() {
        guard !reading else { return }
        let captured = bindings(); guard !captured.isEmpty else { return }
        reading = true
        queue.async { [weak self] in
            let updates = captured.map { binding -> (MacSessionBinding, MacSessionState?) in
                let snapshot = MacSessionState.read(from: binding.path)
                return (binding, snapshot?.matches(session: binding.sessionID, pane: binding.paneID, generation: binding.generation) == true ? snapshot : nil)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.reading = false
                for (binding, snapshot) in updates { self.receive(binding, snapshot) }
            }
        }
    }
    deinit { timer.cancel() }
}

/// macOS local notifications carry opaque destinations and generic text, never prompt/result previews.
final class MacSessionNotifications: NSObject, UNUserNotificationCenterDelegate {
    struct Destination {
        let sessionID: AxoSessionID
        let paneID: PaneID
        let generation: UUID
        let conversationID: String
    }
    private let center = UNUserNotificationCenter.current()
    private let activate: (Destination) -> Void
    private let isViewing: (AxoSessionID) -> Bool
    private let testDestination: () -> Destination?
    private var settings: NSWindowController?
    private weak var permissionLabel: NSTextField?
    init(isViewing: @escaping (AxoSessionID) -> Bool, testDestination: @escaping () -> Destination?, activate: @escaping (Destination) -> Void) {
        self.isViewing = isViewing; self.testDestination = testDestination; self.activate = activate; super.init()
        UserDefaults.standard.register(defaults: ["axoAttentionNotifications": true])
        center.delegate = self
        if UserDefaults.standard.bool(forKey: "axoAttentionNotifications") { requestPermission() }
    }
    func notify(_ snapshot: MacSessionState, binding: MacSessionBinding) {
        guard UserDefaults.standard.bool(forKey: "axoAttentionNotifications"), let conversation = snapshot.conversationID else { return }
        let content = UNMutableNotificationContent()
        content.title = "Axo"
        content.body = snapshot.attentionReason == .question ? "An agent is waiting for your input." :
            snapshot.attentionReason == .failure ? "An agent needs your attention after an error." : "An agent's reply is ready for review."
        content.sound = .default
        content.threadIdentifier = binding.sessionID.rawValue.uuidString
        content.userInfo = ["sessionID": binding.sessionID.rawValue.uuidString, "paneID": binding.paneID.rawValue.uuidString,
                            "runtimeGeneration": binding.generation.uuidString, "conversationID": conversation]
        // One replaceable notification per session, not an unbounded completion backlog.
        let request = UNNotificationRequest(identifier: identifier(binding.sessionID), content: content, trigger: nil)
        center.add(request) { _ in /* Permission denial never affects the session or its sidebar state. */ }
    }
    func dismiss(_ session: AxoSessionID, includingTests: Bool = false) {
        let ids = [identifier(session)] + (includingTests ? ["axo.test." + session.rawValue.uuidString] : [])
        center.removeDeliveredNotifications(withIdentifiers: ids); center.removePendingNotificationRequests(withIdentifiers: ids)
    }
    private func identifier(_ session: AxoSessionID) -> String { "axo.attention." + session.rawValue.uuidString }
    private func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in self?.refreshPermissionStatus() }
    }
    private func refreshPermissionStatus() {
        center.getNotificationSettings { [weak self] value in
            let description: String
            switch value.authorizationStatus {
            case .notDetermined: description = "Permission has not been requested. Enable notifications above."
            case .denied: description = "Notifications are disabled in macOS. Open Notification Settings to allow Axo."
            case .authorized: description = "Permission allowed. Banner preferences and Focus can still suppress delivery."
            case .provisional: description = "Quiet notifications allowed; enable banners in macOS Notification Settings."
            case .ephemeral: description = "Notification permission is temporary."
            @unknown default: description = "Check Axo's permission in macOS Notification Settings."
            }
            DispatchQueue.main.async { self?.permissionLabel?.stringValue = description }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let info = notification.request.content.userInfo
        let isTest = info["isTest"] as? Bool == true
        let session = (info["sessionID"] as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async { [weak self] in
            if !isTest, let session, self?.isViewing(AxoSessionID(session)) == true { completionHandler([]) }
            else { completionHandler([.banner, .sound]) }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { completionHandler(); return }
        let info = response.notification.request.content.userInfo
        guard let session = (info["sessionID"] as? String).flatMap(UUID.init(uuidString:)),
              let pane = (info["paneID"] as? String).flatMap(UUID.init(uuidString:)),
              let generation = (info["runtimeGeneration"] as? String).flatMap(UUID.init(uuidString:)),
              let conversation = info["conversationID"] as? String, !conversation.isEmpty, conversation.utf8.count <= 128 else { completionHandler(); return }
        center.removeDeliveredNotifications(withIdentifiers: [response.notification.request.identifier])
        DispatchQueue.main.async { [weak self] in
            self?.activate(.init(sessionID: AxoSessionID(session), paneID: PaneID(pane), generation: generation, conversationID: conversation))
            completionHandler()
        }
    }
    func showSettings() {
        refreshPermissionStatus()
        if let settings { settings.showWindow(nil); settings.window?.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 285),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Axo Settings"; window.isReleasedWhenClosed = false
        let toggle = NSButton(checkboxWithTitle: "Notify when sessions need attention", target: self, action: #selector(toggleNotifications(_:)))
        toggle.state = UserDefaults.standard.bool(forKey: "axoAttentionNotifications") ? .on : .off
        let description = NSTextField(wrappingLabelWithString: "Notifications contain generic text, not prompts or replies. Banners are suppressed while you are viewing that session.")
        description.textColor = .secondaryLabelColor
        let permission = NSButton(title: "macOS Notification Settings…", target: self, action: #selector(openSystemSettings(_:)))
        let status = NSTextField(wrappingLabelWithString: "Checking notification permission…")
        status.textColor = .secondaryLabelColor; permissionLabel = status
        let test = NSButton(title: "Send Test Notification", target: self, action: #selector(sendTestNotification(_:)))
        test.toolTip = "Send a clearly marked test for the selected live Pi session. No prompt is submitted."
        let stack = NSStackView(views: [toggle, description, status, permission, test]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView?.addSubview(stack)
        if let view = window.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
                                         stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
                                         stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        }
        settings = NSWindowController(window: window); window.center(); settings?.showWindow(nil)
        refreshPermissionStatus()
    }
    @objc private func sendTestNotification(_ sender: Any?) {
        guard UserDefaults.standard.bool(forKey: "axoAttentionNotifications") else {
            permissionLabel?.stringValue = "Enable notifications before sending a test."; return
        }
        guard let destination = testDestination() else {
            permissionLabel?.stringValue = "Select an open Pi conversation with saved history, then retry. No session was started."; return
        }
        let content = UNMutableNotificationContent()
        content.title = "Axo notification test"
        content.body = "This is a test notification. Click to open its session. No prompt will be submitted."
        content.sound = .default
        content.threadIdentifier = destination.sessionID.rawValue.uuidString
        content.userInfo = ["sessionID": destination.sessionID.rawValue.uuidString, "paneID": destination.paneID.rawValue.uuidString,
                            "runtimeGeneration": destination.generation.uuidString, "conversationID": destination.conversationID, "isTest": true]
        let request = UNNotificationRequest(identifier: "axo.test." + destination.sessionID.rawValue.uuidString, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            DispatchQueue.main.async {
                self?.permissionLabel?.stringValue = error == nil ? "Test accepted by macOS. Click its banner or find it in Notification Center." :
                    "macOS did not accept the test. Check notification permission and retry."
            }
        }
    }
    @objc private func toggleNotifications(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "axoAttentionNotifications")
        if sender.state == .on { requestPermission() }
        else { center.removeAllDeliveredNotifications(); center.removeAllPendingNotificationRequests() }
    }
    @objc private func openSystemSettings(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
