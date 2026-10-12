import SwiftUI

struct AxodServiceSettingsView: View {
    @Bindable var coordinator: AxodWorkbenchCoordinator
    private var lifecycle: AxodServiceLifecycle { coordinator.serviceLifecycle }

    var body: some View {
        Form {
            Section("Background service") {
                LabeledContent("Status", value: status)
                HStack {
                    if lifecycle.registration == .notRegistered {
                        Button("Enable") { coordinator.enableBackgroundService() }
                            .disabled(lifecycle.operation != .idle)
                    }
                    Button("Open Settings") { coordinator.openLoginItemsSettings() }
                    Button("Check Status") {
                        lifecycle.observeRegistration()
                        if coordinator.connectionState == .connected { coordinator.refresh() }
                        else { coordinator.connect() }
                    }
                }
            }
            Section {
                Toggle("Open Axo at login", isOn: Binding(
                    get: { lifecycle.loginRegistration == .enabled },
                    set: { enabled in Task { await lifecycle.setFrontendAtLogin(enabled) } }))
                    .disabled(lifecycle.operation != .idle || lifecycle.loginRegistration == .notFound || lifecycle.loginRegistration == .unavailable)
                if lifecycle.loginRegistration == .requiresApproval {
                    Text("Login approval needed.").foregroundStyle(.secondary)
                }
            }
            Section {
                DisclosureGroup("Details") {
                    Text(lifecycle.registration.message)
                    if let host = coordinator.hostStatus { LabeledContent("Version", value: host.daemonVersion) }
                    if coordinator.helperUpdateAvailable { Text("Helper update available.") }
                    if coordinator.hasUnresolvedHelperHandoff { Text("An earlier helper update is unconfirmed. Its original record is preserved.") }
                    if let failure = coordinator.serviceSetupFailure ?? lifecycle.failureMessage {
                        Text(failure).foregroundStyle(.orange)
                    }
                    Text("Sessions keep running when you quit Axo. Opening Axo at login is a separate setting.")
                }
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(minWidth: 560, minHeight: 360)
        .onAppear { lifecycle.observeRegistration() }
    }

    private var status: String {
        switch lifecycle.registration {
        case .notRegistered: return "Off"
        case .requiresApproval: return "Approval needed"
        case .notFound: return "Unavailable"
        case .unavailable: return "Unknown"
        case .enabled:
            switch coordinator.connectionState {
            case .connected: return "Running"
            case .starting: return "Checking…"
            case .failed, .disconnected: return "Unavailable"
            }
        }
    }
}
