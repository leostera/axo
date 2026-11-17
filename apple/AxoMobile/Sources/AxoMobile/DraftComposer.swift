import AxoMobileModel
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
      voiceDestination: phone.selection,
      showApps: showApps,
      pi: pi,
      send: send)
    .onChange(of: voice?.transcript, initial: true) { _, transcript in
      if let transcript { take(transcript) }
    }
  }

  private func take(_ transcript: VoiceTranscript) {
    guard let destination = transcript.destination, voice?.consume(transcript) == true else { return }
    phone.setDraft(transcript.appending(to: phone.draft(for: destination)), for: destination)
    if transcript.delivery == .send, phone.selection == destination, canSend, !phone.isSending { send(.interrupt) }
  }

  /// The open chat's Pi, read here so only the box redraws as it changes.
  private var pi: ComposerPi? {
    guard let workbench, let destination = phone.selection else { return nil }
    if session == nil || phone.modelChoice(for: destination) != nil {
      let choice = phone.modelChoice(for: destination)
      return ComposerPi(
        runtime: choice?.runtime,
        models: session.map { workbench.chat($0).models } ?? workbench.draftModels,
        commands: nil,
        loadModels: {
          if let session { await workbench.loadModels(in: session) }
          else { await workbench.loadDraftModels() }
        },
        loadCommands: {},
        choose: { model in
          let level = choice.flatMap { model.thinkingLevels.contains($0.thinkingLevel) ? $0.thinkingLevel : nil }
          phone.chooseModel(model, thinkingLevel: level, for: destination)
        },
        chooseLevel: { level in phone.chooseModel(choice?.model, thinkingLevel: level, for: destination) },
        useDefault: session == nil ? { phone.chooseModel(nil, for: destination) } : nil,
        modelsFailure: session == nil ? workbench.draftModelsFailure : workbench.failure,
        supportsCommands: false)
    }
    guard let session else { return nil }
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
