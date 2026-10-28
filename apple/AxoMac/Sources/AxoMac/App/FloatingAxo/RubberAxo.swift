import AppKit
import AxoRubber

/// Axo in the menu bar, made of rubber, while it is pulled: an elastic soft body (LiquidFun,
/// through `AxoRubber`) over the menu bar icon, with the icon's image bent over it. The pull
/// stretches it towards the pointer while its far side holds on, until it pops (`popDistance`):
/// a new Axo comes away under the pointer and this one springs back into the menu bar, wobbling.
/// Let go before that, and it just springs back.
///
/// It is drawn, each frame of the display, in a see-through, click-through panel over the menu
/// bar, while the real icon is hidden.
@MainActor
final class RubberAxo: NSObject {
  /// Pulled this far, in points, it pops.
  static let popDistance: CGFloat = 70

  var onPop: () -> Void = {}
  /// Back in its place, still: the real icon can show again.
  var onRest: () -> Void = {}

  private let rubber: OpaquePointer
  private let image: CGImage
  private let icon: CGRect
  private let panel: NSPanel
  private let surface = CALayer()
  private let origin: CGPoint
  private let scale: CGFloat
  private let columns: Int
  private let rows: Int
  private var held = true
  private var link: CADisplayLink?
  private var lastFrame: CFTimeInterval?
  /// Alive until it is back at rest, whoever let go of it.
  private static var springing: Set<RubberAxo> = []

  /// Over `icon` (screen points), showing `image`, grabbed at `grab`.
  init?(icon: CGRect, image: CGImage, grab: CGPoint) {
    guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: 0, dy: -2).contains(CGPoint(x: icon.midX, y: icon.midY)) })
      ?? NSScreen.main,
      let rubber = axo_rubber_create(Float(icon.minX), Float(icon.minY), Float(icon.width), Float(icon.height))
    else { return nil }
    self.rubber = rubber
    self.image = image
    self.icon = icon
    origin = screen.frame.origin
    scale = screen.backingScaleFactor
    columns = Int(axo_rubber_columns(rubber))
    rows = Int(axo_rubber_rows(rubber))
    panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    super.init()
    axo_rubber_grab(rubber, Float(grab.x), Float(grab.y))
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.isRestorable = false
    panel.hidesOnDeactivate = false
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
    view.wantsLayer = true
    surface.contentsScale = scale
    surface.contentsGravity = .resize
    view.layer?.addSublayer(surface)
    panel.contentView = view
    draw()
    panel.orderFrontRegardless()
    let link = view.displayLink(target: self, selector: #selector(frame(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
    Self.springing.insert(self)
  }

  /// From where it is pulled towards its place: the way it pulls back.
  private(set) var pull: CGVector = .zero

  /// How far it is pulled, from 0 to 1 when it pops.
  var tension: CGFloat { min(1, CGFloat(axo_rubber_stretch(rubber)) / Self.popDistance) }

  func move(to point: CGPoint) {
    guard held else { return }
    axo_rubber_move(rubber, Float(point.x), Float(point.y))
    pull = CGVector(dx: icon.midX - point.x, dy: icon.midY - point.y)
  }

  /// Let go before it popped.
  func letGo() {
    guard held else { return }
    held = false
    axo_rubber_let_go(rubber)
  }

  private func close() {
    link?.invalidate()
    link = nil
    panel.orderOut(nil)
    axo_rubber_destroy(rubber)
    Self.springing.remove(self)
  }

  // MARK: Each frame

  @objc private func frame(_ link: CADisplayLink) {
    let now = link.timestamp
    let seconds = min(lastFrame.map { now - $0 } ?? 1 / 60, 0.05)
    lastFrame = now
    axo_rubber_step(rubber, Float(seconds))
    if held, CGFloat(axo_rubber_stretch(rubber)) >= Self.popDistance {
      held = false
      axo_rubber_let_go(rubber)
      onPop()
    }
    if axo_rubber_at_rest(rubber) {
      onRest()
      return close()
    }
    draw()
  }

  private func draw() {
    var xy = [Float](repeating: 0, count: columns * rows * 2)
    axo_rubber_points(rubber, &xy)
    let points = stride(from: 0, to: xy.count, by: 2).map { CGPoint(x: CGFloat(xy[$0]), y: CGFloat(xy[$0 + 1])) }
    let xs = points.map(\.x), ys = points.map(\.y)
    let area = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
      .insetBy(dx: -2, dy: -2).integral
    let width = Int(area.width * scale), height = Int(area.height * scale)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -area.minX, y: -area.minY)
    context.interpolationQuality = .high
    // The grid in the icon's own space, so the image is drawn in its rectangle at the origin.
    let local = points.map { CGPoint(x: $0.x - icon.minX, y: $0.y - icon.minY) }
    context.translateBy(x: icon.minX, y: icon.minY)
    MeshWarp.draw(image, size: icon.size, columns: columns, rows: rows, points: local, in: context)
    surface.contents = context.makeImage()
    surface.frame = CGRect(x: area.minX - origin.x, y: area.minY - origin.y, width: area.width, height: area.height)
  }
}
