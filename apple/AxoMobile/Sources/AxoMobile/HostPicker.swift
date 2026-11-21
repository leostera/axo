import AxoClient
import AxoMobileModel
import AxoProtocol
import AxoSessionUI
import SwiftUI

/// New chats switch their draft destination; existing chats can fork to another host.
struct HostPicker: View {
  let phone: PhoneWorkbench
  var voice: VoicePrompt?
  var showName = false
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var fork: Fork?
  @State private var forkError: String?

  private struct Fork: Identifiable {
    let id = UUID()
    let source: SessionForkSnapshot
    let destination: RemoteHost
    let credential: UUID
    let retry: SessionForkAttempt?
  }

  var body: some View {
    picker
      .popover(item: $fork) { operation in
        SessionForkSheet(machine: operation.destination.label, retry: operation.retry) {
          guard operation.credential == phone.agentDiscoveryRevision else { throw SessionForkError.selectionChanged }
          return try await phone.planSessionFork(from: operation.source, to: operation.destination.reference)
        } fork: { requestID, folder, agent in
          guard operation.credential == phone.agentDiscoveryRevision else { throw SessionForkError.selectionChanged }
          try await phone.forkSession(from: operation.source, to: operation.destination.reference,
            requestID: requestID, folder: folder, agent: agent)
          return nil
        }
        .presentationCompactAdaptation(.popover)
      }
      .alert("Can’t fork session", isPresented: Binding(
        get: { forkError != nil }, set: { if !$0 { forkError = nil } }
      )) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(forkError ?? "")
      }
  }

  @ViewBuilder
  private var picker: some View {
    if let host = openHost {
      let candidates = phone.hosts.hosts.filter { phone.isDrafting || $0.hostId != host.hostId }
      if phone.isDrafting || !candidates.isEmpty {
        Menu {
          ForEach(candidates, id: \.hostId) { candidate in
            Button {
              if phone.isDrafting {
                phone.chooseHost(candidate.hostId, voice: voice)
              } else {
                do {
                  let retry = phone.pendingFork(to: candidate.reference)
                  fork = Fork(source: try retry?.snapshot ?? phone.forkSnapshot(), destination: candidate,
                    credential: phone.agentDiscoveryRevision, retry: retry?.attempt)
                } catch {
                  forkError = error.localizedDescription
                }
              }
            } label: {
              let name = "\(candidate.label)\(candidate.status == .online ? "" : ", offline")"
              if let logo = HostPresentation.logoName(candidate) {
                Label(name, image: logo)
              } else {
                Label(name, systemImage: HostPresentation.symbol(candidate))
              }
            }
            .disabled(candidate.status != .online || phone.isSending)
          }
        } label: {
          badge(host, selectable: true)
        }
        .accessibilityLabel("Host: \(host.label)")
        .accessibilityHint(phone.isDrafting ? "Chooses where to start this chat" : "Forks this session to another machine")
        .accessibilityIdentifier("host-picker")
      } else {
        badge(host, selectable: false)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Host: \(host.label)")
          .accessibilityIdentifier("host-badge")
      }
    }
  }

  private func badge(_ host: RemoteHost, selectable: Bool) -> some View {
    HStack(spacing: 4) {
      HostIcon(host: host).frame(width: 14, height: 14)
      if showName || sizeClass == .regular {
        Text(host.label).lineLimit(1).composerLabelWidth(100)
        if selectable {
          Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
      }
    }
    .font(.caption).foregroundStyle(.secondary)
    .padding(.horizontal, 8)
    .composerPill()
  }

  private var openHost: RemoteHost? {
    guard let id = phone.selection?.host else { return nil }
    return phone.hosts.hosts.first { $0.hostId == id }
  }
}

extension RemoteHost {
  var symbol: String { HostPresentation.symbol(self) }
}
