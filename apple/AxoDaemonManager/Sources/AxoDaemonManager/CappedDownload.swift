import Foundation

/// Downloads a URL into a file, giving up as soon as the body is longer than a limit, so a wrong
/// or hostile answer cannot fill the disk before anything checks what it is.
final class CappedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  enum Failure: Error, Equatable {
    case status(Int)
    case tooLarge(maximumBytes: Int64)
    case transport(String)
  }

  /// `@unchecked Sendable`: the state below is touched only from the delegate's serial queue.
  private let file: FileHandle
  private let maximumBytes: Int64
  private var written: Int64 = 0
  private var failure: Failure?
  private var continuation: CheckedContinuation<Void, Error>?

  private init(file: FileHandle, maximumBytes: Int64) {
    self.file = file
    self.maximumBytes = maximumBytes
  }

  /// Writes `url`'s body to a new file at `destination`. Throws `Failure` for an answer other
  /// than 200, a body (or a declared length) over `maximumBytes`, or a transport error.
  static func fetch(
    _ url: URL, to destination: URL, maximumBytes: Int64, configuration: URLSessionConfiguration
  ) async throws {
    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
      throw Failure.transport("could not create \(destination.lastPathComponent)")
    }
    let file = try FileHandle(forWritingTo: destination)
    defer { try? file.close() }
    let download = CappedDownload(file: file, maximumBytes: maximumBytes)
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: download, delegateQueue: queue)
    defer { session.finishTasksAndInvalidate() }
    let task = session.dataTask(with: url)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        queue.addOperation {
          download.continuation = continuation
          task.resume()
        }
      }
    } onCancel: {
      task.cancel()
    }
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status != 200 {
      failure = .status(status)
    } else if response.expectedContentLength > maximumBytes {
      failure = .tooLarge(maximumBytes: maximumBytes)
    }
    completionHandler(failure == nil ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard failure == nil else { return }
    written += Int64(data.count)
    guard written <= maximumBytes else {
      failure = .tooLarge(maximumBytes: maximumBytes)
      dataTask.cancel()
      return
    }
    do { try file.write(contentsOf: data) } catch {
      failure = .transport(error.localizedDescription)
      dataTask.cancel()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let continuation = continuation
    self.continuation = nil
    if let failure {
      continuation?.resume(throwing: failure)
    } else if let error {
      if (error as? URLError)?.code == .cancelled {
        continuation?.resume(throwing: CancellationError())
      } else {
        continuation?.resume(throwing: Failure.transport(error.localizedDescription))
      }
    } else {
      continuation?.resume()
    }
  }
}
