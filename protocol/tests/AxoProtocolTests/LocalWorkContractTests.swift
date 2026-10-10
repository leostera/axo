import XCTest
@testable import AxoProtocol

final class LocalWorkContractTests: XCTestCase {
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
