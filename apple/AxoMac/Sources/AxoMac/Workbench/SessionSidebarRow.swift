import AxoProtocol
import SwiftUI

/// The sidebar's header: a menu of which Macs' Sessions it lists (this Mac, each other Mac,
/// or all of them), and a button to create a Workspace.
struct SidebarHeader: View {
  let title: String
  let selection: SidebarMacs
  let hosts: [PeerHost]
  let topPadding: CGFloat
  let onSelect: (SidebarMacs) -> Void
  let onNewWorkspace: () -> Void

  var body: some View {
    HStack(spacing: 2) {
      Menu {
        choice("This Mac", .thisMac)
        if !hosts.isEmpty {
          Divider()
          ForEach(hosts) { host in
            choice(host.online ? host.label : "\(host.label) (offline)", .mac(host.hostId))
          }
          Divider()
          choice("All Macs", .all)
        }
      } label: {
        HStack(spacing: 3) {
          Text(title)
            .font(.system(size: 12, weight: .semibold))
          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(.secondary)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Choose which Macs' Sessions to list")
      .accessibilityLabel("Sessions on \(title)")
      .accessibilityIdentifier("sidebar-macs-menu")
      Spacer(minLength: 0)
      Button(action: onNewWorkspace) {
        Image(systemName: "plus")
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 18, height: 18)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Create a Workspace (⌘N)")
      .accessibilityLabel("New Workspace")
      .accessibilityIdentifier("new-workspace-button")
    }
    .padding(.horizontal, 8)
    .padding(.top, topPadding)
    .padding(.bottom, 2)
    .frame(height: 22 + topPadding)
  }

  private func choice(_ label: String, _ macs: SidebarMacs) -> some View {
    Button {
      onSelect(macs)
    } label: {
      if selection == macs {
        Label(label, systemImage: "checkmark")
      } else {
        Text(label)
      }
    }
  }
}

struct SessionSidebarRow: View {
  let session: TerminalSession
  let isSelected: Bool
  /// Shows how long ago the Session was last active, as the recent list does.
  var showsAge = false
  /// The other Mac the Session runs on, shown when the list mixes Macs.
  var hostLabel: String? = nil
  @Environment(GhosttyRuntime.self) private var ghostty

  var body: some View {
    let status = sidebarStatus(for: session, attention: ghostty.attentionShellIDs)
    HStack(spacing: 4) {
      Image(systemName: status.symbolName)
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(status.color)
        .frame(width: 9)
      sessionGlyph(for: session, size: 12)
        .frame(width: 14)
      Text(session.displayName)
        .font(.system(size: 12))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      if let hostLabel {
        Text(hostLabel)
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
      if showsAge {
        // Ages only need to move once a minute.
        TimelineView(.periodic(from: .now, by: 60)) { context in
          Text(SessionActivityOrder.age(of: SessionActivityOrder.lastActivity(of: session), now: context.date))
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.tertiary)
        }
      }
    }
    .padding(.leading, 6)
    .padding(.trailing, 8)
    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
    .background(
      isSelected ? Color.accentColor.opacity(0.16) : .clear,
      in: RoundedRectangle(cornerRadius: 4)
    )
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      [session.displayName, hostLabel.map { "on \($0)" }, status.accessibilityDescription]
        .compactMap { $0 }.joined(separator: ", "))
  }
}

func sidebarStatus(
  for session: TerminalSession, attention: Set<ShellID>
) -> TerminalSessionStatus {
  // A local terminal bell or finished command marks the session until one of its panes is focused.
  if session.shells.contains(where: { attention.contains($0.id) }) { return .needsAttention }
  return session.status ?? (session.shells.contains(where: { $0.isPi }) ? .starting : .ready)
}

@ViewBuilder
func sessionGlyph(for session: TerminalSession, size: CGFloat) -> some View {
  if let emoji = session.emoji {
    Text(emoji)
      .font(.system(size: size))
  } else {
    Image(systemName: session.shells.contains(where: { $0.isPi }) ? "sparkle" : "terminal")
      .font(.system(size: size))
      .foregroundStyle(.secondary)
  }
}

private extension TerminalSessionStatus {
  var symbolName: String {
    switch self {
    case .starting, .unavailable: "circle.dotted"
    case .ready: "circle.fill"
    case .working: "hammer.fill"
    case .needsAttention: "exclamationmark.triangle.fill"
    }
  }

  var color: Color {
    switch self {
    case .starting, .unavailable: .secondary
    case .ready: .green
    case .working: .accentColor
    case .needsAttention: .yellow
    }
  }

  var accessibilityDescription: String {
    switch self {
    case .starting: "starting"
    case .ready: "ready"
    case .working: "working"
    case .needsAttention: "needs attention"
    case .unavailable: "unavailable"
    }
  }
}

/// One Session in the collapsed sidebar: its glyph with a status badge.
struct CollapsedSessionButton: View {
  let session: TerminalSession
  let isSelected: Bool
  let onSelect: () -> Void
  @Environment(GhosttyRuntime.self) private var ghostty

  var body: some View {
    let status = sidebarStatus(for: session, attention: ghostty.attentionShellIDs)
    Button(action: onSelect) {
      ZStack(alignment: .bottomTrailing) {
        sessionGlyph(for: session, size: 15)
        Image(systemName: status.symbolName)
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(status.color)
          .background(Color(nsColor: .windowBackgroundColor), in: Circle())
      }
      .frame(width: 36, height: 36)
      .background(
        isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
    }
    .buttonStyle(.plain)
    .help(session.displayName)
    .accessibilityLabel("\(session.displayName), \(status.accessibilityDescription)")
  }
}
