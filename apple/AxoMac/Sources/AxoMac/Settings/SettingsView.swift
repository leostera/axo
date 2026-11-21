import AppKit
import AxoDaemonManager
import AxoProtocol
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
  case permissions
  case sessions
  case agent
  case remoteAccess
  case about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .appearance: "Appearance"
    case .permissions: "Setup & Permissions"
    case .sessions: "Sessions"
    case .agent: "Agent"
    case .remoteAccess: "Remote Access"
    case .about: "About"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .appearance: "paintbrush"
    case .permissions: "checkmark.shield"
    case .sessions: "sidebar.left"
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
  let settingsClient: AxodSettingsClient?
  var remoteAccess: RemoteAccessModel
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
            settingsClient: settingsClient,
            ghostty: ghostty,
            sleepPrevention: sleepPrevention
          )
        case .appearance:
          AppearanceSettingsView(theme: $appearanceTheme)
        case .permissions:
          VStack(alignment: .leading, spacing: 16) {
            HStack {
              Text("Setup & Permissions").font(.title2.bold())
              Spacer()
              Button("Run Setup Again…") { AppSetupModel.shared.show(tour: true) }
            }
            SetupPermissionsPane(model: AppSetupModel.shared)
          }
          .onChange(of: daemon.status) { _, _ in Task { await AppSetupModel.shared.refresh(force: true) } }
        case .sessions:
          SessionsSettingsView(sessions: sessions, daemon: daemon, settingsClient: settingsClient)
        case .agent:
          AgentSettingsView(daemon: daemon, sessions: sessions, settingsClient: settingsClient)
        case .remoteAccess:
          RemoteAccessSettingsView(
            daemon: daemon, remoteAccess: remoteAccess, pairingCode: $pairingLink.pendingCode)
        case .about:
          AboutSettingsView(daemon: daemon)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(20)
    }
    .frame(minWidth: 860, minHeight: 560)
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
  let settingsClient: AxodSettingsClient?

  var body: some View {
    Form {
      SystemPromptSection()

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
        Picker("Agent for new local sessions", selection: Binding(
          get: { sessions.defaultCodingAgent }, set: { sessions.selectDefaultAgent($0) }
        )) {
          if !sessions.availableCodingAgents.contains(sessions.defaultCodingAgent) {
            Text("\(sessions.defaultCodingAgent.displayName) — not detected").tag(sessions.defaultCodingAgent)
          }
          ForEach(sessions.availableCodingAgents) { agent in Text(agent.displayName).tag(agent) }
        }
        .disabled(!daemon.status.isRunning || sessions.availableCodingAgents.isEmpty)
        Button("Refresh Agents") { Task { await sessions.refreshAvailableCodingAgents() } }
          .disabled(!daemon.status.isRunning)
        Text("Axo checks installed agents on this Mac. Choosing one does not start a session.")
          .font(.caption).foregroundStyle(.secondary)
      }
      .task(id: daemon.status) { await sessions.refreshAvailableCodingAgents() }
    }
    .formStyle(.grouped)
  }
}
