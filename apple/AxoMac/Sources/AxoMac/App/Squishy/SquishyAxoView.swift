import AppKit
import AxoMascot
import MetalKit

/// The squishy 3D Axo, drawn: its soft body (`SquishyBody`, simulated on the coarse mesh), shown
/// through the fine one (`SquishySkin`) by `SquishyRenderer`, in a see-through Metal view that
/// steps the body and draws it each frame.
///
/// Everything here is in the view's points, its origin in the middle, y up; the body's model
/// points are `zoom` of those.
@MainActor
final class SquishyAxoView: MTKView, MTKViewDelegate {
  /// The skin is the same for every Axo, and slow-ish to make: made once.
  private static let skin = SquishySkin()

  /// Model points to view points: the mesh is about 130 points across, this makes it `size`.
  let zoom: CGFloat
  /// Turned counterclockwise, radians (its window's physics body's).
  var roll: CGFloat = 0
  /// Where it looks, from -1 to 1 each way (right, up).
  var look: CGPoint = .zero

  private let body: SquishyBody
  private let renderer: SquishyRenderer
  private let queue: MTLCommandQueue
  private var face: SquishyRenderer.Frame.Face = .calm
  private var faceUntil: Date?
  private var squeezed = false
  private var blinkAt = Date().addingTimeInterval(.random(in: 2...5))
  private var lastFrame: CFTimeInterval?

  /// Its size when drawn as `width` points across.
  static func size(width: CGFloat) -> CGSize {
    let mesh = skin.coarse.vertices
    let xs = mesh.map(\.x), ys = mesh.map(\.y)
    let across = CGFloat(xs.max()! - xs.min()!), tall = CGFloat(ys.max()! - ys.min()!)
    return CGSize(width: width, height: width * tall / across)
  }

  init?(frame: CGRect, width: CGFloat) {
    let skin = Self.skin
    guard let device = MTLCreateSystemDefaultDevice(), let renderer = SquishyRenderer(mesh: skin.fine, device: device),
      let queue = device.makeCommandQueue()
    else { return nil }
    let xs = skin.coarse.vertices.map(\.x)
    zoom = width / CGFloat(xs.max()! - xs.min()!)
    body = SquishyBody(mesh: skin.coarse)
    self.renderer = renderer
    self.queue = queue
    super.init(frame: frame, device: device)
    colorPixelFormat = SquishyRenderer.pixelFormat
    depthStencilPixelFormat = SquishyRenderer.depthFormat
    sampleCount = SquishyRenderer.sampleCount
    clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    layer?.isOpaque = false
    preferredFramesPerSecond = 60
    delegate = self
  }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  // MARK: Touched

  /// A point in the view, from its middle, as the body's model point (unturned, unzoomed).
  private func model(_ point: CGPoint) -> CGPoint {
    let c = cos(-roll), s = sin(-roll)
    return CGPoint(x: (point.x * c - point.y * s) / zoom, y: (point.x * s + point.y * c) / zoom)
  }

  /// Poked at `point` (from its middle): that part of it dents in.
  func poke(at point: CGPoint) { body.poke(at: model(point)) }
  /// Held at `point` (from its middle) until `letGo`: its window carries it from there, so the
  /// rest of it hangs and wobbles.
  func grab(at point: CGPoint) {
    let at = model(point)
    body.grab(at: at)
    body.pull(to: at)
  }
  func letGo() { body.letGo() }
  /// Its window sped up by `change` points a second (screen, y up).
  func jolt(_ change: CGVector) {
    let c = cos(-roll), s = sin(-roll)
    body.jolt(CGVector(dx: (change.dx * c - change.dy * s) / zoom, dy: (change.dx * s + change.dy * c) / zoom))
  }
  /// Landed at `speed` points a second.
  func land(speed: CGFloat) { body.land(speed: speed / zoom) }
  /// Blown up `scale` times its size.
  func inflate(_ scale: CGFloat) { body.inflate(scale) }

  /// Pulls the face for a reaction, for about as long as the flat Axo's.
  func react(_ reaction: MascotReaction) {
    switch reaction {
    case .giggle, .happy: show(.happy, for: 0.7)
    case .annoyed: show(.squeezed, for: MascotPokes.annoyedFor)
    case .scream: show(.scream, for: 0.9)
    }
  }

  /// Squeezing its eyes shut (nearly bursting), until told otherwise.
  func setSqueezed(_ squeezed: Bool) { self.squeezed = squeezed }

  private func show(_ face: SquishyRenderer.Frame.Face, for seconds: TimeInterval) {
    self.face = face
    faceUntil = Date().addingTimeInterval(seconds)
  }

  // MARK: Each frame

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    let now = CACurrentMediaTime()
    let elapsed = min(1.0 / 20, lastFrame.map { now - $0 } ?? 1.0 / 60)
    lastFrame = now
    body.step(elapsed)
    guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
      let commands = queue.makeCommandBuffer()
    else { return }
    let positions = Self.skin.fineVertices(for: body.positions)
    renderer.draw(positions, frame: frame(), pass: pass, commands: commands)
    commands.present(drawable)
    commands.commit()
  }

  private func frame() -> SquishyRenderer.Frame {
    let date = Date()
    if let faceUntil, date > faceUntil {
      face = .calm
      self.faceUntil = nil
    }
    var frame = SquishyRenderer.Frame(size: bounds.size, scale: window?.backingScaleFactor ?? 2)
    frame.zoom = Float(zoom)
    frame.roll = Float(roll)
    frame.look = SIMD2(Float(look.x), Float(look.y))
    frame.face = squeezed ? .squeezed : face
    // A blink: shut and open over 0.14 s, every few seconds.
    let blinking = date.timeIntervalSince(blinkAt)
    if blinking > 0.14 {
      blinkAt = date.addingTimeInterval(.random(in: 2.5...6))
    } else if blinking > 0 {
      frame.blink = Float(sin(blinking / 0.14 * .pi))
    }
    return frame
  }
}
