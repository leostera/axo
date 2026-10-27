import AxoPhoneModel
import SwiftUI

/// The open chat's box. Its words, and whether a message is on its way, are read here, so only
/// this redraws as they change. So are the words being said: a finished dictation goes after
/// what is typed, and is sent if Send ended it and the chat can take it.
struct DraftComposer: View {
  let phone: PhoneWorkbench
  let placeholder: String
  let canSend: Bool
  let voice: VoicePrompt?
  let send: () -> Void

  var body: some View {
    ChatComposer(
      draft: Binding(
        get: { phone.selection.map(phone.draft(for:)) ?? "" },
        set: { text in if let selection = phone.selection { phone.setDraft(text, for: selection) } }),
      placeholder: placeholder,
      canSend: canSend && !phone.isSending,
      voice: voice,
      send: send)
    .onChange(of: voice?.transcript) { _, transcript in
      if let transcript { take(transcript) }
    }
  }

  private func take(_ transcript: VoiceTranscript) {
    voice?.consume(transcript)
    guard let selection = phone.selection else { return }
    phone.setDraft(transcript.appending(to: phone.draft(for: selection)), for: selection)
    if transcript.delivery == .send, canSend, !phone.isSending { send() }
  }
}
