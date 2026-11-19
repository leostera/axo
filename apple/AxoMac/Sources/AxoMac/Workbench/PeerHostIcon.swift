import AxoProtocol
import SwiftUI

struct PeerHostIcon: View {
  let host: PeerHost
  var body: some View {
    Group {
      if host.hostKind == "linux" { Image("host-linux") }
      else if host.hostKind == "windows" { Image("host-windows") }
      else if host.hostKind == "cloud" { Image("host-cloud") }
      else { Image(systemName: symbol) }
    }
    .accessibilityLabel(host.model?.name ?? host.hostKind ?? "Host")
  }
  private var symbol: String {
    guard host.hostKind == "macos" else { return "server.rack" }
    switch host.model?.family {
    case .laptop: return "laptopcomputer"
    case .studio: return "macstudio"
    case .mini: return "macmini"
    case .tower: return "macpro.gen3"
    case .desktop, nil: return "desktopcomputer"
    }
  }
}
