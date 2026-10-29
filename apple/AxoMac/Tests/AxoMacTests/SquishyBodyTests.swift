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

  func testCarriedByOneSideItHangsBackAndLetGoItSpringsBack() {
    let body = axo()
    let width = { (b: SquishyBody) in b.positions.map(\.x).max()! - b.positions.map(\.x).min()! }
    let rest = width(body)
    // Held by its right side, and its window pulled right faster and faster: the rest lags.
    body.grab(at: CGPoint(x: 30, y: 0))
    var widest = rest
    for _ in 0..<30 {
      body.jolt(CGVector(dx: 40, dy: 0))
      body.step(1.0 / 60)
      widest = max(widest, width(body))
    }
    XCTAssertGreaterThan(widest, rest + 5, "stretched")
    body.letGo()
    run(body, 3)
    XCTAssertEqual(width(body), rest, accuracy: 2, "back")
  }

  func testLandingSquashesIt() {
    let body = axo()
    let height = { (b: SquishyBody) in b.positions.map(\.y).max()! - b.positions.map(\.y).min()! }
    let rest = height(body)
    body.land(speed: 400)
    var lowest = rest
    for _ in 0..<30 {
      body.step(1.0 / 60)
      lowest = min(lowest, height(body))
    }
    XCTAssertLessThan(lowest, rest - 3, "squashed")
    run(body, 3)
    XCTAssertEqual(height(body), rest, accuracy: 1, "back")
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
