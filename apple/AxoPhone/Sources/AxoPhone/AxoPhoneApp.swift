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
    #if DEBUG && targetEnvironment(simulator)
      account = PreviewFixture.requested
        ? AccountSession(store: PreviewTokenStore())
        : AccountSession(store: KeychainTokenStore())
    #else
      account = AccountSession(store: KeychainTokenStore())
    #endif
  }
}

public struct AxoPhoneRoot: View {
  @StateObject private var environment = AppEnvironment()
  @State private var sidewaysScrolling = SidewaysScrolling()

  public init() {}

  public var body: some View {
    Group {
      switch environment.account.state {
      case .signedOut:
        SignInView(endpoint: environment.endpoint, account: environment.account)
      case .signedIn:
        WorkbenchView(environment: environment)
      }
    }
    .environment(sidewaysScrolling)
  }
}

#if DEBUG && targetEnvironment(simulator)
  /// A signed-in phone with a made-up token, for the preview.
  private struct PreviewTokenStore: SessionTokenStoring {
    func load() -> SessionToken? {
      SessionToken("axo1.6b0f0e0e-2c43-4b8e-9d0a-0d8f7b2b9c11.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
    }
    func save(_ token: SessionToken) throws {}
    func delete() {}
  }
#endif
