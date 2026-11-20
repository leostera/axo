import AxoClient
import AxoProtocol
import XCTest

@testable import AxoMobileModel

@MainActor
final class DraftModelSelectionTests: XCTestCase {
  private let model = PiModel(provider: "test", id: "reasoner", name: "Reasoner", thinkingLevels: [.off, .high])
  private let catalog = #"{"models":[{"provider":"test","id":"reasoner","name":"Reasoner","thinkingLevels":["off","high"]}]}"#

  private func world(_ macs: [Mac]) async throws -> PhoneWorld {
    let world = PhoneWorld(macs, answers: false)
    world.transport.listing = Wire.listing(hosts: macs.map(\.hostJSON), sessions: macs.flatMap { mac in
      mac.sessions.map { Wire.session(host: mac.id, id: $0, name: "Existing", status: "ready") }
    })
    // History is independent of model initialization, and must not stall these tests.
    world.transport.responder = { request in
      request.method == "axo.client.session.open" ? .result(Wire.opened(epoch: nil, [])) : nil
    }
    try await world.start()
    return world
  }

  private func beginSend(_ world: PhoneWorld, host: Mac, channel: ScriptedChannel) async throws -> Task<PhoneWorkbench.SendOutcome, Never> {
    let phone = world.workbench!
    let destination = try XCTUnwrap(phone.selection)
    phone.setDraft("First message", for: destination)
    phone.chooseModel(model, thinkingLevel: .high, for: destination)
    let sending = Task { await phone.send() }
    let create = try await channel.nextRequest()
    XCTAssertEqual(create.method, "axo.remote.session.create")
    channel.reply(to: create.id, result: #"{"session":\#(sessionJSON(host: host.id, id: 99, name: "New chat", shells: []))}"#)
    return sending
  }

  private func acknowledgeConfiguration(_ channel: ScriptedChannel) async throws {
    let models = try await channel.nextRequest()
    XCTAssertEqual(models.method, "axo.remote.session.models")
    XCTAssertEqual(models.params["sessionId"] as? String, SessionID(integerLiteral: 99).rawValue)
    channel.reply(to: models.id, result: catalog)
    let set = try await channel.nextRequest()
    XCTAssertEqual(set.method, "axo.remote.session.model.set")
    XCTAssertEqual(set.params["model"] as? [String: String], ["provider": "test", "id": "reasoner"])
    XCTAssertEqual(set.params["thinkingLevel"] as? String, "high")
    XCTAssertFalse(channel.hasRequest, "no first prompt while configuration acknowledgement is held")
    channel.reply(to: set.id, result: #"{"saved":true}"#)
  }

  func testInspectingAHostCatalogCreatesNoChatAndChangesNoExistingModel() async throws {
    let host = Mac("A", online: true)
    let world = try await world([host])
    let phone = world.workbench!
    let channel = try await world.transport.channel()
    let loading = Task { await phone.current?.loadDraftModels(for: .opencode) }
    let read = try await channel.nextRequest()
    XCTAssertEqual(read.method, "axo.remote.agents.models")
    XCTAssertEqual(read.params["agent"] as? String, "opencode")
    XCTAssertNil(read.params["sessionId"])
    XCTAssertEqual(read.hostID, host.id.uuidString.lowercased())
    channel.reply(to: read.id, result: catalog)
    await loading.value
    XCTAssertEqual(phone.current?.draftModels, [model])
    XCTAssertNil(phone.selection?.session)
    XCTAssertFalse(channel.hasRequest, "no create, model.set or prompt")
  }

  func testFirstPromptWaitsForAvailabilityAndConfigurationAcknowledgement() async throws {
    let host = Mac("A", online: true, sessions: [1])
    let world = try await world([host])
    let channel = try await world.transport.channel()
    let sending = try await beginSend(world, host: host, channel: channel)
    try await acknowledgeConfiguration(channel)
    let prompt = try await channel.nextRequest()
    XCTAssertEqual(prompt.method, "axo.remote.session.prompt")
    XCTAssertEqual(prompt.params["text"] as? String, "First message")
    channel.reply(to: prompt.id, result: #"{"accepted":true}"#)
    let result = await sending.value
    XCTAssertEqual(result, .sent)
    XCTAssertEqual(world.workbench.selection?.session, 99)
    XCTAssertFalse(channel.hasRequest)
  }

  func testConfigurationFailureKeepsDraftAndRetryUsesTheSameChat() async throws {
    let host = Mac("A", online: true, sessions: [1])
    let world = try await world([host])
    let channel = try await world.transport.channel()
    let sending = try await beginSend(world, host: host, channel: channel)
    channel.reply(to: try await channel.nextRequest("axo.remote.session.models").id, result: catalog)
    let set = try await channel.nextRequest("axo.remote.session.model.set")
    channel.reply(to: set.id, error: -32007, message: "Provider credentials unavailable")
    let failed = await sending.value
    XCTAssertEqual(failed, .failed)
    let destination = try XCTUnwrap(world.workbench.selection)
    XCTAssertEqual(destination.session, 99)
    XCTAssertEqual(world.workbench.draft(for: destination), "First message")
    XCTAssertEqual(world.workbench.modelChoice(for: destination)?.thinkingLevel, .high)
    XCTAssertFalse(channel.hasRequest, "a failed set cannot fall through to prompt")

    let retry = Task { await world.workbench.send() }
    try await acknowledgeConfiguration(channel) // starts with models, not another create
    let prompt = try await channel.nextRequest()
    XCTAssertEqual(prompt.method, "axo.remote.session.prompt")
    channel.reply(to: prompt.id, result: #"{"accepted":true}"#)
    let result = await retry.value
    XCTAssertEqual(result, .sent)
  }

  func testUnavailableChoiceDoesNotDowngradeOrSend() async throws {
    let host = Mac("A", online: true, sessions: [1])
    let world = try await world([host])
    let channel = try await world.transport.channel()
    let sending = try await beginSend(world, host: host, channel: channel)
    let read = try await channel.nextRequest()
    XCTAssertEqual(read.method, "axo.remote.session.models")
    channel.reply(to: read.id, result: #"{"models":[]}"#)
    let result = await sending.value
    XCTAssertEqual(result, .failed)
    XCTAssertFalse(channel.hasRequest)
    XCTAssertEqual(world.workbench.draft(for: try XCTUnwrap(world.workbench.selection)), "First message")
  }

  func testHostChoicesAreSeparateAndLateCatalogCannotReplaceAnotherHostsCatalog() async throws {
    let a = Mac("A", online: true, sessions: [1])
    let b = Mac("B", online: true, sessions: [2])
    let world = try await world([a, b])
    let phone = world.workbench!
    phone.select(host: a.id, session: nil)
    let aSelection = try XCTUnwrap(phone.selection)
    phone.chooseModel(model, thinkingLevel: .high, for: aSelection)
    let aWorkbench = try XCTUnwrap(phone.current)
    let loadingA = Task { await aWorkbench.loadDraftModels() }
    let channel = try await world.transport.channel()
    let readA = try await channel.nextRequest()
    phone.chooseHost(b.id)
    XCTAssertNil(phone.modelChoice(for: try XCTUnwrap(phone.selection)))
    let loadingB = Task { await phone.current?.loadDraftModels() }
    let readB = try await channel.nextRequest()
    channel.reply(to: readB.id, result: #"{"models":[{"provider":"other","id":"small","name":"Small","thinkingLevels":["off"]}]}"#)
    await loadingB.value
    channel.reply(to: readA.id, result: catalog)
    await loadingA.value
    XCTAssertEqual(phone.current?.draftModels?.map(\.id), ["small"])
    XCTAssertEqual(phone.selection?.host, b.id)
    phone.chooseHost(a.id)
    XCTAssertEqual(phone.modelChoice(for: try XCTUnwrap(phone.selection))?.model, model)
    phone.chooseModel(nil, for: try XCTUnwrap(phone.selection))
    XCTAssertNil(phone.modelChoice(for: try XCTUnwrap(phone.selection)))
  }

  func testNavigationDuringCreateRetiresSendAndAnExplicitRetryReusesItsPreparedChat() async throws {
    let a = Mac("A", online: true, sessions: [1])
    let b = Mac("B", online: true, sessions: [2])
    let world = try await world([a, b])
    let phone = world.workbench!
    phone.select(host: a.id, session: nil)
    let destination = try XCTUnwrap(phone.selection)
    phone.setDraft("First message", for: destination)
    phone.chooseModel(model, thinkingLevel: .high, for: destination)
    let sending = Task { await phone.send() }
    let channel = try await world.transport.channel()
    let create = try await channel.nextRequest("axo.remote.session.create")
    // Even returning to A does not revive the old Send.
    phone.select(host: b.id, session: nil)
    phone.select(host: a.id, session: nil)
    channel.reply(to: create.id, result: #"{"session":\#(sessionJSON(host: a.id, id: 99, name: "New chat", shells: []))}"#)
    let result = await sending.value
    XCTAssertEqual(result, .failed)
    XCTAssertEqual(phone.selection, destination)
    XCTAssertEqual(phone.draft(for: destination), "First message")
    XCTAssertFalse(channel.hasRequest)
    // Even before the account lists it, the acknowledged creation belongs to this draft.
    let retry = Task { await phone.send() }
    try await acknowledgeConfiguration(channel)
    let prompt = try await channel.nextRequest("axo.remote.session.prompt")
    channel.reply(to: prompt.id, result: #"{"accepted":true}"#)
    let retried = await retry.value
    XCTAssertEqual(retried, .sent)
  }

  func testLeavingConversationRetiresPendingSendWithoutChangingItsDraftOrSelection() async throws {
    let host = Mac("A", online: true, sessions: [1])
    let world = try await world([host])
    let phone = world.workbench!
    phone.select(host: host.id, session: nil)
    let destination = try XCTUnwrap(phone.selection)
    phone.setDraft("Keep this draft", for: destination)
    phone.chooseModel(model, thinkingLevel: .high, for: destination)
    let sending = Task { await phone.send() }
    let channel = try await world.transport.channel()
    let create = try await channel.nextRequest("axo.remote.session.create")
    phone.retirePendingSend()
    channel.reply(to: create.id, result: #"{"session":\#(sessionJSON(host: host.id, id: 99, name: "New chat", shells: []))}"#)
    let result = await sending.value
    XCTAssertEqual(result, .failed)
    XCTAssertEqual(phone.selection, destination)
    XCTAssertEqual(phone.draft(for: destination), "Keep this draft")
    XCTAssertFalse(channel.hasRequest, "Opening Apps cannot release a delayed configuration or prompt")
  }

  func testAnEmptyHostReportsUnavailabilityWithoutCreatingAnything() async throws {
    let world = try await world([Mac("Empty", online: true)])
    let loading = Task { await world.workbench.current?.loadDraftModels() }
    let channel = try await world.transport.channel()
    let read = try await channel.nextRequest("axo.remote.agents.models")
    channel.reply(to: read.id, result: #"{"models":[]}"#)
    await loading.value
    XCTAssertEqual(world.workbench.current?.draftModels, [])
    XCTAssertNotNil(world.workbench.current?.draftModelsFailure)
    XCTAssertFalse(channel.hasRequest)
  }

  func testAHostRestartDoesNotInheritThePreviousGenerationsDraftChoice() async throws {
    var host = Mac("A", online: true, sessions: [1])
    let world = try await world([host])
    let destination = try XCTUnwrap(world.workbench.selection)
    world.workbench.chooseModel(model, thinkingLevel: .high, for: destination)
    host.generation = UUID()
    world.transport.listing = Mac.listing([host])
    await world.workbench.refresh()
    XCTAssertEqual(world.workbench.current?.reference.hostGeneration, host.generation)
    XCTAssertNil(world.workbench.modelChoice(for: destination))
  }

  func testInvalidThinkingCannotEraseAnExplicitChoice() async throws {
    let world = try await world([Mac("A", online: true)])
    let destination = try XCTUnwrap(world.workbench.selection)
    world.workbench.chooseModel(model, thinkingLevel: .high, for: destination)
    world.workbench.chooseModel(model, thinkingLevel: .xhigh, for: destination)
    XCTAssertEqual(world.workbench.modelChoice(for: destination)?.thinkingLevel, .high)
    XCTAssertNil(DraftModelChoice(model: model, thinkingLevel: .xhigh))
  }
}
