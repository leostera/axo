import Foundation

/// Short-lived, upload-only R2 capability. Never encoded into drafts or transcript frames.
struct FileUploadAuthorization: Decodable, Sendable {
    let file: SharedFile
    let upload: SignedUpload?

    struct SignedUpload: Decodable, Sendable {
        let url: URL
        let headers: [String: String]
        let expiresAt: Int64

        func request(for file: SharedFile) throws -> URLRequest {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let expectedHeaders = ["Content-Type": file.mediaType.rawValue, "Content-Length": String(file.byteLength),
                                   "If-None-Match": "*", "x-amz-checksum-sha256": try checksumBase64(file.sha256)]
            guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
                  url.host?.range(of: "^[a-f0-9]{32}\\.r2\\.cloudflarestorage\\.com$", options: .regularExpression) != nil,
                  url.pathComponents.contains(file.id), headers == expectedHeaders,
                  expiresAt > now, expiresAt <= now + 301_000,
                  URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
                      $0.name == "X-Amz-Algorithm" && $0.value == "AWS4-HMAC-SHA256"
                  }) == true else {
                throw FileTransferError.message("Invalid or expired direct upload authorization.")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.httpShouldHandleCookies = false
            request.timeoutInterval = min(300, Double(expiresAt - now) / 1000)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            return request
        }
    }

    func validate(reservation: SharedFile) throws {
        guard file == reservation || (file.id == reservation.id && file.sessionId == reservation.sessionId && file.filename == reservation.filename
            && file.mediaType == reservation.mediaType && file.byteLength == reservation.byteLength && file.sha256 == reservation.sha256
            && file.origin == reservation.origin && file.createdAt == reservation.createdAt && file.state == .ready),
              (file.state == .ready && upload == nil) || (file.state == .pending && upload != nil) else {
            throw FileTransferError.message("Direct upload authorization does not match this draft.")
        }
    }
}

private func checksumBase64(_ hash: String) throws -> String {
    var bytes = Data()
    for index in stride(from: 0, to: hash.count, by: 2) {
        let start = hash.index(hash.startIndex, offsetBy: index)
        let end = hash.index(start, offsetBy: 2)
        guard let byte = UInt8(hash[start..<end], radix: 16) else { throw FileTransferError.message("Invalid file checksum.") }
        bytes.append(byte)
    }
    return bytes.base64EncodedString()
}
