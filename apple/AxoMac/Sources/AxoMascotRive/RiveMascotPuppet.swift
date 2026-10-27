import AxoMac
import AxoMascot
import RiveRuntime
import SwiftUI

/// An artboard through `RiveViewModel`, which takes state machine inputs (the newer Rive
/// API takes data binding instead, which the generated file does not have).
@MainActor
final class RiveMascotPuppet: MascotPuppet {
  /// Names in `packages/axo-mascot/src/mascot.ts` (`MascotContract`).
  private enum Input {
    static let poke = "poke"
    static let annoyed = "annoyed"
    static let happy = "happy"
    static let tracking = "tracking"
    static let lookX = "lookX"
    static let lookY = "lookY"
    static let loading = "loading"
  }

  private let rive: RiveViewModel

  init(file: RiveFile, artboard: String) {
    rive = RiveViewModel(
      RiveModel(riveFile: file), stateMachineName: RiveMascotAnimation.stateMachine, fit: .contain,
      autoPlay: true, artboardName: artboard)
  }

  var view: AnyView { rive.view() }

  func look(x: Double, y: Double) {
    rive.setInput(Input.lookX, value: min(max(x, -100), 100))
    rive.setInput(Input.lookY, value: min(max(y, -100), 100))
    rive.setInput(Input.tracking, value: true)
  }

  func stopLooking() {
    rive.setInput(Input.tracking, value: false)
  }

  func react(_ reaction: MascotReaction) {
    switch reaction {
    case .giggle: rive.triggerInput(Input.poke)
    case .annoyed: rive.triggerInput(Input.annoyed)
    case .happy: rive.triggerInput(Input.happy)
    }
  }

  func setLoading(_ loading: Bool) {
    rive.setInput(Input.loading, value: loading)
  }
}
