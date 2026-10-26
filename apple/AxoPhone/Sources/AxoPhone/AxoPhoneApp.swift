import AxoClient
import AxoPhoneModel
import SwiftUI

/// The app's one set of long-lived objects.
@MainActor
final class AppEnvironment: ObservableObject {
  let endpoint: RelayEndpoint
  let account: AccountSession

  init() {
    // A local Worker for development: AXO_RELAY_URL=http://127.0.0.1:8787
    if let text = ProcessInfo.processInfo.environment["AXO_RELAY_URL"], let url = URL(string: text),
      let local = RelayEndpoint(origin: url, allowInsecureLoopback: true)
    {
      endpoint = local
    } else {
      endpoint = .production
    }
    account = AccountSession(store: KeychainTokenStore())
  }
}

public struct AxoPhoneRoot: View {
  @StateObject private var environment = AppEnvironment()

  public init() {}

  public var body: some View {
    Group {
      switch environment.account.state {
      case .signedOut:
        SignInView(endpoint: environment.endpoint, account: environment.account)
      case .signedIn:
        HostsView(environment: environment)
      }
    }
  }
}
