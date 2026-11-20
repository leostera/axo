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
  var agent: CodingAgent?
  let send: (PromptDelivery) -> Void

  var body: some View {
    let destination = phone.selection
    ChatComposer(
      draft: Binding(
        get: { destination.map(phone.draft(for:)) ?? "" },
        set: { text in if let destination { phone.setDraft(text, for: destination) } }),
      placeholder: placeholder,
      canSend: canSend && !phone.isSending,
      ready: phone.canSendDraft,
      files: phone.selection.map(phone.attachments(for:)) ?? [],
      attach: { phone.attach($0) },
      detach: { phone.detach($0) },
      retryAttachment: { phone.retryUpload($0) },
      voice: voice,
      voiceDestination: destination,
      showApps: showApps,
      phone: phone,
      agent: agent,
      pi: pi,
      send: send)
    .onChange(of: voice?.transcript, initial: true) { _, transcript in
      if let transcript { take(transcript) }
    }
  }

  private func take(_ transcript: VoiceTranscript) {
    guard let destination = transcript.destination, voice?.consume(transcript) == true else { return }
    phone.keepVoiceTranscript(transcript)
    if transcript.delivery == .send, phone.selection == destination, canSend, !phone.isSending { send(.interrupt) }
  }

  /// The open chat's Pi, read here so only the box redraws as it changes.
  private var pi: ComposerPi? {
    guard let workbench, let destination = phone.selection else { return nil }
    if session == nil || phone.modelChoice(for: destination) != nil {
      let draftAgent = phone.newChatAgent
      let choice = phone.modelChoice(for: destination)
      return ComposerPi(
        runtime: choice?.runtime,
        models: session.map { workbench.chat($0).models } ?? (workbench.draftModelsAgent == draftAgent ? workbench.draftModels : nil),
        commands: nil,
        loadModels: {
          if let session { await workbench.loadModels(in: session) }
          else { await workbench.loadDraftModels(for: draftAgent) }
        },
        loadCommands: {},
        choose: { model in
          let level = choice?.thinkingLevel.flatMap { model.thinkingLevels.contains($0) ? $0 : nil }
          phone.chooseModel(model, thinkingLevel: level, for: destination, agent: draftAgent)
        },
        chooseLevel: { level in phone.chooseModel(choice?.model, thinkingLevel: level, for: destination, agent: draftAgent) },
        useDefault: session == nil ? { phone.chooseModel(nil, for: destination, agent: draftAgent) } : nil,
        modelsFailure: session == nil ? (workbench.draftModelsAgent == draftAgent ? workbench.draftModelsFailure : nil) : workbench.failure,
        catalogOnly: session == nil && draftAgent == .claudeCode,
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
