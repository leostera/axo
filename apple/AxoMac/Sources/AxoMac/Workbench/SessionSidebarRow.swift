import AxoProtocol
import SwiftUI

/// The sidebar's header: what it lists, a switch between the Workspace tree and the recent
/// list, and in the tree a button to create a Workspace.
struct SidebarHeader: View {
  let mode: SidebarMode
  let topPadding: CGFloat
  let onSelectMode: (SidebarMode) -> Void
  let onNewWorkspace: () -> Void

  var body: some View {
    HStack(spacing: 2) {
      Text(mode == .workspaces ? "Workspaces" : "Recent")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
      let other: SidebarMode = mode == .workspaces ? .recent : .workspaces
      Button { onSelectMode(other) } label: {
        Image(systemName: mode == .workspaces ? "clock" : "list.bullet.indent")
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 18, height: 18)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(other == .recent ? "List Sessions by recent activity" : "Group Sessions by Workspace")
      .accessibilityLabel(other == .recent ? "Show recent Sessions" : "Show Workspaces")
      .accessibilityIdentifier("sidebar-mode-button")
      if mode == .workspaces {
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
    }
    .padding(.horizontal, 8)
    .padding(.top, topPadding)
    .padding(.bottom, 2)
    .frame(height: 22 + topPadding)
  }
}

struct SessionSidebarRow: View {
  let session: TerminalSession
  let isSelected: Bool
  /// Shows how long ago the Session was last active, as the recent list does.
  var showsAge = false
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
    .accessibilityLabel("\(session.displayName), \(status.accessibilityDescription)")
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
