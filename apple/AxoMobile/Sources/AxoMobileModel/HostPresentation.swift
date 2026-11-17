import AxoProtocol

/// Legacy host records can say "macos" even for non-Macs. Require reported Apple hardware,
/// not the person's editable host label, before calling the machine a Mac.
public enum HostPresentation {
  public static func isKnownMac(_ host: RemoteHost) -> Bool {
    guard host.hostKind == "macos", let identifier = host.model?.identifier else { return false }
    return identifier.hasPrefix("Mac") || identifier.hasPrefix("iMac")
  }

  public static func collectionName(_ hosts: [RemoteHost]) -> String {
    !hosts.isEmpty && hosts.allSatisfy(isKnownMac) ? "Macs" : "Hosts"
  }

  public static func symbol(_ host: RemoteHost) -> String {
    guard isKnownMac(host) else {
      return host.hostKind == "windows" ? "desktopcomputer" : "server.rack"
    }
    switch host.model?.family {
    case .laptop: return "laptopcomputer"
    case .studio: return "macstudio"
    case .mini: return "macmini"
    case .tower: return "macpro.gen3"
    case .desktop, nil: return "desktopcomputer"
    }
  }
}
