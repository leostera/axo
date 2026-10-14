import ComposableArchitecture
import HexCore
import ScreenCaptureKit
import SwiftUI
import XCTest

@testable import Hex

@MainActor
final class RustBetaBannerTests: XCTestCase {
	func testEligibilityRequiresAppleSiliconAndMacOS15() {
		XCTAssertFalse(RustBetaAnnouncement.isSupported(macOSMajorVersion: 14, appleSilicon: true))
		XCTAssertFalse(RustBetaAnnouncement.isSupported(macOSMajorVersion: 15, appleSilicon: false))
		XCTAssertTrue(RustBetaAnnouncement.isSupported(macOSMajorVersion: 15, appleSilicon: true))
		XCTAssertTrue(RustBetaAnnouncement.isSupported(macOSMajorVersion: 26, appleSilicon: true))
		XCTAssertEqual(RustBetaAnnouncement.downloadURL.absoluteString, "https://hex.kitlangton.com")
	}

	func testDismissalOnlyChangesTheBannerPreference() async {
		let settings = Shared(value: HexSettings())
		let bootstrap = Shared(value: ModelBootstrapState())
		let state = SettingsFeature.State(
			hexSettings: settings,
			transcriptionHistory: Shared(value: .init()),
			modelDownload: ModelDownloadFeature.State(hexSettings: settings, modelBootstrapState: bootstrap)
		)
		let store = Store(initialState: state) { SettingsFeature() }
		await store.send(.dismissRustBetaBanner).finish()
		await store.send(.dismissRustBetaBanner).finish()
		var expected = HexSettings()
		expected.hasDismissedRustBetaBanner = true
		XCTAssertEqual(settings.wrappedValue, expected)
	}

	func testSettingsScreenshots() async throws {
		guard ProcessInfo.processInfo.environment["HEX_BANNER_SCREENSHOTS"] == "1" else {
			throw XCTSkip("Use tools/scripts/capture-rust-beta-banner.ts for isolated Settings previews.")
		}
		XCTAssertEqual(Bundle.main.bundleIdentifier, "ly.anoma.Hex.LegacyBannerPreview")
		guard #available(macOS 15.0, *), RustBetaAnnouncement.isAvailable else {
			throw XCTSkip("The beta banner requires Apple silicon and macOS 15 or newer.")
		}
		let variants: [(String, CGFloat, CGFloat, ColorScheme, Bool)] = [
			("light", 700, 700, .light, false),
			("dark", 700, 700, .dark, false),
			("narrow", 620, 560, .light, false),
			("dismissed", 700, 700, .light, true),
		]
		for (name, width, height, scheme, dismissed) in variants {
			let store = previewStore()
			if dismissed {
				store.send(.settings(.dismissRustBetaBanner))
			}
			let view = NSHostingView(rootView: AppView(store: store)
				.frame(width: width, height: height)
				.environment(\.colorScheme, scheme)
				.environment(\.controlActiveState, .active)
				.environment(\.openURL, OpenURLAction { _ in .handled }))
			let window = NSWindow(
				contentRect: NSRect(x: 0, y: 0, width: width, height: height),
				styleMask: [.titled, .fullSizeContentView, .closable, .resizable],
				backing: .buffered,
				defer: false
			)
			window.isReleasedWhenClosed = false
			window.ignoresMouseEvents = true
			window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
			window.toolbarStyle = .unified
			window.contentView = view
			window.center()
			window.orderFrontRegardless()
			defer { window.close() }
			try await Task.sleep(for: .milliseconds(400))
			view.layoutSubtreeIfNeeded()
			// Capture only our own window, without requesting general screen-recording access.
			let content = try await SCShareableContent.currentProcess
			let ownedWindow = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
			XCTAssertEqual(ownedWindow.owningApplication?.processID, ProcessInfo.processInfo.processIdentifier)
			let filter = SCContentFilter(desktopIndependentWindow: ownedWindow)
			let configuration = SCStreamConfiguration()
			configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
			configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
			configuration.showsCursor = false
			configuration.ignoreShadowsSingleWindow = true
			let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
			let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
			XCTAssertGreaterThan(png.count, 10_000)
			let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
			attachment.name = "Rust beta Settings - \(name)"
			attachment.lifetime = .keepAlways
			add(attachment)
		}
	}

	private func previewStore() -> StoreOf<AppFeature> {
		let settings = Shared(value: HexSettings(
			selectedModel: ParakeetModel.englishV2.identifier,
			hasCompletedModelBootstrap: true,
			hasCompletedStorageMigration: true
		))
		let history = Shared(value: TranscriptionHistory())
		let bootstrap = Shared(value: ModelBootstrapState())
		let model = CuratedModelInfo(
			displayName: "Parakeet TDT v2",
			internalName: ParakeetModel.englishV2.identifier,
			size: "English", accuracyStars: 5, speedStars: 5, storageSize: "650MB", isDownloaded: true
		)
		let state = AppFeature.State(
			transcription: TranscriptionFeature.State(
				hexSettings: settings, modelBootstrapState: bootstrap, transcriptionHistory: history
			),
			settings: SettingsFeature.State(
				hexSettings: settings,
				transcriptionHistory: history,
				availableInputDevices: [.init(id: "fixture:microphone", name: "Built-in Microphone", legacyID: "fixture")],
				defaultInputDeviceName: "Built-in Microphone",
				modelDownload: ModelDownloadFeature.State(
					hexSettings: settings, modelBootstrapState: bootstrap,
					availableModels: [ModelInfo(name: model.internalName, isDownloaded: true)],
					curatedModels: [model]
				)
			),
			history: HistoryFeature.State(transcriptionHistory: history),
			hexSettings: settings,
			modelBootstrapState: bootstrap,
			microphonePermission: .granted,
			accessibilityPermission: .granted,
			inputMonitoringPermission: .granted
		)
		// Render production views without starting hardware, network, or file-backed effects.
		return Store(initialState: state) {
			Reduce { state, action in
				if case .settings(.dismissRustBetaBanner) = action {
					state.settings.$hexSettings.withLock { $0.hasDismissedRustBetaBanner = true }
				}
				return .none
			}
		}
	}
}
