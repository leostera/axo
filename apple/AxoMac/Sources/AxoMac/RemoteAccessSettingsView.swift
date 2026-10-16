import AxoDaemonManager
import AxoRPC
import SwiftUI

struct RemoteAccessSettingsView: View {
  @ObservedObject var daemon: DaemonController

  @State private var connection: RemoteAccessStatus?
  @State private var statusError: String?
  @State private var isRequestingConnection = false

  private var daemonIsRunning: Bool {
    if case .running = daemon.status { return true }
    return false
  }

  private var notRunningActionTitle: String {
    switch daemon.status {
    case .disabled: "Enable axod"
    case .requiresApproval: "Open Login Items"
    default: "Start & Connect"
    }
  }

  var body: some View {
    Form {
      Section("Connection") {
        RemoteConnectionSummary(
          status: connection,
          daemonIsRunning: daemonIsRunning,
          notRunningActionTitle: notRunningActionTitle,
          requestError: statusError,
          isRequestingConnection: isRequestingConnection,
          connect: connect
        )
      }

      Section("This Mac") {
        LabeledContent("Host name", value: connection?.hostName ?? "Loading…")
        LabeledContent("Platform", value: Self.platformDescription)
      }
    }
    .formStyle(.grouped)
    .task(id: daemon.status) {
      await monitorConnection()
    }
  }

  private static var platformDescription: String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
  }

  private func monitorConnection() async {
    while !Task.isCancelled {
      await refreshConnection()
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        return
      }
    }
  }

  private func refreshConnection() async {
    guard daemonIsRunning else {
      connection = nil
      statusError = "axod is not running."
      return
    }

    do {
      connection = try await UnixSocketRPC.remoteAccessStatus(
        at: DaemonController.socketPath()
      )
      statusError = nil
    } catch {
      connection = nil
      statusError = error.localizedDescription
    }
  }

  private func connect() {
    guard !isRequestingConnection else { return }
    guard daemonIsRunning else {
      switch daemon.status {
      case .disabled: daemon.enableDaemon()
      case .requiresApproval: daemon.openLoginItemsSettings()
      default: daemon.startIfNeeded()
      }
      return
    }

    isRequestingConnection = true
    Task {
      defer { isRequestingConnection = false }
      do {
        try await UnixSocketRPC.requestRemoteAccessConnection(
          at: DaemonController.socketPath()
        )
        statusError = nil
      } catch {
        statusError = error.localizedDescription
      }
      await refreshConnection()
    }
  }
}

private struct RemoteConnectionSummary: View {
  let status: RemoteAccessStatus?
  let daemonIsRunning: Bool
  let notRunningActionTitle: String
  let requestError: String?
  let isRequestingConnection: Bool
  let connect: () -> Void

  private var isConnected: Bool { status?.isConnected == true }
  private var isConnecting: Bool { status?.state == .connecting }

  private var title: String {
    guard daemonIsRunning else { return "axod is not running" }
    return switch status?.state {
    case .connected: "Connected"
    case .connecting: "Connecting…"
    default: "Disconnected"
    }
  }

  private var symbol: String {
    switch status?.state {
    case .connected: "checkmark.circle.fill"
    case .connecting: "arrow.triangle.2.circlepath"
    default: "xmark.circle.fill"
    }
  }

  private var color: Color {
    switch status?.state {
    case .connected: .green
    case .connecting: .orange
    default: .secondary
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Label(title, systemImage: symbol)
          .font(.headline)
          .foregroundStyle(color)

        if let connectedSince = status?.connectedSinceUnixMillis, isConnected {
          TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text("Connected for \(Self.duration(since: connectedSince, now: timeline.date))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } else if let message = status?.lastError ?? requestError {
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        } else if isConnecting {
          Text("axod is trying to reach the Axo API.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: 12)

      if !isConnected {
        Button(
          daemonIsRunning ? (isConnecting ? "Retry" : "Connect") : notRunningActionTitle,
          action: connect
        )
        .disabled(isRequestingConnection)
        .accessibilityHint("Ask axod to connect to the Axo API")
      }
    }
    .padding(.vertical, 4)
  }

  private static func duration(since unixMillis: UInt64, now: Date) -> String {
    let connectedAt = Date(timeIntervalSince1970: Double(unixMillis) / 1_000)
    let elapsed = max(0, Int(now.timeIntervalSince(connectedAt)))
    let hours = elapsed / 3_600
    let minutes = (elapsed % 3_600) / 60
    let seconds = elapsed % 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m \(seconds)s" }
    return "\(seconds)s"
  }
}
