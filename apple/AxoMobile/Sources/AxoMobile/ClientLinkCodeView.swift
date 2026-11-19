import AxoMobileModel
import AxoProtocol
import CoreImage.CIFilterBuiltins
import SwiftUI

struct ClientLinkCodeView: View {
  let code: ClientDeviceLinkCode
  let model: DeviceLinkingModel
  let useExistingHost: () -> Void
  private let context = CIContext()

  var body: some View {
    NavigationStack {
      TimelineView(.periodic(from: .now, by: 1)) { timeline in
        VStack(spacing: 24) {
          Text("Link this Axo with your phone").font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)
          Text("On your existing phone, open Profile → Linked Axos → Link another Axo, then scan this code.")
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
          if Double(code.candidate.expiresAt) > timeline.date.timeIntervalSince1970 * 1000, let image {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
              .frame(maxWidth: 280, maxHeight: 280).padding(16).background(.white)
              .privacySensitive().accessibilityLabel("Private device linking code")
          } else {
            ContentUnavailableView("Code expired", systemImage: "qrcode")
          }
          ProgressView("Waiting for approval")
          Button("Use another computer instead", action: useExistingHost)
          Text("No pairing phone yet? Show a linking code in the other Axo’s Linked Axos settings, then scan it with this device.")
            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
          Text("Signing in alone does not let this device approve actions. Keep this private code on screen until linking finishes.")
            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
          Spacer(minLength: 0)
        }.padding(24)
      }
      .navigationTitle("Link this Axo").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { Button("Cancel") { Task { await model.cancelWaiting() } } }
      }
    }
    .task(id: code.id) {
      while !Task.isCancelled, model.phase == .waiting {
        await model.poll()
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
      }
    }
  }

  private var image: UIImage? {
    guard let text = try? code.qrText else { return nil }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage, let cg = context.createCGImage(output, from: output.extent) else { return nil }
    return UIImage(cgImage: cg)
  }
}
