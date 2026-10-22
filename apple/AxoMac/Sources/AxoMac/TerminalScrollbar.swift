import AppKit
import Foundation

/// Ghostty's scrollback position for one surface, in terminal rows.
struct TerminalScrollbarState: Equatable {
  /// Rows in scrollback plus the active screen.
  let total: UInt64
  /// First visible row; zero is the top of scrollback.
  let offset: UInt64
  /// Visible rows in the viewport.
  let length: UInt64
}

/// Converts between Ghostty's top-origin row offsets and AppKit's bottom-origin scroll offsets.
/// Mirrors the pinned Ghostty.app `SurfaceScrollView` calculations.
enum TerminalScrollbarGeometry {
  static func documentHeight(
    for state: TerminalScrollbarState?,
    cellHeight: CGFloat,
    contentHeight: CGFloat
  ) -> CGFloat {
    guard cellHeight > 0, let state else { return contentHeight }
    // Keep the same padding around the scrollback grid as the viewport has around its grid.
    let padding = contentHeight - CGFloat(state.length) * cellHeight
    return CGFloat(state.total) * cellHeight + padding
  }

  static func scrollOrigin(for state: TerminalScrollbarState, cellHeight: CGFloat) -> CGFloat {
    guard cellHeight > 0, state.total >= state.offset + state.length else { return 0 }
    return CGFloat(state.total - state.offset - state.length) * cellHeight
  }

  static func row(
    documentHeight: CGFloat,
    visibleOriginY: CGFloat,
    visibleHeight: CGFloat,
    cellHeight: CGFloat
  ) -> Int? {
    guard cellHeight > 0 else { return nil }
    let offsetFromTop = documentHeight - visibleOriginY - visibleHeight
    return max(0, Int(offsetFromTop / cellHeight))
  }
}

/// Ghostty.app's `scrollbar` and background-luminance configuration rules.
enum TerminalScrollbarConfig {
  /// Ghostty accepts `system` (default) and `never`; unknown values fall back to `system`.
  static func showsScrollbar(configValue: String?) -> Bool {
    configValue != "never"
  }

  /// Matches Ghostty's `isLightColor` luminance threshold for choosing the scroller appearance.
  static func isDarkBackground(red: UInt8, green: UInt8, blue: UInt8) -> Bool {
    let luminance =
      0.299 * Double(red) / 255 + 0.587 * Double(green) / 255 + 0.114 * Double(blue) / 255
    return luminance <= 0.5
  }
}

/// A native overlay scroller layered above a Ghostty surface. Only the scroller itself accepts
/// pointer events, so wheel, click and selection input still reach the terminal surface.
final class TerminalScrollbarOverlayView: NSScrollView {
  var onScrollToRow: ((Int) -> Void)?
  weak var wheelTarget: NSView?

  private let documentContainer = NSView()
  private var state: TerminalScrollbarState?
  private var cellHeight: CGFloat = 0
  private var isLiveScrolling = false
  private var lastSentRow: Int?
  private var observers: [NSObjectProtocol] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    hasVerticalScroller = true
    hasHorizontalScroller = false
    autohidesScrollers = false
    usesPredominantAxisScrolling = true
    scrollerStyle = .overlay
    drawsBackground = false
    documentView = documentContainer
    setAccessibilityElement(false)

    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: NSScrollView.willStartLiveScrollNotification, object: self, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.isLiveScrolling = true }
      })
    observers.append(
      center.addObserver(
        forName: NSScrollView.didEndLiveScrollNotification, object: self, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.isLiveScrolling = false }
      })
    observers.append(
      center.addObserver(
        forName: NSScrollView.didLiveScrollNotification, object: self, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.handleLiveScroll() }
      })
    observers.append(
      center.addObserver(
        forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: nil
      ) { [weak self] _ in
        // Ghostty.app keeps overlay scrollers so the terminal grid never loses a column.
        MainActor.assumeIsolated { self?.scrollerStyle = .overlay }
      })
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported for TerminalScrollbarOverlayView")
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let scroller = verticalScroller, !scroller.isHidden, state != nil else { return nil }
    let local = convert(point, from: superview)
    guard scroller.frame.contains(local) else { return nil }
    return super.hitTest(point)
  }

  override func scrollWheel(with event: NSEvent) {
    // Wheel input belongs to Ghostty, which owns scrollback and mouse reporting.
    wheelTarget?.scrollWheel(with: event)
  }

  func update(state: TerminalScrollbarState?, cellHeight: CGFloat) {
    self.state = state
    self.cellHeight = cellHeight
    synchronize()
  }

  func setAppearance(darkBackground: Bool) {
    appearance = NSAppearance(named: darkBackground ? .darkAqua : .aqua)
  }

  override func layout() {
    super.layout()
    synchronize()
  }

  private func synchronize() {
    documentContainer.frame.size = CGSize(
      width: contentSize.width,
      height: TerminalScrollbarGeometry.documentHeight(
        for: state, cellHeight: cellHeight, contentHeight: contentSize.height)
    )
    if !isLiveScrolling, let state, cellHeight > 0 {
      contentView.scroll(
        to: CGPoint(
          x: 0, y: TerminalScrollbarGeometry.scrollOrigin(for: state, cellHeight: cellHeight)))
      lastSentRow = Int(clamping: state.offset)
    }
    reflectScrolledClipView(contentView)
  }

  private func handleLiveScroll() {
    let visible = contentView.documentVisibleRect
    guard
      let row = TerminalScrollbarGeometry.row(
        documentHeight: documentContainer.frame.height,
        visibleOriginY: visible.origin.y,
        visibleHeight: visible.height,
        cellHeight: cellHeight),
      row != lastSentRow
    else { return }
    lastSentRow = row
    onScrollToRow?(row)
  }
}
