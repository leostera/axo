import SwiftUI

// The interaction design follows Ghostty's command palette (MIT,
// macos/Sources/Features/Command Palette at the pinned revision): focus is taken on the next
// main-loop turn (Ghostty #8497), losing focus closes the palette, and arrows and ⌃P/⌃N are
// zero-size key-equivalent buttons so they work while the text field has focus.

/// The palette over the window: a click outside closes it.
struct CommandPaletteOverlay: View {
  var palette: CommandPaletteModel
  var onChoose: (CommandPaletteAction) -> Void

  var body: some View {
    if palette.isPresented {
      ZStack(alignment: .top) {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture { palette.dismiss() }
          .accessibilityHidden(true)
        CommandPaletteView(palette: palette, onChoose: onChoose)
          .padding(.top, 48)
      }
    }
  }
}

struct CommandPaletteView: View {
  @Bindable var palette: CommandPaletteModel
  var onChoose: (CommandPaletteAction) -> Void
  @FocusState private var isQueryFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        SelectionKeys(palette: palette)
        TextField("Search Sessions, panes and commands", text: $palette.query)
          .textFieldStyle(.plain)
          .font(.system(size: 18, weight: .light))
          .padding(.horizontal, 14)
          .frame(height: 44)
          .focused($isQueryFocused)
          .onSubmit(choose)
          .onExitCommand { palette.dismiss() }
          .accessibilityIdentifier("command-palette-query")
      }
      Divider()
      CommandPaletteResults(palette: palette, onChoose: choose)
    }
    .frame(width: 560)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor))
    )
    .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("command-palette")
    .onAppear {
      DispatchQueue.main.async { isQueryFocused = true }
    }
    .onChange(of: isQueryFocused) { _, focused in
      if !focused { palette.dismiss() }
    }
  }

  private func choose() {
    if let action = palette.choose() { onChoose(action) }
  }
}

/// Up/Down and ⌃P/⌃N move the selection while typing.
private struct SelectionKeys: View {
  var palette: CommandPaletteModel

  var body: some View {
    Group {
      key(.upArrow, [], by: -1)
      key(.downArrow, [], by: 1)
      key("p", .control, by: -1)
      key("n", .control, by: 1)
    }
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }

  private func key(_ key: KeyEquivalent, _ modifiers: EventModifiers, by offset: Int) -> some View
  {
    Button { palette.moveSelection(by: offset) } label: { Color.clear }
      .buttonStyle(.plain)
      .keyboardShortcut(key, modifiers: modifiers)
  }
}

private struct CommandPaletteResults: View {
  var palette: CommandPaletteModel
  var onChoose: () -> Void

  var body: some View {
    if palette.results.isEmpty {
      Text("No matches")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 44)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(Array(palette.results.enumerated()), id: \.element.id) { index, result in
              CommandPaletteRow(result: result, isSelected: index == palette.selectedIndex) {
                palette.select(result.id)
                onChoose()
              }
              .id(result.id)
            }
          }
          .padding(6)
        }
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: palette.selectedResult?.id) { _, id in
          if let id { proxy.scrollTo(id) }
        }
      }
    }
  }
}

private struct CommandPaletteRow: View {
  let result: CommandPaletteResult
  let isSelected: Bool
  var onChoose: () -> Void
  @State private var isHovered = false

  private var item: CommandPaletteItem { result.item }

  var body: some View {
    Button(action: onChoose) {
      HStack(spacing: 10) {
        Image(systemName: icon)
          .foregroundStyle(.secondary)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(CommandPaletteHighlight.attributed(item.title, result.match.titleHighlights))
            .lineLimit(1)
          if !item.subtitle.isEmpty {
            Text(
              CommandPaletteHighlight.attributed(item.subtitle, result.match.subtitleHighlights)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          }
        }
        Spacer(minLength: 8)
        if item.isCurrent {
          Text("Current")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .foregroundStyle(.secondary)
        }
        if let shortcut = item.shortcut {
          Text(shortcut)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 6).fill(
          isSelected
            ? Color.accentColor.opacity(0.22)
            : (isHovered ? Color.secondary.opacity(0.12) : Color.clear))
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .accessibilityIdentifier("command-palette-row-\(item.id)")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var icon: String {
    switch item.kind {
    case .session: "rectangle.stack"
    case .pane: "rectangle.split.2x1"
    case .command: "command"
    }
  }
}

/// Matched characters drawn in the accent colour.
enum CommandPaletteHighlight {
  static func attributed(_ text: String, _ offsets: [Int]) -> AttributedString {
    var attributed = AttributedString(text)
    guard !offsets.isEmpty else { return attributed }
    let matched = Set(offsets)
    var index = attributed.startIndex
    var offset = 0
    while index < attributed.endIndex {
      let next = attributed.index(afterCharacter: index)
      if matched.contains(offset) {
        attributed[index..<next].foregroundColor = .accentColor
        attributed[index..<next].inlinePresentationIntent = .stronglyEmphasized
      }
      index = next
      offset += 1
    }
    return attributed
  }
}
