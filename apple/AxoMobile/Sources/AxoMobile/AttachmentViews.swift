import AxoClient
import AxoMobileModel
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Compact overlapping previews; controls live on the preview, never in a filename/size row.
struct AttachmentStrip: View {
  let files: [PhoneWorkbench.DraftAttachment]
  let detach: (UUID) -> Void
  let retry: (UUID) -> Void
  @State private var selected: UUID?

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: -12) {
        ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
          AttachmentTile(file: file, selected: selected == file.id,
            select: { selected = selected == file.id ? nil : file.id },
            detach: { detach(file.id) }, retry: { retry(file.id) })
            .zIndex(selected == file.id ? 100 : Double(index))
        }
      }
      .padding(.horizontal, 16).padding(.vertical, 8)
    }
    .onChange(of: files.map(\.id)) { _, ids in
      if let selected, !ids.contains(selected) { self.selected = nil }
    }
  }
}

private struct AttachmentTile: View {
  let file: PhoneWorkbench.DraftAttachment
  let selected: Bool
  let select: () -> Void
  let detach: () -> Void
  let retry: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var ready: Bool { if case .ready = file.state { true } else { false } }
  private var status: String {
    switch file.state {
    case .uploading: "Uploading"
    case .ready: "Ready"
    case .failed(let reason): "Upload failed. \(reason)"
    }
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button(action: select) {
        thumbnail
          .saturation(ready ? 1 : 0)
          .opacity(ready ? 1 : 0.45)
          .frame(width: 80, height: 80)
          .background(.quaternary)
          .clipShape(RoundedRectangle(cornerRadius: 14))
          .overlay {
            RoundedRectangle(cornerRadius: 14)
              .strokeBorder(Color.primary.opacity(selected ? 0.3 : 0.12), lineWidth: 0.5)
          }
      }
      .buttonStyle(.plain)
      .accessibilityLabel(file.name)
      .accessibilityValue(status)
      .accessibilityHint("Tap to show the remove button")
      .accessibilityIdentifier("attachment-preview")
      .accessibilityAction(named: "Remove attachment", detach)
      .overlay {
        switch file.state {
        case .uploading:
          ProgressView().tint(.primary).padding(10)
            .background(.regularMaterial, in: Circle())
            .accessibilityLabel("Uploading \(file.name)")
            .accessibilityIdentifier("attachment-uploading")
            .allowsHitTesting(false)
        case .failed:
          if file.canRetry {
            Button(action: retry) {
              Image(systemName: "arrow.clockwise").font(.body.weight(.semibold))
                .frame(width: 44, height: 44).background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry \(file.name)")
            .accessibilityIdentifier("attachment-retry")
          } else {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
              .accessibilityLabel(status)
              .allowsHitTesting(false)
          }
        case .ready: EmptyView()
        }
      }
      if selected {
        Button(action: detach) {
          Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white).frame(width: 22, height: 22).background(.black.opacity(0.8), in: Circle())
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .offset(x: 8, y: -8)
        .accessibilityLabel("Remove \(file.name)")
        .accessibilityIdentifier("attachment-remove")
      }
    }
    .frame(width: 80, height: 80)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: ready)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("attachment")
  }

  @ViewBuilder private var thumbnail: some View {
    if let thumbnail = file.thumbnail, let image = UIImage(data: thumbnail) {
      Image(uiImage: image).resizable().scaledToFill()
    } else {
      Image(systemName: file.mimeType.hasPrefix("image/") ? "photo" : "doc")
        .font(.system(size: 28)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

  /// The pictures on the clipboard, each as the first image type its item has: a screenshot is a
  /// PNG, a picture copied from Photos or Safari is whatever it was.
  static func pasted(_ items: [[String: Any]]) -> [File] {
    items.enumerated().compactMap { index, item in
      let pictures = item.compactMap { key, value -> (UTType, Data)? in
        guard let type = UTType(key), type.conforms(to: .image) else { return nil }
        if let data = value as? Data { return (type, data) }
        if let image = value as? UIImage, let png = image.pngData() { return (.png, png) }
        return nil
      }
      // PNG, JPEG, GIF and WebP before a type a model cannot read.
      let readable: [UTType] = [.png, .jpeg, .gif, .webP]
      guard let (type, data) = pictures.min(by: { (readable.firstIndex(of: $0.0) ?? 9) < (readable.firstIndex(of: $1.0) ?? 9) })
      else { return nil }
      return picture(data, type: type, base: "pasted-\(index + 1)")
    }
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
