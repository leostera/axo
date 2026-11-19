import AxoMobileModel
import AxoProtocol
import SwiftUI

/// A live Session never moves: its menu explicitly starts a new chat on the chosen host.
struct HostPicker: View {
  let phone: PhoneWorkbench
  var voice: VoicePrompt?
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    if let host = openHost {
      Menu {
        if !phone.isDrafting { Text("Start a new chat on another host") }
        ForEach(phone.hosts.hosts, id: \.hostId) { candidate in
          Button {
            if phone.isDrafting {
              phone.chooseHost(candidate.hostId, voice: voice)
            } else {
              voice?.destinationOptionsChanged()
              phone.select(host: candidate.hostId, session: nil)
            }
          } label: {
            Text("\(phone.isDrafting ? "" : "New chat on ")\(candidate.label)\(candidate.status == .online ? "" : ", offline")")
          }
          .disabled(candidate.status != .online || phone.isSending)
        }
      } label: {
        HStack(spacing: 4) {
          HostIcon(host: host).frame(width: 14, height: 14)
          if sizeClass == .regular {
            Text(host.label).lineLimit(1).frame(maxWidth: 100)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
          }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 8).frame(height: ComposerMetrics.control)
        .background(Color.primary.opacity(0.05), in: Capsule())
      }
      .accessibilityLabel("Host: \(host.label)")
      .accessibilityHint(phone.isDrafting ? "Chooses where to start this chat" : "Starts a new chat; this Session and its draft stay here")
      .accessibilityIdentifier("host-picker")
    }
  }

  private var openHost: RemoteHost? {
    guard let id = phone.selection?.host else { return nil }
    return phone.hosts.hosts.first { $0.hostId == id }
  }
}

extension RemoteHost {
  var symbol: String { HostPresentation.symbol(self) }
}
