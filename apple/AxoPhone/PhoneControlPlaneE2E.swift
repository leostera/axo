#if DEBUG && targetEnvironment(simulator)
import AxoCore
import Darwin
import Foundation

/// Only an explicitly launched disposable simulator reads this private fixture.
/// The credential still goes through the actual API's signed Access verification.
@MainActor enum PhoneControlPlaneE2E {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--axo-control-plane-e2e") }
    private struct Configuration: Decodable {
        let version: Int
        let origin: URL
        let cookie: String
    }
    static func model() throws -> CentralPhoneWorkbenchModel {
        guard requested,
              !ProcessInfo.processInfo.arguments.contains("--axo-control-plane-preview"),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileReadNoPermission)
        }
        let path = support.appendingPathComponent("control-plane-e2e.json")
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_uid == geteuid(), attributes.st_nlink == 1,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), attributes.st_mode & 0o777 == 0o600,
              attributes.st_size > 0, attributes.st_size <= 16384 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: 16385) ?? Data()
        guard data.count == Int(attributes.st_size) else { throw CocoaError(.fileReadCorruptFile) }
        let configuration = try JSONDecoder().decode(Configuration.self, from: data)
        guard configuration.version == 1, configuration.origin.host == "127.0.0.1" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let endpoint = try AxoControlPlaneEndpoint(ownedLoopbackFixture: configuration.origin.absoluteString)
        let credential = try AxoControlPlaneAccessCookie(configuration.cookie)
        return CentralPhoneWorkbenchModel(endpoint: endpoint, credential: credential, persistsCredentials: false)
    }
}
#endif
