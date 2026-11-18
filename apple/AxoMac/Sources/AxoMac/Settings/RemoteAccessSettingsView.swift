import AxoDaemonManager
import AxoProtocol
import SwiftUI

/// What linking with a code does to this Mac. A code links the Mac to the account that made it,
/// which can then run commands here and read its conversations, and a code can arrive by any
/// `axo://pair` link. So replacing a link the Mac already has, or may have (an older axod does
/// not say), is never one click: the person confirms it.
enum RemoteAccessLinkAction: Equatable {
  case link
  case replace

  init(status: RemoteAccessStatus?) {
    self = status?.linked == false ? .link : .replace
  }
}

struct RemoteAccessSettingsView: View {
  var daemon: DaemonController
  var remoteAccess: RemoteAccessModel
  @Binding var pairingCode: HostPairingCode?

  @State private var pairingCodeText = ""
  @State private var pairingError: String?
  @State private var pairingSuccess: String?
  @State private var isLinking = false
  @State private var confirmingReplacement = false
  @State private var connectError: String?
  @State private var isRequestingConnection = false

  private var connection: RemoteAccessStatus? { remoteAccess.status }

  private var daemonIsRunning: Bool {
    if case .running = daemon.status { return true }
    return false
  }

  private var parsedPairingCode: HostPairingCode? {
    HostPairingCode(parsing: pairingCodeText)
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
      Section("Link this Mac") {
        Text("Enter the one-time code from your Axo account to connect this Mac.")
          .foregroundStyle(.secondary)
        Text(
          "The account that made the code can run commands on this Mac and read its conversations. Only use a code you made yourself."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        TextField("XXXX-YYYY", text: $pairingCodeText)
          .font(.system(.title3, design: .monospaced))
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Host pairing code")

        if let pairingError {
          Text(pairingError)
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
        if let pairingSuccess {
          Label(pairingSuccess, systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
        }

        Button {
          switch RemoteAccessLinkAction(status: connection) {
          case .link: linkHost()
          case .replace: confirmingReplacement = true
          }
        } label: {
          if isLinking {
            ProgressView("Linking this Mac…")
          } else {
            Text("Link this Mac")
          }
        }
        .disabled(parsedPairingCode == nil || !daemonIsRunning || isLinking)
        .confirmationDialog(
          "Replace this Mac's link?", isPresented: $confirmingReplacement
        ) {
          Button("Replace Link", role: .destructive) { linkHost() }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text(
            "This Mac is already linked to an Axo account. This code moves it to the account that made the code, which can then run commands here and read its conversations."
          )
        }
      }

      Section("Connection") {
        RemoteConnectionSummary(
          status: connection,
          daemonIsRunning: daemonIsRunning,
          notRunningActionTitle: notRunningActionTitle,
          requestError: connectError ?? remoteAccess.statusError,
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
    .onAppear {
      applyPairingCode(pairingCode)
    }
    .onChange(of: pairingCode) { _, code in
      applyPairingCode(code)
    }
    .task {
      // Axod pushes later changes; this only covers opening Settings.
      await remoteAccess.refresh()
    }
  }

  private static var platformDescription: String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
  }

  private func applyPairingCode(_ code: HostPairingCode?) {
    guard let code else { return }
    pairingCodeText = code.value
    pairingCode = nil
    pairingError = nil
    pairingSuccess = nil
  }

  private func linkHost() {
    guard let code = parsedPairingCode, !isLinking else { return }
    isLinking = true
    pairingError = nil
    pairingSuccess = nil

    Task {
      defer { isLinking = false }
      do {
        let result = try await remoteAccess.link(using: code)
        pairingCodeText = ""
        pairingSuccess = "\(result.hostLabel) is linked. axod will connect automatically."
      } catch {
        pairingError = error.localizedDescription
      }
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
        try await remoteAccess.connect()
        connectError = nil
      } catch {
        connectError = error.localizedDescription
      }
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
