import AxoProtocol
import Foundation
import Observation

@MainActor
@Observable
final class PairingLinkRouter {
  static let shared = PairingLinkRouter()

  var pendingCode: HostPairingCode?
  private(set) var routeRevision = 0

  func receive(_ url: URL) -> Bool {
    guard let code = HostPairingCode.fromPairingURL(url) else { return false }
    pendingCode = code
    routeRevision &+= 1
    return true
  }
}
