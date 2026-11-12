import AxoMascotVector
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@MainActor
final class AxoMascotVectorTests: XCTestCase {
  func testTheNativeMaskContainsTheEyesAndSmileButNotTheCanvas() {
    let path = AxoMascotMark().path(in: CGRect(x: 0, y: 0, width: 1064, height: 604))
    XCTAssertTrue(path.contains(CGPoint(x: 455 - 96, y: 695 - 326)))
    XCTAssertTrue(path.contains(CGPoint(x: 797 - 96, y: 695 - 326)))
    XCTAssertTrue(path.contains(CGPoint(x: 626 - 96, y: 751 - 326)))
    XCTAssertFalse(path.contains(CGPoint(x: 626 - 96, y: 550 - 326)), "the face's interior stays transparent in the Mark")
    XCTAssertFalse(path.contains(.zero))
  }

  func testRedAccentColorsOnlyMascotInkNotARectangularBackground() throws {
    let renderer = ImageRenderer(content: AxoMascotMark().fill(Color(red: 1, green: 0, blue: 0)).frame(width: 40, height: 40))
    renderer.scale = 2
    let image = try XCTUnwrap(renderer.cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    let count = image.width * image.height
    let ink = (0..<count).filter { pixels[$0 * 4 + 3] > 0 }
    XCTAssertGreaterThan(ink.count, count / 20)
    XCTAssertLessThan(ink.count, count / 2, "never a filled square or silhouette")
    for index in [0, image.width - 1, count - image.width, count - 1] {
      XCTAssertEqual(pixels[index * 4 + 3], 0, "all canvas corners are transparent")
    }
    XCTAssertTrue(ink.allSatisfy { pixels[$0 * 4] > 0 && pixels[$0 * 4 + 1] == 0 && pixels[$0 * 4 + 2] == 0 })
    if let output = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"] {
      let url = URL(fileURLWithPath: output).appendingPathComponent("mascot-red.png")
      let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
      CGImageDestinationAddImage(destination, image, nil)
      XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
  }

  func testZeroSizeIsEmptyAndASquarePreservesTheWideMascotAspectRatio() {
    XCTAssertTrue(AxoMascotMark().path(in: .zero).isEmpty)
    let bounds = AxoMascotMark().path(in: CGRect(x: 0, y: 0, width: 40, height: 40)).boundingRect
    XCTAssertGreaterThan(bounds.width, bounds.height * 1.5)
    XCTAssertGreaterThan(bounds.minY, 0)
    XCTAssertLessThan(bounds.maxY, 40)
  }
}
