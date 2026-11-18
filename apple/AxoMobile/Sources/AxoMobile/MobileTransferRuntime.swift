import AxoClient
import AxoMobileModel
import Foundation
import SwiftUI

/// Only this fixed, non-secret receipt crosses to the installation harness.
@MainActor
enum MobileTransferRuntime {
  enum Status: String, Codable { case exported, exportedSignedOut, completed, completedSignedOut, unavailable, invalid, conflict, revoked, pendingWork }
  struct Report: Encodable {
    let schema = 1
    let runID: UUID
    let sourceRunID: UUID
    let bundleID: String
    let status: Status
  }
  static let filename = "axo-identity-transfer.json"

  static func exportIfRequested(pendingWork: Bool) {
    guard MobileTransferConfiguration.requested,
      Bundle.main.bundleIdentifier == "dev.leostera.axo.phone" else { return }
    guard let text = ProcessInfo.processInfo.environment["AXO_IDENTITY_TRANSFER_RUN_ID"],
      let id = UUID(uuidString: text) else { return }
    let status: Status
    do {
      let config = try MobileTransferConfiguration.current()
      guard config.mode == .source else { throw MobileIdentityTransfer.Failure.invalid }
      guard !pendingWork, try !hasRecordingFiles() else { throw MobileIdentityTransfer.Failure.pendingWork }
      let bridge = try MobileTransferKeychain(accessGroup: config.accessGroup)
      if let fence = try bridge.fence() {
        guard fence == .ready(id), let bytes = try bridge.payload() else { throw MobileIdentityTransfer.Failure.conflict }
        let snapshot = try MobileIdentityTransfer.parse(bytes, expectedID: id)
        status = snapshot.session == nil ? .exportedSignedOut : .exported
      } else {
        let token = try KeychainTokenStore().loadForCompanion()
        let bytes = try MobileIdentityTransfer.export(defaults: .standard, token: token, transferID: id)
        try bridge.prepare(bytes, id: id)
        status = token == nil ? .exportedSignedOut : .exported
      }
    } catch { status = classify(error) }
    write(Report(runID: id, sourceRunID: id, bundleID: "dev.leostera.axo.phone", status: status))
  }

  static func importIfRequested() async -> Status {
    let runID = ProcessInfo.processInfo.environment["AXO_IDENTITY_TRANSFER_RUN_ID"].flatMap(UUID.init(uuidString:)) ?? UUID()
    var sourceID = ProcessInfo.processInfo.environment["AXO_IDENTITY_TRANSFER_SOURCE_RUN_ID"].flatMap(UUID.init(uuidString:))
    let status: Status
    do {
      let config = try MobileTransferConfiguration.current()
      guard config.mode == .destination else { throw MobileIdentityTransfer.Failure.invalid }
      let journal = try MobileTransferJournal(accessGroup: config.accessGroup)
      let bridge = try MobileTransferKeychain(accessGroup: config.accessGroup)
      let bytes: Data
      if let saved = try journal.load() {
        let state = try MobileIdentityTransfer.readJournal(saved)
        guard !state.completed, let staged = state.staged else { throw MobileIdentityTransfer.Failure.alreadyCompleted }
        guard sourceID == nil || sourceID == state.transferID else { throw MobileIdentityTransfer.Failure.conflict }
        sourceID = state.transferID
        bytes = staged
      } else {
        guard sourceID != nil, let payload = try bridge.payload() else { throw MobileIdentityTransfer.Failure.unavailable }
        bytes = payload
      }
      guard let id = sourceID else { throw MobileIdentityTransfer.Failure.invalid }
      let snapshot = try MobileIdentityTransfer.parse(bytes, expectedID: id)
      if let token = snapshot.session {
        // Do not activate normal account/companion services to validate the imported session.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let account = try await AccountClient(tokens: StaticSessionToken(token), loader: session).account()
        guard account.accountId == token.accountID else { throw MobileIdentityTransfer.Failure.conflict }
      }
      try Task.checkCancellation()
      try MobileIdentityTransfer.apply(snapshot: snapshot, bytes: bytes, bridge: bridge,
        destination: TransferDestination(journalStore: journal))
      status = snapshot.session == nil ? .completedSignedOut : .completed
    } catch { status = classify(error) }
    write(Report(runID: runID, sourceRunID: sourceID ?? runID, bundleID: Bundle.main.bundleIdentifier ?? "unknown", status: status))
    return status
  }

  static func reportCommittedIfRequested() {
    guard MobileTransferConfiguration.requested, Bundle.main.bundleIdentifier == "dev.leostera.axo",
      let text = ProcessInfo.processInfo.environment["AXO_IDENTITY_TRANSFER_RUN_ID"], let runID = UUID(uuidString: text)
    else { return }
    do {
      let config = try MobileTransferConfiguration.current()
      guard let bytes = try MobileTransferJournal(accessGroup: config.accessGroup).load() else { return }
      let receipt = try MobileIdentityTransfer.readJournal(bytes)
      guard receipt.completed else { return }
      let expected = ProcessInfo.processInfo.environment["AXO_IDENTITY_TRANSFER_SOURCE_RUN_ID"].flatMap(UUID.init(uuidString:))
      let bridge = try MobileTransferKeychain(accessGroup: config.accessGroup)
      let status: Status
      let fence = try bridge.fence()
      if expected != nil && expected != receipt.transferID { status = .conflict }
      else if receipt.sessionOwnership != .transferred || fence != .consumed(receipt.transferID) { status = .revoked }
      else { status = try KeychainTokenStore().loadForCompanion() == nil ? .completedSignedOut : .completed }
      write(Report(runID: runID, sourceRunID: receipt.transferID, bundleID: "dev.leostera.axo", status: status))
    } catch { /* Never resurrect a credential or overwrite a valid report because storage is locked. */ }
  }

  private static func hasRecordingFiles() throws -> Bool {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axo-watch-voice", isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else { return false }
    return try !FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty
  }

  private static func classify(_ error: Error) -> Status {
    if (error as? RelayError) == .signInRequired { return .revoked }
    if (error as? PhoneDeviceKey.StorageError) == .identityMismatch { return .conflict }
    switch error as? MobileIdentityTransfer.Failure {
    case .invalid, .expired: return .invalid
    case .conflict: return .conflict
    case .revoked: return .revoked
    case .pendingWork: return .pendingWork
    default: return .unavailable
    }
  }

  private static func write(_ report: Report) {
    guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent(filename)
      try JSONEncoder().encode(report).write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    } catch { /* Missing receipt never counts as completed migration. */ }
  }
}

private struct TransferDestination: MobileIdentityTransfer.Destination {
  let defaults = UserDefaults.standard
  let journalStore: MobileTransferJournal
  func token() throws -> SessionToken? { try KeychainTokenStore().loadForCompanion() }
  func saveToken(_ token: SessionToken) throws { try KeychainTokenStore().save(token) }
  func journal() throws -> Data? { try journalStore.load() }
  func saveJournal(_ data: Data) throws { try journalStore.save(data) }
}

struct MobileTransferView: View {
  let onCompleted: () -> Void
  @State private var running = false
  @State private var status: MobileTransferRuntime.Status?

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "lock.shield").font(.largeTitle)
      Text("Keep your Axo sign-in").font(.title2.bold())
      Text(message).multilineTextAlignment(.center)
      if running { ProgressView() }
      else { Button("Check transfer") { Task { await run() } }.buttonStyle(.borderedProminent) }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task { await run() }
  }

  private var message: String {
    switch status {
    case .conflict: "Existing account, preferences or approval identity differ. Nothing will be replaced."
    case .revoked: "The original sign-in changed. This transfer is stopped; use the original Axo."
    case .pendingWork: "Finish the recording or draft in the original Axo first."
    case .invalid: "A current transfer from the original Axo is required."
    case .unavailable: "Unlock this device and check its connection. The original Axo stays intact."
    default: "Checking your existing account, preferences and approval identity on this device. No key will be replaced."
    }
  }

  private func run() async {
    guard !running else { return }
    running = true
    status = await MobileTransferRuntime.importIfRequested()
    running = false
    if !MobileTransferConfiguration.requiresDestinationGate { onCompleted() }
  }
}
