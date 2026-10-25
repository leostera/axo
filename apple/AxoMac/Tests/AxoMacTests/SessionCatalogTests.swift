import AxoRPC
import XCTest

@testable import AxoMac

final class SessionCatalogTests: XCTestCase {
  private func shell(_ id: ShellID) -> TerminalShell {
    TerminalShell(
      id: id, processId: 1, initialPwd: "/", ptyDevice: "/dev/null", attachSocketPath: "/tmp/s")
  }

  private func session(_ id: SessionID, _ shells: [ShellID], name: String = "") -> TerminalSession {
    TerminalSession(id: id, initialPwd: "/", shells: shells.map(shell), name: name)
  }

  func testSessionsAreSortedByIDAndTheLastDuplicateWins() {
    let catalog = SessionCatalog([
      session(3, [30]), session(1, [10], name: "old"), session(2, [20]), session(1, [11], name: "new"),
    ])
    XCTAssertEqual(catalog.sessions.map(\.id), [1, 2, 3])
    XCTAssertEqual(catalog.session(for: 1)?.name, "new")
    XCTAssertEqual(catalog.shellsByID.keys.sorted(), [11, 20, 30])
  }

  func testUpsertInsertsInOrderOrReplacesInPlace() {
    var catalog = SessionCatalog([session(1, [10]), session(4, [40])])
    catalog.upsert(session(3, [30]))
    catalog.upsert(session(0, [1]))
    catalog.upsert(session(9, [90]))
    XCTAssertEqual(catalog.sessions.map(\.id), [0, 1, 3, 4, 9])
    catalog.upsert(session(3, [31], name: "renamed"))
    XCTAssertEqual(catalog.sessions.map(\.id), [0, 1, 3, 4, 9])
    XCTAssertEqual(catalog.session(for: 3)?.name, "renamed")
    XCTAssertEqual(catalog.session(containing: 31)?.id, 3)
    XCTAssertNil(catalog.session(containing: 30))
  }

  func testLookupsMissForAbsentSessions() {
    let catalog = SessionCatalog([session(2, [20]), session(5, [50])])
    for absent: SessionID in [0, 1, 3, 4, 6] {
      XCTAssertNil(catalog.session(for: absent))
    }
    XCTAssertNil(SessionCatalog().session(for: 1))
  }

  func testRemovingAndReplacingShellsTouchOnlyOpenSessions() {
    var catalog = SessionCatalog([session(1, [10]), session(2, [20])])
    catalog.replaceShells(of: 2, with: [shell(20), shell(21)])
    catalog.replaceShells(of: 7, with: [shell(70)])
    XCTAssertEqual(catalog.session(for: 2)?.shells.map(\.id), [20, 21])
    XCTAssertNil(catalog.session(for: 7))

    let removed = catalog.removing([1, 7])
    XCTAssertEqual(removed.sessions.map(\.id), [2])
    XCTAssertEqual(catalog.sessions.map(\.id), [1, 2], "removing returns a copy")
  }
}
