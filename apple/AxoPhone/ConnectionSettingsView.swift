import AxoCore
import SwiftUI

struct ConnectionSettingsView: View {
    @Binding var endpoint: String
    let status: String
    let canConnect: Bool
    let reconnect: () -> Void
    let signIn: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var validEndpoint: Bool { (try? RelayEndpoint(endpoint)) != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac connection") {
                    Label(status, systemImage: "desktopcomputer")
                    Button("Reconnect", action: reconnect).disabled(!canConnect || !validEndpoint)
                    Button("Sign in with Cloudflare Access", action: signIn).disabled(!canConnect || !validEndpoint)
                }
                Section {
                    TextField("HTTPS relay endpoint", text: $endpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("relayEndpoint")
                    if !validEndpoint { Text("Enter an HTTPS origin without a path.").font(.caption).foregroundStyle(.orange) }
                } header: { Text("Relay") } footer: {
                    Text("Your Mac must have Axo running. Prompts are not queued while it is offline.")
                }
            }
            .tint(.white)
            .navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .presentationDragIndicator(.visible)
    }
}
