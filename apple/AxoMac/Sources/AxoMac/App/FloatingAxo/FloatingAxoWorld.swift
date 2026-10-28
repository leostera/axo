import AppKit
import SpriteKit

/// The floating Axo's physics, in screen coordinates (AppKit's: points, y up). One body, Axo;
/// the screen it is on as walls, floor and ceiling; and a ledge on the top of every window it
/// can see, which it lands on from above and passes up through from below.
///
/// SpriteKit steps it, from the SKView in Axo's panel; the world draws nothing itself.
@MainActor
final class FloatingAxoWorld: SKScene, @preconcurrency SKPhysicsContactDelegate {
  private enum Category {
    static let axo: UInt32 = 1 << 0
    static let walls: UInt32 = 1 << 1
    static let ledges: UInt32 = 1 << 2
  }

  /// Points per second squared, down: a light, cartoon gravity.
  static let gravity: CGFloat = -2600
  /// How often the window ledges are read again.
  private static let ledgeRefresh: TimeInterval = 0.25

  var onStep: () -> Void = {}
  /// Touched down hard enough to matter: the impulse.
  var onLanded: (CGFloat) -> Void = { _ in }
  /// Came to rest after being thrown.
  var onSettled: () -> Void = {}

  private let axo = SKNode()
  private let walls = SKNode()
  private var ledges: [(ledge: Ledge, node: SKNode)] = []
  private var lastLedgeRead: TimeInterval = 0
  private var held = false
  /// Thrown and not yet at rest.
  private var flying = false
  private var stillSince: TimeInterval?
  private let bodySize: CGSize

  var axoPosition: CGPoint { axo.position }
  var axoRotation: CGFloat { axo.zRotation }

  init(start: CGPoint, bodySize: CGSize) {
    self.bodySize = bodySize
    super.init(size: CGSize(width: 1, height: 1))
    scaleMode = .fill
    backgroundColor = .clear
    // SpriteKit's gravity is in metres per second squared, 150 points to the metre.
    physicsWorld.gravity = CGVector(dx: 0, dy: Self.gravity / 150)
    physicsWorld.contactDelegate = self

    let body = SKPhysicsBody(rectangleOf: CGSize(width: bodySize.width - 10, height: bodySize.height - 6))
    body.restitution = 0.32
    body.friction = 0.6
    body.linearDamping = 0.08
    body.angularDamping = 1.2
    // Thrown, it moves further than its own width in a step: without this it can pass straight
    // through a wall, which is a line.
    body.usesPreciseCollisionDetection = true
    body.categoryBitMask = Category.axo
    body.collisionBitMask = Category.walls | Category.ledges
    body.contactTestBitMask = Category.walls | Category.ledges
    axo.physicsBody = body
    axo.position = start
    addChild(axo)
    addChild(walls)
    fitWalls(to: start)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  // MARK: Held and let go

  /// Carried by the pointer: no gravity, no turning, exactly where it is held.
  func hold(at point: CGPoint) {
    held = true
    flying = false
    stillSince = nil
    guard let body = axo.physicsBody else { return }
    body.isDynamic = false
    axo.position = point
    axo.zRotation = 0
    onStep()
  }

  /// Off it goes at `velocity` (points per second). `freeze` leaves it where it is.
  func letGo(velocity: CGVector, freeze: Bool) {
    held = false
    fitWalls(to: axo.position)
    guard !freeze, let body = axo.physicsBody else { return }
    body.isDynamic = true
    body.velocity = velocity
    // A throw to the side sets it turning, the way a flicked thing does.
    body.angularVelocity = -velocity.dx / 900
    flying = true
  }

  // MARK: The world

  /// Walls, floor and ceiling: the screen under `point`, without the menu bar and the Dock.
  private func fitWalls(to point: CGPoint) {
    let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    guard let area = screen?.visibleFrame else { return }
    walls.physicsBody = SKPhysicsBody(edgeLoopFrom: area)
    walls.physicsBody?.categoryBitMask = Category.walls
    walls.physicsBody?.friction = 0.6
    walls.physicsBody?.restitution = 0.2
  }

  /// The visible tops of ordinary windows (layer 0, so not Axo's own floating panel), front to
  /// back.
  private func readLedges() {
    let mainHeight = NSScreen.screens.first?.frame.height ?? 0
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let windows: [CGRect] = list.compactMap { info in
      guard (info[kCGWindowLayer as String] as? Int) == 0,
        (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
        let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
        let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
        width > 80, height > 40
      else { return nil }
      // Quartz measures from the top of the main screen, down; AppKit from its bottom, up.
      return CGRect(x: x, y: mainHeight - y - height, width: width, height: height)
    }
    let found = WindowLedges.ledges(of: windows)
    guard found != ledges.map(\.ledge) else { return }
    ledges.forEach { $0.node.removeFromParent() }
    ledges = found.map { ledge in
      let node = SKNode()
      node.physicsBody = SKPhysicsBody(edgeFrom: CGPoint(x: ledge.minX, y: ledge.y), to: CGPoint(x: ledge.maxX, y: ledge.y))
      node.physicsBody?.categoryBitMask = Category.ledges
      node.physicsBody?.friction = 0.6
      node.physicsBody?.restitution = 0.2
      addChild(node)
      return (ledge, node)
    }
  }

  override func update(_ currentTime: TimeInterval) {
    if currentTime - lastLedgeRead > Self.ledgeRefresh {
      lastLedgeRead = currentTime
      readLedges()
    }
    // One-way ledges: solid only to an Axo whose bottom is above them.
    let bottom = axo.position.y - bodySize.height / 2
    for (ledge, node) in ledges {
      node.physicsBody?.categoryBitMask = bottom >= ledge.y - 2 ? Category.ledges : 0
    }
  }

  override func didSimulatePhysics() {
    if flying, let body = axo.physicsBody {
      let speed = hypot(body.velocity.dx, body.velocity.dy)
      // Lying still, the solver still leaves it a little jitter (about 10 points a second).
      if speed < 30, abs(body.angularVelocity) < 0.8 {
        stillSince = stillSince ?? ProcessInfo.processInfo.systemUptime
        if ProcessInfo.processInfo.systemUptime - (stillSince ?? 0) > 0.25 {
          stillSince = nil
          if !rightItself(body) {
            flying = false
            onSettled()
          }
        }
      } else {
        stillSince = nil
      }
    }
    if !held { onStep() }
  }

  /// Lying on its side or its head, it hops up and turns upright in the air: a kick up, and
  /// the spin that turns it the rest of the way by the time gravity brings it down. False when
  /// it is upright already.
  private func rightItself(_ body: SKPhysicsBody) -> Bool {
    // From −π to π: how far it is from upright, and which way is shorter.
    let tilt = atan2(sin(axo.zRotation), cos(axo.zRotation))
    guard abs(tilt) > 0.35 else { return false }
    let kick: CGFloat = 420
    let airborne = 2 * kick / -Self.gravity
    body.velocity = CGVector(dx: 0, dy: kick)
    body.angularVelocity = -tilt / airborne
    return true
  }

  func didBegin(_ contact: SKPhysicsContact) {
    onLanded(contact.collisionImpulse)
  }
}
