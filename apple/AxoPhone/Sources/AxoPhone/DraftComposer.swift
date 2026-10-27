import AxoPhoneModel
import SwiftUI

/// The open chat's box. Its words, and whether a message is on its way, are read here, so only
/// this redraws as they change.
struct DraftComposer: View {
  let phone: PhoneWorkbench
  let placeholder: String
  let canSend: Bool
  let send: () -> Void

  var body: some View {
    ChatComposer(
      draft: Binding(
        get: { phone.selection.map(phone.draft(for:)) ?? "" },
        set: { text in if let selection = phone.selection { phone.setDraft(text, for: selection) } }),
      placeholder: placeholder,
      canSend: canSend && !phone.isSending,
      send: send)
  }
}
