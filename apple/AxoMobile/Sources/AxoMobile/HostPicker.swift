import AxoMobileModel
import AxoProtocol
import SwiftUI

/// An existing Session shows its host; only a new chat can choose one.
struct HostPicker: View {
  let phone: PhoneWorkbench
  var voice: VoicePrompt?
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    if let host = openHost {
      if phone.isDrafting {
        Menu {
          ForEach(phone.hosts.hosts, id: \.hostId) { candidate in
            Button {
              phone.chooseHost(candidate.hostId, voice: voice)
            } label: {
              Text("\(candidate.label)\(candidate.status == .online ? "" : ", offline")")
            }
            .disabled(candidate.status != .online || phone.isSending)
          }
        } label: {
          badge(host, selectable: true)
        }
        .accessibilityLabel("Host: \(host.label)")
        .accessibilityHint("Chooses where to start this chat")
        .accessibilityIdentifier("host-picker")
      } else {
        badge(host, selectable: false)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Host: \(host.label)")
          .accessibilityIdentifier("host-badge")
      }
    }
  }

  private func badge(_ host: RemoteHost, selectable: Bool) -> some View {
    HStack(spacing: 4) {
      HostIcon(host: host).frame(width: 14, height: 14)
      if sizeClass == .regular {
        Text(host.label).lineLimit(1).frame(maxWidth: 100)
        if selectable {
          Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
      }
    }
    .font(.caption).foregroundStyle(.secondary)
    .padding(.horizontal, 8)
    .composerPill()
  }

  private var openHost: RemoteHost? {
    guard let id = phone.selection?.host else { return nil }
    return phone.hosts.hosts.first { $0.hostId == id }
  }
}

extension RemoteHost {
  var symbol: String { HostPresentation.symbol(self) }
}
