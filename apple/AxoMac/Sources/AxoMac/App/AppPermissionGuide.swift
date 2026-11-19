import AppKit
import CoreGraphics
import SwiftUI

/// A file-backed, copy-only drag source. The URL is the real permission owner, not an alias,
/// proxy bundle or icon-only pasteboard item that would grant the wrong executable.
@MainActor
final class PermissionDragTile: NSView, NSDraggingSource {
  let executable: URL
  private let icon: NSImage
  private var down: NSEvent?
  init(executable: URL) {
    self.executable = executable
    // The preview can be friendly without changing the file/identity granted by macOS.
    icon = NSApplication.shared.applicationIconImage ?? NSWorkspace.shared.icon(forFile: executable.path)
    super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 44))
    setAccessibilityLabel("Drag axod into the permission list")
  }
  required init?(coder: NSCoder) { nil }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlBackgroundColor.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    icon.draw(in: NSRect(x: 10, y: 6, width: 32, height: 32))
    ("axod — Axo’s background service" as NSString).draw(at: NSPoint(x: 52, y: 14),
      withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
  }
  override func mouseDown(with event: NSEvent) { down = event }
  override func mouseDragged(with event: NSEvent) {
    guard let down, hypot(event.locationInWindow.x - down.locationInWindow.x,
      event.locationInWindow.y - down.locationInWindow.y) >= 3 else { return }
    let item = fileDragItem()
    beginDraggingSession(with: [item], event: down, source: self).animatesToStartingPositionsOnCancelOrFail = true
    self.down = nil
  }
  /// Keep the preview image independent of the file whose OS permission is being granted.
  func fileDragItem() -> NSDraggingItem {
    let item = NSDraggingItem(pasteboardWriter: executable as NSURL)
    item.setDraggingFrame(bounds, contents: icon)
    return item
  }
  func draggingSession(_ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

private struct PermissionTile: NSViewRepresentable {
  let executable: URL
  func makeNSView(context: Context) -> PermissionDragTile { PermissionDragTile(executable: executable) }
  func updateNSView(_ nsView: PermissionDragTile, context: Context) {}
}

struct PermissionGuideView: View {
  let item: SetupItem
  let executable: URL
  let close: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(item.title).font(.headline)
        Spacer()
        Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close guide")
      }
      Text("Drag this installed copy of axod into the list, then turn it on.")
        .font(.callout).foregroundStyle(.secondary)
      PermissionTile(executable: executable).frame(height: 44)
      HStack {
        Text("Checks the running axod, not Axo.app. If an older axod entry is already enabled, remove that entry in System Settings and add this installed copy. Axo never changes permissions for you.")
        .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([executable]) }
          .controlSize(.small)
      }
    }
    .padding(16)
    .frame(width: 360)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
  }
}

@MainActor
final class AppPermissionGuide {
  static let shared = AppPermissionGuide()
  private var panel: NSPanel?
  private var timer: Timer?
  private var expires = Date.distantPast

  func show(item: SetupItem, executable: URL, recheck: @escaping () -> Void,
    granted: @escaping () -> Bool) throws
  {
    guard let url = item.settingsURL,
      !executable.path.contains("/AppTranslocation/"),
      (try? executable.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) != true,
      FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw NSError(domain: "axo.setup", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Install Axo in Applications before adding its axod helper."])
    }
    guard NSWorkspace.shared.open(url) else {
      throw NSError(domain: "axo.setup", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Could not open System Settings. Open Privacy & Security manually."])
    }
    close()
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 392, height: 160),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    AppWindowPlacement.applyAppAppearance(panel)
    panel.hidesOnDeactivate = false
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    let content = NSHostingController(rootView: PermissionGuideView(item: item, executable: executable,
      close: { [weak self] in self?.close() }))
    panel.contentViewController = content
    panel.setContentSize(content.view.fittingSize)
    self.panel = panel
    expires = Date().addingTimeInterval(180)
    position()
    panel.orderFrontRegardless()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        if granted() || Date() > self.expires { self.close(); return }
        self.position()
        recheck()
      }
    }
    recheck()
  }
  func close() {
    timer?.invalidate(); timer = nil
    panel?.close(); panel = nil
  }

  /// Window bounds/owner PID are public metadata, even without Screen Recording. Never read
  /// titles, capture pixels or move System Settings; overlay the guide near its bottom edge.
  private func position() {
    guard let panel else { return }
    let ids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").map(\.processIdentifier))
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in windows {
      guard let pid = window[kCGWindowOwnerPID as String] as? Int32, ids.contains(pid),
        (window[kCGWindowLayer as String] as? Int) == 0,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let quartz = CGRect(dictionaryRepresentation: bounds as CFDictionary), quartz.width > 300, quartz.height > 200,
        let primary = NSScreen.screens.first else { continue }
      let frame = NSRect(x: quartz.minX, y: primary.frame.maxY - quartz.maxY, width: quartz.width, height: quartz.height)
      panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 12))
      return
    }
    AppWindowPlacement.centerOnPrimaryScreen(panel)
  }
}
