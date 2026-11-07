import AxoClient
import AxoPhoneModel
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The message box: one rounded card, the words on top and a bar under them with + on the left
/// (the camera, photos, files and plugins, in a menu above it) and voice and Send on the right. It
/// grows with the words. It stays closed, saying why in its placeholder, when there is nobody to
/// send to. Once a message runs past a few lines it can be opened full screen. Return starts a new
/// line and Send sends, as the web does on a touch screen. With `voice`, a message can be said
/// instead of typed: while listening the box becomes the listening bar.
struct ChatComposer: View {
  @Binding var draft: String
  let placeholder: String
  let canSend: Bool
  /// Words or files to send, and no file still uploading.
  var ready = true
  var files: [PhoneWorkbench.DraftAttachment] = []
  var attach: ([(data: Data, name: String, mimeType: String, thumbnail: Data?)]) -> Void = { _ in }
  var detach: (UUID) -> Void = { _ in }
  let voice: VoicePrompt?
  /// Settings › Apps, from the + menu's Plugins.
  var showApps: (() -> Void)?
  let send: () -> Void

  @State private var editorHeight: CGFloat = 0
  @State private var showingExpandedEditor = false
  @State private var pickedPhotos: [PhotosPickerItem] = []
  @State private var showingPhotos = false
  @State private var showingFiles = false
  @State private var showingCamera = false
  @State private var showingAddMenu = false

  private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty }
  /// About three lines: long enough to want the whole screen to read and edit it.
  private var isLong: Bool { editorHeight >= 66 }

  private var isListening: Bool {
    guard let voice else { return false }
    return voice.isListening || voice.state == .finishing
  }

  private var showsVoiceStatus: Bool {
    switch voice?.state {
    case .preparing, .failed: true
    default: false
    }
  }

  var body: some View {
    let _ = RenderCount.note("Composer")
    VStack(spacing: 10) {
      if let voice { VoiceStatusCard(voice: voice) }
      if !files.isEmpty { AttachmentStrip(files: files, detach: detach) }
      if let voice, isListening {
        VoiceListeningBar(voice: voice, canSend: canSend)
      } else {
        box
      }
    }
    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isListening)
    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showsVoiceStatus)
  }

  private var box: some View {
    VStack(alignment: .leading, spacing: 4) {
      TextField(placeholder, text: $draft, axis: .vertical)
        .lineLimit(1...8)
        .padding(.horizontal, 6).padding(.top, 4).padding(.bottom, 2)
        .frame(minHeight: 30)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { editorHeight = $0 }
        .disabled(!canSend)
        .accessibilityIdentifier("composer")
      // Return starts a new line, as on the web on a touch screen; Send sends.
      HStack(spacing: 8) {
        addButton
        Spacer(minLength: 0)
        if isLong { expandButton }
        if let voice { VoiceButton(voice: voice, enabled: canSend) }
        sendButton
      }
    }
    .composerCard()
    .fullScreenCover(isPresented: $showingExpandedEditor) {
      ExpandedComposerEditor(draft: $draft, placeholder: placeholder)
    }
    .photosPicker(isPresented: $showingPhotos, selection: $pickedPhotos, maxSelectionCount: Attachment.maxPerPrompt, matching: .images)
    .onChange(of: pickedPhotos) { _, items in
      guard !items.isEmpty else { return }
      pickedPhotos = []
      Task { attach(await AttachmentImport.photos(items)) }
    }
    .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
      guard case .success(let urls) = result else { return }
      attach(AttachmentImport.files(urls))
    }
    .fullScreenCover(isPresented: $showingCamera) {
      CameraPicker { image in attach([AttachmentImport.camera(image)]) }
        .ignoresSafeArea()
    }
  }

  /// What can go with a message, in a frosted menu above the +.
  private var addButton: some View {
    Button { showingAddMenu = true } label: {
      Image(systemName: "plus").font(.system(size: 19, weight: .regular))
        .foregroundStyle(canSend ? Color.primary : Color.secondary)
        .frame(width: ComposerMetrics.control, height: ComposerMetrics.control)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(!canSend)
    .accessibilityLabel("Add photos, files and more")
    .accessibilityIdentifier("attach")
    .popover(isPresented: $showingAddMenu, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
      AddMenu(
        camera: UIImagePickerController.isSourceTypeAvailable(.camera),
        plugins: showApps != nil
      ) { choice in
        showingAddMenu = false
        // The menu goes first; a sheet asked for while it is still leaving would not show.
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(350))
          switch choice {
          case .camera: showingCamera = true
          case .photos: showingPhotos = true
          case .files: showingFiles = true
          case .plugins: showApps?()
          }
        }
      }
      .presentationCompactAdaptation(.popover)
    }
  }

  private var expandButton: some View {
    Button { showingExpandedEditor = true } label: {
      Image(systemName: "arrow.up.left.and.arrow.down.right")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: ComposerMetrics.control, height: ComposerMetrics.control)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Expand message editor")
  }

  private var sendButton: some View {
    Button(action: send) {
      Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold))
        .foregroundStyle(canSend && hasDraft && ready ? ChatColors.background : Color.secondary)
        .frame(width: ComposerMetrics.control, height: ComposerMetrics.control)
        .background(canSend && hasDraft && ready ? Color.primary : ChatColors.disabledControl, in: Circle())
    }
    .accessibilityLabel("Send")
    .accessibilityIdentifier("send-message")
    .disabled(!(canSend && hasDraft && ready))
  }
}

/// The composer's measurements, shared by the text box and the voice bar that takes its place:
/// slim, a little room above and below one line of text, round ends.
enum ComposerMetrics {
  /// A button's circle, and the box's height for one line.
  static let control: CGFloat = 36
  /// Between the box's edge and the buttons in it.
  static let edge: CGFloat = 5
  /// Above and below the text, inside the button's height.
  static let textInset: CGFloat = 8
  static var cornerRadius: CGFloat { control / 2 + edge }
}

/// What the + menu offers.
enum AddChoice: CaseIterable {
  case camera, photos, files, plugins
}

/// The + menu: big rows, each an icon in a round well and a label, on frosted glass.
private struct AddMenu: View {
  let camera: Bool
  let plugins: Bool
  let pick: (AddChoice) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if camera { row(.camera, "Camera", "camera") }
      row(.photos, "Photos", "photo.on.rectangle")
      row(.files, "Files", "folder")
      if plugins { row(.plugins, "Plugins", "powerplug") }
    }
    .padding(8)
    .frame(width: 240)
    .presentationBackground(.thinMaterial)
  }

  private func row(_ choice: AddChoice, _ title: String, _ icon: String) -> some View {
    Button { pick(choice) } label: {
      HStack(spacing: 14) {
        Image(systemName: icon)
          .font(.system(size: 19, weight: .regular))
          .frame(width: 44, height: 44)
          .background(Color.primary.opacity(0.08), in: Circle())
        Text(title).font(.body)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8).padding(.vertical, 5)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("add-\(title.lowercased())")
  }
}

/// The system camera, for a photo to send.
private struct CameraPicker: UIViewControllerRepresentable {
  let took: (UIImage) -> Void
  @Environment(\.dismiss) private var dismiss

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let parent: CameraPicker
    init(_ parent: CameraPicker) { self.parent = parent }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
      if let image = info[.originalImage] as? UIImage { parent.took(image) }
      parent.dismiss()
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
  }
}

extension View {
  /// The composer's card: the words on top, a bar of controls under them.
  func composerCard() -> some View {
    padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 8)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
      )
      .padding(.horizontal, 12)
  }

  /// The composer's rounded box around one row of controls.
  func composerBox() -> some View {
    padding(ComposerMetrics.edge)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ComposerMetrics.cornerRadius))
      .overlay(
        RoundedRectangle(cornerRadius: ComposerMetrics.cornerRadius).stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
      )
      .padding(.horizontal, 12)
  }
}

/// The whole screen for a long message; Done returns to the conversation with it in the box.
private struct ExpandedComposerEditor: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: String
  let placeholder: String
  @FocusState private var isFocused: Bool

  var body: some View {
    NavigationStack {
      TextEditor(text: $draft)
        .font(.body)
        .focused($isFocused)
        .scrollContentBackground(.hidden)
        .overlay(alignment: .topLeading) {
          if draft.isEmpty {
            Text(placeholder)
              .foregroundStyle(.secondary)
              .padding(.top, 8)
              .padding(.leading, 5)
              .allowsHitTesting(false)
          }
        }
        .padding(.horizontal, 12)
        .background(ChatColors.background)
        .accessibilityLabel("Expanded message")
        .navigationTitle(placeholder)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
    }
    .task { isFocused = true }
  }
}
