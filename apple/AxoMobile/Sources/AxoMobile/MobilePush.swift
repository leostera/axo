import AxoClient
import AxoMobileModel
import Foundation
import Observation
import UIKit
import UserNotifications

/// Canonical development installs only. The provider key and all destinations stay server-side.
@MainActor
@Observable
final class MobilePush: NSObject, UNUserNotificationCenterDelegate {
  static let shared = MobilePush()
  private(set) var inboxRevision = UUID()
  private var inboxRoute: RequestNotificationRoute?
  private var deviceToken: Data?
  private var account: AccountSession?
  private var endpoint: RelayEndpoint = .production
  private var lastSession: SessionToken?
  private var lastSubmitted: Data?
  private var submittedSession: SessionToken?
  private var registering = false
  private var refreshAgain = false
  private var requestedDeviceToken = false
  private var testReceived = false
  private let launchedAt = Date()
  private let defaults = UserDefaults.standard

  private var enabled: Bool {
    #if targetEnvironment(simulator)
      return false
    #else
      return Bundle.main.bundleIdentifier == "dev.leostera.axo"
        && Bundle.main.object(forInfoDictionaryKey: "AXOPushEnvironment") as? String == "sandbox"
        && !EnclaveProbeRuntime.requestsDestinationGate(role: .mobile)
    #endif
  }

  func attach(account: AccountSession, endpoint: RelayEndpoint) {
    guard enabled else { return }
    self.account = account
    self.endpoint = endpoint
    UNUserNotificationCenter.current().delegate = self
  }

  func receive(deviceToken: Data) {
    guard enabled, !deviceToken.isEmpty, deviceToken.count <= 1024 else { return }
    self.deviceToken = deviceToken
    Task { await refresh() }
  }

  func becameActive() async {
    requestedDeviceToken = false
    await refresh()
  }

  func registrationFailed() {
    requestedDeviceToken = false
    reportTest(.registrationUnavailable)
  }

  func refresh() async {
    guard enabled, let account else { return }
    if registering { refreshAgain = true; return }
    registering = true
    defer {
      registering = false
      if refreshAgain {
        refreshAgain = false
        Task { await refresh() }
      }
    }
    let session: SessionToken?
    do { session = try await account.tokens.sessionToken() }
    catch {
      // Locked/unavailable storage is not sign-out and cannot revoke a usable registration.
      guard account.hasEndedSession else { reportTest(.registrationUnavailable); return }
      session = nil
    }
    guard !Task.isCancelled else { return }
    await reportDeliveredTest()
    let center = UNUserNotificationCenter.current()
    if session == nil {
      UIApplication.shared.unregisterForRemoteNotifications()
      requestedDeviceToken = false
      deviceToken = nil
      // Best effort when offline; server session revocation is independently checked at dispatch.
      if let lastSession { await submit(token: nil, session: lastSession) }
      self.lastSession = nil
      submittedSession = nil
      lastSubmitted = nil
      inboxRoute = nil
      center.removeAllDeliveredNotifications()
      return
    }
    guard let session else { return }
    lastSession = session
    let settings = await center.notificationSettings()
    if settings.authorizationStatus == .notDetermined {
      reportTest(.awaitingPermission)
      _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }
    let current = await center.notificationSettings()
    guard !Task.isCancelled, (try? await account.tokens.sessionToken()) == session else { return }
    let allowed = current.authorizationStatus == .authorized || current.authorizationStatus == .provisional
    guard allowed else {
      reportTest(.permissionDenied)
      await submit(token: nil, session: session)
      return
    }
    reportTest(.awaitingDeviceToken)
    // A didRegister callback refreshes enrollment, but must never recursively register again.
    if !requestedDeviceToken {
      requestedDeviceToken = true
      UIApplication.shared.registerForRemoteNotifications()
    }
    guard let deviceToken else { return }
    if lastSubmitted == deviceToken && submittedSession == session {
      reportTest(.enrolled)
      return
    }
    await submit(token: deviceToken, session: session)
  }

  private func submit(token: Data?, session: SessionToken) async {
    let installationKey = "push.installation.v1"
    let installation: UUID
    if let stored = defaults.string(forKey: installationKey), let parsed = UUID(uuidString: stored) {
      installation = parsed
    } else {
      installation = UUID()
      defaults.set(installation.uuidString, forKey: installationKey)
    }
    // Advancing from the clock also survives an old defaults backup without replaying its revision.
    let previous = defaults.object(forKey: "push.revision.v1") as? NSNumber
    guard let revision = RequestNotificationRevision.next(after: previous?.int64Value) else { return }
    defaults.set(revision, forKey: "push.revision.v1")
    do {
      try await AccountClient(endpoint: endpoint, tokens: StaticSessionToken(session))
        .setRequestNotifications(installationID: installation, revision: revision, deviceToken: token)
      lastSubmitted = token
      submittedSession = session
      if token != nil { reportTest(.enrolled) }
    } catch {
      reportTest(.registrationUnavailable)
      if (try? await account?.tokens.sessionToken()) == session { account?.noteFailure(error) }
      // Never log URLSession errors, destination tokens or request bodies. A foreground refresh retries.
    }
  }

  func takeInboxRoute() -> RequestNotificationRoute? {
    defer { inboxRoute = nil }
    return inboxRoute
  }

  /// Only call with an authoritative connected inbox, never a disconnected/cache-only snapshot.
  func reconcile(pending: Set<UUID>) async {
    guard enabled, let account else { return }
    guard let session = try? await account.tokens.sessionToken() else { return }
    let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
    guard (try? await account.tokens.sessionToken()) == session else { return }
    let obsolete = delivered.filter { notification in
      guard let route = RequestNotificationRoute(userInfo: notification.request.content.userInfo) else { return false }
      return route.accountID != session.accountID || !pending.contains(route.requestID)
    }.map { $0.request.identifier }
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: obsolete)
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
    willPresent notification: UNNotification) async -> UNNotificationPresentationOptions
  {
    guard let route = RequestNotificationRoute(userInfo: notification.request.content.userInfo) else { return [] }
    guard await shouldPresent(route) else { return [] }
    await reportReceivedTest(route)
    return [.banner, .sound]
  }

  private func shouldPresent(_ route: RequestNotificationRoute) async -> Bool {
    guard let account, let token = try? await account.tokens.sessionToken() else { return false }
    return token.accountID == route.accountID
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse) async
  {
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let route = RequestNotificationRoute(userInfo: response.notification.request.content.userInfo)
    else { return }
    await openInbox(route)
  }

  enum TestStatus: String, Encodable {
    case awaitingPermission, permissionDenied, awaitingDeviceToken, enrolled, registrationUnavailable
    case receivedForeground, receivedInNotificationCenter
  }

  /// A deliberately fixed, opt-in development report. Never copies the OS notification or token.
  private func reportTest(_ status: TestStatus) {
    guard let text = ProcessInfo.processInfo.environment["AXO_PUSH_TEST_RUN_ID"], let runID = UUID(uuidString: text) else { return }
    let received = status == .receivedForeground || status == .receivedInNotificationCenter
    guard !testReceived || received else { return }
    if received { testReceived = true }
    struct Report: Encodable { let schema = 1; let runID: UUID; let status: TestStatus }
    guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
      let data = try? JSONEncoder().encode(Report(runID: runID, status: status)) else { return }
    try? data.write(to: documents.appendingPathComponent("axo-push-test.json"), options: .atomic)
  }

  private var testRequestID: UUID? {
    ProcessInfo.processInfo.environment["AXO_PUSH_TEST_REQUEST_ID"].flatMap(UUID.init(uuidString:))
  }

  private func reportReceivedTest(_ route: RequestNotificationRoute) {
    if testRequestID == nil || route.requestID == testRequestID { reportTest(.receivedForeground) }
  }

  private func reportDeliveredTest() async {
    guard let account, let session = try? await account.tokens.sessionToken() else { return }
    let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
    if delivered.contains(where: {
      guard let route = RequestNotificationRoute(userInfo: $0.request.content.userInfo) else { return false }
      return route.accountID == session.accountID && $0.date >= launchedAt
        && (testRequestID == nil || route.requestID == testRequestID)
    }) { reportTest(.receivedInNotificationCenter) }
  }

  private func openInbox(_ route: RequestNotificationRoute) async {
    guard await shouldPresent(route) else { return }
    inboxRoute = route
    inboxRevision = UUID()
  }
}
