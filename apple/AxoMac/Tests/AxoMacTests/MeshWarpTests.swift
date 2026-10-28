import XCTest

@testable import AxoMac

final class MeshWarpTests: XCTestCase {
  private let size = CGSize(width: 28, height: 16)

  func testTheAffineTakesOneTriangleOntoTheOther() throws {
    let from = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10)]
    let to = [CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 25), CGPoint(x: -5, y: 5)]
    let transform = try XCTUnwrap(MeshWarp.affine(from: from, to: to))
    for (a, b) in zip(from, to) {
      let mapped = a.applying(transform)
      XCTAssertEqual(mapped.x, b.x, accuracy: 0.001)
      XCTAssertEqual(mapped.y, b.y, accuracy: 0.001)
    }
    XCTAssertNil(MeshWarp.affine(from: from, to: [to[0], to[0], to[1]]))
  }

  /// A solid image warped over `points`, into a 56 x 32 canvas; the alpha of each pixel.
  private func draw(points: (Int, Int) -> CGPoint) -> (alpha: [UInt8], width: Int) {
    let image = CGContext(
      data: nil, width: 28, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    image.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    image.fill(CGRect(origin: .zero, size: size))
    let canvas = CGContext(
      data: nil, width: 56, height: 32, bitsPerComponent: 8, bytesPerRow: 56 * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let grid = (0..<3).flatMap { row in (0..<4).map { column in points(column, row) } }
    MeshWarp.draw(image.makeImage()!, size: size, columns: 4, rows: 3, points: grid, in: canvas)
    let bytes = canvas.data!.assumingMemoryBound(to: UInt8.self)
    return ((0..<(56 * 32)).map { bytes[$0 * 4 + 3] }, 56)
  }

  func testAtRestItDrawsTheImageWhereItIs() {
    let drawn = draw { column, row in CGPoint(x: 28 * CGFloat(column) / 3, y: 16 * CGFloat(row) / 2) }
    // The canvas's rows run from the top; the image is in its bottom left 28 x 16.
    func alpha(x: Int, yFromBottom y: Int) -> UInt8 { drawn.alpha[(31 - y) * drawn.width + x] }
    XCTAssertEqual(alpha(x: 14, yFromBottom: 8), 255)
    XCTAssertEqual(alpha(x: 9, yFromBottom: 5), 255, "no seam where triangles meet")
    XCTAssertEqual(alpha(x: 40, yFromBottom: 8), 0)
    XCTAssertEqual(alpha(x: 14, yFromBottom: 24), 0)
  }

  func testStretchedItCoversTheStretchedGrid() {
    // The right column pulled out to the canvas's right edge.
    let drawn = draw { column, row in CGPoint(x: column == 3 ? 56 : 28 * CGFloat(column) / 3, y: 16 * CGFloat(row) / 2) }
    XCTAssertEqual(drawn.alpha[(31 - 8) * drawn.width + 45], 255)
  }
}
