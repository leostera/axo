import AppKit
import Foundation

/// Per-surface presentation state driven by Ghostty surface actions. Title and pwd are
/// presentation hints only: they never rename sessions or change Axod state.
struct TerminalSurfaceStatus: Equatable {
  enum Progress: Equatable {
    case value(Int), indeterminate, error(Int?), paused(Int?)
  }

  struct Search: Equatable {
    var needle: String
    var total: Int?
    var selected: Int?
  }

  struct ChildExit: Equatable {
    var exitCode: UInt32
    var runtimeMilliseconds: UInt64
  }

  var secureInput = false
  var readonly = false
  var rendererHealthy = true
  var keySequenceActive = false
  var keyTables: [String] = []
  var progress: Progress?
  var childExit: ChildExit?
  var title: String?
  var pwd: String?
  var search: Search?

  enum Event: Equatable {
    enum Toggle: Equatable { case on, off, toggle }
    enum ProgressState: Equatable { case remove, set, error, indeterminate, pause }

    case secureInput(Toggle)
    case readonly(Bool)
    case rendererHealthy(Bool)
    case keySequence(active: Bool)
    case keyTableActivate(String)
    case keyTableDeactivate
    case keyTableDeactivateAll
    case progress(ProgressState, percent: Int8)
    case childExited(ChildExit)
    case title(String?)
    case pwd(String?)
    case startSearch(String)
    case endSearch
    case searchTotal(Int)
    case searchSelected(Int)
  }

  mutating func apply(_ event: Event) {
    switch event {
    case .secureInput(.on): secureInput = true
    case .secureInput(.off): secureInput = false
    case .secureInput(.toggle): secureInput.toggle()
    case .readonly(let value): readonly = value
    case .rendererHealthy(let value): rendererHealthy = value
    case .keySequence(let active): keySequenceActive = active
    case .keyTableActivate(let name): keyTables.append(name)
    case .keyTableDeactivate: _ = keyTables.popLast()
    case .keyTableDeactivateAll: keyTables.removeAll()
    case .progress(let state, let percent):
      let value = percent < 0 ? nil : Int(min(percent, 100))
      switch state {
      case .remove: progress = nil
      case .set: progress = value.map(Progress.value) ?? .indeterminate
      case .error: progress = .error(value)
      case .indeterminate: progress = .indeterminate
      case .pause: progress = .paused(value)
      }
    case .childExited(let exit): childExit = exit
    case .title(let value): title = value
    case .pwd(let value): pwd = value
    case .startSearch(let needle):
      search = Search(needle: needle, total: search?.total, selected: search?.selected)
    case .endSearch: search = nil
    case .searchTotal(let total): search?.total = total < 0 ? nil : total
    case .searchSelected(let selected): search?.selected = selected < 0 ? nil : selected
    }
  }

  /// Short, non-sensitive badges for the pane overlay, in Ghostty.app's precedence.
  var badges: [String] {
    var badges: [String] = []
    if let childExit {
      badges.append(
        "Process exited with code \(childExit.exitCode) after "
          + Duration.milliseconds(Int64(clamping: childExit.runtimeMilliseconds)).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
    }
    if !rendererHealthy { badges.append("Renderer unhealthy") }
    if readonly { badges.append("Read-only") }
    if secureInput { badges.append("Secure input") }
    if let table = keyTables.last { badges.append("Key table: \(table)") }
    if keySequenceActive { badges.append("Key sequence…") }
    switch progress {
    case .value(let percent): badges.append("\(percent)%")
    case .indeterminate: badges.append("Working…")
    case .error(let percent): badges.append(percent.map { "Error at \($0)%" } ?? "Error")
    case .paused(let percent): badges.append(percent.map { "Paused at \($0)%" } ?? "Paused")
    case nil: break
    }
    return badges
  }
}

/// Non-interactive status overlay at the top-right of a pane.
final class TerminalStatusBadgeView: NSTextField {
  init() {
    super.init(frame: .zero)
    isEditable = false
    isSelectable = false
    isBordered = false
    drawsBackground = true
    backgroundColor = .windowBackgroundColor
    textColor = .secondaryLabelColor
    font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    isHidden = true
    wantsLayer = true
    layer?.cornerRadius = 4
    setAccessibilityRole(.staticText)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for TerminalStatusBadgeView")
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func show(_ status: TerminalSurfaceStatus, in bounds: NSRect) {
    let badges = status.badges
    guard !badges.isEmpty else {
      isHidden = true
      return
    }
    stringValue = badges.joined(separator: " · ")
    sizeToFit()
    let width = min(frame.width + 8, max(bounds.width - 8, 0))
    frame = NSRect(
      x: bounds.maxX - width - 4, y: bounds.maxY - frame.height - 6, width: width,
      height: frame.height + 2)
    isHidden = false
  }
}
