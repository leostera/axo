import SwiftUI
import AxoCore

@main
struct AxoPhoneApp: App {
    var body: some Scene { WindowGroup { ConversationView() } }
}

struct ConversationView: View {
    @State private var client = ConversationClient()
    @AppStorage("relayEndpoint") private var endpointText = "https://api.axo.example.invalid"
    @State private var draft = ""
    @State private var submittedDraft: (id: String, text: String)?
    @State private var showLogin = false
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase
    private var endpoint: RelayEndpoint? { try? RelayEndpoint(endpointText) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                connectionBar
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(client.snapshot?.messages ?? []) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.role == "user" ? "You" : "Pi").font(.caption.bold()).foregroundStyle(.secondary)
                                Text(.init(message.text)).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding()
                }
                if let question = client.snapshot?.question {
                    VStack(alignment: .leading) {
                        Text(question.title).font(.headline)
                        ForEach(question.options, id: \.self) { option in
                            Button(option) { answer(question, option) }
                                .buttonStyle(.bordered).disabled(!client.canSend)
                        }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                }
                if let notice = client.notice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                HStack(alignment: .bottom) {
                    TextField("Message Pi — or use keyboard dictation", text: $draft, axis: .vertical)
                        .lineLimit(2...6).textFieldStyle(.roundedBorder)
                    Button("Send", action: send)
                        .disabled(!client.canSend || client.snapshot?.question != nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.utf16.count > 16_000)
                }.padding()
            }
            .navigationTitle("Axo")
            .sheet(isPresented: $showLogin) {
                if let endpoint {
                    NavigationStack {
                        AccessLogin(endpoint: endpoint, onAuthenticated: { token in
                            do {
                                try AccessCredential.save(token, host: endpoint.baseURL.host!)
                                showLogin = false
                                client.connect(endpoint: endpoint, authorizationCookie: token)
                            } catch { self.error = "Could not save Access credentials securely." }
                        }, onFailure: { error = $0 })
                        .navigationTitle("Cloudflare Access")
                        .toolbar { Button("Cancel") { showLogin = false } }
                    }
                }
            }
            .onChange(of: client.lastAcknowledgedID) { _, id in
                if let sent = submittedDraft, id == sent.id {
                    if draft == sent.text { draft = "" }
                    submittedDraft = nil
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { client.disconnect() }
                if phase == .active, client.link == .disconnected { reconnect() }
            }
        }
    }

    private var connectionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("HTTPS relay endpoint", text: $endpointText)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .onChange(of: endpointText) { _, _ in client.disconnect() }
            HStack {
                Text(status).font(.caption)
                Spacer()
                Button("Reconnect", action: reconnect)
                Button("Sign in") { if endpoint != nil { showLogin = true } else { error = "Enter an HTTPS origin, without a path." } }
            }
        }.padding(.horizontal)
    }

    private var status: String {
        switch client.link {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .macOffline: return "Mac offline — prompts are not queued"
        case .failed(let message): return message
        case .online: return client.snapshot.map { "Pi: \($0.state.rawValue)" } ?? "Waiting for conversation…"
        }
    }

    private func reconnect() {
        guard let endpoint else { error = "Enter a valid HTTPS endpoint."; return }
        guard let token = AccessCredential.load(host: endpoint.baseURL.host!) else { showLogin = true; return }
        client.connect(endpoint: endpoint, authorizationCookie: token)
    }

    private func send() {
        guard let session = client.snapshot?.sessionId else { return }
        let id = UUID().uuidString
        submittedDraft = (id, draft)
        client.send(.prompt(id: id, session: session, text: draft))
    }

    private func answer(_ question: Question, _ value: String) {
        guard let session = client.snapshot?.sessionId else { return }
        client.send(.answer(id: UUID().uuidString, session: session, question: question.id, value: value))
    }
}
