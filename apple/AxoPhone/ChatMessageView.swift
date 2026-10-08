import AxoCore
import MarkdownUI
import SwiftUI

struct ChatMessageView: View {
    let message: ConversationMessage
    var activity: AgentActivity? = nil
    var outputState: ToolOutputState? = nil
    var loadOutput: () -> Void = {}
    @State private var copied = false
    @ScaledMetric(relativeTo: .body) private var bodySize = 18.0

    var body: some View {
        if message.role == "thinking" {
            Text(message.text)
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("thinkingBlock")
        } else if message.role == "tool" {
            ToolTranscriptView(message: message, activity: activity, outputState: outputState, loadOutput: loadOutput)
        } else if message.status == .failed {
            Text(message.text)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if message.role == "user" {
            Text(message.text)
                .font(.body).textSelection(.enabled)
                .padding(.horizontal, 17).padding(.vertical, 13)
                .background(Color.blue.opacity(0.24), in: RoundedRectangle(cornerRadius: 23))
                .overlay(RoundedRectangle(cornerRadius: 23).stroke(Color.blue.opacity(0.34), lineWidth: 0.5))
                .padding(.leading, 48)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contextMenu { copyButton; ShareLink(item: message.text) }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Markdown(message.text)
                    .markdownTheme(theme)
                    .markdownImageProvider(OmittedImages())
                    .markdownInlineImageProvider(OmittedImages())
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
                    })
                HStack(spacing: 18) {
                    copyButton
                    ShareLink(item: message.text) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share response")
                }
                .font(.system(size: 16)).foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = message.text
            copied = true
        } label: { Image(systemName: copied ? "checkmark" : "square.on.square") }
            .accessibilityLabel(copied ? "Copied response" : "Copy response")
    }

    private var theme: Theme {
        Theme.basic
            .text { ForegroundColor(.white.opacity(0.94)); FontSize(bodySize) }
            .paragraph { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownMargin(top: 0, bottom: 18)
            }
            .heading1 { configuration in
                configuration.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.35)) }
                    .markdownMargin(top: 20, bottom: 14)
            }
            .heading2 { configuration in
                configuration.label.markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.15)) }
                    .markdownMargin(top: 18, bottom: 12)
            }
            .blockquote { configuration in
                configuration.label
                    .padding(.leading, 17)
                    .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.22)).frame(width: 3) }
                    .markdownMargin(top: 6, bottom: 18)
            }
            .codeBlock { configuration in
                VStack(alignment: .leading, spacing: 12) {
                    if let language = configuration.language {
                        Text(language).font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal) {
                        configuration.label
                            .markdownTextStyle { FontFamilyVariant(.monospaced); FontSize(.em(0.85)) }
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(16).background(Color(white: 0.075), in: RoundedRectangle(cornerRadius: 16))
                .markdownMargin(top: 4, bottom: 18)
            }
            .table { configuration in
                ScrollView(.horizontal) { configuration.label }
                    .markdownMargin(top: 4, bottom: 18)
            }
    }
}

/// Markdown can contain remote image URLs; rendering a chat must not fetch them.
private struct OmittedImages: ImageProvider, InlineImageProvider {
    func makeImage(url: URL?) -> some View {
        Label("Image omitted", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
    }
    func image(with url: URL, label: String) async throws -> Image { Image(systemName: "photo") }
}

struct ChatEmptyState: View {
    let status: String
    let connect: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkle").font(.system(size: 32, weight: .light))
                .frame(width: 68, height: 68).background(Color(white: 0.07), in: Circle())
            Text("What are we working on?").font(.title2.weight(.semibold))
            Text("Your Mac’s Pi session, right here.").font(.body).foregroundStyle(.secondary)
            Button(status, action: connect).font(.caption).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity).padding(.vertical, 90)
    }
}

struct ChatQuestionCard: View {
    let question: Question
    let canAnswer: Bool
    let answer: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("Pi needs your input", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(question.title).font(.headline)
                ForEach(question.options, id: \.self) { option in
                    Button { answer(option) } label: {
                        Text(option).multilineTextAlignment(.leading)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                    }.buttonStyle(.plain).disabled(!canAnswer)
                }
            }.padding(16)
        }
        .frame(maxHeight: 230)
        .background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 22))
    }
}
