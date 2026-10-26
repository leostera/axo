import AxoMac
import CoreGraphics
import Foundation
import Metal
import RiveRuntime

/// Plays the mascot from the app bundle's `axo.riv` with the Rive runtime.
@MainActor
public final class RiveMascotAnimation: MascotAnimation {
  /// The state machine every artboard runs (`MascotContract` in packages/axo-mascot).
  public static let stateMachine = "Mascot"

  private let source: () throws -> Data
  private var loaded: (file: File, device: any MTLDevice)?

  public init(source: @escaping () throws -> Data = RiveMascotAnimation.bundledFile) {
    self.source = source
  }

  public nonisolated static func bundledFile() throws -> Data {
    guard let url = Bundle.main.url(forResource: "axo", withExtension: "riv") else {
      throw MascotError.missingFile
    }
    return try Data(contentsOf: url)
  }

  public func makeFrameSource(artboard: String, pixelSize: CGSize) async throws -> any MascotFrameSource {
    let (file, device) = try await load()
    return try await MascotFramePlayer(
      file: file,
      artboardName: artboard,
      stateMachineName: Self.stateMachine,
      pixelSize: pixelSize,
      device: device)
  }

  public func makePuppet(artboard: String) -> (any MascotPuppet)? {
    guard let data = try? source(), let file = try? RiveFile(data: data, loadCdn: false) else { return nil }
    return RiveMascotPuppet(file: file, artboard: artboard)
  }

  /// One worker and file for every artboard.
  public func load() async throws -> (file: File, device: any MTLDevice) {
    if let loaded { return loaded }
    guard let device = MTLCreateSystemDefaultDevice() else { throw MascotError.metalUnavailable }
    let file = try await File(source: .data(try source()), worker: Worker(device: device))
    loaded = (file, device)
    return (file, device)
  }
}
