#if DEBUG
import AxoCore
import CryptoKit
import Foundation
import UIKit
import UniformTypeIdentifiers

/// Synthetic, in-process HTTP fixture for simulator UI tests; never connects to a relay.
@MainActor
enum SharedFilePreview {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--axo-file-draft-preview") || FilePreviewProtocol.isPhoto || isPastePreview }
    static var isPastePreview: Bool { ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--axo-paste-") }) }
    static var isInlinePhotoPreview: Bool { ProcessInfo.processInfo.arguments.contains("--axo-inline-photo-preview") }
    static func makeClient() async throws -> SessionFilesClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FilePreviewProtocol.self]
        let client = SessionFilesClient(endpoint: try RelayEndpoint("https://files-preview.invalid"), cookie: "preview-cookie", configuration: configuration)
        client.cancelAllUploads()
        for draft in client.drafts { client.removeDraft(draft.id) }
        client.selectSession("preview-session")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pasteFile = ProcessInfo.processInfo.arguments.contains("--axo-paste-file-preview")
        defer { if !pasteFile { try? FileManager.default.removeItem(at: directory) } }
        let source = directory.appendingPathComponent(pasteFile ? "pasted-report.md" : FilePreviewProtocol.isPhoto ? "draft-photo.png" : "draft-report.md")
        try FilePreviewProtocol.content.write(to: source)
        if isPastePreview {
            if pasteFile {
                let provider = NSItemProvider()
                provider.suggestedName = source.lastPathComponent
                provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                    completion(source.absoluteString.data(using: .utf8), nil)
                    return nil
                }
                UIPasteboard.general.setItemProviders([provider], localOnly: true, expirationDate: nil)
            }
            else if FilePreviewProtocol.isPhoto { UIPasteboard.general.image = UIImage(data: FilePreviewProtocol.content) }
            else { UIPasteboard.general.string = " pasted" }
            return client
        }
        if FilePreviewProtocol.isPhoto { try await PhotoPublication.addSelectedPhoto(source, to: client, isCurrentDestination: { true }) }
        else { await client.addFile(source) }
        return client
    }
}

private actor PreviewFileServer {
    struct Reply: Sendable { let body: Data; let mediaType: String }
    private var state = "pending"
    private var revision = 1
    private var attributes: [String: Any] = [:]
    func respond(_ request: URLRequest) throws -> Reply {
        let path = request.url!.path
        if request.httpMethod == "POST", path.hasSuffix("/uploads") {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count > 0 { body = Data(buffer.prefix(count)) }
            }
            attributes = (try JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        }
        if request.httpMethod == "PUT" || path.hasSuffix("/complete") { state = "ready"; revision += 1 }
        if request.httpMethod == "DELETE" { state = "deleted"; revision += 1 }
        if path.hasSuffix("/content") && request.httpMethod == "GET" { return Reply(body: FilePreviewProtocol.content, mediaType: FilePreviewProtocol.mediaType) }
        let file: [String: Any] = ["id": "00000000-0000-4000-8000-000000000002", "sessionId": "preview-session", "filename": attributes["filename"] ?? (FilePreviewProtocol.isPhoto ? "draft-photo.png" : "draft-report.md"),
            "mediaType": attributes["mediaType"] ?? FilePreviewProtocol.mediaType, "byteLength": attributes["byteLength"] ?? FilePreviewProtocol.content.count,
            "sha256": attributes["sha256"] ?? SHA256.hash(data: FilePreviewProtocol.content).map { String(format: "%02x", $0) }.joined(),
            "origin": "phone", "createdAt": 0, "state": state]
        if path.hasSuffix("/authorize") {
            let id = "00000000-0000-4000-8000-000000000002"
            let hex = file["sha256"] as! String
            let checksum = Data(stride(from: 0, to: 64, by: 2).map { offset in UInt8(String(hex.dropFirst(offset).prefix(2)), radix: 16)! }).base64EncodedString()
            return Reply(body: try JSONSerialization.data(withJSONObject: ["file": file, "upload": [
                "url": "https://\(String(repeating: "a", count: 32)).r2.cloudflarestorage.com/test-files/files/\(id)/synthetic?X-Amz-Algorithm=AWS4-HMAC-SHA256",
                "expiresAt": Int64(Date().timeIntervalSince1970 * 1000) + 60_000,
                "headers": ["Content-Type": file["mediaType"] as! String, "Content-Length": String(file["byteLength"] as! Int), "If-None-Match": "*", "x-amz-checksum-sha256": checksum],
            ]]), mediaType: "application/json")
        }
        let body: [String: Any] = path.hasSuffix("/files") ? ["files": state == "pending" ? [] : [file], "nextCursor": NSNull(), "revision": revision] : file
        return Reply(body: try JSONSerialization.data(withJSONObject: body), mediaType: "application/json")
    }
}

private final class FilePreviewProtocol: URLProtocol, @unchecked Sendable {
    static var isPhoto: Bool { ProcessInfo.processInfo.arguments.contains("--axo-photo-draft-preview") || ProcessInfo.processInfo.arguments.contains("--axo-inline-photo-preview") || ProcessInfo.processInfo.arguments.contains("--axo-paste-image-preview") }
    static var mediaType: String { isPhoto ? "image/png" : "text/markdown" }
    static let content: Data = isPhoto
        ? Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAAXNSR0IArs4c6QAAADhlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAACKADAAQAAAABAAAACAAAAAC2TFloAAAAF0lEQVQYGWM0SjnxnwEPYMIjB5YaHgoAcgACbQpAV0UAAAAASUVORK5CYII=")!
        : Data("# Synthetic shared report\n\nThis document exists only in the simulator fixture.\n".utf8)
    private static let server = PreviewFileServer()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "files-preview.invalid" || request.url?.host == String(repeating: "a", count: 32) + ".r2.cloudflarestorage.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task {
            do {
                let reply = try await Self.server.respond(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.mediaType, "Cache-Control": "private, no-store"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply.body)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}
#endif
