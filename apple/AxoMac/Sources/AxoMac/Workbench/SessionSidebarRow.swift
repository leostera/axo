import AxoProtocol
import SwiftUI

struct SidebarSectionHeader: View {
  let title: String
  let buttonLabel: String
  let helpText: String
  let accessibilityIdentifier: String
  let topPadding: CGFloat
  let action: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
      Button(action: action) {
        Image(systemName: "plus")
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 18, height: 18)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(helpText)
      .accessibilityLabel(buttonLabel)
      .accessibilityIdentifier(accessibilityIdentifier)
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
