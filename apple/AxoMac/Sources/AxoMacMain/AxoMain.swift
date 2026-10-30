import AxoMac
import AxoMascotRive

/// The shipped app's executable entry; all app code lives in the `AxoMac` library.
@main
enum AxoMain {
  @MainActor static func main() {
    AxoAppEntryPoint.main(mascot: RiveMascotAnimation())
  }
}
