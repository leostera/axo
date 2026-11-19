import AxoMobileModel
import AxoProtocol
import SwiftUI

/// Discovery determines draft choices. An existing Session shows its agent without a menu.
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
    } else if phone.selection != nil {
      badge(currentAgent, selectable: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent: \(currentAgent?.displayName ?? "Unknown")")
        .accessibilityIdentifier("agent-badge")
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
          badge(phone.newChatAgent, selectable: true)
        }
        .accessibilityLabel("Agent: \(phone.newChatAgent.displayName)")
        .accessibilityIdentifier("agent-picker")
      } else {
        Text(status).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func badge(_ agent: CodingAgent?, selectable: Bool) -> some View {
    HStack(spacing: 4) {
      if let agent {
        Image(agent.logoName).resizable().scaledToFit().frame(width: 14, height: 14)
      } else {
        Image(systemName: "person.crop.square")
      }
      if sizeClass == .regular {
        Text(agent?.displayName ?? "Agent").lineLimit(1)
        if selectable {
          Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
      }
    }
    .font(.caption).foregroundStyle(.secondary)
    .padding(.horizontal, 8).frame(height: ComposerMetrics.control)
    .background(Color.primary.opacity(0.05), in: Capsule())
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
