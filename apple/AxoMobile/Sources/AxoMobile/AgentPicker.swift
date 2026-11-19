import AxoMobileModel
import AxoProtocol
import SwiftUI

/// Host discovery, not the static list of adapters, determines the choices.
struct AgentPicker: View {
  @Bindable var phone: PhoneWorkbench
  var voice: VoicePrompt?

  var body: some View {
    if let selection = phone.selection, selection.session == nil {
      HStack {
        if let agents = phone.availableCodingAgents, !agents.isEmpty {
          Menu {
            Picker("Agent", selection: Binding(get: { phone.newChatAgent }, set: { phone.chooseAgent($0, voice: voice) })) {
              ForEach(agents) { agent in
                Label(agent.displayName, image: agent.logoName).tag(agent)
              }
            }
          } label: {
            HStack(spacing: 6) {
              Image(phone.newChatAgent.logoName).resizable().scaledToFit().frame(width: 15, height: 15)
              Text(phone.newChatAgent.displayName).font(.footnote).lineLimit(1)
              Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 11).frame(height: 28)
            .background(.regularMaterial, in: Capsule())
          }
          .accessibilityLabel("Agent: \(phone.newChatAgent.displayName)")
          .accessibilityIdentifier("agent-picker")
        } else if let failure = phone.agentCatalogFailure {
          Button(failure) { Task { await phone.refreshAvailableCodingAgents(voice: voice) } }.font(.caption)
        } else {
          Text(phone.availableCodingAgents == nil ? "Checking agents…" : "No coding agents available")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .task(id: phone.current?.reference) { await phone.refreshAvailableCodingAgents(voice: voice) }
      .onChange(of: phone.link) { _, value in
        if value == .connected { Task { await phone.refreshAvailableCodingAgents(voice: voice) } }
      }
    }
  }
}
