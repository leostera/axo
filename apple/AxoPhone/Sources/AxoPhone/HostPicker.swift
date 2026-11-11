import AxoPhoneModel
import AxoProtocol
import SwiftUI

/// Which Mac the chat is on, as a chip above the message box; shown only when the account has more
/// than one. On a new chat it is the choice of where to start it: tap, pick a Mac, send. On a chat
/// already going it only says where it is.
struct HostPicker: View {
  let phone: PhoneWorkbench

  var body: some View {
    if phone.hosts.hosts.count > 1, let host = openHost {
      HStack {
        if phone.canChooseHost {
          Menu {
            ForEach(phone.hosts.hosts, id: \.hostId) { candidate in
              Button {
                phone.chooseHost(candidate.hostId)
              } label: {
                Label(
                  "\(candidate.label)\(candidate.status == .online ? "" : ", offline")",
                  systemImage: candidate.hostId == host.hostId ? "checkmark" : candidate.symbol)
              }
              .disabled(candidate.status != .online)
            }
          } label: {
            chip(host, choosing: true)
          }
          .accessibilityLabel("Start on \(host.label)")
          .accessibilityHint("Chooses the Mac to start this chat on")
          .accessibilityIdentifier("host-picker")
        } else {
          chip(host, choosing: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("On \(host.label)")
            .accessibilityIdentifier("host-picker")
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
    }
  }

  private var openHost: RemoteHost? {
    guard let id = phone.selection?.host else { return nil }
    return phone.hosts.hosts.first { $0.hostId == id }
  }

  private func chip(_ host: RemoteHost, choosing: Bool) -> some View {
    HStack(spacing: 6) {
      Image(systemName: host.symbol).font(.system(size: 13, weight: .medium))
      Text(host.label).font(.footnote).lineLimit(1)
      Circle()
        .fill(host.status == .online ? Color.green : Color.secondary.opacity(0.5))
        .frame(width: 6, height: 6)
      if choosing {
        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
      }
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 11)
    .frame(height: 28)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    .contentShape(Capsule())
    // As wide as the Mac's name.
    .fixedSize()
  }
}

extension RemoteHost {
  /// The symbol it is shown by: the shape of Mac it is, or a laptop when it has not said.
  var symbol: String {
    switch model?.family {
    case .laptop, nil: "laptopcomputer"
    case .studio: "macstudio"
    case .mini: "macmini"
    case .desktop: "desktopcomputer"
    case .tower: "macpro.gen3"
    }
  }
}
