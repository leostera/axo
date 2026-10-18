import AppKit
import AxoRPC
import Darwin
import Foundation
import GhosttyKit

@MainActor
final class GhosttyRuntime: ObservableObject {
  @Published private(set) var errorMessage: String?
  @Published private(set) var scrollSensitivity: Double

  private struct SurfaceEntry {
    let shell: TerminalShell
    let host: GhosttySurfaceHostNSView
    let view: GhosttySurfaceNSView
  }

  private var config: ghostty_config_t?
  private var app: ghostty_app_t?
  private(set) var focusedShellID: Int64?
  // A Ghostty surface and its platform NSView outlive SwiftUI's pane view identities.
  private var terminalSurfaces: [Int64: SurfaceEntry] = [:]
  private var notificationTokens: [NSObjectProtocol] = []

  init() {
    let storedSensitivity =
      UserDefaults.standard.object(
        forKey: TerminalScrollSensitivity.preferenceKey
      ) as? Double
    scrollSensitivity = TerminalScrollSensitivity.boundedMultiplier(
      storedSensitivity ?? TerminalScrollSensitivity.defaultMultiplier
    )
    initialize()
  }

  deinit {
    notificationTokens.forEach(NotificationCenter.default.removeObserver)
    MainActor.assumeIsolated {
      for entry in terminalSurfaces.values {
        entry.view.removeFromSuperview()
        if let surface = entry.view.detach() {
          ghostty_surface_free(surface)
        }
      }
    }
    if let app {
      ghostty_app_free(app)
    }
    if let config {
      ghostty_config_free(config)
    }
  }

  func surfaceView(
    for shell: TerminalShell,
    helperURL: URL,
    onFocus: @escaping () -> Void,
    onStatusChange: @escaping (String) -> Void,
    onSplit: @escaping (TerminalSplitDirection) -> Void,
    onClose: @escaping () -> Void
  ) -> GhosttySurfaceNSView {
    if let existing = terminalSurfaces[shell.id], existing.shell == shell {
      existing.view.onFocus = onFocus
      existing.view.onStatusChange = onStatusChange
      existing.view.onSplit = onSplit
      existing.view.onClose = onClose
      onStatusChange(existing.view.status)
      return existing.view
    }

    destroySurface(shellID: shell.id)
    let view = GhosttySurfaceNSView(runtime: self, shellID: shell.id, onFocus: onFocus)
    let host = GhosttySurfaceHostNSView()
    view.onStatusChange = onStatusChange
    view.onSplit = onSplit
    view.onClose = onClose
    createSurface(in: view, shell: shell, helperURL: helperURL)
    host.attachSurface(view)
    terminalSurfaces[shell.id] = SurfaceEntry(shell: shell, host: host, view: view)
    return view
  }

  func surfaceHost(for shellID: Int64) -> GhosttySurfaceHostNSView? {
    terminalSurfaces[shellID]?.host
  }

  func setFocusedShellID(_ shellID: Int64?) {
    focusedShellID = shellID
  }

  func detachSurface(from host: GhosttySurfaceHostNSView) {
    host.detachSurface()
  }

  func setScrollSensitivity(_ multiplier: Double) {
    let multiplier = TerminalScrollSensitivity.boundedMultiplier(multiplier)
    guard multiplier != scrollSensitivity else { return }
    scrollSensitivity = multiplier
    UserDefaults.standard.set(multiplier, forKey: TerminalScrollSensitivity.preferenceKey)
  }

  func reconcileSurfaces(with shells: [TerminalShell]) {
    let openShells = Dictionary(uniqueKeysWithValues: shells.map { ($0.id, $0) })
    let closedShellIDs = terminalSurfaces.compactMap { shellID, entry in
      openShells[shellID] == entry.shell ? nil : shellID
    }
    for shellID in closedShellIDs {
      destroySurface(shellID: shellID)
    }
  }

  private func destroySurface(shellID: Int64) {
    guard let entry = terminalSurfaces.removeValue(forKey: shellID) else { return }
    entry.view.removeFromSuperview()
    if let surface = entry.view.detach() {
      ghostty_surface_free(surface)
    }
  }

  private func createSurface(
    in view: GhosttySurfaceNSView,
    shell: TerminalShell,
    helperURL: URL
  ) {
    guard let app else {
      view.status = errorMessage ?? "libghostty is unavailable."
      return
    }
    guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
      view.status = "The bundled axod terminal-attach helper is missing."
      return
    }

    var surfaceConfig = ghostty_surface_config_new()
    surfaceConfig.userdata = Unmanaged.passUnretained(view).toOpaque()
    surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
    surfaceConfig.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque())
    )
    surfaceConfig.scale_factor = Double(
      view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    )
    surfaceConfig.font_size = 0
    surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

    let command = Self.terminalAttachCommand(
      helperPath: helperURL.path,
      socketPath: shell.attachSocketPath,
      shellID: shell.id
    )

    let createdSurface = shell.initialPwd.withCString { workingDirectory in
      command.withCString { command in
        surfaceConfig.working_directory = workingDirectory
        surfaceConfig.command = command
        return ghostty_surface_new(app, &surfaceConfig)
      }
    }

    guard let createdSurface else {
      view.status = "Ghostty could not create a terminal surface."
      return
    }

    view.attach(createdSurface)
    view.status = "Connected to shell \(shell.id)"
    updateSurfaceSize(in: view, contentSize: view.bounds.size)
  }

  func destroySurface(in view: GhosttySurfaceNSView) {
    guard let surface = view.detach() else { return }
    ghostty_surface_free(surface)
  }

  func tick() {
    guard let app else { return }
    ghostty_app_tick(app)
  }

  func updateFocus(_ focused: Bool) {
    guard let app else { return }
    ghostty_app_set_focus(app, focused)
  }

  var surfaceCount: Int { terminalSurfaces.count }

  var keyWindowFocusedShellID: Int64? {
    guard let focusedView = NSApp.keyWindow?.firstResponder as? GhosttySurfaceNSView else {
      return nil
    }
    return terminalSurfaces.first { $0.value.view === focusedView }?.key
  }

  func hasSurface(for shellID: Int64) -> Bool {
    terminalSurfaces[shellID]?.view.surface != nil
  }

  func focusSurface(for shellID: Int64) -> Bool {
    guard let view = terminalSurfaces[shellID]?.view,
      let window = view.window,
      window.isKeyWindow
    else { return false }
    if window.firstResponder === view { return true }
    return window.makeFirstResponder(view) && window.firstResponder === view
  }

  @discardableResult
  func insertText(_ text: String, into shellID: Int64) -> Bool {
    guard let view = terminalSurfaces[shellID]?.view, view.surface != nil else { return false }
    view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    return true
  }

  @discardableResult
  func perform(_ action: GhosttySurfaceAction, on shellID: Int64? = nil) -> Bool {
    guard let shellID = shellID ?? focusedShellID,
      let surface = terminalSurfaces[shellID]?.view.surface
    else { return false }
    return action.rawValue.withCString {
      ghostty_surface_binding_action(surface, $0, UInt(action.rawValue.utf8.count))
    }
  }

  func forwardKeyEquivalent(_ event: NSEvent) -> Bool {
    guard let shellID = focusedShellID,
      let view = terminalSurfaces[shellID]?.view,
      view.surface != nil
    else { return false }
    view.forwardKeyEquivalent(event)
    return true
  }

  func copySelection(from shellID: Int64? = nil) {
    guard let shellID = shellID ?? focusedShellID,
      let surface = terminalSurfaces[shellID]?.view.surface
    else { return }
    var selection = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &selection) else { return }
    defer { ghostty_surface_free_text(surface, &selection) }
    guard let text = selection.text else { return }
    let data = Data(bytes: text, count: Int(selection.text_len))
    let value = String(decoding: data, as: UTF8.self)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  func pasteClipboard(into shellID: Int64? = nil) {
    guard let shellID = shellID ?? focusedShellID,
      let text = NSPasteboard.general.string(forType: .string)
    else { return }
    pasteText(text, into: shellID)
  }

  func pasteText(_ text: String, into shellID: Int64) {
    guard !text.isEmpty else { return }
    Task { @MainActor [weak self] in
      for _ in 0..<40 {
        guard let self else { return }
        if let surface = self.terminalSurfaces[shellID]?.view.surface {
          text.withCString { ghostty_surface_paste_text(surface, $0, UInt(text.utf8.count)) }
          return
        }
        try? await Task.sleep(for: .milliseconds(25))
      }
    }
  }

  func updateSurfaceSize(in view: GhosttySurfaceNSView, contentSize: CGSize) {
    guard let surface = view.surface else { return }
    let fallbackScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    let frameSize = view.frame.size
    let backingFrame = view.convertToBacking(view.frame)
    let scaleX = frameSize.width > 0 ? backingFrame.width / frameSize.width : fallbackScale
    let scaleY = frameSize.height > 0 ? backingFrame.height / frameSize.height : fallbackScale
    ghostty_surface_set_content_scale(surface, scaleX, scaleY)
    let backingSize = view.convertToBacking(contentSize)
    let width = UInt32(max(0, backingSize.width))
    let height = UInt32(max(0, backingSize.height))
    guard width > 0, height > 0 else { return }
    ghostty_surface_set_size(surface, width, height)
  }

  private func initialize() {
    configureGhosttyResources()

    guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
      errorMessage = "libghostty could not initialize."
      return
    }
    guard let config = ghostty_config_new() else {
      errorMessage = "libghostty could not create its configuration."
      return
    }

    // Load Axo's macOS default first so explicit Ghostty config values can override it.
    loadAxoConfigDefaults(into: config)
    ghostty_config_load_default_files(config)
    ghostty_config_load_recursive_files(config)
    ghostty_config_finalize(config)

    var runtimeConfig = ghostty_runtime_config_s(
      userdata: Unmanaged.passUnretained(self).toOpaque(),
      supports_selection_clipboard: true,
      wakeup_cb: { userdata in GhosttyRuntime.wakeup(userdata) },
      action_cb: { _, target, action in
        // Axo enters libghostty from MainActor-bound surface calls and ticks, so this callback
        // updates AppKit state synchronously on that same thread.
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated {
          GhosttyRuntime.handlePointerAction(target: target, action: action)
        }
      },
      read_clipboard_cb: { userdata, location, state, mimes, count, list in
        guard Thread.isMainThread else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        return MainActor.assumeIsolated {
          GhosttyRuntime.readClipboard(
            userdata: userdata,
            location: location,
            state: state,
            mimes: mimes,
            count: count,
            list: list
          )
        }
      },
      confirm_read_clipboard_cb: { userdata, confirm, state, request in
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
          GhosttyRuntime.confirmClipboardRead(
            userdata: userdata, confirm: confirm, state: state, request: request)
        }
      },
      write_clipboard_cb: { _, location, content, count, confirm in
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
          GhosttyRuntime.writeClipboard(
            location: location, content: content, count: count, confirm: confirm)
        }
      },
      close_surface_cb: { _, _ in }
    )

    guard let app = ghostty_app_new(&runtimeConfig, config) else {
      ghostty_config_free(config)
      errorMessage = "libghostty could not create its terminal app."
      return
    }

    self.config = config
    self.app = app
    ghostty_app_set_focus(app, NSApp.isActive)
    observeApplicationState()
  }

  private func configureGhosttyResources() {
    if let configuredDirectory = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"],
      !configuredDirectory.isEmpty
    {
      return
    }

    let installedAppURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: "com.mitchellh.ghostty"
    )
    let bundledResourcesURL = Bundle.main.resourceURL?.appendingPathComponent(
      "ghostty-resources", isDirectory: true
    )
    guard
      let resourceDirectory = GhosttyResourceLocator.resolve(
        installedGhosttyAppURL: installedAppURL,
        bundledResourcesURL: bundledResourcesURL
      )
    else {
      return
    }
    setenv("GHOSTTY_RESOURCES_DIR", resourceDirectory.path, 1)
  }

  private func loadAxoConfigDefaults(into config: ghostty_config_t) {
    let configURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("axo-ghostty-default-\(UUID().uuidString).ghostty")
    do {
      try "copy-on-select = clipboard\n".write(to: configURL, atomically: true, encoding: .utf8)
    } catch {
      errorMessage = "Axo could not enable copy-on-select: \(error.localizedDescription)"
      return
    }
    defer { try? FileManager.default.removeItem(at: configURL) }
    configURL.path.withCString { ghostty_config_load_file(config, $0) }
  }

  private static func readClipboard(
    userdata: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    state: UnsafeMutableRawPointer?,
    mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    count: Int,
    list: Bool
  ) -> ghostty_clipboard_read_result_e {
    guard let view = clipboardView(userdata), let surface = view.surface,
      let pasteboard = TerminalClipboardPolicy.pasteboard(for: location)
    else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

    var requestedMIMEs = Set<String>()
    if let mimes {
      for index in 0..<count {
        guard let mime = mimes[index] else { continue }
        requestedMIMEs.insert(String(cString: mime))
      }
    }
    let requestsPlainText = requestedMIMEs.contains(TerminalClipboardPolicy.textMIMEType)
    guard requestsPlainText || list else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

    let hasPlainText = pasteboard.types?.contains(.string) == true
    let text = requestsPlainText ? pasteboard.string(forType: .string) : nil
    guard text != nil || list else {
      return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
    }
    // This is an exact snapshot for Ghostty's confirmation callback; the text is not sent to
    // the terminal until the user approves that request.
    completeClipboardRequest(
      surface: surface,
      state: state,
      text: text,
      available: list ? TerminalClipboardPolicy.availableMIMETypes(hasPlainText: hasPlainText) : []
    )
    return GHOSTTY_CLIPBOARD_READ_STARTED
  }

  private static func confirmClipboardRead(
    userdata: UnsafeMutableRawPointer?,
    confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    state: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
  ) {
    guard let view = clipboardView(userdata), let surface = view.surface, let confirm else {
      if let surface = clipboardView(userdata)?.surface {
        ghostty_surface_deny_clipboard_request(surface, state)
      }
      return
    }
    let payload = confirm.pointee
    if payload.available_len > 0 {
      guard let available = payload.available,
        (0..<payload.available_len).allSatisfy({ index in
          guard let mime = available[index] else { return false }
          return String(cString: mime) == TerminalClipboardPolicy.textMIMEType
        })
      else {
        ghostty_surface_deny_clipboard_request(surface, state)
        return
      }
    }
    let text: String
    if request == GHOSTTY_CLIPBOARD_REQUEST_LIST && payload.contents_len == 0 {
      text = ""
    } else {
      guard payload.contents_len == 1, let contents = payload.contents,
        let mime = contents[0].mime, String(cString: mime) == TerminalClipboardPolicy.textMIMEType
      else {
        ghostty_surface_deny_clipboard_request(surface, state)
        return
      }
      let length = Int(contents[0].len)
      let data: Data
      if length == 0 {
        data = Data()
      } else if let dataPointer = contents[0].data {
        data = Data(bytes: dataPointer, count: length)
      } else {
        ghostty_surface_deny_clipboard_request(surface, state)
        return
      }
      guard let decodedText = String(data: data, encoding: .utf8) else {
        ghostty_surface_deny_clipboard_request(surface, state)
        return
      }
      text = decodedText
    }
    guard TerminalClipboardConsent.requestAccess(for: request, text: text) else {
      ghostty_surface_deny_clipboard_request(surface, state)
      return
    }
    var approved = ghostty_clipboard_complete_s(
      contents: payload.contents,
      contents_len: payload.contents_len,
      available: payload.available,
      available_len: payload.available_len,
      confirmed: true,
      remember: false
    )
    ghostty_surface_complete_clipboard_request(surface, &approved, state)
  }

  private static func writeClipboard(
    location: ghostty_clipboard_e,
    content: UnsafePointer<ghostty_clipboard_content_s>?,
    count: Int,
    confirm: Bool
  ) {
    guard let pasteboard = TerminalClipboardPolicy.pasteboard(for: location),
      let content, count > 0
    else { return }
    var contents: [TerminalClipboardContent] = []
    for index in 0..<count {
      guard let mime = content[index].mime else { continue }
      let length = Int(content[index].len)
      let data: Data
      if length == 0 {
        data = Data()
      } else if let pointer = content[index].data {
        data = Data(bytes: pointer, count: length)
      } else {
        return
      }
      contents.append(TerminalClipboardContent(mimeType: String(cString: mime), data: data))
    }
    guard let text = TerminalClipboardPolicy.textContent(from: contents) else { return }
    if confirm && !TerminalClipboardConsent.requestAccess(
      for: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
      text: text
    ) { return }
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  private static func clipboardView(_ userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceNSView? {
    guard let userdata else { return nil }
    return Unmanaged<GhosttySurfaceNSView>.fromOpaque(userdata).takeUnretainedValue()
  }

  private static func completeClipboardRequest(
    surface: ghostty_surface_t,
    state: UnsafeMutableRawPointer?,
    text: String?,
    available: [String]
  ) {
    let textData = text.map { Data($0.utf8) }
    let mime = textData == nil ? nil : strdup(TerminalClipboardPolicy.textMIMEType)
    let contentData = textData.map { data -> UnsafeMutableRawPointer in
      let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(1, data.count), alignment: 1)
      data.withUnsafeBytes { bytes in
        if let baseAddress = bytes.baseAddress {
          buffer.copyMemory(from: baseAddress, byteCount: bytes.count)
        }
      }
      return buffer
    }
    defer {
      if let mime { free(mime) }
      contentData?.deallocate()
    }
    let availableStrings = available.compactMap { strdup($0) }
    defer { availableStrings.forEach { free($0) } }
    let availablePointers: [UnsafePointer<CChar>?] = availableStrings.map { UnsafePointer($0) }

    let complete: (UnsafePointer<ghostty_clipboard_content_s>?) -> Void = { contentPointer in
      availablePointers.withUnsafeBufferPointer { availableBuffer in
        var completion = ghostty_clipboard_complete_s(
          contents: contentPointer,
          contents_len: textData == nil ? 0 : 1,
          available: availableBuffer.baseAddress,
          available_len: availableBuffer.count,
          confirmed: false,
          remember: false
        )
        ghostty_surface_complete_clipboard_request(surface, &completion, state)
      }
    }
    if let textData, let mime, let contentData {
      var content = ghostty_clipboard_content_s(
        mime: mime,
        data: contentData.assumingMemoryBound(to: CChar.self),
        len: textData.count
      )
      withUnsafePointer(to: &content, complete)
    } else {
      complete(nil)
    }
  }

  private func observeApplicationState() {
    let center = NotificationCenter.default
    notificationTokens.append(
      center.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.updateFocus(true) }
      }
    )
    notificationTokens.append(
      center.addObserver(
        forName: NSApplication.didResignActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.updateFocus(false) }
      }
    )
    notificationTokens.append(
      center.addObserver(
        forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let app = self?.app else { return }
          ghostty_app_keyboard_changed(app)
        }
      }
    )
  }

  private static func handlePointerAction(
    target: ghostty_target_s,
    action: ghostty_action_s
  ) -> Bool {
    guard target.tag == GHOSTTY_TARGET_SURFACE,
      let surface = target.target.surface,
      let userdata = ghostty_surface_userdata(surface)
    else { return false }
    let view = Unmanaged<GhosttySurfaceNSView>.fromOpaque(userdata).takeUnretainedValue()
    switch action.tag {
    case GHOSTTY_ACTION_MOUSE_SHAPE:
      view.setCursorShape(action.action.mouse_shape)
      return true
    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
      switch action.action.mouse_visibility {
      case GHOSTTY_MOUSE_VISIBLE:
        view.setCursorVisibility(true)
        return true
      case GHOSTTY_MOUSE_HIDDEN:
        view.setCursorVisibility(false)
        return true
      default:
        return false
      }
    default:
      return false
    }
  }

  private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
      MainActor.assumeIsolated { runtime.tick() }
    }
  }

  private static func terminalAttachCommand(
    helperPath: String,
    socketPath: String,
    shellID: Int64
  ) -> String {
    [
      helperPath,
      "terminal-attach",
      "--attach-socket",
      socketPath,
      "--shell-id",
      String(shellID),
    ]
    .map(shellQuoted)
    .joined(separator: " ")
  }

  private static func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

enum GhosttySurfaceAction: String {
  case selectAll = "select_all"
  case undo
  case redo
}
