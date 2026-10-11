import SwiftUI

struct AxodServiceSettingsView: View {
    @Bindable var coordinator: AxodWorkbenchCoordinator
    private var lifecycle: AxodServiceLifecycle { coordinator.serviceLifecycle }

    var body: some View {
        Form {
            Section("Background host") {
                Text(lifecycle.registration.message)
                Text("Axod owns Pi and shell processes. Quitting the frontend leaves their work running. Only macOS launches the production helper.")
                    .foregroundStyle(.secondary)
                if lifecycle.registration == .notRegistered {
                    Button("Enable Background Service…") { coordinator.enableBackgroundService() }
                        .disabled(lifecycle.operation != .idle)
                }
                Button("Review macOS Background Items…") { coordinator.openLoginItemsSettings() }
                Button("Refresh Registration Status") { lifecycle.observeRegistration() }
            }
            Section("Observed daemon") {
                if let host = coordinator.hostStatus {
                    LabeledContent("Responding helper", value: host.daemonVersion)
                    if coordinator.helperUpdateAvailable {
                        Text("The running helper differs from this package. Supported operations remain available. No update or restart is performed during reconnect.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Daemon readiness is unknown. An enabled registration does not prove that the helper is running.")
                        .foregroundStyle(.secondary)
                }
            }
            if coordinator.hasUnresolvedHelperHandoff {
                Section("Preserved handoff") {
                    Text("An original helper handoff remains unresolved. Its evidence has been retained; reconnect does not replay, replace, or discard it.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Frontend login startup") {
                Toggle("Open the Axo window at login", isOn: Binding(
                    get: { lifecycle.loginRegistration == .enabled },
                    set: { enabled in Task { await lifecycle.setFrontendAtLogin(enabled) } }))
                    .disabled(lifecycle.operation != .idle || lifecycle.loginRegistration == .notFound || lifecycle.loginRegistration == .unavailable)
                if lifecycle.loginRegistration == .requiresApproval {
                    Text("Frontend login startup needs approval in macOS Login Items.")
                }
                Text("This is separate from the background host. Turning it off does not stop Axod or its sessions.")
                    .foregroundStyle(.secondary)
            }
            if let failure = coordinator.serviceSetupFailure ?? lifecycle.failureMessage {
                Section("Setup outcome") { Text(failure).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(minWidth: 560, minHeight: 360)
        .onAppear { lifecycle.observeRegistration() }
    }
}
