import AxoRPC
import Combine
import Foundation

@MainActor
final class PairingLinkRouter: ObservableObject {
  static let shared = PairingLinkRouter()

  @Published var pendingCode: HostPairingCode?
  @Published private(set) var routeRevision = 0

  func receive(_ url: URL) -> Bool {
    guard let code = HostPairingCode.fromPairingURL(url) else { return false }
    pendingCode = code
    routeRevision &+= 1
    return true
  }
}
