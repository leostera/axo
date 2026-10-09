import AxoCore
import ImageIO
import UIKit

/// Decode budgets are fixed by the UI's purpose, never by file metadata.
enum PhotoThumbnailResolution: Int {
    case composer = 256
    case message = 512
    case fullScreen = 2048
}

enum PhotoThumbnail {
    static func decode(_ url: URL, resolution: PhotoThumbnailResolution) throws -> UIImage {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 40_000_000 / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: resolution.rawValue,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else {
            throw FileTransferError.message("Unsupported image or more than 40 megapixels. Export the original to inspect it separately.")
        }
        return UIImage(cgImage: image)
    }
}
