import AxoMac
import CoreGraphics
import Foundation
import Metal
import RiveRuntime

/// Plays one artboard of the mascot file offscreen and reads each frame back as a `CGImage`.
///
/// The menu bar and the Dock only take images, so the state machine runs here instead of in a
/// view: `nextFrame(advancingBy:)` advances it, draws it into a Metal texture and copies the
/// pixels out. Frames are requested one at a time; the renderer coalesces overlapping
/// submissions and would drop a waiting continuation.
@MainActor
public final class MascotFramePlayer: MascotFrameSource {
  public let pixelSize: CGSize
  private let device: any MTLDevice
  private let rive: Rive
  private let renderer: any RiveUIRendererProtocol
  private let texture: any MTLTexture
  private var lastPixels: Data?

  public init(file: File, artboardName: String, stateMachineName: String, pixelSize: CGSize, device: any MTLDevice) async throws {
    let artboard = try await file.createArtboard(artboardName)
    let stateMachine = try await artboard.createStateMachine(stateMachineName)
    rive = try await Rive(file: file, artboard: artboard, stateMachine: stateMachine)
    renderer = rive.makeRenderer()
    self.device = device
    self.pixelSize = pixelSize

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: MTLRiveColorPixelFormat(),
      width: Int(pixelSize.width),
      height: Int(pixelSize.height),
      mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    // Discrete GPUs cannot share texture memory with the CPU; managed textures are synchronized
    // with a blit before reading.
    descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      throw MascotError.textureUnavailable
    }
    self.texture = texture
  }

  /// Advances the state machine and draws it. Returns nil when the frame is unchanged.
  public func nextFrame(advancingBy seconds: TimeInterval) async throws -> CGImage? {
    rive.stateMachine.advance(by: seconds)
    // A skipped frame is one the renderer had nothing new to draw for.
    guard let pixels = try await draw(), pixels != lastPixels else { return nil }
    lastPixels = pixels
    return Self.image(from: pixels, size: pixelSize)
  }

  private func draw() async throws -> Data? {
    let configuration = RiveUIRendererConfiguration(rive: rive, drawableSize: pixelSize)
    let texture = UncheckedTexture(texture: self.texture)
    let synchronizes = !device.hasUnifiedMemory
    return try await withCheckedThrowingContinuation { continuation in
      let once = ResumeOnce(continuation)
      renderer.draw(
        configuration,
        to: self.texture,
        from: device,
        onDraw: { commandBuffer in
          if synchronizes, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture.texture)
            blit.endEncoding()
          }
          commandBuffer.addCompletedHandler { buffer in
            if let error = buffer.error {
              once.resume(throwing: error)
            } else {
              once.resume(returning: texture.pixels())
            }
          }
        },
        onSkipped: { once.resume(returning: nil) },
        onError: { error in once.resume(throwing: error) })
    }
  }

  /// Rive draws premultiplied BGRA (`MTLRiveColorPixelFormat`).
  private static func image(from pixels: Data, size: CGSize) -> CGImage? {
    guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
    let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    return CGImage(
      width: Int(size.width),
      height: Int(size.height),
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: Int(size.width) * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
      provider: provider,
      decode: nil,
      shouldInterpolate: true,
      intent: .defaultIntent)
  }
}

public enum MascotError: Error {
  case missingFile
  case metalUnavailable
  case textureUnavailable
}

/// The texture is only read on the command buffer's completion, after the GPU is done with it.
private struct UncheckedTexture: @unchecked Sendable {
  let texture: any MTLTexture

  func pixels() -> Data {
    let width = texture.width
    let height = texture.height
    var data = Data(count: width * height * 4)
    data.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      texture.getBytes(
        base,
        bytesPerRow: width * 4,
        from: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0)
    }
    return data
  }
}

/// The renderer reports through exactly one of its callbacks, but on a background thread; this
/// keeps a stray second call from resuming the continuation twice.
private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Data?, any Error>?

  init(_ continuation: CheckedContinuation<Data?, any Error>) {
    self.continuation = continuation
  }

  func resume(returning value: Data?) {
    take()?.resume(returning: value)
  }

  func resume(throwing error: any Error) {
    take()?.resume(throwing: error)
  }

  private func take() -> CheckedContinuation<Data?, any Error>? {
    lock.lock()
    defer { lock.unlock() }
    let taken = continuation
    continuation = nil
    return taken
  }
}
