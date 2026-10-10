import SwiftUI
import UserNotifications

struct MacSettingsView: View {
    private enum SettingsPage: String, CaseIterable, Identifiable {
        case general
        case keyboardShortcuts
        case voice

        var id: Self { self }
        var title: String {
            switch self {
            case .keyboardShortcuts: "Keybindings"
            case .voice: "Voice & Transcript"
            case .general: "General"
            }
        }
        var symbol: String {
            switch self {
            case .keyboardShortcuts: "keyboard"
            case .voice: "waveform"
            case .general: "gearshape"
            }
        }
    }

    @Bindable var voice: MacVoiceCoordinator
    @AppStorage(MacAppearance.settingsKey) private var appearanceRaw = MacAppearance.system.rawValue
    @AppStorage("axoAttentionNotifications") private var attentionNotifications = true
    @AppStorage("axoNotificationPreviews") private var notificationPreviews = false
    @AppStorage(MacVoiceKeyBinding.settingsKey) private var voiceKeyBindingRaw = MacVoiceKeyBinding.defaultValue.rawValue
    @State private var isCapturingVoiceKey = false
    @State private var selectedSection: SettingsPage? = .general
    @State private var notificationPermission = "Checking notification permission…"

    let onNotificationSettingChanged: (Bool) -> Void
    let openNotificationSettings: () -> Void

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationTitle("Axo Settings")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        } detail: {
            switch selectedSection {
            case .keyboardShortcuts:
                keyboardShortcuts
            case .voice:
                voiceSettings
            case .general:
                general
            case nil:
                ContentUnavailableView("Choose a Settings Section", systemImage: "gear")
            }
        }
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 720, minHeight: 480)
        .onChange(of: attentionNotifications) { _, enabled in
            onNotificationSettingChanged(enabled)
        }
        .onChange(of: appearanceRaw) { _, _ in MacAppearance.applyPreference() }
        .task { refreshNotificationPermission() }
    }

    private var keyboardShortcuts: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                pageHeading("Keybindings", subtitle: "Review Axo shortcuts and choose the key used for voice dictation.")
                shortcutGroup("Panes", rows: [
                    ("Previous pane", "⌘["),
                    ("Next pane", "⌘]"),
                    ("Split right", "⌘D"),
                    ("Split down", "⇧⌘D"),
                    ("Close pane", "⌘W"),
                ])
                shortcutGroup("Sessions", rows: [
                    ("Previous session", "⌘{"),
                    ("Next session", "⌘}"),
                    ("New session", "⌘T"),
                ])
                shortcutGroup("Workspaces", rows: [
                    ("Previous workspace", "⌘<"),
                    ("Next workspace", "⌘>"),
                    ("New workspace", "⌘N"),
                ])
                shortcutGroup("Window", rows: [
                    ("Command palette", "⇧⌘P"),
                    ("Toggle sidebar", "⌃⌘S"),
                    ("Open Settings", "⌘,"),
                ])
                voiceKeybindingGroup
            }
            .padding(32)
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var voiceSettings: some View {
        Form {
            pageHeading("Voice & Transcript", subtitle: "Configure local dictation and review transcripts captured from your terminal sessions.")
            Section("Activation") {
                Label("Voice key: \(voiceKeyBinding.title)", systemImage: "keyboard")
                Text("Hold the key to talk. Double-press it to lock recording; double-press again to unlock and transcribe.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("The voice keybinding is active only while a terminal pane is focused. Voice Dictation is also available from the Workspace menu and Command Palette.")
                    .font(.callout).foregroundStyle(.secondary)
                if let target = voice.recordingTarget {
                    Label("Recording for \(target.label)", systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                } else if voice.isStarting {
                    Label("Preparing microphone and speech recognition…", systemImage: "waveform")
                        .foregroundStyle(.secondary)
                }
                if let error = voice.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            Section("Transcript history (last \(MacVoiceHistoryStore.maximumTranscripts))") {
                if voice.transcripts.isEmpty {
                    ContentUnavailableView("No Transcripts Yet", systemImage: "text.bubble",
                                           description: Text("Completed dictations will appear here."))
                } else {
                    HStack {
                        Spacer()
                        Button("Clear History", role: .destructive) { voice.clearTranscripts() }
                    }
                    ForEach(voice.transcripts) { transcript in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Label(transcript.destinationLabel, systemImage: transcript.insertion == .inserted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(transcript.insertion == .inserted ? Color.primary : Color.orange)
                                Spacer()
                                Text(transcript.createdAt, style: .date).foregroundStyle(.secondary)
                                Text(transcript.createdAt, style: .time).foregroundStyle(.secondary)
                            }
                            Text(transcript.insertion == .inserted ? "Inserted into the captured pane" : "Original pane unavailable; transcript was not inserted")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(transcript.text).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(transcript.text, forType: .string)
                                }
                                Button("Delete", role: .destructive) { voice.deleteTranscript(transcript.id) }
                                Spacer()
                            }
                        }
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
            }
            Section("On-device transcription") {
                Label("Apple on-device speech recognition", systemImage: "waveform")
                Text("Axo records audio to a private temporary file, transcribes locally using Apple Speech, then deletes the audio. The transcript is inserted as plain text into the pane captured at recording start. Axo never presses Return, runs a command, or submits a Pi prompt. If that pane has closed or restarted, the transcript is kept here instead of being retargeted.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("macOS may download Apple's speech assets. Audio and transcript history stay on this Mac and are not sent to Axo's relay.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var voiceKeyBinding: MacVoiceKeyBinding {
        MacVoiceKeyBinding(rawValue: voiceKeyBindingRaw) ?? .defaultValue
    }

    private var voiceKeybindingGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice Dictation").font(.title3.weight(.semibold))
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice key")
                    Text("Default: Right Option. Hold to talk; double-press to lock or unlock.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                MacVoiceKeyBindingRecorder(
                    binding: Binding(
                        get: { voiceKeyBinding },
                        set: { voiceKeyBindingRaw = $0.rawValue }
                    ),
                    isCapturing: $isCapturingVoiceKey
                )
                .frame(width: 170, height: 30)
            }
            Text("Click the key field and press a modifier or key combination. Escape cancels. The chosen key is reserved while a terminal pane is focused.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
        }
    }

    private var general: some View {
        Form {
            pageHeading("General", subtitle: "Preferences for your Axo workbench.")
            Section("Appearance") {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(MacAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("Notifications") {
                Toggle("Notify when sessions need attention", isOn: $attentionNotifications)
                Toggle("Include recent reply previews", isOn: $notificationPreviews)
                Text("Notifications identify the session and attention reason. Reply previews are off by default; when enabled, up to 180 characters of the latest reply may appear on your Lock Screen. Notifications are suppressed while you are viewing that session.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(notificationPermission)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open macOS Notification Settings…", action: openNotificationSettings)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func pageHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.largeTitle.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private func shortcutGroup(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            ForEach(rows.indices, id: \.self) { index in
                HStack {
                    Text(rows[index].0)
                    Spacer()
                    Text(rows[index].1)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                Divider()
            }
        }
    }

    private func refreshNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: String
            switch settings.authorizationStatus {
            case .notDetermined: status = "macOS has not asked for notification permission yet."
            case .denied: status = "Notifications are disabled in macOS. Enable them in Notification Settings."
            case .authorized: status = "Notifications are allowed. Focus and banner preferences may still suppress delivery."
            case .provisional: status = "Quiet notifications are allowed; configure banners in Notification Settings."
            case .ephemeral: status = "Notification permission is temporary."
            @unknown default: status = "Check Axo’s permission in Notification Settings."
            }
            DispatchQueue.main.async { notificationPermission = status }
        }
    }
}
