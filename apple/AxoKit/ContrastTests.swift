import AxoKit
import SwiftUI
import XCTest

final class ContrastTests: XCTestCase {
  @MainActor func testForkLabelContrastsWithItsRenderedFill() throws {
    for scheme in [ColorScheme.light, .dark] {
      for enabled in [true, false] {
        let view = AxoPrimaryButton("Fork") {}
          .font(.system(size: 18, weight: .medium)).disabled(!enabled)
          .tint(.black).environment(\.colorScheme, scheme).fixedSize()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertGreaterThan(try interiorTextContrast(image), 4.5, "\(scheme), enabled=\(enabled)")
      }
    }
  }
}

/// WCAG relative luminance of opaque interior pixels, excluding the rounded edges and page.
private func interiorTextContrast(_ image: CGImage) throws -> Double {
  let w = image.width, h = image.height
  var rgba = [UInt8](repeating: 0, count: w * h * 4)
  try rgba.withUnsafeMutableBytes { buffer in
    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: w, height: h,
      bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  }
  func linear(_ component: UInt8) -> Double {
    let s = Double(component) / 255
    return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
  }
  var values: [Double] = []
  for y in (h / 4)..<(3 * h / 4) {
    for x in (w / 4)..<(3 * w / 4) {
      let i = 4 * (y * w + x)
      guard rgba[i + 3] == 255 else { continue }
      values.append(0.2126 * linear(rgba[i]) + 0.7152 * linear(rgba[i+1]) + 0.0722 * linear(rgba[i+2]))
    }
  }
  values.sort()
  XCTAssertFalse(values.isEmpty)
  guard !values.isEmpty else { return 1 }
  // Ignore isolated pixels; both ink and fill must occupy a measurable area.
  return (values[values.count * 99 / 100] + 0.05) / (values[values.count / 100] + 0.05)
}
