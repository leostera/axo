#if os(iOS) || os(macOS)
import CryptoKit
import Foundation
import os

/// Only immutable, individually verified model files enter the cache. The downloader never
/// receives an audio buffer, transcript, user identifier, or Axo credentials.
enum ParakeetAssets {
  static let revision = "ee09c569f73759e6d44c9bd16766f477b2b36d39"
  private static let source = URL(string:
    "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml/resolve/\(revision)/")!

  struct File {
    let path: String
    let size: Int
    let digest: String

    init(_ path: String, _ size: Int, _ digest: String) {
      self.path = path
      self.size = size
      self.digest = digest
    }

    func verify(in directory: URL) throws -> Bool {
      try Task.checkCancellation()
      let url = directory.appendingPathComponent(path)
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
        values.isRegularFile == true, values.fileSize == size else { return false }
      let stream = try FileHandle(forReadingFrom: url)
      defer { try? stream.close() }
      var hash = SHA256()
      while let chunk = try stream.read(upToCount: 1024 * 1024), !chunk.isEmpty {
        try Task.checkCancellation()
        hash.update(data: chunk)
      }
      return hash.finalize().map { String(format: "%02x", $0) }.joined() == digest
    }
  }

  static let files: [File] = [
    .init("Decoder.mlmodelc/analytics/coremldata.bin", 243, "46de1a6fe2e49d19a2125bc91acf020df7f2aea84ba821532aade8427a440b05"),
    .init("Decoder.mlmodelc/coremldata.bin", 554, "d200ca07694a347f6d02a3886a062ae839831e094e443222f2e48a14945966a8"),
    .init("Decoder.mlmodelc/metadata.json", 3427, "90a279b822496316458febc0ce761ab05954fadd9d66aa97bea077a35fc8f2b2"),
    .init("Decoder.mlmodelc/model.mil", 13106, "7b95a5a6b672c652000348a67b6d4d92bb8e176b978c6666fe73c28a4d7ec579"),
    .init("Decoder.mlmodelc/weights/weight.bin", 14429952, "27d26890221d82322c1092fd99d7b40578e435d5cf4b83c887c42603caf97aba"),
    .init("Encoder.mlmodelc/analytics/coremldata.bin", 243, "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
    .init("Encoder.mlmodelc/coremldata.bin", 485, "4def7aa848599ad0e17a8b9a982edcdbf33cf92e1f4b798de32e2ca0bc74b030"),
    .init("Encoder.mlmodelc/metadata.json", 2926, "58222fbc48c13c49d9715567803cd50cb9c23e4360462e0f8ffcea59a2c73c63"),
    .init("Encoder.mlmodelc/model.mil", 959769, "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
    .init("Encoder.mlmodelc/weights/weight.bin", 445187200, "4adc7ad44f9d05e1bffeb2b06d3bb02861a5c7602dff63a6b494aed3bf8a6c3e"),
    .init("JointDecision.mlmodelc/analytics/coremldata.bin", 243, "f1183ba213bb94a918c8d2cad19ab045320618f97f6ca662245b3936d7b090f7"),
    .init("JointDecision.mlmodelc/coremldata.bin", 534, "e2c6752f1c8cf2d3f6f26ec93195c9bfa759ad59edf9f806696a138154f96f11"),
    .init("JointDecision.mlmodelc/metadata.json", 2936, "ba8d309417b9acd4a175fdb15687de6a941db2f5b06666a60e7cf3cc8e2d3c3c"),
    .init("JointDecision.mlmodelc/model.mil", 9722, "93bf82042235127cb81ab537dcae47a1c2e7e242ce4ffdaf772981b45eedc4f0"),
    .init("JointDecision.mlmodelc/weights/weight.bin", 3453388, "ca22a65903a05e64137677da608077578a8606090a598abf4875fa6199aaa19d"),
    .init("Preprocessor.mlmodelc/analytics/coremldata.bin", 243, "03ab3c1327a054c54c07a40325db967ec574f2c91dcc8192bfa44aa561bcf2d8"),
    .init("Preprocessor.mlmodelc/coremldata.bin", 494, "d88ea1fc349459c9e100d6a96688c5b29a1f0d865f544be103001724b986b6d6"),
    .init("Preprocessor.mlmodelc/metadata.json", 2974, "fb16c581ff5e1b962e7cb2181ed892cd32f9f84c12b6e80ff3e089f28e35bcbb"),
    .init("Preprocessor.mlmodelc/model.mil", 27166, "3e06d16fd061294c8a75be68c43a3b1ed1f593d4a9c35249e9cdbccadc59721e"),
    .init("Preprocessor.mlmodelc/weights/weight.bin", 298880, "a5f7df6c7f47147ae9486fe18cc7792f9a44d093ec3c6a11e91ef2dc363c48dc"),
    .init("parakeet_vocab.json", 18762, "57019fe3c745772ca83a1b048a4bb951cd51329504ea33d4d83316b96e279a97"),
  ]

  static func directory(
    in root: URL, allowDownload: Bool, progress: @escaping @Sendable (ParakeetProgress) -> Void
  ) async throws -> URL {
    progress(.checking)
    let fm = FileManager.default
    let ready = root.appendingPathComponent(revision, isDirectory: true)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    // Clean up a process killed during a prior download, and retire superseded revisions.
    if fm.fileExists(atPath: root.path) {
      for item in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where item.lastPathComponent != revision {
        try fm.removeItem(at: item)
      }
    }
    if try files.allSatisfy({ try $0.verify(in: ready) }) { return ready }
    if fm.fileExists(atPath: ready.path) { try fm.removeItem(at: ready) }
    guard allowDownload else { throw ParakeetError.modelNotReady }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 45
    configuration.timeoutIntervalForResource = 15 * 60
    let session = URLSession(configuration: configuration)
    defer {
      session.invalidateAndCancel()
      try? fm.removeItem(at: staging)
    }
    let total = Double(files.reduce(0) { $0 + $1.size })
    var completed = 0
    progress(.downloading(0))
    for file in files {
      try Task.checkCancellation()
      let offset = completed
      let monitor = DownloadMonitor(limit: file.size) { bytes in
        progress(.downloading(Double(offset + bytes) / total))
      }
      let (temporary, response) = try await session.download(
        for: URLRequest(url: source.appendingPathComponent(file.path)), delegate: monitor)
      defer { try? fm.removeItem(at: temporary) }
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ParakeetError.modelDownload }
      try Task.checkCancellation()
      let destination = staging.appendingPathComponent(file.path)
      try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.moveItem(at: temporary, to: destination)
      guard try file.verify(in: staging) else { throw ParakeetError.modelDownload }
      completed += file.size
      progress(.downloading(Double(completed) / total))
    }
    try Task.checkCancellation()
    try fm.moveItem(at: staging, to: ready)
    return ready
  }
}

private final class DownloadMonitor: NSObject, URLSessionDownloadDelegate {
  let limit: Int
  let report: @Sendable (Int) -> Void
  private let lastReport = OSAllocatedUnfairLock(initialState: 0)

  init(limit: Int, report: @escaping @Sendable (Int) -> Void) {
    self.limit = limit
    self.report = report
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL) { /* download(for:) owns the temporary URL */ }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard totalBytesWritten <= limit, totalBytesExpectedToWrite <= limit else {
      downloadTask.cancel()
      return
    }
    if lastReport.withLock({ last in
      guard totalBytesWritten - Int64(last) >= 2 * 1024 * 1024 else { return false }
      last = Int(totalBytesWritten)
      return true
    }) { report(Int(totalBytesWritten)) }
  }
}
#endif
