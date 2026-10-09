import AxoCore
import ImageIO
import MarkdownUI
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct SharedFileCard: View {
    let file: SharedFile
    let client: SessionFilesClient?
    @State private var opening = false
    @State private var localURL: URL?
    @State private var previewURL: URL?
    @State private var showText = false
    @State private var thumbnail: UIImage?
    @State private var previewImage: UIImage?
    @State private var showImage = false
    @State private var error: String?

    private var availability: SharedFile.State { client?.files.first(where: { $0.id == file.id })?.state ?? file.state }
    private var availabilityLabel: String {
        if client?.files.contains(where: { $0.id == file.id }) == true { return availability.rawValue }
        return availability == .ready ? "Tap to check availability" : availability.rawValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: openFile) {
                if file.mediaType.isImage {
                    photoContent
                } else { documentContent }
            }
            .buttonStyle(.plain)
            .disabled(client == nil || availability != .ready || opening)
            if let localURL, !file.mediaType.isImage { ShareLink("Export original file", item: localURL).font(.caption) }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .padding(file.mediaType.isImage ? 0 : 14)
        .background(file.mediaType.isImage ? .clear : ChatColors.surface, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("shared-file-\(file.id)")
        .quickLookPreview($previewURL)
        .onChange(of: availability) { _, state in if state != .ready { localURL = nil; thumbnail = nil } }
        .task(id: "\(client?.storageOrigin.absoluteString ?? ""):\(client?.sessionId ?? ""):\(file.id):\(availability.rawValue)") {
            if file.mediaType.isImage { await loadPhotoPreview() }
        }
        .onDisappear { if !showText && !showImage && previewURL == nil { localURL = nil } }
        .sheet(isPresented: $showText) {
            if let localURL { SafeTextFilePreview(url: localURL, file: file) }
        }
        .sheet(isPresented: $showImage, onDismiss: { previewImage = nil }) {
            if let previewImage {
                VStack {
                    Image(uiImage: previewImage).resizable().scaledToFit()
                    if let localURL { ShareLink("Export original file", item: localURL) }
                }.padding()
            }
        }
    }

    private var documentContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc")
            VStack(alignment: .leading, spacing: 4) {
                Text(file.filename).font(.callout.weight(.medium)).lineLimit(2)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(file.byteLength), countStyle: .file)) · \(file.origin == .host ? "Mac" : "iPhone") · \(availabilityLabel)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if opening { ProgressView() } else { Image(systemName: "arrow.down.doc") }
        }
    }

    @ViewBuilder private var photoContent: some View {
        if let thumbnail {
            Image(uiImage: thumbnail).resizable().scaledToFill()
                .frame(width: 240, height: 240).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .accessibilityLabel("Photo attachment")
                .accessibilityIdentifier("shared-photo-\(file.id)")
        } else {
            VStack(spacing: 10) {
                if opening { ProgressView() }
                else {
                    Image(systemName: "photo").font(.title)
                    Text(availability == .ready ? "Tap to load photo" : "Photo unavailable").font(.caption)
                }
            }
            .frame(width: 240, height: 240)
            .background(ChatColors.surface, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func loadPhotoPreview() async {
        guard let client, availability == .ready else { thumbnail = nil; return }
        opening = true
        error = nil
        defer { opening = false }
        do {
            let url = try await client.open(file)
            try Task.checkCancellation()
            let image = try boundedThumbnail(url, maxPixelSize: 512)
            localURL = url
            thumbnail = image
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription; thumbnail = nil }
        }
    }

    private func openFile() {
        guard let client, !opening else { return }
        opening = true
        error = nil
        Task {
            defer { opening = false }
            do {
                let url = try await client.open(file)
                localURL = url
                try presentPreview(url, mediaType: file.mediaType)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func presentPreview(_ url: URL, mediaType: SharedFile.MediaType) throws {
        switch mediaType {
        case .text, .markdown: showText = true
        case .png, .jpeg: previewImage = try boundedThumbnail(url); showImage = true
        case .pdf: previewURL = url
        case .binary: break // Original-byte export is available; unknown formats are never executed.
        }
    }
}

private func boundedThumbnail(_ url: URL, maxPixelSize: Int = 2048) throws -> UIImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0, width <= 40_000_000 / height,
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixelSize, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
        throw FileTransferError.message("Unsupported image or more than 40 megapixels. Export the original to inspect it separately.")
    }
    return UIImage(cgImage: image)
}

private struct SafeTextFilePreview: View {
    let url: URL
    let file: SharedFile
    @State private var text = ""
    @State private var truncated = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if truncated { Text("Preview limited to 512 KiB. Export to read the complete file.").font(.caption).foregroundStyle(.secondary) }
                    if file.mediaType == .markdown {
                        Markdown(text).markdownImageProvider(OmittedImages()).markdownInlineImageProvider(OmittedImages())
                            .textSelection(.enabled)
                            .environment(\.openURL, OpenURLAction { url in ["https", "http"].contains(url.scheme ?? "") ? .systemAction : .discarded })
                    } else { Text(text).font(.callout.monospaced()).textSelection(.enabled) }
                }.padding(20)
            }
            .navigationTitle(file.filename).navigationBarTitleDisplayMode(.inline)
            .toolbar { ShareLink(item: url) }
            .task {
                let result = await Task.detached {
                    guard let handle = try? FileHandle(forReadingFrom: url) else { return ("Could not open file.", false) }
                    defer { try? handle.close() }
                    let bytes = (try? handle.read(upToCount: 512 * 1024)) ?? Data()
                    return (String(decoding: bytes, as: UTF8.self), file.byteLength > bytes.count)
                }.value
                text = result.0
                truncated = result.1
            }
        }
    }
}

struct SessionFilesView: View {
    let client: SessionFilesClient
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: SharedFile?
    @State private var userIsScrolling = false
    private struct FileScroll: Equatable { let offset: CGFloat; let height: CGFloat; let nearBottom: Bool }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Shared snapshots, not a transcript backup. Ready files remain available when the Mac is offline.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let notice = client.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
                }
                ForEach(client.files) { file in
                    SharedFileCard(file: file, client: client)
                        .swipeActions { Button("Delete", role: .destructive) { deleting = file } }
                }
                if client.nextCursor != nil {
                    Button(client.isLoading ? "Loading…" : "Load earlier files") { Task { await client.loadFiles(earlier: true) } }
                        .disabled(client.isLoading)
                }
                if client.files.isEmpty && !client.isLoading { Text("No shared files yet.").foregroundStyle(.secondary) }
            }
            .onScrollPhaseChange { _, phase in userIsScrolling = phase == .interacting || phase == .decelerating }
            .onScrollGeometryChange(for: FileScroll.self) { geometry in
                let offset = geometry.contentOffset.y + geometry.contentInsets.top
                return FileScroll(offset: offset, height: geometry.contentSize.height,
                                  nearBottom: offset > geometry.contentSize.height - geometry.containerSize.height * 1.5)
            } action: { old, new in
                if userIsScrolling && new.height == old.height && new.offset > old.offset && new.nearBottom {
                    Task { await client.loadFiles(earlier: true) }
                }
            }
            .navigationTitle("Session files")
            .toolbar { Button("Done") { dismiss() } }
            .refreshable { await client.loadFiles() }
            .task { await client.loadFiles() }
            .onChange(of: client.isStale) { _, stale in if stale { Task { await client.loadFiles() } } }
            .onChange(of: client.isLoading) { _, loading in
                if !loading && client.isStale && client.notice == nil { Task { await client.loadFiles() } }
            }
            .confirmationDialog("Delete the cloud copy? This does not erase original/exported files, Pi history, or model-provider copies.", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                if let file = deleting { Button("Delete shared file", role: .destructive) { Task { await client.delete(file); deleting = nil; await client.loadFiles() } } }
            }
        }
    }
}

struct DraftFilesBar: View {
    let client: SessionFilesClient
    let reviewUpload: (UUID) -> Void
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(client.currentDrafts) { draft in
                    DraftAttachmentCard(draft: draft, remove: { client.removeDraft(draft.id) },
                                        retry: { client.retryUpload(draft.id) }, reviewUpload: { reviewUpload(draft.id) })
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct DraftAttachmentCard: View {
    let draft: DraftFile
    let remove: () -> Void
    let retry: () -> Void
    let reviewUpload: () -> Void
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
                    .frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 20))
                    .accessibilityLabel(draft.filename)
                    .overlay(alignment: .topTrailing) { removeButton }
            } else {
                HStack {
                    Label(draft.filename, systemImage: "doc").font(.caption.weight(.semibold)).lineLimit(1)
                    removeButton
                }
            }
            if draft.isQueued { Text("Queued for upload").font(.caption2).foregroundStyle(.secondary) }
            else if draft.isUploading { ProgressView(value: draft.progress) }
            else if let error = draft.error {
                Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                Button("Check/retry upload", action: retry).font(.caption)
            } else if draft.file == nil {
                Text("Local draft · not uploaded").font(.caption2).foregroundStyle(.secondary)
                Button("Review/upload", action: reviewUpload).font(.caption)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("draftAttachment")
        .accessibilityValue(draft.readyFile == nil ? "" : "Uploaded")
        .frame(width: thumbnail == nil ? 210 : 96).padding(thumbnail == nil ? 10 : 0)
        .background(thumbnail == nil ? ChatColors.surface : .clear, in: RoundedRectangle(cornerRadius: 12))
        .task(id: draft.source) { thumbnail = try? boundedThumbnail(draft.source, maxPixelSize: 256) }
    }

    private var removeButton: some View {
        Button(action: remove) {
            Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white).frame(width: 26, height: 26)
                .background(.black.opacity(0.6), in: Circle())
                .frame(width: 44, height: 44).contentShape(Circle())
        }
        .buttonStyle(.plain).accessibilityLabel("Remove \(draft.filename)")
    }
}

/// Photos intentionally publish a bounded JPEG representation; document picking preserves bytes.
struct PickedPhoto: Transferable {
    let url: URL

    @MainActor
    static func stageCameraImage(_ image: UIImage) throws -> PickedPhoto {
        guard image.size.width > 0, image.size.height > 0 else { throw FileTransferError.message("Could not capture photo.") }
        let scale = min(1, 2048 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let bounded = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = bounded.jpegData(compressionQuality: 0.9) else { throw FileTransferError.message("Could not create a JPEG photo attachment.") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("photo-\(UUID().uuidString).jpg")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return PickedPhoto(url: url)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in try stageFile(received.file) }
    }

    static func stageFile(_ sourceURL: URL) throws -> PickedPhoto {
            let size = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 25 * 1024 * 1024 else { throw FileTransferError.message("Photo exceeds 25 MiB.") }
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
                throw FileTransferError.message("Could not create a JPEG photo attachment.")
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("photo-\(UUID().uuidString).jpg")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw FileTransferError.message("Could not stage photo.") }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: url)
                throw FileTransferError.message("Could not save photo.")
            }
            return PickedPhoto(url: url)
    }
}
