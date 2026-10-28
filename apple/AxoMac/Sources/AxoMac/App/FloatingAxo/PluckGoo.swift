import AppKit
import AxoGoo

/// The goo Axo stretches out of the menu bar on while it is plucked: a particle fluid (LiquidFun,
/// through `AxoGoo`), viscous and elastic, held by a small "hand" of particles at the icon and a
/// bigger one moved with Axo. Pulled, it draws out into a strand that thins and necks until it
/// breaks; then each half flows back into whichever end it holds on to. Let go before that, and it
/// pulls Axo back into the icon.
///
/// It is drawn, each frame of the display, into a see-through, click-through panel over the icon's
/// screen, under Axo's own panel.
@MainActor
final class PluckGoo: NSObject {
  /// About how far it stretches before it snaps, for how strained Axo looks.
  static let typicalSnap: CGFloat = 170
  /// How long it is drawn after it snapped, at most.
  private static let lingering: TimeInterval = 1.2
  /// Let go early, Axo is pulled back on this spring (per second squared per point, and per
  /// second), a little under critical damping so it lands with a wobble.
  private static let returnStiffness: CGFloat = 260
  private static let returnDamping: CGFloat = 26

  /// Each frame while it holds Axo: where Axo is, which is where the goo pulls it to when let go
  /// early.
  var onStep: (CGPoint) -> Void = { _ in }
  var onSnap: () -> Void = {}
  /// Let go too early: Axo is back in the icon.
  var onReturned: () -> Void = {}
  /// After the snap: where Axo is now, for its end of the goo.
  var axoPosition: () -> CGPoint = { .zero }

  private enum Phase {
    case stretching
    /// Let go early: Axo is pulled home, at this velocity.
    case returning(velocity: CGVector)
    case snapped(at: CFTimeInterval)
    /// Axo is back in: the rest of the goo is swallowed up into the menu bar.
    case swallowed(at: CFTimeInterval)
  }

  private let goo: OpaquePointer
  private let panel: NSPanel
  private let surface = CALayer()
  /// The screen's corner: the panel covers the screen, from there.
  private let origin: CGPoint
  private let scale: CGFloat
  private let anchor: CGPoint
  private var axo: CGPoint
  private var phase = Phase.stretching
  private var link: CADisplayLink?
  private var lastFrame: CFTimeInterval?
  /// Alive until it has been taken back in, whoever let go of it.
  private static var drawing: Set<PluckGoo> = []

  init?(from anchor: CGPoint, to head: CGPoint) {
    guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: 0, dy: -2).contains(anchor) }) ?? NSScreen.main,
      let goo = axo_goo_create(Float(anchor.x), Float(anchor.y), Float(head.x), Float(head.y))
    else { return nil }
    self.goo = goo
    self.anchor = anchor
    axo = head
    origin = screen.frame.origin
    scale = screen.backingScaleFactor
    panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    super.init()
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.isRestorable = false
    panel.hidesOnDeactivate = false
    // Over the menu bar, which it comes out of.
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
    view.wantsLayer = true
    surface.contentsScale = scale
    surface.contentsGravity = .resize
    view.layer?.addSublayer(surface)
    panel.contentView = view
    panel.orderFrontRegardless()
    let link = view.displayLink(target: self, selector: #selector(frame(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
    Self.drawing.insert(self)
  }

  /// How hard Axo is pulling, from 0 to about 1 when it snaps.
  var tension: CGFloat {
    min(1, hypot(axo.x - anchor.x, axo.y - anchor.y) / Self.typicalSnap)
  }

  /// From Axo towards the icon.
  var pull: CGVector { CGVector(dx: anchor.x - axo.x, dy: anchor.y - axo.y) }

  func move(to point: CGPoint) {
    guard case .stretching = phase else { return }
    axo = point
  }

  /// Let go before it snapped: it pulls Axo home.
  func letGo() {
    guard case .stretching = phase else { return }
    phase = .returning(velocity: .zero)
  }

  func close() {
    link?.invalidate()
    link = nil
    panel.orderOut(nil)
    axo_goo_destroy(goo)
    Self.drawing.remove(self)
  }

  // MARK: Each frame

  @objc private func frame(_ link: CADisplayLink) {
    let now = link.timestamp
    let seconds = min(lastFrame.map { now - $0 } ?? 1 / 60, 0.05)
    lastFrame = now
    switch phase {
    case .stretching:
      break
    case .returning(let velocity):
      phase = .returning(velocity: pullHome(velocity, over: CGFloat(seconds)))
    case .snapped:
      axo = axoPosition()
    case .swallowed:
      // Up past the icon, off the top of the screen, taking the goo with it.
      axo = CGPoint(x: anchor.x, y: anchor.y + 80)
    }
    axo_goo_move_axo(goo, Float(axo.x), Float(axo.y))
    axo_goo_step(goo, Float(seconds))

    switch phase {
    case .stretching where !axo_goo_connected(goo):
      phase = .snapped(at: now)
      axo_goo_take_back(goo)
      onSnap()
    case .stretching:
      onStep(axo)
    case .returning(let velocity):
      onStep(axo)
      if hypot(pull.dx, pull.dy) < 8, hypot(velocity.dx, velocity.dy) < 120 {
        phase = .swallowed(at: now)
        axo_goo_take_back(goo)
        onReturned()
      }
    case .snapped(let at), .swallowed(let at):
      if axo_goo_fluid_count(goo) == 0 || now - at > Self.lingering { return close() }
    }
    draw()
  }

  /// The goo, a spring between Axo and the icon, pulling Axo back; the new velocity.
  private func pullHome(_ velocity: CGVector, over seconds: CGFloat) -> CGVector {
    let force = CGVector(
      dx: Self.returnStiffness * pull.dx - Self.returnDamping * velocity.dx,
      dy: Self.returnStiffness * pull.dy - Self.returnDamping * velocity.dy)
    let next = CGVector(dx: velocity.dx + force.dx * seconds, dy: velocity.dy + force.dy * seconds)
    axo = CGPoint(x: axo.x + next.dx * seconds, y: axo.y + next.dy * seconds)
    return next
  }

  private func draw() {
    var bounds = [Float](repeating: 0, count: 4)
    axo_goo_bounds(goo, &bounds)
    let area = CGRect(x: CGFloat(bounds[0]), y: CGFloat(bounds[1]), width: CGFloat(bounds[2]), height: CGFloat(bounds[3]))
    let width = Int((area.width * scale).rounded(.up))
    let height = Int((area.height * scale).rounded(.up))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    guard width > 0, height > 0, let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let pixels = context.data
    else {
      surface.contents = nil
      return
    }
    axo_goo_draw(
      goo, pixels.assumingMemoryBound(to: UInt8.self), Int32(width), Int32(height), bounds[0], bounds[1], Float(scale))
    surface.contents = context.makeImage()
    surface.frame = CGRect(
      x: area.minX - origin.x, y: area.minY - origin.y, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
  }
}
