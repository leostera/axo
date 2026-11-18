import AxoClient
import AxoCompanion
import AxoMobileModel
import AxoMigrationUI
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
    precondition(!EnclaveProbeRuntime.requestsDestinationGate(role: .mobile) && !MobileTransferConfiguration.requiresDestinationGate,
      "A preservation destination cannot create account services")
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
    MobilePush.shared.attach(account: account, endpoint: endpoint)
    companion = PhoneCompanionSignIn(authentication: {
      guard !account.hasEndedSession else { return .signedOut }
      let token: SessionToken?
      do { token = try KeychainTokenStore().loadForCompanion() }
      catch let error as KeychainError { throw CompanionError.storage(error.status) }
      guard let token else { return .signedOut }
      return .signedIn(try CompanionSession(token: token.value))
    }, enabled: !(MobileTransferConfiguration.requested && Bundle.main.bundleIdentifier == "dev.leostera.axo"), transcribeAudio: { url in
      guard #available(iOS 26, *) else { throw CompanionVoiceFailure.unsupported }
      return try await CompanionAudioTranscriber().transcribe(url)
    })
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
      Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
        guard let observer else { return }
        let environment = Unmanaged<AppEnvironment>.fromOpaque(observer).takeUnretainedValue()
        Task { @MainActor in environment.checkTransferredSession() }
      }, MobileTransferKeychain.changeNotification as CFString, nil, .deliverImmediately)
  }

  func checkTransferredSession() {
    guard (try? KeychainTokenStore().migrationSessionRevoked()) == true else { return }
    account.noteTransferredSessionRevoked()
  }
}

/// Activate WatchConnectivity at application launch, including background file delivery before
/// SwiftUI has created a window. Views and the delegate share the same companion service.
@MainActor
public final class AxoMobileLifecycle: NSObject, UIApplicationDelegate {
  public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    if !EnclaveProbeRuntime.requestsDestinationGate(role: .mobile) && !MobileTransferConfiguration.requiresDestinationGate {
      _ = AppEnvironment.shared
    }
    return true
  }

  public func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    MobilePush.shared.receive(deviceToken: deviceToken)
  }

  public func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    MobilePush.shared.registrationFailed()
  }
}

public struct AxoMobileRoot: View {
  @State private var transferCompleted = false
  public init() {}

  public var body: some View {
    if MobileTransferConfiguration.requiresDestinationGate && !transferCompleted {
      MobileTransferView(onCompleted: { transferCompleted = true })
    } else if EnclaveProbeRuntime.requestsDestinationGate(role: .mobile) {
      IdentityPreservationView(role: .mobile)
    } else {
      AxoMobileAccountRoot()
    }
  }
}

private struct AxoMobileAccountRoot: View {
  @StateObject private var environment = AppEnvironment.shared
  @State private var sidewaysScrolling = SidewaysScrolling()
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Group {
      switch environment.account.state {
      case .signedOut:
        SignInView(endpoint: environment.endpoint, account: environment.account)
      case .signedIn:
        WorkbenchView(environment: environment)
      }
    }
    .environment(sidewaysScrolling)
    .task {
      _ = EnclaveProbeRuntime.runIfRequested(role: .mobile)
      MobileTransferRuntime.exportIfRequested(pendingWork: environment.companion.hasPendingVoiceWork)
      MobileTransferRuntime.reportCommittedIfRequested()
    }
    .task(id: environment.account.credentialRevision) {
      await MobilePush.shared.refresh()
      await environment.companion.refresh()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        _ = EnclaveProbeRuntime.runIfRequested(role: .mobile)
        environment.checkTransferredSession()
        MobileTransferRuntime.exportIfRequested(pendingWork: environment.companion.hasPendingVoiceWork)
        MobileTransferRuntime.reportCommittedIfRequested()
        environment.account.restoreStoredSession()
        Task {
          await MobilePush.shared.becameActive()
          await environment.companion.refresh()
        }
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
