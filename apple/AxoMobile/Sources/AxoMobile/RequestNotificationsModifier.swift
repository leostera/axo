import AxoMobileModel
import SwiftUI

struct RequestNotificationsModifier: ViewModifier {
  let phone: PhoneWorkbench
  let openConversation: (RequestNotificationRoute) async -> Void

  private var connectedRequests: Set<String>? {
    phone.link == .connected ? Set(phone.questions.map { $0.elicitation.id }) : nil
  }

  private struct CleanupRevision: Hashable {
    let pending: Set<String>?
    let delivery: UUID
    let resolution: UUID
  }

  func body(content: Content) -> some View {
    content
      .task(id: MobilePush.shared.inboxRevision) {
        guard let route = MobilePush.shared.takeInboxRoute() else { return }
        await openConversation(route)
      }
      .task(id: CleanupRevision(pending: connectedRequests, delivery: MobilePush.shared.deliveryRevision, resolution: phone.notificationResolutionRevision)) {
        guard connectedRequests != nil else { return }
        let pending = phone.questions.filter {
          Double($0.elicitation.expiresAt) > Date().timeIntervalSince1970 * 1000
        }.compactMap { UUID(uuidString: $0.elicitation.id) }
        await MobilePush.shared.reconcile(pending: Set(pending), resolved: phone.settledRequestIDs)
        // The first pass protects fresh alerts from a snapshot that is still catching up.
        // Retry even if no further inbox event arrives; otherwise that grace becomes permanent.
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        guard phone.link == .connected else { return }
        await MobilePush.shared.reconcile(pending: Set(phone.questions.compactMap { UUID(uuidString: $0.elicitation.id) }), resolved: phone.settledRequestIDs)
      }
  }
}
