#if DEBUG
import AxoCore
import CryptoKit
import Foundation

/// Synthetic, in-process HTTP fixture for simulator UI tests; never connects to a relay.
@MainActor
enum SharedFilePreview {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--axo-file-draft-preview") || FilePreviewProtocol.isPhoto }
    static func makeClient() async throws -> SessionFilesClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FilePreviewProtocol.self]
        let client = SessionFilesClient(endpoint: try RelayEndpoint("https://files-preview.invalid"), cookie: "preview-cookie", configuration: configuration)
        client.cancelAllUploads()
        for draft in client.drafts { client.removeDraft(draft.id) }
        client.selectSession("preview-session")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent(FilePreviewProtocol.isPhoto ? "draft-photo.png" : "draft-report.md")
        try FilePreviewProtocol.content.write(to: source)
        if FilePreviewProtocol.isPhoto { try await PhotoPublication.addSelectedPhoto(source, to: client, isCurrentDestination: { true }) }
        else { await client.addFile(source) }
        return client
    }
}

private actor PreviewFileServer {
    struct Reply: Sendable { let body: Data; let mediaType: String }
    private var state = "pending"
    private var revision = 1
    func respond(_ request: URLRequest) throws -> Reply {
        let path = request.url!.path
        if request.httpMethod == "PUT" || path.hasSuffix("/complete") { state = "ready"; revision += 1 }
        if request.httpMethod == "DELETE" { state = "deleted"; revision += 1 }
        if path.hasSuffix("/content") && request.httpMethod == "GET" { return Reply(body: FilePreviewProtocol.content, mediaType: "text/markdown") }
        let file: [String: Any] = ["id": "00000000-0000-4000-8000-000000000002", "sessionId": "preview-session", "filename": FilePreviewProtocol.isPhoto ? "draft-photo.png" : "draft-report.md",
            "mediaType": FilePreviewProtocol.mediaType, "byteLength": FilePreviewProtocol.content.count,
            "sha256": SHA256.hash(data: FilePreviewProtocol.content).map { String(format: "%02x", $0) }.joined(),
            "origin": "phone", "createdAt": 0, "state": state]
        if path.hasSuffix("/authorize") {
            let id = "00000000-0000-4000-8000-000000000002"
            let checksum = Data(SHA256.hash(data: FilePreviewProtocol.content)).base64EncodedString()
            return Reply(body: try JSONSerialization.data(withJSONObject: ["file": file, "upload": [
                "url": "https://\(String(repeating: "a", count: 32)).r2.cloudflarestorage.com/test-files/files/\(id)/synthetic?X-Amz-Algorithm=AWS4-HMAC-SHA256",
                "expiresAt": Int64(Date().timeIntervalSince1970 * 1000) + 60_000,
                "headers": ["Content-Type": FilePreviewProtocol.mediaType, "Content-Length": String(FilePreviewProtocol.content.count), "If-None-Match": "*", "x-amz-checksum-sha256": checksum],
            ]]), mediaType: "application/json")
        }
        let body: [String: Any] = path.hasSuffix("/files") ? ["files": state == "pending" ? [] : [file], "nextCursor": NSNull(), "revision": revision] : file
        return Reply(body: try JSONSerialization.data(withJSONObject: body), mediaType: "application/json")
    }
}

private final class FilePreviewProtocol: URLProtocol, @unchecked Sendable {
    static var isPhoto: Bool { ProcessInfo.processInfo.arguments.contains("--axo-photo-draft-preview") }
    static var mediaType: String { isPhoto ? "image/png" : "text/markdown" }
    static let content: Data = isPhoto
        ? Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGQsAAAAASUVORK5CYII=")!
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
