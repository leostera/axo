import SwiftUI
import UIKit

struct CameraCaptureView: UIViewControllerRepresentable {
    let captured: (UIImage) -> Void
    let cancelled: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image"]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let owner: CameraCaptureView
        init(owner: CameraCaptureView) { self.owner = owner }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { owner.cancelled() }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { owner.cancelled(); return }
            owner.captured(image)
        }
    }
}
