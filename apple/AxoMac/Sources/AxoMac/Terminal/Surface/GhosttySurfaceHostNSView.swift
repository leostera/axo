import AppKit

/// Hosts one surface plus its overlays (scrollbar, link hover, status badge, find bar).
@MainActor
final class GhosttySurfaceHostNSView: NSView {
  private var terminalView: NSView?
  // Created only for Ghostty surfaces; it mirrors Ghostty.app's native overlay scrollbar.
  private var scrollbarOverlay: TerminalScrollbarOverlayView?
  private var linkHover: TerminalLinkHoverView?
  private var statusBadge: TerminalStatusBadgeView?
  private var findBar: TerminalFindBarView?

  override var wantsDefaultClipping: Bool { true }

  func attachSurface(_ view: NSView) {
    guard terminalView !== view || view.superview !== self else { return }
    if let terminalView, terminalView !== view {
      terminalView.removeFromSuperview()
    }
    if let previousHost = view.superview as? GhosttySurfaceHostNSView {
      previousHost.releaseSurface(view)
    } else {
      view.removeFromSuperview()
    }
    terminalView = view
    view.frame = bounds
    view.autoresizingMask = [.width, .height]
    addSubview(view)
    if let surfaceView = view as? GhosttySurfaceNSView {
      attachScrollbar(to: surfaceView)
    }
  }

  private func attachScrollbar(to surfaceView: GhosttySurfaceNSView) {
    let overlay = scrollbarOverlay ?? TerminalScrollbarOverlayView(frame: bounds)
    scrollbarOverlay = overlay
    overlay.frame = bounds
    overlay.autoresizingMask = [.width, .height]
    overlay.wheelTarget = surfaceView
    overlay.onScrollToRow = { [weak surfaceView] row in surfaceView?.scrollToRow(row) }
    if overlay.superview !== self {
      addSubview(overlay, positioned: .above, relativeTo: surfaceView)
    }
    surfaceView.onScrollbarChange = { [weak self, weak surfaceView] in
      guard let self, let surfaceView, self.terminalView === surfaceView else { return }
      self.synchronizeScrollbar(with: surfaceView)
    }
    let hover = linkHover ?? TerminalLinkHoverView()
    linkHover = hover
    if hover.superview !== self { addSubview(hover, positioned: .above, relativeTo: overlay) }
    surfaceView.onHoveredLinkChange = { [weak self, weak surfaceView] in
      guard let self, let surfaceView, self.terminalView === surfaceView else { return }
      self.linkHover?.show(surfaceView.hoveredLink, in: self.bounds)
    }
    hover.show(surfaceView.hoveredLink, in: bounds)
    let badge = statusBadge ?? TerminalStatusBadgeView()
    statusBadge = badge
    if badge.superview !== self { addSubview(badge, positioned: .above, relativeTo: overlay) }
    let find = findBar ?? TerminalFindBarView()
    findBar = find
    if find.superview !== self { addSubview(find, positioned: .above, relativeTo: badge) }
    find.onAction = { [weak surfaceView] action in
      surfaceView?.performFind(action)
    }
    surfaceView.onSurfaceStatusChange = { [weak self, weak surfaceView] in
      guard let self, let surfaceView, self.terminalView === surfaceView else { return }
      self.statusBadge?.show(surfaceView.surfaceStatus, in: self.bounds)
      let wasSearching = self.findBar?.isHidden == false
      self.findBar?.show(surfaceView.surfaceStatus.search, in: self.bounds)
      if wasSearching, surfaceView.surfaceStatus.search == nil {
        self.window?.makeFirstResponder(surfaceView)
      }
    }
    badge.show(surfaceView.surfaceStatus, in: bounds)
    find.show(surfaceView.surfaceStatus.search, in: bounds)
    synchronizeScrollbar(with: surfaceView)
  }

  private func synchronizeScrollbar(with surfaceView: GhosttySurfaceNSView) {
    guard let scrollbarOverlay else { return }
    scrollbarOverlay.isHidden = !surfaceView.showsScrollbar
    scrollbarOverlay.setAppearance(darkBackground: surfaceView.hasDarkBackground)
    scrollbarOverlay.update(state: surfaceView.scrollbarState, cellHeight: surfaceView.cellHeight)
  }

  private func removeScrollbar() {
    scrollbarOverlay?.removeFromSuperview()
    scrollbarOverlay?.onScrollToRow = nil
    scrollbarOverlay?.wheelTarget = nil
    scrollbarOverlay = nil
    linkHover?.removeFromSuperview()
    linkHover = nil
    statusBadge?.removeFromSuperview()
    statusBadge = nil
    findBar?.onAction = nil
    findBar?.removeFromSuperview()
    findBar = nil
  }

  func detachSurface() {
    guard let terminalView else { return }
    releaseSurface(terminalView)
  }

  fileprivate func releaseSurface(_ view: NSView) {
    guard terminalView === view else { return }
    terminalView = nil
    removeScrollbar()
    if view.superview === self {
      view.removeFromSuperview()
    }
  }

  override func layout() {
    super.layout()
    guard let terminalView, terminalView.superview === self else { return }
    terminalView.frame = bounds
    (terminalView as? GhosttySurfaceNSView)?.updateContentSize(terminalView.bounds.size)
    scrollbarOverlay?.frame = bounds
  }
}
