#!/usr/bin/env swift
// Builds every icon size from axo-logo-original.jpeg. Run from this directory: swift make-icons.swift
//
// The original has its rounded-square shape baked in, with black corners. Both platforms apply
// their own shape, so the artwork is cut out of the original's rounded square and placed on a
// flat grey square (iOS and the web) or inside a rounded square with margin (macOS).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: "axo-logo-original.jpeg") as CFURL, nil)
  .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }!
let sourceSize = CGFloat(source.width)  // square
let space = CGColorSpace(name: CGColorSpace.sRGB)!
/// The original's flat background (223 in sRGB), drawn in the same colour space so the two match exactly.
let grey = CGColor(colorSpace: space, components: [223 / 255, 223 / 255, 223 / 255, 1])!

/// A rounded square with continuous-looking corners (a superellipse), `rect` in CG coordinates.
func squircle(_ rect: CGRect, exponent: Double = 5) -> CGPath {
  let path = CGMutablePath()
  let steps = 360
  for step in 0...steps {
    let angle = Double(step) / Double(steps) * 2 * .pi
    let c = cos(angle), s = sin(angle)
    let x = rect.midX + rect.width / 2 * CGFloat(copysign(pow(abs(c), 2 / exponent), c))
    let y = rect.midY + rect.height / 2 * CGFloat(copysign(pow(abs(s), 2 / exponent), s))
    step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
  }
  path.closeSubpath()
  return path
}

func render(size: Int, opaque: Bool, artFraction: CGFloat, rounded: Bool) -> CGImage {
  let info = (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue
  let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
  context.interpolationQuality = .high
  let canvas = CGFloat(size)
  let box = CGRect(x: (canvas - canvas * artFraction) / 2, y: (canvas - canvas * artFraction) / 2,
                   width: canvas * artFraction, height: canvas * artFraction)
  if rounded {
    context.addPath(squircle(box))
    context.clip()
  }
  context.setFillColor(grey)
  context.fill(box)
  // Keep only the original's rounded square, a hair inside its edge; the black corners stay out.
  let inset = box.width * 0.012
  context.saveGState()
  context.addPath(squircle(box.insetBy(dx: inset, dy: inset)))
  context.clip()
  context.draw(source, in: box)
  context.restoreGState()
  return context.makeImage()!
}

func write(_ image: CGImage, to path: String) {
  try? FileManager.default.createDirectory(
    at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
  let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, image, nil)
  precondition(CGImageDestinationFinalize(destination), "could not write \(path)")
}

// iOS: one flat 1024 square; the system rounds it.
write(render(size: 1024, opaque: true, artFraction: 1, rounded: false), to: "ios/AppIcon.appiconset/icon-1024.png")
try! """
{
  "images" : [
    { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

""".write(toFile: "ios/AppIcon.appiconset/Contents.json", atomically: true, encoding: .utf8)

// macOS: a rounded square 80% of the canvas on a transparent one, at every size the system asks for.
var macImages: [String] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
  let pixels = points * scale
  let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
  write(render(size: pixels, opaque: false, artFraction: 0.8, rounded: true), to: "macos/AppIcon.appiconset/\(name)")
  macImages.append(#"    { "filename" : "\#(name)", "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(points)x\#(points)" }"#)
}
try! """
{
  "images" : [
\(macImages.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

""".write(toFile: "macos/AppIcon.appiconset/Contents.json", atomically: true, encoding: .utf8)

// The web: favicons and the touch icon, flat squares the browser rounds itself.
for (name, size) in [("favicon-32.png", 32), ("favicon-192.png", 192), ("apple-touch-icon.png", 180), ("icon-512.png", 512)] {
  write(render(size: size, opaque: true, artFraction: 1, rounded: false), to: "web/\(name)")
}
print("done")
