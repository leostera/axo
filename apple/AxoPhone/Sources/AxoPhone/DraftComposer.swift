import AxoPhoneModel
import AxoProtocol
import SwiftUI

/// The open chat's box. Its words, and whether a message is on its way, are read here, so only
/// this redraws as they change. So are the words being said: a finished dictation goes after
/// what is typed, and is sent if Send ended it and the chat can take it.
struct DraftComposer: View {
  let phone: PhoneWorkbench
  let placeholder: String
  let canSend: Bool
  let voice: VoicePrompt?
  var showApps: (() -> Void)?
  /// The open chat, for what its Pi runs and takes (RFD0033); nil for a new chat.
  var workbench: HostWorkbenchModel?
  var session: SessionID?
  let send: (PromptDelivery) -> Void

  var body: some View {
    ChatComposer(
      draft: Binding(
        get: { phone.selection.map(phone.draft(for:)) ?? "" },
        set: { text in if let selection = phone.selection { phone.setDraft(text, for: selection) } }),
      placeholder: placeholder,
      canSend: canSend && !phone.isSending,
      ready: phone.canSendDraft,
      files: phone.selection.map(phone.attachments(for:)) ?? [],
      attach: { phone.attach($0) },
      detach: { phone.detach($0) },
      voice: voice,
      showApps: showApps,
      pi: pi,
      send: send)
    .onChange(of: voice?.transcript) { _, transcript in
      if let transcript { take(transcript) }
    }
  }

  private func take(_ transcript: VoiceTranscript) {
    voice?.consume(transcript)
    guard let selection = phone.selection else { return }
    phone.setDraft(transcript.appending(to: phone.draft(for: selection)), for: selection)
    if transcript.delivery == .send, canSend, !phone.isSending { send(.followUp) }
  }

  /// The open chat's Pi, read here so only the box redraws as it changes.
  private var pi: ComposerPi? {
    guard let workbench, let session else { return nil }
    let chat = workbench.chat(session)
    return ComposerPi(
      runtime: workbench.piRuntime(of: session),
      models: chat.models,
      commands: chat.commands,
      loadModels: { await workbench.loadModels(in: session) },
      loadCommands: { await workbench.loadCommands(in: session) },
      choose: { model in Task { await workbench.setModel(model, in: session) } },
      chooseLevel: { level in Task { await workbench.setModel(thinkingLevel: level, in: session) } })
  }
}
