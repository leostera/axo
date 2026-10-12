#if DEBUG
import AxoProtocol
import Foundation

/// Preview values traverse the same closed boundary as real responses. They
/// neither read stored catalogs nor construct unchecked trusted domain records.
enum CentralBrowserPreview {
    static func records(source: CentralSource, piID: UUID) throws -> (workspaces: [CentralWorkspace], sessions: [CentralSessionView]) {
        let workspace = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", session = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        func envelope(_ body: [String: Any]) throws -> JSONValue {
            let value: [String: Any] = ["hostGeneration": source.machine.hostGeneration.uuidString, "storeGeneration": source.storeGeneration.uuidString, "revision": 7, "value": body]
            return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let workspaceBody: [String: Any] = ["records": [["workspaceId": workspace, "name": "Axo", "directory": "/preview/Axo", "lifecycle": "open", "configRevision": 7]], "cursor": NSNull()]
        func pane(_ id: String, ordinal: Int, role: String) -> [String: Any] {
            ["desired": ["paneId": id, "sessionId": session, "role": ["kind": role], "present": true, "ordinal": ordinal, "configRevision": 7],
             "availability": "materializing", "lastRuntime": NSNull(), "terminal": NSNull()]
        }
        let view: [String: Any] = ["session": ["sessionId": session, "workspaceId": workspace, "name": "Build the phone app", "manualName": false, "lifecycle": "open", "configRevision": 7],
                                 "panes": [pane(piID.uuidString, ordinal: 0, role: "pi"), pane("dddddddd-dddd-4ddd-8ddd-dddddddddddd", ordinal: 1, role: "accountShell")], "readiness": "materializing"]
        let workspaceResult = try CentralRequest.workspaces(source: source).parseResult(envelope(workspaceBody))
        let sessionResult = try CentralRequest.sessions(source: source, workspaceId: UUID(uuidString: workspace)!).parseResult(envelope(["records": [view], "cursor": NSNull()]))
        guard case .workspaces(let workspaces, _) = workspaceResult.payload, case .sessions(let sessions, _) = sessionResult.payload else {
            throw AxoProtocolValidationError.invalidResult(method: "preview")
        }
        return (workspaces, sessions)
    }
}
#endif
