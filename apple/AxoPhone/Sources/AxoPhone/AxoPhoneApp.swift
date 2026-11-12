import AxoClient
import AxoCompanion
import AxoPhoneModel
import SwiftUI
import UIKit

/// The app's one set of long-lived objects.
@MainActor
final class AppEnvironment: ObservableObject {
  static let shared = AppEnvironment()
  let endpoint: RelayEndpoint
  let account: AccountSession
  let companion: PhoneCompanionSignIn

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
    let account = self.account
    companion = PhoneCompanionSignIn(authentication: {
      guard !account.hasEndedSession else { return .signedOut }
      let token: SessionToken?
      do { token = try KeychainTokenStore().loadForCompanion() }
      catch let error as KeychainError { throw CompanionError.storage(error.status) }
      guard let token else { return .signedOut }
      return .signedIn(try CompanionSession(token: token.value))
    }, transcribeAudio: { url in
      guard #available(iOS 26, *) else { throw CompanionVoiceFailure.unsupported }
      return try await CompanionAudioTranscriber().transcribe(url)
    })
  }
}

/// Activate WatchConnectivity at application launch, including background file delivery before
/// SwiftUI has created a window. Views and the delegate share the same companion service.
@MainActor
public final class AxoPhoneLifecycle: NSObject, UIApplicationDelegate {
  public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    _ = AppEnvironment.shared
    return true
  }
}

public struct AxoPhoneRoot: View {
  @StateObject private var environment = AppEnvironment.shared
  @State private var sidewaysScrolling = SidewaysScrolling()
  @Environment(\.scenePhase) private var scenePhase

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
    .task(id: environment.account.credentialRevision) { await environment.companion.refresh() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        environment.account.restoreStoredSession()
        Task { await environment.companion.refresh() }
      }
    }
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
