import AxoClient
import AxoMobileModel
import AxoProtocol
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
  private var submittedPreviews: Bool?
  private var answersInFlight: Set<UUID> = []
  private(set) var updatesRevision = UUID()
  nonisolated static let previewPreference = "push.richPreviews.v1"
  private nonisolated static let confirmCategory = "AXO_CONFIRM_V1"
  private nonisolated static let reviewCategory = "AXO_REVIEW_V1"
  private nonisolated static let yesAction = "AXO_CONFIRM_YES_V1"
  private nonisolated static let noAction = "AXO_CONFIRM_NO_V1"
  private var registering = false
  private var refreshAgain = false
  private var requestedDeviceToken = false
  private var requestedFullAuthorization = false
  private var testReceived = false
  private var presentation: PresentationSnapshot?
  private let launchedAt = Date()
  private let defaults = UserDefaults.standard
  // Request text is useful by default; explicit opt-out and iOS preview settings still win.
  private var richPreviews: Bool { defaults.object(forKey: Self.previewPreference) as? Bool ?? true }

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
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.setNotificationCategories([
      UNNotificationCategory(identifier: Self.confirmCategory, actions: [
        UNNotificationAction(identifier: Self.yesAction, title: "Yes", options: [.authenticationRequired]),
        UNNotificationAction(identifier: Self.noAction, title: "No", options: [.authenticationRequired]),
      ], intentIdentifiers: [], options: []),
      UNNotificationCategory(identifier: Self.reviewCategory, actions: [], intentIdentifiers: [], options: []),
    ])
  }

  #if DEBUG && targetEnvironment(simulator)
    /// Inject only a navigation intent; the same account/catalog admission still runs in the model.
    func queueNavigationForPreview(_ route: RequestNotificationRoute) {
      inboxRoute = route
      inboxRevision = UUID()
    }
  #endif

  func previewsChanged() { Task { await refresh() } }

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
    if settings.authorizationStatus == .notDetermined
      || (settings.authorizationStatus == .provisional && !requestedFullAuthorization)
    {
      requestedFullAuthorization = true
      reportTest(.awaitingPermission)
      _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }
    let current = await center.notificationSettings()
    presentation = PresentationSnapshot(current)
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
    if lastSubmitted == deviceToken && submittedSession == session
      && submittedPreviews == richPreviews {
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
    let previews = richPreviews
    do {
      try await AccountClient(endpoint: endpoint, tokens: StaticSessionToken(session))
        .setRequestNotifications(installationID: installation, revision: revision, deviceToken: token, richPreviews: previews)
      lastSubmitted = token
      submittedSession = session
      submittedPreviews = previews
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
      if Self.isInformation(notification.request.content.userInfo) { return route.accountID != session.accountID }
      return RequestNotificationCleanup.shouldRemove(receivedAt: notification.date,
        belongsToCurrentAccount: route.accountID == session.accountID, isPending: pending.contains(route.requestID))
    }.map { $0.request.identifier }
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: obsolete)
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void)
  {
    NotificationCallback.perform(operation: {
      guard let route = RequestNotificationRoute(userInfo: notification.request.content.userInfo),
        await self.shouldPresent(route) else { return UNNotificationPresentationOptions() }
      if notification.request.trigger is UNPushNotificationTrigger { self.reportReceivedTest(route) }
      self.refreshUpdates()
      return [.banner, .list, .sound]
    }, completion: { completionHandler($0) })
  }

  private func shouldPresent(_ route: RequestNotificationRoute) async -> Bool {
    guard let account, let token = try? await account.tokens.sessionToken() else { return false }
    return token.accountID == route.accountID
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void)
  {
    NotificationCallback.perform(operation: {
      guard let route = RequestNotificationRoute(userInfo: response.notification.request.content.userInfo) else { return }
      let remote = response.notification.request.trigger is UNPushNotificationTrigger
      if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
        await self.openInbox(route, remoteReceipt: remote)
      } else if remote && response.notification.request.content.categoryIdentifier == Self.confirmCategory,
        let metadata = RequestNotificationAction(userInfo: response.notification.request.content.userInfo),
        let action = Self.answer(for: response.actionIdentifier)
      {
        await self.answer(route, metadata: metadata, displayedMessage: response.notification.request.content.body, action: action)
      }
    }, completion: { _ in completionHandler() })
  }

  enum TestStatus: String, Encodable {
    case awaitingPermission, permissionDenied, awaitingDeviceToken, enrolled, registrationUnavailable
    case receivedForeground, receivedInNotificationCenter, receivedFromTap
    case actionAccepted, actionDeclined, actionNotConfirmed
  }

  /// A deliberately fixed, opt-in development report. Never copies the OS notification or token.
  private func reportTest(_ status: TestStatus) {
    guard let text = ProcessInfo.processInfo.environment["AXO_PUSH_TEST_RUN_ID"], let runID = UUID(uuidString: text) else { return }
    let received = status == .receivedForeground || status == .receivedInNotificationCenter || status == .receivedFromTap
      || status == .actionAccepted || status == .actionDeclined || status == .actionNotConfirmed
    guard !testReceived || received else { return }
    if received { testReceived = true }
    struct Report: Encodable {
      let schema = 2
      let runID: UUID
      let status: TestStatus
      let presentation: PresentationSnapshot?
    }
    guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
      let data = try? JSONEncoder().encode(Report(runID: runID, status: status, presentation: presentation)) else { return }
    try? data.write(to: documents.appendingPathComponent("axo-push-test.json"), options: .atomic)
  }

  private struct PresentationSnapshot: Encodable {
    let authorization: String
    let alertsEnabled: Bool
    let bannerStyleEnabled: Bool
    let lockScreenEnabled: Bool
    let notificationCenterEnabled: Bool
    let soundEnabled: Bool
    let scheduledDeliveryEnabled: Bool

    init(_ settings: UNNotificationSettings) {
      switch settings.authorizationStatus {
      case .notDetermined: authorization = "notDetermined"
      case .denied: authorization = "denied"
      case .authorized: authorization = "authorized"
      case .provisional: authorization = "provisional"
      case .ephemeral: authorization = "ephemeral"
      @unknown default: authorization = "unknown"
      }
      alertsEnabled = settings.alertSetting == .enabled
      bannerStyleEnabled = settings.alertStyle != .none
      lockScreenEnabled = settings.lockScreenSetting == .enabled
      notificationCenterEnabled = settings.notificationCenterSetting == .enabled
      soundEnabled = settings.soundSetting == .enabled
      scheduledDeliveryEnabled = settings.scheduledDeliverySetting == .enabled
    }
  }

  private static func isInformation(_ userInfo: [AnyHashable: Any]) -> Bool {
    let notice = userInfo["axoNotice"] as? [String: Any]
    return notice?["kind"] as? String == "information" && notice?["version"] as? Int == 1
  }

  private nonisolated static func answer(for identifier: String) -> ElicitationAnswer? {
    switch identifier {
    case yesAction: .accept
    case noAction: .decline
    default: nil
    }
  }

  private func refreshUpdates() { updatesRevision = UUID() }

  private func answer(_ route: RequestNotificationRoute, metadata: RequestNotificationAction, displayedMessage: String, action: ElicitationAnswer) async {
    guard richPreviews, let account,
      let session = try? await account.tokens.sessionToken(), session.accountID == route.accountID,
      !answersInFlight.contains(route.requestID) else { return }
    answersInFlight.insert(route.requestID)
    defer { answersInFlight.remove(route.requestID) }
    let credentialRevision = account.credentialRevision
    let client = AccountClient(endpoint: endpoint, tokens: StaticSessionToken(session))
    do {
      let current = try await client.notificationQuestion(hostID: route.hostID, requestID: route.requestID)
      guard (try? await account.tokens.sessionToken()) == session,
        metadata.matches(current.elicitation, route: route, displayedMessage: displayedMessage) else { throw RelayError.httpStatus(409) }
      let signer = try PhoneDeviceKey.existing()
      let proof = try signer.prove(requestID: route.requestID.uuidString.lowercased(), action: action,
        sealed: nil, name: UIDevice.current.model)
      guard !account.hasEndedSession, account.credentialRevision == credentialRevision else { return }
      try await client.answerNotification(hostID: route.hostID, requestID: route.requestID, digest: metadata.digest,
        expiresAt: metadata.expiresAt, action: action, device: proof)
      reportTest(action == .accept ? .actionAccepted : .actionDeclined)
      updatesRevision = UUID()
    } catch {
      reportTest(.actionNotConfirmed)
      // An uncertain answer is never retried. The next explicit action must review live state.
      let content = UNMutableNotificationContent()
      content.title = "Review in Axo"
      content.body = "The answer was not confirmed. Open Axo before trying again."
      content.categoryIdentifier = Self.reviewCategory
      content.userInfo = ["axo": ["version": 1, "accountId": route.accountID.uuidString.lowercased(),
        "hostId": route.hostID.uuidString.lowercased(), "sessionId": route.sessionID.uuidString.lowercased(),
        "requestId": route.requestID.uuidString.lowercased()]]
      try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
        identifier: "axo-answer-review-" + route.requestID.uuidString, content: content, trigger: nil))
    }
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

  private func openInbox(_ route: RequestNotificationRoute, remoteReceipt: Bool) async {
    guard await shouldPresent(route) else { return }
    if remoteReceipt && (testRequestID == nil || route.requestID == testRequestID) { reportTest(.receivedFromTap) }
    updatesRevision = UUID()
    inboxRoute = route
    inboxRevision = UUID()
  }
}
