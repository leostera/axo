import SwiftUI
import UIKit

/// Presentation exists only after decoding from the local file used for export.
/// Sent files must first pass SessionFilesClient's integrity and scope checks.
struct PhotoPreviewAsset: Identifiable {
    let id = UUID()
    let image: UIImage
    let original: URL

    init(original: URL) throws {
        self.image = try PhotoThumbnail.decode(original, resolution: .fullScreen)
        self.original = original
    }
}

struct PhotoFullScreenPreview: View {
    let asset: PhotoPreviewAsset
    var removeDraftAttachment: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var zoomReset = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZoomablePhotoView(image: asset.image, resetGeneration: zoomReset).ignoresSafeArea()
            VStack {
                HStack(spacing: 12) {
                    Button { dismiss() } label: { control("xmark") }
                        .accessibilityLabel("Close image preview")
                    Spacer()
                    Menu {
                        Button("Reset zoom", systemImage: "arrow.down.right.and.arrow.up.left") { zoomReset += 1 }
                        if let removeDraftAttachment {
                            Button("Remove attachment from draft", systemImage: "trash", role: .destructive) {
                                dismiss()
                                removeDraftAttachment()
                            }
                        }
                    } label: { control("ellipsis") }
                        .accessibilityLabel("Photo options")
                    ShareLink(item: asset.original) { control("square.and.arrow.down") }
                        .accessibilityLabel("Export original file")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18).padding(.top, 12)
                Spacer()
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
    }

    private func control(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white).frame(width: 48, height: 48)
            .background(.regularMaterial, in: Circle())
            .contentShape(Circle())
    }
}
