import AxoRubber
import XCTest

/// Rubber Axo is a real soft body, so these run it: a 28 x 16 icon at (200, 400), grabbed by its
/// right side.
final class AxoRubberTests: XCTestCase {
  private let icon = CGRect(x: 200, y: 400, width: 28, height: 16)
  private var rubber: OpaquePointer!
  private var columns: Int { Int(axo_rubber_columns(rubber)) }
  private var rows: Int { Int(axo_rubber_rows(rubber)) }

  override func setUp() {
    rubber = axo_rubber_create(Float(icon.minX), Float(icon.minY), Float(icon.width), Float(icon.height))
  }

  override func tearDown() {
    axo_rubber_destroy(rubber)
  }

  private var points: [CGPoint] {
    var xy = [Float](repeating: 0, count: columns * rows * 2)
    axo_rubber_points(rubber, &xy)
    return stride(from: 0, to: xy.count, by: 2).map { CGPoint(x: CGFloat(xy[$0]), y: CGFloat(xy[$0 + 1])) }
  }

  /// The particle at the middle of a column, 0 the left edge.
  private func middle(ofColumn column: Int) -> CGPoint { points[(rows / 2) * columns + column] }

  private func run(_ seconds: Double) {
    for _ in 0..<Int(seconds * 60) { axo_rubber_step(rubber, 1.0 / 60) }
  }

  private func pullRight(by distance: CGFloat) {
    let grab = CGPoint(x: icon.maxX - 3, y: icon.midY)
    axo_rubber_grab(rubber, Float(grab.x), Float(grab.y))
    axo_rubber_move(rubber, Float(grab.x + distance), Float(grab.y))
    run(0.3)
  }

  func testAtRestItIsAGridOverTheIcon() {
    XCTAssertEqual(columns, 15)
    XCTAssertEqual(rows, 9)
    XCTAssertEqual(points.first!.x, icon.minX, accuracy: 0.01)
    XCTAssertEqual(points.first!.y, icon.minY, accuracy: 0.01)
    XCTAssertEqual(points.last!.x, icon.maxX, accuracy: 0.01)
    XCTAssertEqual(points.last!.y, icon.maxY, accuracy: 0.01)
    run(0.5)
    XCTAssertTrue(axo_rubber_at_rest(rubber))
    XCTAssertEqual(axo_rubber_stretch(rubber), 0)
  }

  func testPulledItStretchesWhileTheFarSideHoldsOn() {
    pullRight(by: 50)
    XCTAssertFalse(axo_rubber_at_rest(rubber))
    XCTAssertEqual(CGFloat(axo_rubber_stretch(rubber)), 50, accuracy: 3)
    XCTAssertLessThan(abs(middle(ofColumn: 0).x - icon.minX), 2, "the far side holds")
    XCTAssertGreaterThan(middle(ofColumn: columns / 2).x - icon.midX, 8, "the middle stretches along")
  }

  func testLetGoItSpringsBackPastItsPlaceAndSettles() throws {
    pullRight(by: 50)
    axo_rubber_let_go(rubber)
    var leftmost = CGFloat.infinity
    var settled: Double?
    for frame in 1...(3 * 60) {
      axo_rubber_step(rubber, 1.0 / 60)
      leftmost = min(leftmost, middle(ofColumn: columns - 1).x)
      if axo_rubber_at_rest(rubber) {
        settled = Double(frame) / 60
        break
      }
    }
    XCTAssertLessThan(leftmost, icon.maxX - 2, "it overshoots its place: rubber wobbles")
    let time = try XCTUnwrap(settled)
    XCTAssertLessThan(time, 2.5)
    XCTAssertEqual(middle(ofColumn: columns - 1).x, icon.maxX, accuracy: 0.3)
  }
}
