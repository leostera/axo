import AxoMobileModel
import AxoProtocol
import SwiftUI

/// Discovery determines draft choices. A live Session keeps its agent and offers a new chat.
struct AgentPicker: View {
  @Bindable var phone: PhoneWorkbench
  var voice: VoicePrompt?
  var currentAgent: CodingAgent?
  @Environment(\.horizontalSizeClass) private var sizeClass

  var body: some View {
    if phone.isDrafting {
      draftPicker
        .task(id: DiscoveryContext(host: phone.current?.reference, connected: phone.link == .connected,
          online: phone.current?.status == .online, credential: phone.agentDiscoveryRevision)) {
          await phone.refreshAvailableCodingAgents(voice: voice)
        }
    } else if let selection = phone.selection {
      Menu {
        Button("New chat to choose another agent") {
          voice?.destinationOptionsChanged()
          phone.select(host: selection.host, session: nil)
        }
        .disabled(phone.isSending)
      } label: {
        HStack(spacing: 4) {
          if let currentAgent { Image(currentAgent.logoName).resizable().scaledToFit().frame(width: 14, height: 14) }
          else { Image(systemName: "person.crop.square") }
          if sizeClass == .regular { Text(currentAgent?.displayName ?? "Agent") }
        }
          .font(.caption).foregroundStyle(.secondary)
          .padding(.horizontal, 8).frame(height: ComposerMetrics.control)
          .background(Color.primary.opacity(0.05), in: Capsule())
      }
      .accessibilityLabel("Agent: \(currentAgent?.displayName ?? "Unknown")")
      .accessibilityHint("This Session keeps its agent. Start a new chat to choose another.")
      .accessibilityIdentifier("agent-picker")
    }
  }

  private var draftPicker: some View {
    Group {
      if let agents = phone.availableCodingAgents, !agents.isEmpty {
        Menu {
          Picker("Agent", selection: Binding(get: { phone.newChatAgent }, set: { phone.chooseAgent($0, voice: voice) })) {
            ForEach(agents) { agent in
              Label(agent.displayName, image: agent.logoName).tag(agent)
            }
          }
        } label: {
          HStack(spacing: 4) {
            Image(phone.newChatAgent.logoName).resizable().scaledToFit().frame(width: 14, height: 14)
            if sizeClass == .regular {
              Text(phone.newChatAgent.displayName).lineLimit(1)
              Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
          }
          .font(.caption).foregroundStyle(.secondary)
          .padding(.horizontal, 8).frame(height: ComposerMetrics.control)
          .background(Color.primary.opacity(0.05), in: Capsule())
        }
        .accessibilityLabel("Agent: \(phone.newChatAgent.displayName)")
        .accessibilityIdentifier("agent-picker")
      } else {
        Text(status).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var status: String {
    if phone.availableCodingAgents != nil { return "No coding agents available" }
    switch phone.agentCatalogState {
    case .checking: return "Checking agents…"
    case .retrying: return "Checking agents again…"
    case .updateRequired: return "Update Axo on this host to check agents"
    }
  }

  private struct DiscoveryContext: Equatable {
    let host: RemoteHostRef?
    let connected: Bool
    let online: Bool
    let credential: UUID
  }
}
