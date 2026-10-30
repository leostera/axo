import AxoProtocol
import AxoSearch
import SwiftUI
import XCTest

@testable import AxoMac

private func shell(_ id: ShellID, _ role: PaneRole = .terminal, pwd: String = "/")
  -> TerminalShell
{
  TerminalShell(
    id: id, processId: 1, initialPwd: pwd, ptyDevice: "/dev/null", attachSocketPath: "/tmp/s",
    role: role)
}

private func session(
  _ id: SessionID, _ name: String, shells: [TerminalShell] = [], workspace: String? = nil,
  emoji: String? = nil, lastMessageAt: Int64? = nil,
  status: TerminalSessionStatus? = nil, pwd: String = "/"
) -> TerminalSession {
  TerminalSession(
    id: id, initialPwd: pwd, shells: shells, workspaceId: workspace,
    workspaceName: workspace.map { $0.capitalized }, name: name, emoji: emoji,
    lastMessageAt: lastMessageAt, status: status)
}

private func availability(focused: Bool = true, selected: Bool = true)
  -> TerminalCommandAvailability
{
  var availability = TerminalCommandAvailability()
  availability.hasFocusedShell = focused
  availability.hasSelectedSession = selected
  return availability
}

final class CommandPaletteCatalogTests: XCTestCase {
  private func context(
    sessions: [TerminalSession] = [], workspaces: [WorkspaceRecord] = [],
    recent: [SessionID] = [], selected: SessionID? = nil, focused: ShellID? = nil,
    availability: TerminalCommandAvailability = availability()
  ) -> CommandPaletteContext {
    CommandPaletteContext(
      sessions: sessions, workspaces: workspaces, recentSessionIDs: recent,
      selectedSessionID: selected, focusedShellID: focused, availability: availability,
      homeDirectory: "/Users/me")
  }

  func testSessionsComeMostRecentFirstThenTheRestWithTheCurrentOneLast() {
    let sessions = [session(1, "a"), session(2, "b"), session(3, "c"), session(4, "d")]
    // 9 is recent but closed; 2 is current; 1 was never shown.
    let items = CommandPaletteCatalog.items(
      context(sessions: sessions, recent: [2, 4, 9, 3], selected: 2))
    let shown = items.filter { $0.kind == .session }
    XCTAssertEqual(shown.map(\.action), [4, 3, 1, 2].map { .showSession($0) })
    XCTAssertEqual(shown.map(\.isCurrent), [false, false, false, true])
    let repeated = CommandPaletteCatalog.items(context(sessions: sessions, recent: [3, 3]))
    XCTAssertEqual(repeated.filter { $0.kind == .session }.map(\.action), [3, 1, 2, 4].map { .showSession($0) })
  }

  func testASessionShowsItsEmojiNameWorkspaceStatusAndShortDirectory() throws {
    let items = CommandPaletteCatalog.items(
      context(sessions: [
        session(
          1, "deploy", workspace: "api", emoji: "🚀", status: .needsAttention,
          pwd: "/Users/me/src/api"),
        session(2, "notes", status: .ready, pwd: "/Users/meadow"),
      ]))
    let deploy = try XCTUnwrap(items.first { $0.action == .showSession(1) })
    XCTAssertEqual(deploy.title, "🚀 deploy")
    XCTAssertEqual(deploy.subtitle, "Api · Needs attention · ~/src/api")
    XCTAssertEqual(deploy.id, "session:\(SessionID.fixture(1))")
    let notes = try XCTUnwrap(items.first { $0.action == .showSession(2) })
    XCTAssertEqual(notes.subtitle, "/Users/meadow", "ready says nothing; only whole home is ~")
  }

  func testSessionSubtitleIncludesTheLatestMessageRecency() throws {
    let now = Int64(Date().timeIntervalSince1970)
    let tenDaysAgo = now - 10 * 24 * 60 * 60
    let fifteenMinutesAgo = now - 15 * 60
    let items = CommandPaletteCatalog.items(
      context(sessions: [
        session(1, "deploy", lastMessageAt: tenDaysAgo),
        session(2, "notes", lastMessageAt: fifteenMinutesAgo),
      ]))
    let deploy = try XCTUnwrap(items.first { $0.action == .showSession(1) })
    XCTAssertTrue(deploy.subtitle.contains("10 days ago"), deploy.subtitle)
    let notes = try XCTUnwrap(items.first { $0.action == .showSession(2) })
    XCTAssertTrue(notes.subtitle.contains("15 minutes ago"), notes.subtitle)
  }

  func testPanesAreListedOnlyForSessionsWithSeveralAndNumberShellsAfterPi() {
    let items = CommandPaletteCatalog.items(
      context(sessions: [
        session(1, "solo", shells: [shell(10)]),
        session(2, "work", shells: [shell(20, .pi), shell(21), shell(22, pwd: "/Users/me/x")]),
      ]))
    let panes = items.filter { $0.kind == .pane }
    XCTAssertEqual(panes.map(\.title), ["Pi — work", "Shell 1 — work", "Shell 2 — work"])
    XCTAssertEqual(panes.map(\.action), [20, 21, 22].map { .focusPane($0) })
    XCTAssertEqual(panes.last?.subtitle, "~/x")
  }

  func testWorkspaceNameMatchesItsSessionsAndPanes() {
    let items = CommandPaletteCatalog.items(
      context(sessions: [
        session(1, "deploy", shells: [shell(10, .pi), shell(11), shell(12)], workspace: "api"),
        session(2, "website", shells: [shell(20, .pi), shell(21)], workspace: "web"),
      ]))
    let matches = SearchIndex(items) { $0.document }.search(SearchQuery("Api"))

    XCTAssertEqual(
      Set(matches.map { $0.item.action }),
      Set([.showSession(1), .focusPane(10), .focusPane(11), .focusPane(12)]))
  }

  func testCommandsNeedingAPaneOrSessionAppearOnlyWhenThereIsOne() {
    func commands(_ context: CommandPaletteContext) -> [String] {
      CommandPaletteCatalog.items(context).filter { $0.kind == .command }.map(\.title)
    }
    let always = ["New Session", "New Workspace…", "Toggle Sidebar", "Settings…"]
    XCTAssertEqual(commands(context(availability: availability(focused: false, selected: false))), always)

    let open = context(sessions: [session(1, "a", shells: [shell(10)])], selected: 1, focused: 10)
    XCTAssertEqual(
      commands(open),
      ["New Session", "New Workspace…", "Split Right", "Split Down", "Close Focused Shell",
       "Close Session", "Toggle Sidebar", "Settings…"])

    // The menus' availability decides, as for the same commands in the menu bar.
    var unavailable = open
    unavailable.availability = availability(focused: false, selected: false)
    XCTAssertEqual(commands(unavailable), always)
  }

  func testDestructiveCommandsNameWhatTheyWereShownActingOn() throws {
    let items = CommandPaletteCatalog.items(
      context(sessions: [session(1, "a", shells: [shell(10)])], selected: 1, focused: 10))
    XCTAssertEqual(items.first { $0.title == "Close Focused Shell" }?.action, .run(.closeShell(10)))
    let close = try XCTUnwrap(items.first { $0.title == "Close Session" })
    XCTAssertEqual(close.action, .run(.closeSession(1)))
    XCTAssertEqual(close.subtitle, "a")
  }

  func testEachWorkspaceOffersANewSessionInIt() throws {
    let items = CommandPaletteCatalog.items(
      context(workspaces: [
        WorkspaceRecord(workspaceId: "w1", name: "API", directoryPath: "/Users/me/src/api")
      ]))
    let item = try XCTUnwrap(items.first { $0.title == "New Session in API" })
    XCTAssertEqual(item.action, .run(.newSessionInWorkspace(workspaceID: "w1")))
    XCTAssertEqual(item.subtitle, "~/src/api")
    XCTAssertEqual(item.id, "command:new-session-in:w1")
  }

  func testEntryIDsAreUnique() {
    let items = CommandPaletteCatalog.items(
      context(
        sessions: [session(1, "a", shells: [shell(10), shell(11)]), session(2, "b")],
        workspaces: [
          WorkspaceRecord(workspaceId: "w1", name: "A", directoryPath: "/"),
          WorkspaceRecord(workspaceId: "w2", name: "A", directoryPath: "/"),
        ],
        selected: 1, focused: 10))
    XCTAssertEqual(Set(items.map(\.id)).count, items.count)
  }
}

@MainActor
final class CommandPaletteModelTests: XCTestCase {
  private func item(_ title: String, keywords: [String] = []) -> CommandPaletteItem {
    CommandPaletteItem(
      id: title, kind: .command, title: title, subtitle: "", keywords: keywords, shortcut: nil,
      isCurrent: false, action: .run(.openSettings))
  }

  private let items = ["New Session", "Split Right", "Settings…"]

  func testPresentingShowsEveryItemWithTheFirstSelectedAndAnEmptyQuery() {
    let palette = CommandPaletteModel()
    palette.present(items.map { item($0) })
    palette.query = "split"
    palette.dismiss()
    palette.present(items.map { item($0) })
    XCTAssertTrue(palette.isPresented)
    XCTAssertEqual(palette.query, "")
    XCTAssertEqual(palette.results.map(\.id), items)
    XCTAssertEqual(palette.selectedResult?.id, "New Session")
  }

  func testTypingRanksAndSelectsTheBestMatch() {
    let palette = CommandPaletteModel()
    palette.present(items.map { item($0) })
    palette.moveSelection(by: 1)
    palette.query = "set"
    XCTAssertEqual(palette.results.first?.id, "Settings…")
    XCTAssertEqual(palette.selectedIndex, 0)
    XCTAssertEqual(palette.results.first?.match.titleHighlights, [0, 1, 2])
  }

  func testSelectionWrapsAroundBothEnds() {
    let palette = CommandPaletteModel()
    palette.present(items.map { item($0) })
    palette.moveSelection(by: -1)
    XCTAssertEqual(palette.selectedResult?.id, "Settings…")
    palette.moveSelection(by: 1)
    XCTAssertEqual(palette.selectedResult?.id, "New Session")
    palette.moveSelection(by: 4)
    XCTAssertEqual(palette.selectedResult?.id, "Split Right")
  }

  func testChoosingClosesAndReturnsTheSelectedAction() {
    let palette = CommandPaletteModel()
    let session = CommandPaletteItem(
      id: "s", kind: .session, title: "deploy", subtitle: "", keywords: [], shortcut: nil,
      isCurrent: false, action: .showSession(7))
    palette.present([item("Settings…"), session])
    palette.select("s")
    XCTAssertEqual(palette.choose(), .showSession(7))
    XCTAssertFalse(palette.isPresented)
  }

  func testWithNoMatchesNothingIsChosenAndThePaletteStaysOpen() {
    let palette = CommandPaletteModel()
    palette.present(items.map { item($0) })
    palette.query = "zzz"
    palette.moveSelection(by: 1)
    XCTAssertNil(palette.selectedResult)
    XCTAssertNil(palette.choose())
    XCTAssertTrue(palette.isPresented)
  }

  func testGitHubRepositoryQueryAddsACloneWorkspaceAction() throws {
    let palette = CommandPaletteModel()
    palette.present(items.map { item($0) })
    palette.query = "github:leostera/myrepo"
    let repository = try XCTUnwrap(GitHubRepository.parsePaletteInput("github:leostera/myrepo"))
    XCTAssertEqual(
      palette.selectedResult?.item.action,
      .cloneGitHubRepository(repository))
    XCTAssertEqual(palette.selectedResult?.item.subtitle, "Clone and create a Workspace")
  }
}

final class GitHubRepositoryTests: XCTestCase {
  func testParsesGitHubOwnerAndRepositorySyntax() throws {
    XCTAssertEqual(
      try XCTUnwrap(GitHubRepository.parsePaletteInput("github:leostera/myrepo")).slug,
      "leostera/myrepo")
    XCTAssertEqual(
      GitHubRepository.parsePaletteInput("  github:some-org/repo.name  ")?.slug,
      "some-org/repo.name")
    XCTAssertEqual(GitHubRepository.parsePaletteInput("gh:some-org/repo")?.slug, "some-org/repo")
  }

  func testRejectsMalformedOrPathEscapingRepositorySyntax() {
    ["github:/repo", "github:org/", "github:../repo", "github:org/..", "github:a/b/c", "gh:org/"]
      .forEach { XCTAssertNil(GitHubRepository.parsePaletteInput($0), $0) }
  }
}

@MainActor
final class CommandPalettePerformerTests: XCTestCase {
  private var toggled = 0
  private var newWorkspaces = 0
  private var settings = 0
  private var clonedRepository: GitHubRepository?

  private func model() async -> TerminalSessionsModel {
    let client = FakeAxodClient()
    client.sessions = [
      session(1, "a", shells: [shell(10), shell(11)]),
      session(2, "b", shells: [shell(20)]),
    ]
    client.workspaces = [WorkspaceRecord(workspaceId: "w1", name: "W", directoryPath: "/")]
    let model = TerminalSessionsModel(client: client)
    await model.refresh()
    return model
  }

  private func performer(_ sessions: TerminalSessionsModel) -> CommandPalettePerformer {
    CommandPalettePerformer(
      sessions: sessions,
      toggleSidebar: { self.toggled += 1 },
      newWorkspace: { self.newWorkspaces += 1 },
      cloneGitHubRepository: { self.clonedRepository = $0 },
      openSettings: { self.settings += 1 })
  }

  func testShowsSessionsAndFocusesPanesThatStillExist() async {
    let sessions = await model()
    let perform = performer(sessions)
    XCTAssertTrue(perform.perform(.showSession(2)))
    XCTAssertEqual(sessions.selectedSessionID, 2)
    XCTAssertTrue(perform.perform(.focusPane(11)))
    XCTAssertEqual(sessions.selectedSessionID, 1)
    XCTAssertEqual(sessions.focusedShellID, 11)
  }

  func testSkipsTargetsThatClosedOrChangedWhileThePaletteWasOpen() async {
    let sessions = await model()
    sessions.showSession(1)
    sessions.focus(10)
    let perform = performer(sessions)
    XCTAssertFalse(perform.perform(.showSession(9)))
    XCTAssertFalse(perform.perform(.focusPane(99)))
    XCTAssertFalse(perform.perform(.run(.newSessionInWorkspace(workspaceID: "gone"))))
    XCTAssertFalse(perform.perform(.run(.closeSession(2))), "2 is not the selected Session")
    XCTAssertFalse(perform.perform(.run(.closeShell(11))), "11 is not the focused pane")
    XCTAssertEqual(sessions.selectedSessionID, 1)
    XCTAssertEqual(sessions.focusedShellID, 10)
  }

  func testCloseActsOnlyOnTheSessionAndPaneTheUserSaw() async {
    let sessions = await model()
    sessions.showSession(1)
    sessions.focus(10)
    let perform = performer(sessions)
    XCTAssertTrue(perform.perform(.run(.closeShell(10))))
    XCTAssertTrue(perform.perform(.run(.closeSession(1))))
  }

  func testAppCommandsReachTheirHandlers() async throws {
    let sessions = await model()
    let perform = performer(sessions)
    let repository = try XCTUnwrap(GitHubRepository.parsePaletteInput("github:axo/app"))
    XCTAssertTrue(perform.perform(.run(.toggleSidebar)))
    XCTAssertTrue(perform.perform(.run(.newWorkspace)))
    XCTAssertTrue(perform.perform(.cloneGitHubRepository(repository)))
    XCTAssertTrue(perform.perform(.run(.openSettings)))
    XCTAssertTrue(perform.perform(.run(.newSessionInWorkspace(workspaceID: "w1"))))
    XCTAssertEqual([toggled, newWorkspaces, settings], [1, 1, 1])
    XCTAssertEqual(clonedRepository, repository)
  }

  func testTheContextListsSessionsInSidebarOrderWithRecentHistory() async {
    let sessions = await model()
    sessions.showSession(2)
    sessions.showSession(1)
    let context = sessions.commandPaletteContext(homeDirectory: "/h")
    XCTAssertEqual(context.sessions.map(\.id), sessions.sidebarOrderedSessions.map(\.id))
    XCTAssertEqual(Array(context.recentSessionIDs.prefix(2)), [1, 2])
    XCTAssertEqual(context.selectedSessionID, 1)
    XCTAssertEqual(context.focusedShellID, sessions.focusedShellID)
    XCTAssertEqual(context.workspaces.map(\.workspaceId), ["w1"])
    XCTAssertEqual(context.homeDirectory, "/h")
  }
}

final class CommandPaletteHighlightTests: XCTestCase {
  func testHighlightsExactlyTheMatchedCharactersEvenAfterEmoji() {
    let text = CommandPaletteHighlight.attributed("🚀 Deploy", [2, 3])
    let colored = text.runs.filter { $0.foregroundColor != nil }.map { String(text[$0.range].characters) }
    XCTAssertEqual(colored, ["De"])
    XCTAssertEqual(
      CommandPaletteHighlight.attributed("abc", []), AttributedString("abc"))
  }
}
