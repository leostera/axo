import AxoClient
import AxoMobileModel
import SwiftUI

struct RequestNotificationsModifier: ViewModifier {
  let phone: PhoneWorkbench
  let account: AccountSession
  @Binding var showingRequests: Bool

  private var connectedRequests: Set<String>? {
    phone.link == .connected ? Set(phone.questions.map { $0.elicitation.id }) : nil
  }

  func body(content: Content) -> some View {
    content
      .task(id: MobilePush.shared.inboxRevision) {
        guard let route = MobilePush.shared.takeInboxRoute(),
          let token = try? await account.tokens.sessionToken(), token.accountID == route.accountID
        else { return }
        // Only opens current account-wide state. Never answers or navigates to a stale request.
        showingRequests = true
      }
      .task(id: connectedRequests) {
        guard connectedRequests != nil else { return }
        let pending = phone.questions.filter {
          Double($0.elicitation.expiresAt) > Date().timeIntervalSince1970 * 1000
        }.compactMap { UUID(uuidString: $0.elicitation.id) }
        await MobilePush.shared.reconcile(pending: Set(pending))
      }
  }
}
