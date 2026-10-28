import AxoGoo
import XCTest

/// The goo is a real fluid, so these run it: pulled from an icon at (200, 400), Axo going down
/// and to the right, as plucking out of the menu bar does.
final class AxoGooTests: XCTestCase {
  private let icon = CGPoint(x: 200, y: 400)
  private var goo: OpaquePointer!

  override func setUp() {
    goo = axo_goo_create(Float(icon.x), Float(icon.y), 200, 394)
  }

  override func tearDown() {
    axo_goo_destroy(goo)
  }

  /// Pulls Axo away at `speed` points a second until it snaps or has gone `distance`; how far it
  /// had gone when it snapped, or nil.
  private func pull(at speed: CGFloat, upTo distance: CGFloat) -> CGFloat? {
    var t: CGFloat = 0
    while true {
      t += 1.0 / 60
      let gone = min(speed * t, distance)
      axo_goo_move_axo(goo, Float(icon.x + 0.6 * gone), Float(icon.y - 6 - 0.8 * gone))
      axo_goo_step(goo, 1.0 / 60)
      if !axo_goo_connected(goo) { return gone }
      if gone >= distance { return nil }
    }
  }

  private var held: (icon: Int32, axo: Int32) {
    var held: [Int32] = [0, 0]
    axo_goo_split(goo, &held)
    return (held[0], held[1])
  }

  func testItStartsInOnePiece() {
    XCTAssertTrue(axo_goo_connected(goo))
    XCTAssertGreaterThan(axo_goo_fluid_count(goo), 200)
    XCTAssertEqual(held.icon, axo_goo_fluid_count(goo))
    XCTAssertEqual(held.axo, axo_goo_fluid_count(goo))
  }

  func testATugStretchesItWithoutSnapping() {
    XCTAssertNil(pull(at: 300, upTo: 70))
    for _ in 0..<30 { axo_goo_step(goo, 1.0 / 60) }
    XCTAssertTrue(axo_goo_connected(goo))
  }

  func testPulledFarItSnaps() throws {
    for speed: CGFloat in [100, 150, 300, 600, 900] {
      setUp()
      let snapped = try XCTUnwrap(pull(at: speed, upTo: 400), "never snapped at \(speed)")
      XCTAssertGreaterThan(snapped, 100, "at \(speed)")
      XCTAssertLessThan(snapped, 260, "at \(speed)")
      XCTAssertEqual(held.icon + held.axo, axo_goo_fluid_count(goo), "nothing is joined to both once it snapped")
      tearDown()
    }
    setUp()
  }

  /// Where it breaks is up to the fluid: pulled out slowly the goo comes with Axo, yanked it stays
  /// at the icon, and in between it necks and snaps in the middle.
  func testWhereItBreaksDependsOnHowFastItIsPulled() throws {
    _ = try XCTUnwrap(pull(at: 100, upTo: 400))
    XCTAssertGreaterThan(held.axo, held.icon * 4)
    tearDown()
    setUp()
    _ = try XCTUnwrap(pull(at: 300, upTo: 400))
    XCTAssertGreaterThan(held.icon, 40)
    XCTAssertGreaterThan(held.axo, 40)
    tearDown()
    setUp()
    _ = try XCTUnwrap(pull(at: 900, upTo: 400))
    XCTAssertGreaterThan(held.icon, held.axo * 4)
  }

  func testOnceSnappedItIsTakenBackIn() throws {
    _ = try XCTUnwrap(pull(at: 300, upTo: 400))
    axo_goo_take_back(goo)
    for _ in 0..<(3 * 60) where axo_goo_fluid_count(goo) > 0 { axo_goo_step(goo, 1.0 / 60) }
    XCTAssertEqual(axo_goo_fluid_count(goo), 0)
  }

  func testItIsDrawnWhiteWithADarkOutlineOnNothing() {
    _ = pull(at: 300, upTo: 60)
    var bounds = [Float](repeating: 0, count: 4)
    axo_goo_bounds(goo, &bounds)
    let width = Int(bounds[2]), height = Int(bounds[3])
    XCTAssertGreaterThan(width, 20)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    axo_goo_draw(goo, &pixels, Int32(width), Int32(height), bounds[0], bounds[1], 1)
    let alphas = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    // Its corners are clear, and it covers some of the area, in white and in ink.
    XCTAssertEqual(alphas.first, 0)
    XCTAssertEqual(alphas.last, 0)
    let opaque = (0..<(width * height)).filter { pixels[$0 * 4 + 3] == 255 }
    XCTAssertGreaterThan(opaque.count, width * height / 10)
    XCTAssertTrue(opaque.contains { pixels[$0 * 4] > 240 }, "white inside")
    XCTAssertTrue(opaque.contains { pixels[$0 * 4] < 40 }, "dark outline")
  }
}
