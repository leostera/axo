import CryptoKit
import Foundation
import Observation

@MainActor @Observable
public final class SessionFilesClient {
    public private(set) var sessionId: String?
    public private(set) var files: [SharedFile] = []
    public private(set) var drafts: [DraftFile] = []
    public private(set) var isLoading = false
    public private(set) var isStale = true
    public private(set) var nextCursor: String?
    public private(set) var notice: String?
    private let endpoint: RelayEndpoint
    private var cookie: String
    private let session: URLSession
    private let configuration: URLSessionConfiguration
    private var uploads: [UUID: Task<Void, Never>] = [:]
    private var uploadQueue: [UUID] = []
    private var listRequestID: UUID?
    private var notificationRevision = 0
    private var loadedRevision = 0
    private var forcedRefresh = 0
    private let cache: URL

    public init(endpoint: RelayEndpoint, cookie: String, configuration: URLSessionConfiguration = .ephemeral) {
        self.endpoint = endpoint
        self.cookie = cookie
        self.configuration = configuration
        self.session = URLSession(configuration: configuration, delegate: PrivateTransferDelegate(), delegateQueue: nil)
        self.cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AxoFiles", isDirectory: true)
        sessionId = UserDefaults.standard.string(forKey: "axo.fileSession.\(endpoint.baseURL.absoluteString)")
        if let directory = try? draftDirectory(), let data = try? Data(contentsOf: directory.appendingPathComponent("drafts.json")),
           let saved = try? JSONDecoder().decode([DraftFile].self, from: data) {
            drafts = saved.compactMap { original in
                var draft = original
                draft.source = directory.appendingPathComponent(draft.id.uuidString)
                guard FileManager.default.fileExists(atPath: draft.source.path) else { return nil }
                if draft.isUploading { draft.fail("Upload interrupted. Check/retry when ready.") }
                return draft
            }
        }
    }
    public var storageOrigin: URL { endpoint.baseURL }
    public func matches(_ endpoint: RelayEndpoint) -> Bool { self.endpoint.baseURL == endpoint.baseURL }
    public func configure(endpoint: RelayEndpoint, cookie: String) { if matches(endpoint) { self.cookie = cookie } }
    public func cancelAllUploads() {
        let queued = uploadQueue
        uploadQueue.removeAll()
        for id in queued { updateDraft(id) { $0.fail("Upload paused. Review/retry when ready.") } }
        for task in uploads.values { task.cancel() }
    }
    public var currentDrafts: [DraftFile] { drafts.filter { $0.sessionId == sessionId } }
    public var readyDrafts: [SharedFile] { currentDrafts.compactMap(\.readyFile) }
    public var canSubmitDrafts: Bool { currentDrafts.allSatisfy { $0.readyFile != nil } }

    public func selectSession(_ id: String) {
        guard id != sessionId else { return }
        sessionId = id
        files = []
        nextCursor = nil
        listRequestID = nil
        isLoading = false
        notice = nil
        notificationRevision = 0
        loadedRevision = 0
        isStale = true
        UserDefaults.standard.set(id, forKey: "axo.fileSession.\(endpoint.baseURL.absoluteString)")
    }
    public func invalidate(sessionId: String, revision: Int? = nil) {
        guard self.sessionId == sessionId else { return }
        if let revision {
            guard revision > loadedRevision, revision > notificationRevision else { return }
            notificationRevision = revision
        } else { forcedRefresh += 1 }
        isStale = true
    }

    public func loadFiles(earlier: Bool = false) async {
        guard let selected = sessionId, !isLoading else { return }
        let cursor = earlier ? nextCursor : nil
        if earlier && cursor == nil { return }
        isLoading = true
        notice = nil
        let requestID = UUID()
        let refresh = forcedRefresh
        listRequestID = requestID
        defer { if listRequestID == requestID { isLoading = false } }
        do {
            var request = try request(session: selected, path: "files")
            if let cursor {
                var parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                parts.queryItems = [URLQueryItem(name: "cursor", value: cursor)]
                request.url = parts.url
            }
            let page: FilePage = try await metadata(request)
            guard sessionId == selected, listRequestID == requestID else { return }
            guard page.files.allSatisfy({ $0.sessionId == selected }) else { throw FileTransferError.message("Wrong file session.") }
            let known = Set(files.map(\.id))
            files = earlier ? files + page.files.filter { !known.contains($0.id) } : page.files
            // The gallery is a bounded cache; next pages remain manually accessible.
            if files.count > 200 { files = Array(files.suffix(200)) }
            nextCursor = page.nextCursor
            loadedRevision = max(loadedRevision, page.revision)
            isStale = refresh != forcedRefresh || notificationRevision > page.revision
            notice = nil
        } catch { if sessionId == selected, listRequestID == requestID { notice = error.localizedDescription } }
    }

    @discardableResult
    public func addFile(_ url: URL) async -> UUID? {
        guard let selected = sessionId else { notice = "Connect to the Mac once to choose a conversation."; return nil }
        guard currentDrafts.count < 8, drafts.count < 32 else { notice = "Choose at most eight attachments per prompt and keep at most 32 unsent files. Discard older drafts before adding more."; return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard size.isRegularFile == true, let bytes = size.fileSize, bytes <= 25 * 1024 * 1024 else { throw FileTransferError.message("Choose a regular file up to 25 MiB.") }
            let used = currentDrafts.reduce(0) { total, draft in total + ((try? draft.source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            let allBytes = drafts.reduce(0) { total, draft in total + ((try? draft.source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            guard allBytes + bytes <= 200 * 1024 * 1024 else { throw FileTransferError.message("Unsent attachment storage reached 200 MiB. Discard old drafts before adding more.") }
            guard used + bytes <= 50 * 1024 * 1024 else { throw FileTransferError.message("Prompt attachments exceed 50 MiB.") }
            let directory = try draftDirectory()
            let id = UUID()
            let staged = directory.appendingPathComponent(id.uuidString)
            try FileManager.default.copyItem(at: url, to: staged)
            drafts.append(DraftFile(id: id, sessionId: selected, filename: url.lastPathComponent, source: staged))
            persistDrafts()
            return id
        } catch { notice = error.localizedDescription; return nil }
    }

    /// Calling this is explicit publication consent. Staging alone never starts an HTTP request.
    public func retryUpload(_ id: UUID) {
        guard uploads[id] == nil, !uploadQueue.contains(id), let draft = drafts.first(where: { $0.id == id }) else { return }
        if uploads.count >= 3 {
            uploadQueue.append(id)
            updateDraft(id) { $0.transfer = .queued }
            return
        }
        updateDraft(id) { $0.transfer = .uploading(progress: 0, reservation: $0.file) }
        uploads[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.finishUpload(id) }
            do { try await self.publishDraft(draft) }
            catch { self.updateDraft(id) { $0.fail(error.localizedDescription) } }
        }
    }

    private func finishUpload(_ id: UUID) {
        uploads.removeValue(forKey: id)
        if let next = uploadQueue.first { uploadQueue.removeFirst(); retryUpload(next) }
    }

    private struct UploadAttributes: Encodable {
        let requestId: UUID
        let filename: String
        let mediaType: SharedFile.MediaType
        let byteLength: Int
        let sha256: String

        func matches(_ file: SharedFile, sessionId: String) -> Bool {
            file.sessionId == sessionId && file.filename == filename && file.mediaType == mediaType
                && file.byteLength == byteLength && file.sha256 == sha256 && file.origin == .phone
        }
    }

    private func uploadAttributes(for draft: DraftFile) throws -> UploadAttributes {
        let data = try Data(contentsOf: draft.source, options: .mappedIfSafe)
        guard data.count <= 25 * 1024 * 1024 else { throw FileTransferError.message("Staged file exceeds 25 MiB.") }
        return UploadAttributes(requestId: draft.id, filename: draft.filename, mediaType: .forFilename(draft.filename), byteLength: data.count, sha256: digest(data))
    }

    private func reserveUpload(_ attributes: UploadAttributes, sessionId: String) async throws -> SharedFile {
        var request = try request(session: sessionId, path: "uploads", method: "POST")
        request.httpBody = try JSONEncoder().encode(attributes)
        let reserved: SharedFile = try await metadata(request)
        guard attributes.matches(reserved, sessionId: sessionId), reserved.state == .pending || reserved.state == .ready else {
            throw FileTransferError.message("Upload reservation did not match the staged file or was cancelled.")
        }
        return reserved
    }

    private func publishDraft(_ draft: DraftFile) async throws {
        try Task.checkCancellation()
        let attributes = try uploadAttributes(for: draft)
        let reserved = try await reserveUpload(attributes, sessionId: draft.sessionId)
        if Task.isCancelled || !drafts.contains(where: { $0.id == draft.id }) {
            if reserved.state == .pending { Task { await self.delete(reserved) } }
            throw CancellationError()
        }
        if reserved.state == .ready { updateDraft(draft.id) { $0.transfer = .ready(reserved) }; return }
        updateDraft(draft.id) { $0.transfer = .uploading(progress: 0, reservation: reserved) }
        let ready = try await uploadContent(draft: draft, reservation: reserved)
        guard ready.id == reserved.id, ready.state == .ready, attributes.matches(ready, sessionId: draft.sessionId) else {
            throw FileTransferError.message("Upload completion did not match the draft.")
        }
        updateDraft(draft.id) { $0.transfer = .ready(ready) }
        invalidate(sessionId: draft.sessionId)
    }

    private func uploadContent(draft: DraftFile, reservation: SharedFile) async throws -> SharedFile {
        let request = try request(session: draft.sessionId, path: "uploads/\(reservation.id)/content", method: "PUT")
        let delegate = PrivateTransferDelegate { [weak self] sent, expected in
            Task { @MainActor in self?.updateDraft(draft.id) { $0.reportProgress(expected > 0 ? Double(sent) / Double(expected) : 0) } }
        }
        let transfer = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { transfer.finishTasksAndInvalidate() }
        let (data, response) = try await transfer.upload(for: request, fromFile: draft.source)
        try check(response, data: data)
        return try JSONDecoder().decode(SharedFile.self, from: data)
    }

    public func removeDraft(_ id: UUID) {
        guard let draft = drafts.first(where: { $0.id == id }) else { return }
        uploads[id]?.cancel()
        uploadQueue.removeAll { $0 == id }
        drafts.removeAll { $0.id == id }
        persistDrafts()
        try? FileManager.default.removeItem(at: draft.source)
        if let file = draft.file, file.state == .pending {
            Task { [weak self] in await self?.delete(file) }
        }
    }
    public func acknowledgeDrafts(ids: [String]) {
        for draft in drafts where draft.file.map({ ids.contains($0.id) }) == true { removeDraft(draft.id) }
    }
    public func delete(_ file: SharedFile) async {
        do {
            let result: SharedFile = try await metadata(request(session: file.sessionId, path: "files/\(file.id)", method: "DELETE"))
            if let index = files.firstIndex(where: { $0.id == result.id }) { files[index] = result }
            try? FileManager.default.removeItem(at: cachedURL(file))
            isStale = true
        } catch { notice = error.localizedDescription }
    }

    public func open(_ file: SharedFile) async throws -> URL {
        try file.validate()
        guard file.sessionId == sessionId, file.state == .ready else { throw FileTransferError.message("File unavailable in this conversation.") }
        // Recheck cloud availability even when a managed local copy exists.
        let current: SharedFile = try await metadata(request(session: file.sessionId, path: "files/\(file.id)"))
        guard file.sessionId == sessionId, current == file else { throw FileTransferError.message("File was deleted, changed, or belongs to an older conversation.") }
        let destination = cachedURL(file)
        if let existing = try? Data(contentsOf: destination, options: .mappedIfSafe), existing.count == file.byteLength, digest(existing) == file.sha256 { return destination }
        let (temporary, response) = try await session.download(for: request(session: file.sessionId, path: "files/\(file.id)/content"))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try check(response, data: Data())
        guard file.sessionId == sessionId else { throw FileTransferError.message("Conversation changed while opening the file.") }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == file.byteLength else { throw FileTransferError.message("File length verification failed.") }
        let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
        guard digest(data) == file.sha256 else { throw FileTransferError.message("File checksum verification failed.") }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try trimCache(required: file.byteLength)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private func request(session: String, path: String, method: String = "GET") throws -> URLRequest {
        guard session.range(of: "^[a-zA-Z0-9_.:-]{1,128}$", options: .regularExpression) != nil else { throw FileTransferError.message("Invalid session destination.") }
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("files/sessions/\(session)/\(path)"))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("CF_Authorization=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    private func metadata<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= 64 * 1024 else { throw FileTransferError.message("File metadata response is too large.") }
        }
        try check(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { let message: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.message ?? "File request failed. Sign in again or check relay availability."
            throw FileTransferError.message(message)
        }
        guard data.count <= 64 * 1024 else { throw FileTransferError.message("File metadata response is too large.") }
    }
    private func updateDraft(_ id: UUID, _ update: (inout DraftFile) -> Void) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        let previous = drafts[index]
        update(&drafts[index])
        let current = drafts[index]
        if previous.file != current.file || previous.isUploading != current.isUploading || previous.isQueued != current.isQueued || previous.error != current.error { persistDrafts() }
    }
    private func persistDrafts() {
        do {
            let directory = try draftDirectory()
            let data = try JSONEncoder().encode(drafts)
            try data.write(to: directory.appendingPathComponent("drafts.json"), options: .atomic)
        } catch { notice = "Could not save attachment drafts: \(error.localizedDescription)" }
    }
    private func draftDirectory() throws -> URL {
        let origin = digest(Data(endpoint.baseURL.absoluteString.utf8))
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AxoDraftFiles/\(origin)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func cachedURL(_ file: SharedFile) -> URL {
        return cache.appendingPathComponent("\(file.id).\(file.mediaType.fileExtension)")
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func trimCache(required: Int) throws {
        let entries = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]).sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        var bytes = entries.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        for entry in entries where bytes + required > 100 * 1024 * 1024 {
            let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try FileManager.default.removeItem(at: entry)
            bytes -= size
        }
    }
}

private final class PrivateTransferDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, Sendable {
    private let progress: @Sendable (Int64, Int64) -> Void
    init(progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > 25 * 1024 * 1024 { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { progress(totalBytesSent, totalBytesExpectedToSend) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
