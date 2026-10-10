import Foundation

@main
struct OwnerAbsenceLeaseChecks {
    enum Failure: Error { case assertion }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axo-owner-lease-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        func check(_ value: Bool) throws { if !value { throw Failure.assertion } }
        let first = try AxodOwnerAbsenceLease.acquire(in: root)
        try check(first != nil)
        try check(try AxodOwnerAbsenceLease.acquire(in: root) == nil)
        first?.release()
        let second = try AxodOwnerAbsenceLease.acquire(in: root)
        try check(second != nil)
        second?.release()

        let lock = root.appendingPathComponent("owner.lock")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lock.path)
        do { _ = try AxodOwnerAbsenceLease.acquire(in: root); throw Failure.assertion }
        catch is AxodOwnerAbsenceLease.Failure {}
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path)
        let link = root.appendingPathComponent("extra-link")
        try FileManager.default.linkItem(at: lock, to: link)
        do { _ = try AxodOwnerAbsenceLease.acquire(in: root); throw Failure.assertion }
        catch is AxodOwnerAbsenceLease.Failure {}
        try FileManager.default.removeItem(at: link)
        try FileManager.default.moveItem(at: lock, to: root.appendingPathComponent("original"))
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: root.appendingPathComponent("original"))
        do { _ = try AxodOwnerAbsenceLease.acquire(in: root); throw Failure.assertion }
        catch is AxodOwnerAbsenceLease.Failure {}
        print("Owner absence lease: contention, release, permissions, hardlink and symlink checks passed.")
    }
}
