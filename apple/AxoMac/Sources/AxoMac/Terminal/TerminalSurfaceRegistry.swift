import AppKit
import AxoProtocol
import AxoClient
import Foundation
import GhosttyKit
import QuartzCore

/// Owns every terminal surface: creating it at its pane's size, attaching it to Axod's stream,
/// reattaching when the stream ends, keeping hidden surfaces sized for the window, and freeing
/// it. `GhosttyRuntime` owns the libghostty app the surfaces belong to, and routes commands to
/// them through `view(for:)`.
@MainActor
final class TerminalSurfaceRegistry {
  private struct Entry {
    let shell: TerminalShell
    let host: GhosttySurfaceHostNSView
    let view: GhosttySurfaceNSView
  }

  /// The runtime whose app creates surfaces; set by the runtime that owns this registry.
  weak var runtime: GhosttyRuntime?
  // Retain each view until its surface is freed: Ghostty passes this unretained per-surface
  // userdata pointer back to the clipboard callbacks, even after SwiftUI pane identities change.
  private var entries: [ShellID: Entry] = [:]
  private var reattachThrottle = ReattachThrottle()
  /// Reattaches deferred by `reattachThrottle`, at most one per shell.
  private var pendingReattaches: [ShellID: Task<Void, Never>] = [:]
  /// Where every open pane would be if its Session were shown; see `sizeOffscreenSurfaces`.
  private var offscreenPaneSizes: [ShellID: CGSize] = [:]
  private var offscreenBackingScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
  /// The deferred resize of hidden surfaces; see `scheduleOffscreenSizing`.
  private var pendingOffscreenSizing: Task<Void, Never>?
  /// How long the window geometry must hold still before hidden surfaces follow it.
  static let offscreenSizingSettleDelay: Duration = .milliseconds(150)

  /// The host and surface view for `shell`'s pane: the existing ones with fresh callbacks, or
  /// new ones (replacing a surface for an earlier incarnation of the shell) that start attaching.
  func presentation(
    for shell: TerminalShell,
    initialSize: CGSize,
    onFocus: @escaping () -> Void,
    onStatusChange: @escaping (TerminalSurfaceConnection) -> Void,
    onSplit: @escaping (TerminalSplitDirection) -> Void,
    onClose: @escaping () -> Void
  ) -> (host: GhosttySurfaceHostNSView, view: GhosttySurfaceNSView) {
    if let existing = entries[shell.id], existing.shell == shell {
      existing.view.onFocus = onFocus
      existing.view.onStatusChange = onStatusChange
      existing.view.onSplit = onSplit
      existing.view.onClose = onClose
      return (existing.host, existing.view)
    }

    destroySurface(shellID: shell.id)
    let view = GhosttySurfaceNSView(
      runtime: runtime,
      shellID: shell.id,
      initialFrameSize: Self.seededSurfaceSize(
        paneSize: offscreenPaneSizes[shell.id], proposedSize: initialSize),
      onFocus: onFocus
    )
    let host = GhosttySurfaceHostNSView()
    view.onStatusChange = onStatusChange
    view.onSplit = onSplit
    view.onClose = onClose
    createSurface(in: view, shell: shell)
    host.attachSurface(view)
    entries[shell.id] = Entry(shell: shell, host: host, view: view)
    return (host, view)
  }

  /// The frame a new surface starts with. libghostty sizes its grid from it and parses Axod's
  /// replay at once, before AppKit lays the surface out; a replay parsed at the wrong width
  /// soft-wraps and stays mangled after the reflow (zsh's PROMPT_SP mark, for one). So the
  /// pane's place in the layout comes first, then SwiftUI's proposal, then a nonzero seed.
  static func seededSurfaceSize(paneSize: CGSize?, proposedSize: CGSize) -> CGSize {
    func isDrawable(_ size: CGSize) -> Bool {
      size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
    if let paneSize, isDrawable(paneSize) { return paneSize }
    if isDrawable(proposedSize) { return proposedSize }
    return CGSize(width: 800, height: 600)
  }


  /// Frees surfaces whose shell closed or was replaced (a new process under the same ID).
  func reconcile(with openShells: [ShellID: TerminalShell]) {
    let stale = entries.compactMap { shellID, entry in
      openShells[shellID] == entry.shell ? nil : shellID
    }
    for shellID in stale { destroySurface(shellID: shellID) }
  }

  /// Frees every surface; the runtime calls this before freeing the libghostty app.
  func freeAll() {
    for shellID in Array(entries.keys) { destroySurface(shellID: shellID) }
  }

  private func destroySurface(shellID: ShellID) {
    reattachThrottle.forget(shellID)
    pendingReattaches.removeValue(forKey: shellID)?.cancel()
    guard let entry = entries.removeValue(forKey: shellID) else { return }
    entry.view.removeFromSuperview()
    if let surface = entry.view.detach() {
      let start = ContinuousClock.now
      ghostty_surface_free(surface)
      AxoTrace.surfaces.notice(
        "event=surface.freed shell_id=\(shellID.rawValue) elapsed_ms=\(AxoTrace.elapsed(since: start), privacy: .public)")
    }
  }

  /// Attaches to the shell off the main thread, then creates (or replaces) the view's surface.
  /// Axod owns the PTY and is its only reader: the surface reads the attach stream and uses the
  /// PTY descriptor only for input, resizing and termios queries (Ghostty external I/O patch).
  private func createSurface(in view: GhosttySurfaceNSView, shell: TerminalShell) {
    guard runtime?.app != nil else {
      view.connection = .failed(runtime?.errorMessage ?? "libghostty is unavailable.")
      return
    }
    let socketPath: UnixSocketPath
    do {
      socketPath = try UnixSocketPath(shell.attachSocketPath)
    } catch {
      view.connection = .failed("axod reported an invalid terminal socket path.")
      return
    }
    view.attachGeneration += 1
    let generation = view.attachGeneration
    let shellID = shell.id
    let start = ContinuousClock.now
    Task.detached(priority: .userInitiated) { [weak self, weak view] in
      let result = Result { try TerminalAttachment.open(socketPath: socketPath, shellID: shellID) }
      AxoTrace.surfaces.notice(
        "event=surface.attach_opened shell_id=\(shellID.rawValue) ok=\((try? result.get()) != nil) elapsed_ms=\(AxoTrace.elapsed(since: start), privacy: .public)")
      await MainActor.run {
        AxoTrace.surfaces.notice(
          "event=surface.attach_on_main shell_id=\(shellID.rawValue) elapsed_ms=\(AxoTrace.elapsed(since: start), privacy: .public)")
        guard let self, let view else {
          if case .success(let attachment) = result { attachment.close() }
          return
        }
        self.adopt(result, in: view, shell: shell, generation: generation)
      }
    }
  }

  private func adopt(
    _ result: Result<TerminalAttachment, Error>,
    in view: GhosttySurfaceNSView,
    shell: TerminalShell,
    generation: Int
  ) {
    let attachment: TerminalAttachment
    switch result {
    case .success(let opened):
      attachment = opened
    case .failure(let error):
      guard view.attachGeneration == generation else { return }
      // A replacement attempt for an exited shell keeps the final screen; the catalog
      // removes the pane.
      if view.surface != nil, case TerminalAttachmentError.rejected(.shellNotOpen) = error { return }
      view.connection = .failed("Could not attach to the terminal: \(error)")
      return
    }
    // Ghostty duplicates both descriptors, so ours close whatever happens below.
    defer { attachment.close() }
    guard view.attachGeneration == generation,
      entries[shell.id]?.view === view,
      let app = runtime?.app
    else { return }

    var surfaceConfig = ghostty_surface_config_new()
    surfaceConfig.userdata = Unmanaged.passUnretained(view).toOpaque()
    surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
    surfaceConfig.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque())
    )
    let scale = view.window?.backingScaleFactor ?? offscreenBackingScale
    surfaceConfig.scale_factor = Double(scale)
    // libghostty parses the replay as soon as the surface exists; give it the pane's real grid,
    // not the 800x600 placeholder.
    if let points = initialSurfaceSize(of: view) {
      surfaceConfig.initial_width = UInt32(points.width * scale)
      surfaceConfig.initial_height = UInt32(points.height * scale)
    }
    surfaceConfig.font_size = 0
    surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
    surfaceConfig.external_io = true
    surfaceConfig.external_output_fd = attachment.outputDescriptor
    surfaceConfig.external_pty_fd = attachment.ptyDescriptor

    let surfaceStart = ContinuousClock.now
    let createdSurface = shell.initialPwd.withCString { workingDirectory in
      surfaceConfig.working_directory = workingDirectory
      return ghostty_surface_new(app, &surfaceConfig)
    }
    AxoTrace.surfaces.notice(
      "event=surface.created shell_id=\(shell.id.rawValue) replay_bytes=\(attachment.replayByteCount) surface_new_ms=\(AxoTrace.elapsed(since: surfaceStart), privacy: .public)")
    guard let createdSurface else {
      view.connection = .failed("Ghostty could not create a terminal surface.")
      return
    }
    if let previous = view.detach() {
      ghostty_surface_free(previous)
    }
    view.attach(createdSurface, ptyDescriptor: attachment.ptyDescriptor)
    view.connection = .connected
    updateSize(of: view, contentSize: view.bounds.size)
    view.reportPTYSize()
  }

  /// Where a surface being created will be drawn: its laid-out bounds once it is in a window,
  /// else its pane's place in the layout. Not the view's frame alone: a new host (zero-sized
  /// until laid out) resizes it on attach.
  private func initialSurfaceSize(of view: GhosttySurfaceNSView) -> CGSize? {
    func isDrawable(_ size: CGSize) -> Bool { size.width >= 1 && size.height >= 1 }
    if view.window != nil, isDrawable(view.bounds.size) { return view.bounds.size }
    if let paneSize = offscreenPaneSizes[view.shellID], isDrawable(paneSize) { return paneSize }
    return isDrawable(view.bounds.size) ? view.bounds.size : nil
  }

  /// Axod ended a surface's output stream. If the shell still runs (the client fell behind, or
  /// axod restarted the attachment) reattach; if it exited, the reattach is rejected and the
  /// catalog closes the pane. See `ReattachThrottle` for the rate limit.
  func outputEnded(_ view: GhosttySurfaceNSView) {
    guard isCurrentSurface(view), pendingReattaches[view.shellID] == nil else { return }
    switch reattachThrottle.decide(for: view.shellID, at: .now) {
    case .now:
      reattach(view)
    case .after(let delay):
      let shellID = view.shellID
      pendingReattaches[shellID] = Task { @MainActor [weak self, weak view] in
        guard (try? await Task.sleep(for: delay)) != nil, let self else { return }
        self.pendingReattaches[shellID] = nil
        if let view { self.reattach(view) }
      }
    }
  }

  private func isCurrentSurface(_ view: GhosttySurfaceNSView) -> Bool {
    entries[view.shellID]?.view === view
  }

  private func reattach(_ view: GhosttySurfaceNSView) {
    guard let entry = entries[view.shellID], entry.view === view else { return }
    createSurface(in: view, shell: entry.shell)
  }

  var surfaceCount: Int { entries.count }

  /// Every surface view, shown or not.
  var views: some Collection<GhosttySurfaceNSView> { entries.values.lazy.map(\.view) }

  func view(for shellID: ShellID) -> GhosttySurfaceNSView? { entries[shellID]?.view }


  func hasSurface(for shellID: ShellID) -> Bool {
    entries[shellID]?.view.surface != nil
  }

  /// Asks the shell's surface, if it exists, to become first responder once it is in a window.
  func requestFocus(for shellID: ShellID) {
    entries[shellID]?.view.requestFocus()
  }


  /// Keeps surfaces of Sessions that are not shown sized as if they were, so their programs lay
  /// out for the current window and switching to them needs no resize. Sizing the libghostty
  /// surface (not just the PTY) keeps its grid and the PTY in step; a hidden grid left at the old
  /// size would wrap output written for the new one.
  func sizeOffscreenSurfaces(layouts: [TerminalLayout], terminalAreaSize: CGSize, backingScale: CGFloat) {
    pendingOffscreenSizing?.cancel()
    pendingOffscreenSizing = nil
    guard recordOffscreenGeometry(layouts: layouts, terminalAreaSize: terminalAreaSize, backingScale: backingScale)
    else { return }
    resizeOffscreenSurfaces()
  }

  /// Like `sizeOffscreenSurfaces`, but resizes hidden surfaces only once the geometry has held
  /// still for `offscreenSizingSettleDelay`. A fullscreen or window-drag animation changes the
  /// terminal area every frame; resizing every hidden surface on each one reflows their grids
  /// and sends a SIGWINCH storm to every hidden program while the visible one is animating.
  /// Pane sizes are recorded at once, so a surface reattached meanwhile still gets the new size.
  func scheduleOffscreenSizing(layouts: [TerminalLayout], terminalAreaSize: CGSize, backingScale: CGFloat) {
    let isFirstGeometry = offscreenPaneSizes.isEmpty
    guard recordOffscreenGeometry(layouts: layouts, terminalAreaSize: terminalAreaSize, backingScale: backingScale)
    else { return }
    pendingOffscreenSizing?.cancel()
    pendingOffscreenSizing = nil
    if isFirstGeometry {
      resizeOffscreenSurfaces()
      return
    }
    pendingOffscreenSizing = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: Self.offscreenSizingSettleDelay)
      } catch {
        return
      }
      guard let self else { return }
      self.pendingOffscreenSizing = nil
      self.resizeOffscreenSurfaces()
    }
  }

  /// Records where every pane would be; `false` when the geometry is not drawable yet.
  private func recordOffscreenGeometry(
    layouts: [TerminalLayout], terminalAreaSize: CGSize, backingScale: CGFloat
  ) -> Bool {
    guard terminalAreaSize.width > 0, terminalAreaSize.height > 0, backingScale > 0 else { return false }
    offscreenBackingScale = backingScale
    offscreenPaneSizes = layouts.reduce(into: [:]) { sizes, layout in
      sizes.merge(TerminalPaneGeometry.paneSizes(for: layout, in: terminalAreaSize)) { _, new in new }
    }
    return true
  }

  private func resizeOffscreenSurfaces() {
    for entry in entries.values where entry.view.window == nil {
      sizeOffscreenSurface(entry.view)
    }
  }

  private func sizeOffscreenSurface(_ view: GhosttySurfaceNSView) {
    guard let surface = view.surface, let size = offscreenPaneSizes[view.shellID] else { return }
    let scale = offscreenBackingScale
    let width = UInt32(max(0, size.width * scale))
    let height = UInt32(max(0, size.height * scale))
    guard width > 0, height > 0 else { return }
    ghostty_surface_set_content_scale(surface, scale, scale)
    ghostty_surface_set_size(surface, width, height)
    recordCellSize(of: surface)
    view.didApplySurfaceSize()
  }

  private func recordCellSize(of surface: ghostty_surface_t) {
    let size = ghostty_surface_size(surface)
    guard size.cell_width_px > 0, size.cell_height_px > 0 else { return }
    runtime?.noteCellPixelSize(
      ClientViewport.PixelSize(width: size.cell_width_px, height: size.cell_height_px))
  }


  func updateSize(of view: GhosttySurfaceNSView, contentSize: CGSize) {
    // Without a window AppKit has no backing scale to convert with; an offscreen surface (a
    // hidden Session's pane, or one reattached while hidden) takes its size from the layout.
    guard view.window != nil else {
      sizeOffscreenSurface(view)
      return
    }
    // Match Ghostty's AppKit surface bridge: libghostty renders at framebuffer resolution,
    // so Core Animation must not rescale its layer when the window moves between displays.
    if let window = view.window {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      view.layer?.contentsScale = window.backingScaleFactor
      CATransaction.commit()
    }

    guard let surface = view.surface else { return }
    let fallbackScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    let frameSize = view.frame.size
    let backingFrame = view.convertToBacking(view.frame)
    let scaleX = frameSize.width > 0 ? backingFrame.width / frameSize.width : fallbackScale
    let scaleY = frameSize.height > 0 ? backingFrame.height / frameSize.height : fallbackScale
    ghostty_surface_set_content_scale(surface, scaleX, scaleY)
    let backingSize = view.convertToBacking(contentSize)
    let width = UInt32(max(0, backingSize.width))
    let height = UInt32(max(0, backingSize.height))
    guard width > 0, height > 0 else { return }
    ghostty_surface_set_size(surface, width, height)
    recordCellSize(of: surface)
    view.didApplySurfaceSize()
  }
}
