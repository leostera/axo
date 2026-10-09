import AxoCore
import SwiftUI

struct PhoneSettingsView: View {
    let model: PhoneWorkbenchState

    private enum Page: Hashable {
        case appearance
        case connection
        case voice
        case privacy
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Preferences") {
                    NavigationLink(value: Page.appearance) {
                        Label("Appearance", systemImage: "circle.lefthalf.filled")
                    }
                }
                Section("Connection") {
                    NavigationLink(value: Page.connection) {
                        LabeledContent("Mac", value: model.connectionStatus)
                    }
                }
                Section("Input") {
                    NavigationLink(value: Page.voice) {
                        Label("Voice prompting", systemImage: "waveform")
                    }
                }
                Section("Privacy") {
                    NavigationLink(value: Page.privacy) {
                        Label("Data and privacy", systemImage: "hand.raised")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .appearance: AppearanceSettingsPage()
                case .connection:
                    ConnectionSettingsView(
                        endpoint: Binding(get: { model.endpointText }, set: { model.endpointText = $0 }),
                        status: model.connectionStatus,
                        canConnect: !model.voice.isBusy,
                        reconnect: model.reconnect,
                        signIn: model.signIn
                    )
                case .voice: VoiceInformationView()
                case .privacy: PhonePrivacySettingsPage()
                }
            }
        }
    }
}

private struct AppearanceSettingsPage: View {
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearancePicker")
            } footer: {
                Text("System follows the appearance selected in iOS Settings.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Done") { dismiss() } }
    }
}

private struct PhonePrivacySettingsPage: View {
    var body: some View {
        List {
            Section("Conversations") {
                Text("Pi remains the authority for conversation history and execution. Axo does not store a cloud transcript archive.")
            }
            Section("Files") {
                Text("Shared file snapshots are stored by the configured relay. Cloudflare can read this data; it is not end-to-end encrypted.")
                Text("Choosing a file stages a local draft. Uploading requires a separate explicit action, and uploads do not send prompts.")
            }
            Section("Offline behavior") {
                Text("Drafts remain in the current app session. Axo does not queue or automatically replay prompts or session-creation requests while the Mac is offline.")
            }
        }
        .navigationTitle("Data and privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
