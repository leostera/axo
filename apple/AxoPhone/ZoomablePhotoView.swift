import SwiftUI
import UIKit

struct ZoomablePhotoView: UIViewRepresentable {
    let image: UIImage
    let resetGeneration: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PhotoScrollView {
        let view = PhotoScrollView(image: image)
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "photoZoomView"
        view.accessibilityLabel = "Image preview"
        return view
    }

    func updateUIView(_ view: PhotoScrollView, context: Context) {
        view.setImage(image)
        if context.coordinator.resetGeneration != resetGeneration {
            context.coordinator.resetGeneration = resetGeneration
            view.setZoomScale(1, animated: true)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var resetGeneration = 0
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? PhotoScrollView)?.photo }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { (scrollView as? PhotoScrollView)?.centerPhoto() }
    }
}

final class PhotoScrollView: UIScrollView {
    let photo = UIImageView()
    private var fittedViewport = CGSize.zero

    init(image: UIImage) {
        super.init(frame: .zero)
        minimumZoomScale = 1
        maximumZoomScale = 6
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        photo.image = image
        photo.isAccessibilityElement = true
        photo.accessibilityLabel = "Photo"
        addSubview(photo)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapPhoto(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(image:)") }

    func setImage(_ image: UIImage) {
        guard photo.image !== image else { return }
        photo.image = image
        fittedViewport = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, let image = photo.image,
              image.size.width > 0, image.size.height > 0 else { return }
        if fittedViewport != bounds.size {
            fittedViewport = bounds.size
            // Fit on first presentation/rotation, not on every streaming or
            // layout update: those must not erase a user's zoom and pan.
            setZoomScale(1, animated: false)
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            photo.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            centerPhoto()
            contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        } else { centerPhoto() }
    }

    func centerPhoto() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        let insets = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != insets { contentInset = insets }
        let value = String(format: "%.1f×", zoomScale)
        if accessibilityValue != value { accessibilityValue = value }
    }

    @objc private func doubleTapPhoto(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale { setZoomScale(minimumZoomScale, animated: true); return }
        let scale: CGFloat = 2.5
        let point = gesture.location(in: photo)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height), animated: true)
    }
}
