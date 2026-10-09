import SwiftUI
import UserNotifications

struct MacSettingsView: View {
    private enum SettingsPage: String, CaseIterable, Identifiable {
        case keyboardShortcuts
        case voice
        case notifications

        var id: Self { self }
        var title: String {
            switch self {
            case .keyboardShortcuts: "Keyboard Shortcuts"
            case .voice: "Voice & Transcripts"
            case .notifications: "Notifications"
            }
        }
        var symbol: String {
            switch self {
            case .keyboardShortcuts: "keyboard"
            case .voice: "waveform"
            case .notifications: "bell"
            }
        }
    }

    @Bindable var voice: MacVoiceCoordinator
    @AppStorage("axoAttentionNotifications") private var attentionNotifications = true
    @AppStorage(MacVoiceTrigger.settingsKey) private var voiceTriggerRaw = MacVoiceTrigger.defaultValue.rawValue
    @State private var selectedSection: SettingsPage? = .keyboardShortcuts
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
            case .notifications:
                notifications
            case nil:
                ContentUnavailableView("Choose a Settings Section", systemImage: "gear")
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onChange(of: attentionNotifications) { _, enabled in
            onNotificationSettingChanged(enabled)
        }
        .task { refreshNotificationPermission() }
    }

    private var keyboardShortcuts: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                pageHeading("Keyboard Shortcuts", subtitle: "Navigate Axo without taking focus away from your terminal work.")
                shortcutGroup("Panes", rows: [
                    ("Previous pane", "⌘["),
                    ("Next pane", "⌘]"),
                    ("Split right", "⌘D"),
                    ("Split down", "⇧⌘E"),
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
                    ("Voice dictation", voiceTrigger.title),
                    ("Toggle sidebar", "⌃⌘S"),
                    ("Open Settings", "⌘,"),
                ])
            }
            .padding(32)
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var voiceSettings: some View {
        Form {
            pageHeading("Voice & Transcripts", subtitle: "Configure local dictation and review transcripts captured from your terminal sessions.")
            Section("Activation") {
                Picker("Option-key voice trigger", selection: Binding(
                    get: { voiceTrigger.rawValue },
                    set: { voiceTriggerRaw = $0 }
                )) {
                    ForEach(MacVoiceTrigger.allCases) { trigger in
                        Text(trigger.title).tag(trigger.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(voiceTrigger.explanation)
                    .font(.callout).foregroundStyle(.secondary)
                Text("The Option gesture is active only while a terminal pane is focused, and reserves a bare Option press for voice. Voice Dictation is also available from the Workspace menu and Command Palette.")
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

    private var voiceTrigger: MacVoiceTrigger {
        MacVoiceTrigger(rawValue: voiceTriggerRaw) ?? .defaultValue
    }

    private var notifications: some View {
        Form {
            pageHeading("Notifications", subtitle: "Choose when Axo may notify you about local session activity.")
            Section {
                Toggle("Notify when sessions need attention", isOn: $attentionNotifications)
                Text("Notifications use generic text and are suppressed while you are viewing that session. Prompts and replies are never included.")
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
