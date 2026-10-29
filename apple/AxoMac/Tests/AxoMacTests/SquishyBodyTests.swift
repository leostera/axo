import XCTest
import simd

@testable import AxoMac

@MainActor
final class SquishyBodyTests: XCTestCase {
  private func axo() -> SquishyBody { SquishyBody(mesh: .axo(subdivisions: 3)) }

  private func run(_ body: SquishyBody, _ seconds: Double) {
    for _ in 0..<Int(seconds * 60) { body.step(1.0 / 60) }
  }

  private func volume(_ body: SquishyBody) -> Float {
    SquishyMesh(vertices: body.positions, triangles: body.mesh.triangles).volume
  }

  /// The vertex facing the viewer nearest the middle of its face.
  private func front(_ body: SquishyBody) -> Int {
    body.positions.indices.max { body.positions[$0].z < body.positions[$1].z }!
  }

  func testLeftAloneItKeepsItsShape() {
    let body = axo()
    let rest = volume(body)
    run(body, 2)
    XCTAssertEqual(volume(body), rest, accuracy: rest * 0.08)
    XCTAssertLessThan(body.wobble, 1)
  }

  func testAPokeDentsItAndItComesBack() {
    let body = axo()
    let nose = front(body)
    let before = body.positions[nose].z
    body.poke(at: .zero)
    run(body, 0.08)
    XCTAssertLessThan(body.positions[nose].z, before - 2, "dented")
    run(body, 3)
    XCTAssertEqual(body.positions[nose].z, before, accuracy: 2, "back")
  }

  func testLiftedByItsTopItComesAlongAndLetGoItIsItsShapeAgain() {
    let body = axo()
    let height = { (b: SquishyBody) in b.positions.map(\.y).max()! - b.positions.map(\.y).min()! }
    let middle = { (b: SquishyBody) in b.positions.map(\.y).reduce(0, +) / Float(b.positions.count) }
    let rest = height(body), restMiddle = middle(body)
    body.land(speed: 0)
    // Held by its top and lifted: it comes along, under its weight.
    body.grab(at: CGPoint(x: 0, y: 20))
    body.pull(to: CGPoint(x: 0, y: 40))
    run(body, 1)
    XCTAssertGreaterThan(middle(body), restMiddle + 5, "lifted")
    // Let go, it falls back to the ground and is its own shape again.
    body.letGo()
    run(body, 3)
    XCTAssertEqual(height(body), rest, accuracy: 3, "back")
    XCTAssertEqual(middle(body), restMiddle, accuracy: 3, "down")
  }

  func testOnTheGroundItSitsUnderItsWeightAndLandingSquashesIt() {
    let body = axo()
    let height = { (b: SquishyBody) in b.positions.map(\.y).max()! - b.positions.map(\.y).min()! }
    let made = height(body)
    body.land(speed: 0)
    run(body, 3)
    let sitting = height(body)
    // Held up by the ground: sagging only a little.
    XCTAssertEqual(sitting, made, accuracy: 4, "sitting")
    body.land(speed: 400)
    var lowest = sitting
    for _ in 0..<30 {
      body.step(1.0 / 60)
      lowest = min(lowest, height(body))
    }
    XCTAssertLessThan(lowest, sitting - 3, "squashed")
    run(body, 3)
    XCTAssertEqual(height(body), sitting, accuracy: 1, "back")
  }

  func testBlownUpItGrows() {
    let body = axo()
    let rest = volume(body)
    body.inflate(2)
    run(body, 1.5)
    XCTAssertEqual(volume(body), rest * 8, accuracy: rest * 0.5)
    body.inflate(1)
    run(body, 3)
    XCTAssertEqual(volume(body), rest, accuracy: rest * 0.1)
  }
}
