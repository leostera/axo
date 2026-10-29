import AxoSquishy
import CoreGraphics
import simd

/// The squishy Axo's body: its mesh as a Bullet soft body (`AxoSquishy`), with air inside and a
/// memory of its shape. Model space, in points, x right, y up, z towards the viewer.
@MainActor
final class SquishyBody {
  let mesh: SquishyMesh
  private let body: OpaquePointer

  init(mesh: SquishyMesh = .axo()) {
    self.mesh = mesh
    let vertices = mesh.vertices.flatMap { [$0.x, $0.y, $0.z] }
    let triangles = mesh.triangles.flatMap { [Int32($0.x), Int32($0.y), Int32($0.z)] }
    body = axo_squishy_create(vertices, Int32(mesh.vertices.count), triangles, Int32(mesh.triangles.count))
  }

  deinit {
    axo_squishy_destroy(body)
  }

  /// Where each vertex is now.
  var positions: [SIMD3<Float>] {
    var xyz = [Float](repeating: 0, count: mesh.vertices.count * 3)
    axo_squishy_positions(body, &xyz)
    return (0..<mesh.vertices.count).map { SIMD3(xyz[$0 * 3], xyz[$0 * 3 + 1], xyz[$0 * 3 + 2]) }
  }

  /// How far it is, on average, from its shape, in points.
  var wobble: Float { axo_squishy_wobble(body) }

  func step(_ seconds: Double) { axo_squishy_step(body, Float(seconds)) }
  /// 1 is as made; more blows it up.
  func inflate(_ inflation: CGFloat) { axo_squishy_set_inflation(body, Float(inflation)) }
  func poke(at point: CGPoint) { axo_squishy_poke(body, Float(point.x), Float(point.y)) }
  func grab(at point: CGPoint) { axo_squishy_grab(body, Float(point.x), Float(point.y)) }
  func pull(to point: CGPoint) { axo_squishy_pull_to(body, Float(point.x), Float(point.y)) }
  func letGo() { axo_squishy_let_go(body) }
  /// It landed at `speed` points a second: it squashes and springs back.
  func land(speed: CGFloat) { axo_squishy_land(body, Float(speed)) }
  /// Its window sped up by `change` points a second.
  func jolt(_ change: CGVector) { axo_squishy_jolt(body, Float(change.dx), Float(change.dy)) }
}
