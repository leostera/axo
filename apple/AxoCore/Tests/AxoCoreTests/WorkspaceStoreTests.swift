import XCTest
@testable import AxoCore

final class WorkspaceStoreTests: XCTestCase {
    private func temporaryStore() throws -> (WorkspaceStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try WorkspaceStore(url: root.appendingPathComponent("registry.json"), scratchRoot: root.appendingPathComponent("work"))
        return (store, root)
    }

    func testCreationIsDurableIdempotentAndIsolated() throws {
        let (store, root) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try store.createWorkspace(name: "Axo", commandID: "first")
        let revision = store.registry.revision
        XCTAssertEqual(try store.createWorkspace(name: "Axo", commandID: "first"), first)
        XCTAssertEqual(store.registry.revision, revision)
        XCTAssertThrowsError(try store.createWorkspace(name: "Other", commandID: "first"))
        let second = try store.createSession(workspaceID: first.workspaceID, name: "Research", commandID: "second")
        XCTAssertNotEqual(first.sessionID, second.sessionID)
        XCTAssertNotEqual(store.registry.sessions[0].piSessionFile, store.registry.sessions[1].piSessionFile)
        let restored = try WorkspaceStore(url: store.url, scratchRoot: root.appendingPathComponent("work"))
        XCTAssertEqual(restored.registry, store.registry)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int, 0o600)
    }

    func testRemoteCreationCanLeaveLocalSelectionUnchanged() throws {
        let (store, root) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let local = try store.createWorkspace(name: "Local", commandID: "local")
        let selected = store.registry.selectedSession

        let remoteWorkspace = try store.createWorkspace(name: "Phone project", commandID: "phone-workspace",
                                                        selectAfterCreation: false)
        XCTAssertEqual(store.registry.selectedSession, selected)
        XCTAssertEqual(try store.createWorkspace(name: "Phone project", commandID: "phone-workspace",
                                                 selectAfterCreation: false), remoteWorkspace)
        XCTAssertEqual(store.registry.selectedSession, selected)

        let remoteSession = try store.createSession(workspaceID: local.workspaceID, name: "Phone session",
                                                    commandID: "phone-session", selectAfterCreation: false)
        XCTAssertEqual(store.registry.selectedSession, selected)
        XCTAssertEqual(try store.createSession(workspaceID: local.workspaceID, name: "Phone session",
                                               commandID: "phone-session", selectAfterCreation: false), remoteSession)
        XCTAssertEqual(store.registry.selectedSession, selected)
    }

    func testSplitCloseAndEmptyLayoutPreserveOtherSessions() throws {
        let (store, root) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try store.createWorkspace(name: "Axo")
        _ = try store.createSession(workspaceID: first.workspaceID, name: "Other")
        let other = store.registry.sessions[1]
        let pi = try XCTUnwrap(store.registry.sessions[0].focusedPane)
        let shell = try store.addShell(sessionID: first.sessionID, beside: pi, axis: .horizontal)
        let nested = try store.addShell(sessionID: first.sessionID, beside: shell, axis: .vertical)
        XCTAssertEqual(store.registry.sessions[0].layout?.panes, [pi, shell, nested])
        XCTAssertEqual(store.registry.sessions[0].panes.map(\.kind), [.pi, .shell, .shell])
        try store.closePane(sessionID: first.sessionID, paneID: shell)
        XCTAssertEqual(store.registry.sessions[0].layout?.panes, [pi, nested])
        try store.closePane(sessionID: first.sessionID, paneID: pi)
        try store.closePane(sessionID: first.sessionID, paneID: nested)
        XCTAssertNil(store.registry.sessions[0].layout)
        XCTAssertNil(store.registry.sessions[0].focusedPane)
        XCTAssertEqual(store.registry.sessions[1], other)
    }

    func testNestedSplitRatioPersistsWithoutChangingIdentities() throws {
        let (store, root) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let created = try store.createWorkspace(name: "Axo")
        let pi = try XCTUnwrap(store.registry.sessions.first?.focusedPane)
        let shell = try store.addShell(sessionID: created.sessionID, beside: pi, axis: .horizontal)
        _ = try store.addShell(sessionID: created.sessionID, beside: shell, axis: .vertical)
        let original = try XCTUnwrap(store.registry.sessions.first?.layout)
        let resized = try original.settingFraction(0.7, at: [true])
        XCTAssertEqual(resized.panes, original.panes)
        XCTAssertNotEqual(resized, original)
        XCTAssertThrowsError(try original.settingFraction(0.01, at: []))
        XCTAssertThrowsError(try original.settingFraction(0.5, at: [false]))
        try store.updateSession(created.sessionID) { $0.layout = resized }
        let restored = try WorkspaceStore(url: store.url, scratchRoot: root)
        XCTAssertEqual(restored.registry.sessions.first?.layout, resized)
    }

    func testFailedMutationDoesNotChangeMemoryOrDisk() throws {
        let (store, root) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let created = try store.createWorkspace(name: "Axo")
        let state = store.registry, bytes = try Data(contentsOf: store.url)
        XCTAssertThrowsError(try store.updateSession(created.sessionID) { session in
            session.layout = .split(axis: .horizontal, fraction: .nan,
                                    first: .pane(session.panes[0].id), second: .pane(session.panes[0].id))
        })
        XCTAssertEqual(store.registry, state)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        XCTAssertThrowsError(try store.createSession(workspaceID: WorkspaceID(), name: "Missing"))
        XCTAssertEqual(store.registry, state)
    }

    func testInvalidNamesAndCorruptStoreFailClosed() throws {
        let (store, root) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["", " \n ", "bad\u{0}name", String(repeating: "x", count: 121)] {
            XCTAssertThrowsError(try store.createWorkspace(name: name))
        }
        _ = try store.createWorkspace(name: "Valid")
        try Data("not json".utf8).write(to: store.url)
        XCTAssertThrowsError(try WorkspaceStore(url: store.url, scratchRoot: root))
    }

    func testGhosttyWeightedEqualizationRatiosAreValidSavedMetadata() throws {
        let (store, root) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let created = try store.createWorkspace(name: "Axo")
        let pi = try XCTUnwrap(store.registry.sessions.first?.focusedPane)
        _ = try store.addShell(sessionID: created.sessionID, beside: pi, axis: .horizontal)
        try store.updateSession(created.sessionID) { session in
            guard case .split(let axis, _, let first, let second) = session.layout else { throw WorkspaceFault.invalidLayout }
            session.layout = .split(axis: axis, fraction: 1.0 / 12.0, first: first, second: second)
        }
        XCTAssertNoThrow(try store.registry.validate())
    }

    func testNulPathsCannotReachTerminalCStringBoundary() throws {
        let (store, root) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try store.createWorkspace(name: "Axo", initialDirectory: "/tmp/unsafe\u{0}suffix"))
        XCTAssertTrue(store.registry.workspaces.isEmpty)
        XCTAssertThrowsError(try store.createWorkspace(name: "Axo", initialSessionFile: "/tmp/unsafe\u{0}suffix"))
        XCTAssertTrue(store.registry.workspaces.isEmpty)
    }

    func testTitlesAreDurableAndManualRenamesAlwaysWin() throws {
        let (store, root) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let created = try store.createWorkspace(name: "Project")
        XCTAssertEqual(store.registry.sessions[0].name, "Untitled")
        try store.applyAutomaticTitle("Sidebar polish", to: created.sessionID)
        XCTAssertEqual(store.registry.sessions[0].effectiveNameSource, .automatic)
        try store.renameSession(created.sessionID, name: "My session")
        try store.applyAutomaticTitle("Late automatic title", to: created.sessionID)
        try store.renameWorkspace(created.workspaceID, name: "My project")
        let restored = try WorkspaceStore(url: store.url, scratchRoot: root)
        XCTAssertEqual(restored.registry.sessions[0].name, "My session")
        XCTAssertEqual(restored.registry.sessions[0].effectiveNameSource, .manual)
        XCTAssertEqual(restored.registry.workspaces[0].name, "My project")
        // Renaming even to the placeholder explicitly prevents future automatic replacement.
        try store.renameSession(created.sessionID, name: "Untitled")
        try store.applyAutomaticTitle("Must not overwrite", to: created.sessionID)
        XCTAssertEqual(store.registry.sessions[0].name, "Untitled")
    }

    func testProjectWorkingDirectoryDoesNotMoveOrReuseConversationStorage() throws {
        let (store, root) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try store.createWorkspace(name: "Project", commandID: "cwd", initialDirectory: "/project")
        let session = try store.createSession(workspaceID: workspace.workspaceID, name: "Untitled", commandID: "tab", initialDirectory: "/project/subfolder")
        XCTAssertEqual(store.registry.sessions.map(\.directory), ["/project", "/project/subfolder"])
        XCTAssertTrue(store.registry.sessions.allSatisfy { $0.piSessionFile.hasPrefix(root.path + "/work/") })
        XCTAssertNotEqual(store.registry.sessions[0].piSessionFile, store.registry.sessions[1].piSessionFile)
        XCTAssertThrowsError(try store.createWorkspace(name: "Project", commandID: "cwd", initialDirectory: "/different"))
        XCTAssertThrowsError(try store.createSession(workspaceID: workspace.workspaceID, name: "Untitled", commandID: "tab", initialDirectory: "/different"))
        XCTAssertEqual(session.sessionID, store.registry.sessions[1].id)
    }

    func testOldRegistriesWithoutNameSourcesStillDecode() throws {
        let (store, root) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.createWorkspace(name: "Project")
        let restored = try JSONDecoder().decode(WorkspaceRegistry.self, from: JSONEncoder().encode(store.registry))
        XCTAssertNil(restored.sessions[0].nameSource)
        XCTAssertEqual(restored.sessions[0].effectiveNameSource, .untitled)
    }

    func testProjectMainDirectoryAndShellDirectoriesSurviveReload() throws {
        let (store, root) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let project = try store.createWorkspace(name: "My project", initialDirectory: "/projects/main")
        _ = try store.createSession(workspaceID: project.workspaceID, name: "Untitled")
        let pane = try XCTUnwrap(store.registry.sessions[0].focusedPane)
        let shell = try store.addShell(sessionID: project.sessionID, beside: pane, axis: .horizontal)
        try store.updateSession(project.sessionID) { session in
            let index = try XCTUnwrap(session.panes.firstIndex(where: { $0.id == shell }))
            session.panes[index].directory = "/projects/main/subfolder"
        }
        let restored = try WorkspaceStore(url: store.url, scratchRoot: root)
        XCTAssertEqual(restored.registry.workspaces[0].directory, "/projects/main")
        XCTAssertEqual(restored.registry.sessions[1].directory, "/projects/main")
        XCTAssertEqual(restored.registry.sessions[0].panes[1].directory, "/projects/main/subfolder")
        XCTAssertTrue(restored.registry.sessions.allSatisfy { $0.piSessionFile.hasPrefix(root.path + "/work/") })
    }

    func testInvalidShellDirectoriesCannotBePersisted() throws {
        let (store, root) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let project = try store.createWorkspace(name: "Project")
        let before = store.registry
        for path in ["relative/path", "/bad\u{0}directory", "/" + String(repeating: "x", count: 4_096)] {
            XCTAssertThrowsError(try store.updateSession(project.sessionID) { $0.panes[0].directory = path })
            XCTAssertEqual(store.registry, before)
        }
    }

    func testOldPaneRecordsWithoutWorkingDirectoriesRemainReadable() throws {
        let pane = PaneRecord(kind: .shell)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pane)) as? [String: Any])
        encoded.removeValue(forKey: "directory")
        let decoded = try JSONDecoder().decode(PaneRecord.self, from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertEqual(decoded.id, pane.id)
        XCTAssertNil(decoded.directory)
    }

    func testDuplicatesAllocateNewConversationsAndPaneIdentitiesWithoutCopyingHistory() throws {
        let (store, root) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let created = try store.createWorkspace(name: "Project", initialDirectory: "/project")
        let pi = try XCTUnwrap(store.registry.sessions[0].focusedPane)
        let shell = try store.addShell(sessionID: created.sessionID, beside: pi, axis: .vertical)
        try store.updateSession(created.sessionID) { $0.conversationID = "original-conversation" }
        let original = store.registry.sessions[0]
        let copiedID = try store.duplicateSession(original.id)
        let copy = try XCTUnwrap(store.registry.sessions.first(where: { $0.id == copiedID }))
        XCTAssertEqual(copy.name, "Untitled copy")
        XCTAssertEqual(copy.directory, original.directory)
        XCTAssertNil(copy.conversationID)
        XCTAssertNotEqual(copy.piSessionFile, original.piSessionFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.piSessionFile))
        XCTAssertTrue(Set(copy.panes.map(\.id)).isDisjoint(with: [pi, shell]))
        XCTAssertEqual(copy.panes.map(\.kind), original.panes.map(\.kind))
        XCTAssertEqual(copy.layout?.panes, copy.panes.map(\.id))
        XCTAssertEqual(store.registry.sessions[0], original)
        _ = try store.duplicateWorkspace(created.workspaceID)
        XCTAssertEqual(store.registry.workspaces.count, 2)
        XCTAssertTrue(store.registry.sessions.filter({ $0.workspaceID != original.workspaceID }).allSatisfy { $0.conversationID == nil })
        XCTAssertNoThrow(try store.registry.validate())
    }

    func testRemovalArchivesMetadataAndRetainsConversationFiles() throws {
        let (store, root) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let created = try store.createWorkspace(name: "Project")
        let file = URL(fileURLWithPath: store.registry.sessions[0].piSessionFile)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("existing Pi history".utf8); try bytes.write(to: file)
        try store.archiveSession(created.sessionID)
        XCTAssertNil(store.registry.selectedSession)
        XCTAssertThrowsError(try store.select(created.sessionID))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try store.archiveWorkspace(created.workspaceID)
        XCTAssertEqual(store.registry.workspaces[0].isArchived, true)
        XCTAssertEqual(store.registry.sessions[0].isArchived, true)
        XCTAssertThrowsError(try store.createSession(workspaceID: created.workspaceID, name: "Not allowed"))
        let restored = try WorkspaceStore(url: store.url, scratchRoot: root)
        XCTAssertEqual(restored.registry, store.registry)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testLegacyStandaloneSessionsAreClassifiedByCreationIdentityAndSurviveRename() throws {
        let (store, root) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try store.createWorkspace(name: "Playground", commandID: "prototype-import")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        var workspaces = try XCTUnwrap(json["workspaces"] as? [[String: Any]])
        workspaces[0].removeValue(forKey: "kind"); json["workspaces"] = workspaces
        try JSONSerialization.data(withJSONObject: json).write(to: store.url)
        let restored = try WorkspaceStore(url: store.url, scratchRoot: root)
        XCTAssertEqual(restored.registry.workspaces[0].effectiveKind, .standalone)
        try restored.renameWorkspace(legacy.workspaceID, name: "Renamed container")
        XCTAssertEqual(restored.registry.workspaces[0].effectiveKind, .standalone)
        _ = try restored.createWorkspace(name: "Sessions", initialDirectory: "/a/real/project")
        XCTAssertEqual(restored.registry.workspaces[1].effectiveKind, .project)
    }

    func testStandaloneKindRetainsLegacySerializationForExistingRecordsAndRollback() throws {
        let legacy = Data("\"playground\"".utf8)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceKind.self, from: legacy), .standalone)
        XCTAssertEqual(try JSONEncoder().encode(WorkspaceKind.standalone), legacy)
    }

    func testPrototypeImportReferencesOriginalFileWithoutCopyingIt() throws {
        let (store, root) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.createWorkspace(name: "Playground", initialDirectory: "/existing/playground",
                                      initialSessionFile: "/existing/playground/session.jsonl")
        XCTAssertEqual(store.registry.sessions[0].piSessionFile, "/existing/playground/session.jsonl")
        XCTAssertEqual(store.registry.sessions[0].directory, "/existing/playground")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/existing/playground/session.jsonl"))
    }
}
