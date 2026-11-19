import AxoMobileModel
import AxoProtocol
import SwiftUI

struct HostIcon: View {
  let host: RemoteHost
  var body: some View {
    Group {
      if let name = HostPresentation.logoName(host) {
        Image(name).resizable().scaledToFit()
          .accessibilityIdentifier("host-logo-\(host.hostKind)")
      } else {
        Image(systemName: HostPresentation.symbol(host)).resizable().scaledToFit()
          .accessibilityIdentifier("host-symbol-\(HostPresentation.symbol(host))")
      }
    }
    .accessibilityLabel(host.model?.name ?? (host.hostKind == "linux" ? "Linux" : host.hostKind == "windows" ? "Windows" : host.hostKind == "cloud" ? "Cloud host" : "Host"))
  }
}
