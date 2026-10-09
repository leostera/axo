import AxoCore
import Foundation
import UIKit
import UniformTypeIdentifiers

struct ClipboardAttachment {
    enum Kind { case photo, file }
    let source: URL
    let kind: Kind
    private let directory: URL?

    func discardTemporaryCopy() { try? FileManager.default.removeItem(at: directory ?? source) }

    static func kind(of provider: NSItemProvider) -> Kind? {
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) || provider.canLoadObject(ofClass: UIImage.self) { return .photo }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || fileType(of: provider) != nil { return .file }
        return nil
    }

    @MainActor
    static func load(_ provider: NSItemProvider) async throws -> ClipboardAttachment {
        guard let kind = kind(of: provider) else { throw FileTransferError.message("Unsupported clipboard attachment.") }
        if kind == .photo {
            if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                do { return try await loadRepresentation(provider, type: type, kind: .photo) }
                catch { if !provider.canLoadObject(ofClass: UIImage.self) { throw error } }
            }
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadObject(ofClass: UIImage.self) { object, error in
                    Task { @MainActor in
                        do {
                            guard let image = object as? UIImage else { throw error ?? FileTransferError.message("Could not paste image.") }
                            let photo = try PickedPhoto.stageCameraImage(image)
                            continuation.resume(returning: ClipboardAttachment(source: photo.url, kind: .photo, directory: nil))
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { object, error in
                    do {
                        let url: URL?
                        if let value = object as? URL { url = value }
                        else if let value = object as? Data { url = URL(dataRepresentation: value, relativeTo: nil) }
                        else if let value = object as? String { url = URL(string: value) }
                        else { url = nil }
                        guard let url, url.isFileURL else { throw error ?? FileTransferError.message("Clipboard file is unavailable.") }
                        continuation.resume(returning: try copy(url, name: provider.suggestedName, kind: .file))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        guard let type = fileType(of: provider) else { throw FileTransferError.message("Clipboard file is unavailable.") }
        return try await loadRepresentation(provider, type: type, kind: .file)
    }

    private static func fileType(of provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            let namedDocument = provider.suggestedName.map { !URL(fileURLWithPath: $0).pathExtension.isEmpty } ?? false
            return type.conforms(to: .data) && !type.conforms(to: .url)
                && (!type.conforms(to: .text) || namedDocument)
        }
    }

    private static func loadRepresentation(_ provider: NSItemProvider, type: String, kind: Kind) async throws -> ClipboardAttachment {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    guard let url else { throw error ?? FileTransferError.message("Could not paste attachment.") }
                    // Provider URLs expire when this callback returns. Own a private
                    // copy here, before resuming the asynchronous staging pipeline.
                    var name = provider.suggestedName
                    if let suggested = name, URL(fileURLWithPath: suggested).pathExtension.isEmpty,
                       let suffix = UTType(type)?.preferredFilenameExtension {
                        name = "\(suggested).\(suffix)"
                    }
                    continuation.resume(returning: try copy(url, name: name, kind: kind))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func copy(_ source: URL, name: String?, kind: Kind) throws -> ClipboardAttachment {
        guard source.isFileURL else { throw FileTransferError.message("Only local clipboard files can be attached.") }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 25 * 1024 * 1024 else {
            throw FileTransferError.message("Paste a regular file of at most 25 MiB.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let filename = URL(fileURLWithPath: name ?? source.lastPathComponent).lastPathComponent
            let target = directory.appendingPathComponent(filename.isEmpty || filename == "." || filename == ".." ? "attachment" : filename)
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 25 * 1024 * 1024 + 1) ?? Data()
            guard !data.isEmpty, data.count <= 25 * 1024 * 1024 else { throw FileTransferError.message("Clipboard file exceeds 25 MiB.") }
            guard data.count == size else { throw FileTransferError.message("Clipboard file changed while copying. Paste it again.") }
            try data.write(to: target, options: [.atomic, .completeFileProtection])
            return ClipboardAttachment(source: target, kind: kind, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
