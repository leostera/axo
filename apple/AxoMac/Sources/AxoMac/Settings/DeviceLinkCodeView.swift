import AppKit
import AxoProtocol
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The code is a private, one-use capability. It is never copied to logs or a relay URL.
struct DeviceLinkCodeView: View {
  let code: HostDeviceLinkCode
  let close: () -> Void
  private let context = CIContext()

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { timeline in
      let active = Double(code.expiresAt) > timeline.date.timeIntervalSince1970 * 1000
      VStack(spacing: 18) {
        Text("Link this Axo").font(.title2.weight(.semibold))
        Text("On your phone, open Profile → Linked Axos → Link another Axo, then scan this code.")
          .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        if active, let qr = image {
          Image(nsImage: qr).interpolation(.none).resizable().scaledToFit()
            .frame(width: 256, height: 256).padding(16).background(.white)
            .privacySensitive().accessibilityLabel("Private Axo device linking code")
        } else {
          ContentUnavailableView("Code expired", systemImage: "qrcode",
            description: Text("Close this window and create a new linking code."))
            .frame(width: 288, height: 288)
        }
        Text("This phone will be able to link devices, approve requests and enter private sign-in details on this computer.")
          .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        Button("Close", action: close).keyboardShortcut(.cancelAction)
      }
      .padding(28).frame(width: 410)
    }
  }

  private var image: NSImage? {
    guard let text = try? code.qrText else { return nil }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage,
      let cg = context.createCGImage(output, from: output.extent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
  }
}
