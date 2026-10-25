import AxoDaemonManager
import AxoProtocol
import SwiftUI

/// What one Axod command setting (agent or shell) shows; the editing logic is shared.
struct DaemonCommandSetting {
  let key: AxoConfigKey
  let title: String
  let prompt: String
  let help: String
  let unavailableHint: String
  /// Prefix for the field, save button and error accessibility identifiers.
  let identifier: String

  static let agent = DaemonCommandSetting(
    key: .agentCommand,
    title: "Default Agent",
    prompt: "pi",
    help: "Enter the full command line. Use an absolute executable path or a command on axod's PATH. Arguments support shell-style quoting; Axod launches it directly without a shell and appends its managed Pi session and extension arguments. Changes apply to new Agent sessions.",
    unavailableHint: "Start axod to view or change the configured command.",
    identifier: "default-agent-command")

  static let shell = DaemonCommandSetting(
    key: .shellCommand,
    title: "Shell",
    prompt: "Your login shell",
    help: "Axod runs this command in its own terminal session, not in Terminal.app. The default follows your login shell. Use an absolute executable path or a command on axod's PATH; arguments support shell-style quoting. Changes apply to new or restarted shell processes.",
    unavailableHint: "Start axod to view or change the configured shell.",
    identifier: "default-shell-command")
}

/// Loads a command setting from Axod when it is running and saves edits back.
struct DaemonCommandSettingSection: View {
  let setting: DaemonCommandSetting
  var daemon: DaemonController
  let client: AxodSettingsClient?
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
    Section(setting.title) {
      TextField("Command", text: $command, prompt: Text(setting.prompt))
        .disabled(!isLoaded || isLoading || isSaving)
        .accessibilityIdentifier(setting.identifier)

      Text(setting.help)
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
          Task { await save() }
        }
        .disabled(!canSave)
        .accessibilityIdentifier("save-\(setting.identifier)")
      }

      if !isLoaded && !isLoading && errorMessage == nil {
        Text(setting.unavailableHint)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("\(setting.identifier)-error")
      }
    }
    .task(id: daemon.status) {
      guard daemon.status.isRunning else { return }
      await load()
    }
  }

  private func load() async {
    guard let client else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let value = try await client.configValue(for: setting.key)
      command = value.value
      savedCommand = value.value
      isLoaded = true
      errorMessage = nil
    } catch {
      isLoaded = false
      errorMessage = error.localizedDescription
    }
  }

  private func save() async {
    guard let client else { return }
    isSaving = true
    defer { isSaving = false }
    do {
      let value = try await client.setConfigValue(command, for: setting.key)
      command = value.value
      savedCommand = value.value
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
