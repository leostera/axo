import AxoMobileModel
import AxoProtocol
import SwiftUI

/// Which coding agent a new chat runs, as a chip above the message box (RFD0072). Shown only
/// while starting a chat: a chat keeps the agent it started with.
struct AgentPicker: View {
  @Bindable var phone: PhoneWorkbench

  var body: some View {
    if let selection = phone.selection, selection.session == nil {
      HStack {
        Menu {
          Picker("Agent", selection: $phone.newChatAgent) {
            ForEach(CodingAgent.allCases) { agent in
              Text(agent.displayName).tag(agent)
            }
          }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 12, weight: .medium))
            Text(phone.newChatAgent.displayName).font(.footnote).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
          }
          .foregroundStyle(.secondary)
          .padding(.horizontal, 11)
          .frame(height: 28)
          .background(.regularMaterial, in: Capsule())
          .overlay(Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
          .contentShape(Capsule())
          .fixedSize()
        }
        .accessibilityLabel("Agent: \(phone.newChatAgent.displayName)")
        .accessibilityHint("Chooses the coding agent this chat runs")
        .accessibilityIdentifier("agent-picker")
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
    }
  }
}
