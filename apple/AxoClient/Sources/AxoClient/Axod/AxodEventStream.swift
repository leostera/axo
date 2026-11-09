import AxoProtocol
import Foundation

/// Events axod pushes on a connection of their own (`axo.session.events.stream`).
///
/// The subscription lives exactly as long as the connection: `close()` ends both. `next()`
/// returns `nil` once the stream ended, by `close()`, by axod (it ends a stream after a lag
/// marker), or by the connection dropping; the caller then opens a new one and relists.
public final class AxodEventStream: Sendable {
  public let subscription: TerminalSubscriptionID
  private let rpc: JSONRPCConnection
  private let batches: AsyncStream<[TerminalSessionEvent]>
  private let reader: Task<Void, Never>

  static func open(transport: any AxoTransport, request: SessionSubscribeRequest) async throws
    -> AxodEventStream
  {
    let rpc = JSONRPCConnection(transport: transport)
    // Listen before asking, so a batch right after the answer is not missed.
    let (batches, sink) = AsyncStream<[TerminalSessionEvent]>.makeStream()
    let reader = Task {
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          for await notification in rpc.notifications
          where notification.method == AxodEventStream.eventsMethod {
            guard let batch = try? notification.params(as: Batch.self) else { continue }
            sink.yield(batch.events)
          }
        }
        group.addTask {
          for await _ in rpc.connectionLost { return }
        }
        await group.next()
        group.cancelAll()
      }
      sink.finish()
    }
    do {
      let subscription: TerminalSubscriptionID = try await rpc.call(
        AxodEventStream.openMethod, params: request, timeout: .seconds(10))
      return AxodEventStream(
        subscription: subscription, rpc: rpc, batches: batches, reader: reader)
    } catch {
      reader.cancel()
      await rpc.disconnect()
      throw error
    }
  }

  private init(
    subscription: TerminalSubscriptionID, rpc: JSONRPCConnection,
    batches: AsyncStream<[TerminalSessionEvent]>, reader: Task<Void, Never>
  ) {
    self.subscription = subscription
    self.rpc = rpc
    self.batches = batches
    self.reader = reader
  }

  /// The next batch, in order, or `nil` once the stream ended.
  public func next() async -> [TerminalSessionEvent]? {
    var iterator = batches.makeAsyncIterator()
    return await iterator.next()
  }

  /// Ends the stream and its subscription.
  public func close() async {
    reader.cancel()
    await rpc.disconnect()
  }

  static let openMethod = "axo.session.events.stream"
  static let eventsMethod = "axo.session.events"

  private struct Batch: Decodable {
    let events: [TerminalSessionEvent]
  }
}
