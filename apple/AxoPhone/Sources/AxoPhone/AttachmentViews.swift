import AxoClient
import AxoPhoneModel
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The files in the message box, above it: a thumbnail or a page, the name, and how the upload
/// goes, each with a way to take it out.
struct AttachmentStrip: View {
  let files: [PhoneWorkbench.DraftAttachment]
  let detach: (UUID) -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(files) { file in chip(file) }
      }
      .padding(.horizontal, 12)
    }
  }

  private func chip(_ file: PhoneWorkbench.DraftAttachment) -> some View {
    HStack(spacing: 8) {
      Group {
        if let thumbnail = file.thumbnail, let image = UIImage(data: thumbnail) {
          Image(uiImage: image).resizable().scaledToFill()
        } else {
          Image(systemName: "doc").font(.system(size: 17)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(.secondary.opacity(0.12))
        }
      }
      .frame(width: 40, height: 40)
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .opacity(file.state == .uploading ? 0.6 : 1)
      VStack(alignment: .leading, spacing: 2) {
        Text(file.name).font(.footnote).lineLimit(1)
        status(file).font(.caption2)
      }
      .frame(maxWidth: 150, alignment: .leading)
      Button { detach(file.id) } label: {
        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Remove \(file.name)")
    }
    .padding(4).padding(.trailing, 2)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    .accessibilityIdentifier("attachment")
  }

  @ViewBuilder private func status(_ file: PhoneWorkbench.DraftAttachment) -> some View {
    switch file.state {
    case .uploading:
      HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Uploading…") }.foregroundStyle(.secondary)
    case .ready:
      Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).foregroundStyle(.secondary)
    case .failed(let reason):
      Text(reason).foregroundStyle(.orange).lineLimit(1)
    }
  }
}

/// Turns what the person picked into files to upload: photos as JPEG when the camera kept them as
/// HEIC (models read JPEG, not HEIC), files as they are, each with a thumbnail if it is a picture.
enum AttachmentImport {
  typealias File = (data: Data, name: String, mimeType: String, thumbnail: Data?)

  static func photos(_ items: [PhotosPickerItem]) async -> [File] {
    var files: [File] = []
    for (index, item) in items.enumerated() {
      guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
      let type = item.supportedContentTypes.first ?? .jpeg
      let base = "photo-\(index + 1)"
      files.append(picture(data, type: type, base: base))
    }
    return files
  }

  /// A photo just taken, as JPEG.
  static func camera(_ image: UIImage) -> File {
    let jpeg = image.jpegData(compressionQuality: 0.85) ?? Data()
    return (jpeg, "photo.jpg", "image/jpeg", thumbnailData(image))
  }

  static func files(_ urls: [URL]) -> [File] {
    urls.compactMap { url in
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      guard let data = try? Data(contentsOf: url) else { return nil }
      let type = UTType(filenameExtension: url.pathExtension) ?? .data
      if type.conforms(to: .image) { return picture(data, type: type, base: url.deletingPathExtension().lastPathComponent) }
      return (data, url.lastPathComponent, type.preferredMIMEType ?? "application/octet-stream", nil)
    }
  }

  /// A picture as a model can read it: PNG, JPEG, GIF and WebP as they are, anything else
  /// (HEIC, TIFF…) as JPEG.
  private static func picture(_ data: Data, type: UTType, base: String) -> File {
    let image = UIImage(data: data)
    let thumbnail = image.flatMap(thumbnailData)
    let readable: [UTType: String] = [.png: "png", .jpeg: "jpg", .gif: "gif", .webP: "webp"]
    if let ext = readable[type], let mime = type.preferredMIMEType {
      return (data, "\(base).\(ext)", mime, thumbnail)
    }
    if let image, let jpeg = image.jpegData(compressionQuality: 0.85) {
      return (jpeg, "\(base).jpg", "image/jpeg", thumbnail)
    }
    return (data, "\(base).\(type.preferredFilenameExtension ?? "bin")", type.preferredMIMEType ?? "application/octet-stream", nil)
  }

  private static func thumbnailData(_ image: UIImage) -> Data? {
    let side: CGFloat = 120
    let scale = side / max(image.size.width, image.size.height, 1)
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
      .jpegData(compressionQuality: 0.7)
  }
}
