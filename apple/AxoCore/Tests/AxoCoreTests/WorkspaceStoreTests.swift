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

    func testPrototypeImportReferencesOriginalFileWithoutCopyingIt() throws {
        let (store, root) = try temporaryStore(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.createWorkspace(name: "Playground", initialDirectory: "/existing/playground",
                                      initialSessionFile: "/existing/playground/session.jsonl")
        XCTAssertEqual(store.registry.sessions[0].piSessionFile, "/existing/playground/session.jsonl")
        XCTAssertEqual(store.registry.sessions[0].directory, "/existing/playground")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/existing/playground/session.jsonl"))
    }
}
