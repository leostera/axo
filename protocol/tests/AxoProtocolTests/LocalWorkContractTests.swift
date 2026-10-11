import XCTest
@testable import AxoProtocol

final class LocalWorkContractTests: XCTestCase {
    func testEmptyStartupParametersHaveOnlyCapturedDestinationAndMetadata() throws {
        let target = MachineTarget(machineId: UUID(), hostGeneration: UUID())
        let parameters = EmptyStartupSessionParameters(target: target, commandId: UUID(), expectedRevision: WorkRevision(rawValue: 0)!, name: "New Session")
        try AxoProtocolWorkRequestValidator.validate(parameters)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(parameters)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["target", "commandId", "expectedRevision", "name"])
        let destination = try XCTUnwrap(object["target"] as? [String: Any])
        XCTAssertEqual(Set(destination.keys), ["machineId", "hostGeneration"])
        XCTAssertThrowsError(try AxoProtocolWorkRequestValidator.validate(EmptyStartupSessionParameters(target: target, commandId: UUID(), expectedRevision: WorkRevision(rawValue: 0)!, name: " invalid ")))
    }

    func testEmptyStartupResponseRequiresStandaloneNameRevisionAndCurrentHost() throws {
        let host = UUID(), target = MachineTarget(machineId: UUID(), hostGeneration: UUID())
        let parameters = EmptyStartupSessionParameters(target: target, commandId: UUID(), expectedRevision: WorkRevision(rawValue: 0)!, name: "New Session")
        func response(workspace: JSONValue = .null, revision: Double = 1, generation: UUID? = nil) -> JSONValue {
            .object(["hostGeneration": .string((generation ?? target.hostGeneration).uuidString), "revision": .number(revision),
                "session": .object(["sessionId": .string(UUID().uuidString), "workspaceId": workspace, "name": .string("New Session"), "nameSource": .string("manual"),
                    "pi": .object(["paneId": .string(UUID().uuidString), "chatId": .null, "admission": .string("notAdmitted")]), "runtime": .null, "shellPanes": .array([])])])
        }
        XCTAssertNil(try AxoProtocolResultValidator.emptyStartupSession(response(), parameters: parameters).session.workspaceId)
        XCTAssertThrowsError(try AxoProtocolResultValidator.emptyStartupSession(response(workspace: .string(UUID().uuidString)), parameters: parameters))
        XCTAssertThrowsError(try AxoProtocolResultValidator.emptyStartupSession(response(revision: 2), parameters: parameters))
        XCTAssertThrowsError(try AxoProtocolResultValidator.emptyStartupSession(response(generation: host), parameters: parameters))
    }

    func testLocalDirectoryParsesAndEncodesAsPathNotProfileID() throws {
        XCTAssertNil(LocalDirectoryPath(rawValue: "relative"))
        XCTAssertNil(LocalDirectoryPath(rawValue: "/bad\0path"))
        XCTAssertNil(LocalDirectoryPath(rawValue: "/" + String(repeating: "x", count: 16384)))
        XCTAssertNil(LocalDirectoryPath(selectedURL: URL(string: "https://example.com/folder")!))
        let directory = try XCTUnwrap(LocalDirectoryPath(rawValue: "/tmp/project"))
        let target = MachineTarget(machineId: UUID(), hostGeneration: UUID())
        let parameters = LocalWorkspaceCreateParameters(target: target, commandId: UUID(),
            expectedRevision: WorkRevision(rawValue: 0)!, directoryPath: directory, name: "Project")
        try AxoProtocolWorkRequestValidator.validate(parameters)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(parameters)) as? [String: Any])
        XCTAssertEqual(object["directoryPath"] as? String, "/tmp/project")
        XCTAssertNil(object["directoryId"])
    }

    func testPickedDirectoryUsesPhysicalPathRatherThanFoundationPrivatePrefixAlias() throws {
#if canImport(Darwin)
        let name = "axo-picked-directory-\(UUID().uuidString)"
        let selected = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: selected) }
        let parsed = try XCTUnwrap(LocalDirectoryPath(selectedURL: selected))
        XCTAssertEqual(parsed.rawValue, "/private/tmp/" + name)
        let alias = selected.appendingPathComponent("alias", isDirectory: true)
        let directory = selected.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        XCTAssertEqual(LocalDirectoryPath(selectedURL: alias)?.rawValue, "/private/tmp/" + name + "/real")
        XCTAssertNil(LocalDirectoryPath(selectedURL: selected.appendingPathComponent("missing")))
#endif
    }

    func testLocalCreateResponseIsRevisionNameAndLocalIdentityBound() throws {
        let generation = UUID(), workspace = UUID()
        let target = MachineTarget(machineId: UUID(), hostGeneration: generation)
        func response(directoryID: String, revision: Int = 1) throws -> JSONValue {
            let object: [String: Any] = ["hostGeneration": generation.uuidString.lowercased(), "revision": revision,
                "workspace": ["workspaceId": workspace.uuidString.lowercased(), "name": "Project", "directoryId": directoryID]]
            return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let id = "local_" + workspace.uuidString.lowercased()
        let result = try AxoProtocolResultValidator.localWorkspaceCreate(response(directoryID: id), target: target,
            expectedRevision: WorkRevision(rawValue: 0)!, name: "Project")
        XCTAssertEqual(result.workspace.workspaceId, workspace)
        XCTAssertThrowsError(try AxoProtocolResultValidator.localWorkspaceCreate(response(directoryID: "profile"), target: target,
            expectedRevision: WorkRevision(rawValue: 0)!, name: "Project"))
        XCTAssertThrowsError(try AxoProtocolResultValidator.localWorkspaceCreate(response(directoryID: id, revision: 2), target: target,
            expectedRevision: WorkRevision(rawValue: 0)!, name: "Project"))
    }
}
