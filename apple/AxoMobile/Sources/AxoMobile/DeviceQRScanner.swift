import SwiftUI
import VisionKit

/// Camera frames and raw codes stay in this process. Nothing is photographed or uploaded.
struct DeviceQRScanner: UIViewControllerRepresentable {
  let scanned: (String) -> Void
  let failed: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned, failed: failed) }

  func makeUIViewController(context: Context) -> UIViewController {
    guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
      Task { @MainActor in failed() }
      return UIViewController()
    }
    let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
      qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
      isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
    scanner.delegate = context.coordinator
    do { try scanner.startScanning() } catch { Task { @MainActor in failed() } }
    return scanner
  }

  func updateUIViewController(_ controller: UIViewController, context: Context) {}

  static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
    (controller as? DataScannerViewController)?.stopScanning()
  }

  @MainActor
  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    let scanned: (String) -> Void
    let failed: () -> Void
    private var completed = false
    init(scanned: @escaping (String) -> Void, failed: @escaping () -> Void) {
      self.scanned = scanned; self.failed = failed
    }
    func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
      guard !completed else { return }
      for item in addedItems {
        guard case .barcode(let barcode) = item, let text = barcode.payloadStringValue else { continue }
        completed = true
        scanner.stopScanning()
        scanned(text)
        return
      }
    }
    func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
      guard !completed else { return }
      completed = true
      scanner.stopScanning()
      failed()
    }
  }
}
