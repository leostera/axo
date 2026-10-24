import AppKit
import GhosttyKit

/// libghostty clipboard callbacks. Reads and writes are gated by explicit user consent.
extension GhosttyRuntime {
  static func readClipboard(
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

  static func confirmClipboardRead(
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

  static func writeClipboard(
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
    guard let text = TerminalClipboardPolicy.singlePlainText(from: contents) else { return }
    if confirm && !TerminalClipboardConsent.requestAccess(
      for: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
      text: text
    ) { return }
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  static func clipboardView(_ userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceNSView? {
    guard let userdata else { return nil }
    return Unmanaged<GhosttySurfaceNSView>.fromOpaque(userdata).takeUnretainedValue()
  }

  static func completeClipboardRequest(
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
}
