import AppKit
import AxoDaemonManager
import AxoRPC
import SwiftUI

enum AppearanceTheme: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

enum SettingsSection: String, CaseIterable, Identifiable {
  case general
  case appearance
  case agent
  case remoteAccess
  case about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .appearance: "Appearance"
    case .agent: "Agent"
    case .remoteAccess: "Remote Access"
    case .about: "About"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .appearance: "paintbrush"
    case .agent: "terminal"
    case .remoteAccess: "network"
    case .about: "info.circle"
    }
  }
}

struct SettingsView: View {
  var daemon: DaemonController
  var sessions: TerminalSessionsModel
  var sleepPrevention: SleepPreventionController
  let ghostty: GhosttyRuntime
  @Binding var selection: SettingsSection
  @Binding var appearanceTheme: AppearanceTheme
  @Bindable var pairingLink: PairingLinkRouter

  private var sidebarSelection: Binding<SettingsSection?> {
    Binding(
      get: { selection },
      set: { if let section = $0 { selection = section } }
    )
  }

  var body: some View {
    HStack(spacing: 0) {
      List(SettingsSection.allCases, selection: sidebarSelection) { section in
        Label(section.title, systemImage: section.systemImage)
          .tag(section)
      }
      .listStyle(.sidebar)
      .frame(width: 180)

      Divider()

      Group {
        switch selection {
        case .general:
          GeneralSettingsView(
            daemon: daemon,
            ghostty: ghostty,
            sleepPrevention: sleepPrevention
          )
        case .appearance:
          AppearanceSettingsView(theme: $appearanceTheme)
        case .agent:
          AgentSettingsView(daemon: daemon, sessions: sessions)
        case .remoteAccess:
          RemoteAccessSettingsView(daemon: daemon, pairingCode: $pairingLink.pendingCode)
        case .about:
          AboutSettingsView(daemon: daemon)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(20)
    }
    .frame(minWidth: 700, minHeight: 440)
  }
}

private struct AppearanceSettingsView: View {
  @Binding var theme: AppearanceTheme

  var body: some View {
    Form {
      Picker("Theme", selection: $theme) {
        ForEach(AppearanceTheme.allCases) { theme in
          Text(theme.title).tag(theme)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("appearance-theme-picker")
    }
    .formStyle(.grouped)
  }
}

private struct AgentSettingsView: View {
  var daemon: DaemonController
  var sessions: TerminalSessionsModel
  @State private var command = "pi"
  @State private var savedCommand = "pi"
  @State private var errorMessage: String?
  @State private var isLoading = false
  @State private var isSaving = false
  @State private var isLoaded = false

  private var canSave: Bool {
    isLoaded && !isLoading && !isSaving && command != savedCommand
  }

  var body: some View {
    Form {
      Section("Recovery") {
        Toggle(
          "Automatically restart unavailable Pi sessions",
          isOn: Binding(
            get: { sessions.automaticallyRestartUnavailablePi },
            set: { sessions.setAutomaticPiRestartEnabled($0) }
          )
        )
        .accessibilityIdentifier("auto-restart-unavailable-pi-toggle")

        Text(
          "Axo retries recovery only when Pi reports it is idle or its transcript is unowned. It never force-stops a Pi automatically; if the state is uncertain, Restart Pi remains available."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      Section("Default Agent") {
        TextField("Command", text: $command, prompt: Text("pi"))
          .disabled(!isLoaded || isLoading || isSaving)
          .accessibilityIdentifier("default-agent-command")

        Text(
          "Enter the full command line. Use an absolute executable path or a command on axod's PATH. Arguments support shell-style quoting; Axod launches it directly without a shell and appends its managed Pi session and extension arguments. Changes apply to new Agent sessions."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        HStack {
          if isLoading || isSaving {
            ProgressView()
              .controlSize(.small)
          }
          Spacer()
          Button("Save") {
            Task { await saveCommand() }
          }
          .disabled(!canSave)
          .accessibilityIdentifier("save-default-agent-command")
        }

        if !isLoaded && !isLoading && errorMessage == nil {
          Text("Start axod to view or change the configured command.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("default-agent-command-error")
        }
      }
    }
    .formStyle(.grouped)
    .task(id: daemon.status) {
      guard case .running = daemon.status else { return }
      await loadCommand()
    }
  }

  @MainActor
  private func loadCommand() async {
    isLoading = true
    defer { isLoading = false }
    do {
      let socketPath = try DaemonController.socketPath()
      let settings = try await UnixSocketRPC.configValue(for: .agentCommand, at: socketPath)
      command = settings.value
      savedCommand = settings.value
      isLoaded = true
      errorMessage = nil
    } catch {
      isLoaded = false
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func saveCommand() async {
    isSaving = true
    defer { isSaving = false }
    do {
      let socketPath = try DaemonController.socketPath()
      let settings = try await UnixSocketRPC.setConfigValue(
        command,
        for: .agentCommand,
        at: socketPath
      )
      command = settings.value
      savedCommand = settings.value
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private struct ShellCommandSettingsSection: View {
  var daemon: DaemonController
  @State private var command = ""
  @State private var savedCommand = ""
  @State private var errorMessage: String?
  @State private var isLoading = false
  @State private var isSaving = false
  @State private var isLoaded = false

  private var canSave: Bool {
    isLoaded && !isLoading && !isSaving && command != savedCommand
  }

  var body: some View {
    Section("Shell") {
      TextField("Command", text: $command, prompt: Text("Your login shell"))
        .disabled(!isLoaded || isLoading || isSaving)
        .accessibilityIdentifier("default-shell-command")

      Text(
        "Axod runs this command in its own terminal session, not in Terminal.app. The default follows your login shell. Use an absolute executable path or a command on axod's PATH; arguments support shell-style quoting. Changes apply to new or restarted shell processes."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      HStack {
        if isLoading || isSaving {
          ProgressView()
            .controlSize(.small)
        }
        Spacer()
        Button("Save") {
          Task { await saveCommand() }
        }
        .disabled(!canSave)
        .accessibilityIdentifier("save-default-shell-command")
      }

      if !isLoaded && !isLoading && errorMessage == nil {
        Text("Start axod to view or change the configured shell.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("default-shell-command-error")
      }
    }
    .task(id: daemon.status) {
      guard case .running = daemon.status else { return }
      await loadCommand()
    }
  }

  @MainActor
  private func loadCommand() async {
    isLoading = true
    defer { isLoading = false }
    do {
      let socketPath = try DaemonController.socketPath()
      let settings = try await UnixSocketRPC.configValue(for: .shellCommand, at: socketPath)
      command = settings.value
      savedCommand = settings.value
      isLoaded = true
      errorMessage = nil
    } catch {
      isLoaded = false
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func saveCommand() async {
    isSaving = true
    defer { isSaving = false }
    do {
      let socketPath = try DaemonController.socketPath()
      let settings = try await UnixSocketRPC.setConfigValue(
        command,
        for: .shellCommand,
        at: socketPath
      )
      command = settings.value
      savedCommand = settings.value
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private struct GeneralSettingsView: View {
  var daemon: DaemonController
  var ghostty: GhosttyRuntime
  var sleepPrevention: SleepPreventionController

  private var scrollSensitivityPosition: Binding<Double> {
    Binding(
      get: { TerminalScrollSensitivity.sliderPosition(for: ghostty.scrollSensitivity) },
      set: {
        ghostty.setScrollSensitivity(
          TerminalScrollSensitivity.multiplier(atSliderPosition: $0)
        )
      }
    )
  }

  private var displayedScrollSensitivity: String {
    let value = TerminalScrollSensitivity.boundedMultiplier(ghostty.scrollSensitivity)
    return "\(value.formatted(.number.precision(.fractionLength(1))))×"
  }

  var body: some View {
    Form {
      Section("Terminal") {
        VStack(alignment: .leading, spacing: 8) {
          Slider(value: scrollSensitivityPosition, in: 0...1) {
            Text("Scroll sensitivity")
          }
          .accessibilityValue(Text(displayedScrollSensitivity))

          HStack {
            Text("0.1×")
            Spacer()
            Text("1.0×")
            Spacer()
            Text("3.0×")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      Section("Power") {
        Toggle(
          "Prevent sleep while Axo is running",
          isOn: Binding(
            get: { sleepPrevention.isEnabled },
            set: { sleepPrevention.setEnabled($0) }
          )
        )
        Text("Prevents idle system sleep. Manual sleep and closing the lid are unaffected.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      ShellCommandSettingsSection(daemon: daemon)

      Section("axod") {
        LabeledContent("Daemon status", value: daemon.status.settingsTitle)

        switch daemon.status {
        case .disabled:
          Button("Enable axod") {
            daemon.enableDaemon()
          }
        case .requiresApproval:
          Button("Open Login Items Settings") {
            daemon.openLoginItemsSettings()
          }
          Button("Check Status") {
            daemon.startIfNeeded()
          }
        case .failed:
          Button("Retry daemon") {
            daemon.startIfNeeded()
          }
          Button("Enable axod") {
            daemon.enableDaemon()
          }
        case .starting, .running, .updating:
          EmptyView()
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct AboutSettingsView: View {
  var daemon: DaemonController

  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
  }

  private var appCommit: String {
    Bundle.main.infoDictionary?["AXOGitCommit"] as? String ?? "Unknown"
  }

  private var daemonVersion: String {
    guard case .running(let version, _) = daemon.status else { return "Not available" }
    return version
  }

  private var daemonBuild: String {
    guard case .running(_, let buildNumber) = daemon.status else { return "Not available" }
    return buildNumber.description
  }

  private var daemonStatus: String {
    switch daemon.status {
    case .starting: "Starting…"
    case .running: "Running"
    case .updating: "Restarting…"
    case .requiresApproval: "Approval required"
    case .disabled: "Not enabled"
    case .failed(let message): "Unavailable — \(message)"
    }
  }

  var body: some View {
    VStack(spacing: 14) {
      Spacer(minLength: 0)

      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()
        .scaledToFit()
        .frame(width: 96, height: 96)
        .accessibilityHidden(true)

      VStack(spacing: 6) {
        Text("Axo")
          .font(.system(size: 30, weight: .bold))
        Text("Agentic harness for terminal romantics")
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      VStack(spacing: 6) {
        aboutRow("Version", appVersion)
        aboutRow("Build", DaemonController.appBuildNumberLabel)
        aboutRow("Commit", appCommit)
        Divider()
          .frame(width: 240)
          .padding(.vertical, 3)
        aboutRow("axod version", daemonVersion)
        aboutRow("axod build", daemonBuild)
        aboutRow("Daemon status", daemonStatus)
      }
      .padding(.vertical, 4)

      HStack(spacing: 12) {
        Link("Docs", destination: URL(string: "https://github.com/leostera/axo#readme")!)
        Link("GitHub", destination: URL(string: "https://github.com/leostera/axo")!)
      }
      .buttonStyle(.bordered)

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func aboutRow(_ title: String, _ value: String) -> some View {
    HStack(spacing: 10) {
      Text(title)
        .foregroundStyle(.secondary)
        .frame(width: 120, alignment: .trailing)
      Text(value)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(minWidth: 130, alignment: .leading)
    }
    .font(.callout)
  }
}
