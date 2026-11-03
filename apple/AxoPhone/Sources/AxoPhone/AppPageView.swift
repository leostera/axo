import AxoPhoneModel
import AxoProtocol
import SwiftUI

/// One app's page: what it is for, its accounts with Add account, what Axo can do with them, and
/// what Sessions did. How Add account works is the app's: a token pasted here, a code entered at
/// the provider, a sign-in on one of the person's Macs, or the provider's sign-in on the web.
struct AppPageView: View {
  let model: AppsModel
  let name: String
  @Environment(\.openURL) private var openURL
  @State private var adding: AddingToken?
  @State private var changingClient = false
  @State private var removing: AppAccount?
  @State private var signingInByPhone = false

  /// A token form for a new account, or for a new token for `account`.
  private struct AddingToken: Identifiable {
    let account: String?
    var id: String { account ?? "" }
  }

  var body: some View {
    Group {
      if let app = model.app(named: name) {
        page(app)
      } else {
        ContentUnavailableView("No such app", systemImage: "powerplug", description: Text("It may have been removed."))
      }
    }
    .navigationTitle(model.app(named: name)?.title ?? "App")
    .navigationBarTitleDisplayMode(.inline)
    .appsNotice(model)
  }

  private func page(_ app: AppConnection) -> some View {
    List {
      Section { header(app) }
        .listRowBackground(Color.clear)

      if case .oauth(let client?) = app.signIn, !client.ready || changingClient {
        ClientSetupSection(model: model, app: app, client: client, changing: client.ready) { changingClient = false }
      }
      if case .phone(let offer) = app.signIn, !offer.clientReady || changingClient {
        PhoneClientSection(model: model, app: app, offer: offer, changing: offer.clientReady) { changingClient = false }
      }

      if !app.needsClient || !app.accounts.isEmpty {
        accounts(app)
      }

      if let flow = model.deviceFlow, flow.app == app.name { DeviceCodeSection(model: model, app: app, flow: flow) }
      if let flow = model.macFlow, flow.app == app.name { MacWaitingSection(model: model, app: app, flow: flow) }

      if !app.permissions.isEmpty {
        Section {
          ForEach(app.permissions, id: \.self) { permission in
            Label(permission, systemImage: "checkmark").font(.callout)
          }
        } header: {
          Text("What Axo can do")
        } footer: {
          Text("Only with the accounts above, and only when one of your Sessions asks.")
        }
      }

      Section("Recent activity") { CallsList(model: model, service: app.name, limit: 20) }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(ChatColors.background)
    .sheet(isPresented: $signingInByPhone) {
      PhoneSignInForm(model: model, app: app)
    }
    .sheet(item: $adding) { adding in
      if case .token(let signIn) = app.signIn {
        TokenAccountForm(model: model, app: app, signIn: signIn, account: adding.account)
      }
    }
    .confirmationDialog(
      "Remove \(removing?.account ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      titleVisibility: .visible, presenting: removing
    ) { account in
      Button("Remove", role: .destructive) { Task { await model.remove(account.account, from: app) } }
    } message: { _ in
      Text("Your Sessions can no longer use it. \(revoked(app))")
    }
  }

  private func header(_ app: AppConnection) -> some View {
    VStack(spacing: 8) {
      AppLogo(source: .app(app.name), size: 64)
      Text(app.title).font(.title2.weight(.semibold))
      let meta = [app.provider, app.category.isEmpty ? "" : AppsCatalog.categoryTitle(app.category)].filter { !$0.isEmpty }
      if !meta.isEmpty {
        Text(meta.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
      }
      if !app.description.isEmpty {
        Text(app.description).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - Accounts

  @ViewBuilder private func accounts(_ app: AppConnection) -> some View {
    Section {
      ForEach(app.accounts) { account in
        HStack(spacing: 10) {
          Image(systemName: isMacApp(app) ? "laptopcomputer" : "person.crop.circle").foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 2) {
            Text(account.account).lineLimit(1)
            if account.state == .needsSignIn {
              Text(needsSignInText(app, account)).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
          }
          Spacer(minLength: 4)
          if account.state == .needsSignIn, !isMacApp(app) {
            Button(isTokenApp(app) ? "Add token" : "Sign in") { add(app, account: account.account) }
              .buttonStyle(.bordered).controlSize(.small)
              .disabled(model.isBusy || model.deviceFlow != nil)
          } else if account.state == .ready {
            Circle().fill(Color.green).frame(width: 7, height: 7).accessibilityLabel("Connected")
          }
        }
        .swipeActions {
          if !isMacApp(app) {
            Button("Remove", role: .destructive) { removing = account }
          }
        }
        .contextMenu {
          if !isMacApp(app) {
            Button("Remove", systemImage: "trash", role: .destructive) { removing = account }
          }
        }
        .accessibilityIdentifier("app-account")
      }
      if isMacApp(app), app.accounts.isEmpty {
        Text("Pair a Mac to use \(app.title).").foregroundStyle(.secondary)
      }
      if !isMacApp(app), model.deviceFlow == nil, model.macFlow == nil, !app.needsClient {
        Button { add(app, account: nil) } label: {
          Label(addTitle(app), systemImage: isWebSignIn(app) ? "safari" : "plus")
        }
        .disabled(model.isBusy)
      }
    } header: {
      Text("Accounts")
    } footer: {
      accountsFooter(app)
    }
  }

  @ViewBuilder private func accountsFooter(_ app: AppConnection) -> some View {
    switch app.signIn {
    case .mac(let setup, let helpURL):
      HStack(spacing: 4) {
        Text("Your Macs are its accounts. \(setup)")
        if let url = URL(string: helpURL) { Link("Learn more", destination: url) }
      }
    case .oauth(let client):
      VStack(alignment: .leading, spacing: 6) {
        Text("Signing in happens on the web, in \(app.title)'s page there. Come back here when it is done.")
        if client?.ready == true, !changingClient {
          Button("Change \(app.provider.isEmpty ? app.title : app.provider) client") { changingClient = true }
            .font(.footnote)
        }
      }
    case .phone:
      VStack(alignment: .leading, spacing: 6) {
        Text("Axo signs in as a new device of yours, and shows in \(app.title) › Settings › Devices; ending it there signs Axo out.")
        if !changingClient {
          Button("Change API ID") { changingClient = true }.font(.footnote)
        }
      }
    case .unknown:
      Text("This version of the app cannot add \(app.title) accounts yet; Add account opens it on the web.")
    case .token, .device:
      EmptyView()
    }
  }

  private func add(_ app: AppConnection, account: String?) {
    switch app.signIn {
    case .token: adding = AddingToken(account: account)
    case .device: Task { await model.startDeviceSignIn(for: app) }
    case .phone: signingInByPhone = true
    case .oauth, .unknown: openURL(model.webPage(for: app))
    case .mac: break
    }
  }

  private func addTitle(_ app: AppConnection) -> String {
    isWebSignIn(app) ? "Add account on the web" : "Add account"
  }

  private func isWebSignIn(_ app: AppConnection) -> Bool {
    switch app.signIn {
    case .oauth, .unknown: true
    default: false
    }
  }

  private func isTokenApp(_ app: AppConnection) -> Bool {
    if case .token = app.signIn { return true }
    return false
  }

  private func isMacApp(_ app: AppConnection) -> Bool {
    if case .mac = app.signIn { return true }
    return false
  }

  private func needsSignInText(_ app: AppConnection, _ account: AppAccount) -> String {
    isTokenApp(app) ? account.lastError ?? "Needs a new token" : "Needs sign-in"
  }

  private func revoked(_ app: AppConnection) -> String {
    let provider = app.provider.isEmpty ? "the service" : app.provider
    switch app.signIn {
    case .token(let signIn):
      return signIn.mac != nil
        ? "Axo deletes a key it created at \(provider); one you pasted, delete there too."
        : "Axo forgets its token. To stop it working, delete it at \(provider) too."
    case .device: return "Axo signs out of \(provider)."
    case .phone: return "Axo logs its device out of \(provider)."
    default: return "Axo's access is revoked at \(provider)."
    }
  }
}

// MARK: - Device sign-in

/// A device sign-in (ChatGPT's): the code to enter at the provider, until Axo hears it was.
private struct DeviceCodeSection: View {
  let model: AppsModel
  let app: AppConnection
  let flow: AppsModel.DeviceFlow
  @State private var copied = false

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 10) {
        Text("Enter this code at \(provider)").font(.headline)
        Text(flow.userCode)
          .font(.system(.title, design: .monospaced).weight(.semibold))
          .textSelection(.enabled)
          .accessibilityLabel("Sign-in code \(flow.userCode)")
          .accessibilityIdentifier("device-code")
        Text("It works for 15 minutes. This finishes by itself once you have.").font(.caption).foregroundStyle(.secondary)
      }
      .padding(.vertical, 4)
      Button(copied ? "Copied" : "Copy code", systemImage: "doc.on.doc") {
        UIPasteboard.general.string = flow.userCode
        copied = true
      }
      if let url = flow.verificationURL {
        Link(destination: url) { Label("Open \(provider)", systemImage: "safari") }
      }
      Button("Cancel", role: .cancel) { model.cancelSignIn() }
    } header: {
      Text("Sign in to \(app.title)")
    } footer: {
      Text("Only enter it if you started this sign-in here.")
    }
  }

  private var provider: String { app.provider.isEmpty ? app.title : app.provider }
}

/// A sign-in in the browser of one of the person's Macs, until Axo has the key.
private struct MacWaitingSection: View {
  let model: AppsModel
  let app: AppConnection
  let flow: AppsModel.MacFlow

  var body: some View {
    Section {
      HStack(spacing: 12) {
        ProgressView()
        VStack(alignment: .leading, spacing: 2) {
          Text("Finish in the browser on \(flow.mac)")
          Text("\(provider)'s sign-in page opened there. This finishes by itself once you approve.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Button("Stop waiting", role: .cancel) { model.cancelSignIn() }
    } header: {
      Text("Sign in to \(provider)")
    } footer: {
      Text("It waits for 5 minutes.")
    }
  }

  private var provider: String { app.provider.isEmpty ? app.title : app.provider }
}

// MARK: - OAuth client

/// Sets up the OAuth app Axo signs in to a provider with: registered with the provider using
/// Axo's redirect URI, its ID and secret entered here once and kept encrypted with the account.
private struct ClientSetupSection: View {
  let model: AppsModel
  let app: AppConnection
  let client: AppOAuthClient
  let changing: Bool
  let done: () -> Void
  @State private var clientId = ""
  @State private var clientSecret = ""
  @State private var copied = false

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 6) {
        Text("1. Register an OAuth app with \(provider)").font(.callout.weight(.semibold))
        Text("Use this redirect URI:").font(.caption).foregroundStyle(.secondary)
        Text(client.redirectUri).font(.caption.monospaced()).textSelection(.enabled)
      }
      Button(copied ? "Copied" : "Copy redirect URI", systemImage: "doc.on.doc") {
        UIPasteboard.general.string = client.redirectUri
        copied = true
      }
      if let url = URL(string: client.consoleUrl) {
        Link(destination: url) { Label("Open \(provider)", systemImage: "safari") }
      }
      Text("2. Enter its client ID and secret").font(.callout.weight(.semibold))
      TextField("Client ID", text: $clientId)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .accessibilityIdentifier("client-id")
      SecureField("Client secret", text: $clientSecret)
        .accessibilityIdentifier("client-secret")
      Button("Save") {
        Task {
          if await model.setClient(of: app, clientId: clientId, clientSecret: clientSecret) {
            clientId = ""
            clientSecret = ""
            done()
          }
        }
      }
      .disabled(model.isBusy || clientId.trimmingCharacters(in: .whitespaces).isEmpty || clientSecret.isEmpty)
      if changing { Button("Cancel", role: .cancel, action: done) }
    } header: {
      Text(changing ? "Change \(provider) client" : "Set up \(provider)")
    } footer: {
      Text(
        "Axo keeps them encrypted with your account and never shows the secret again."
          + (app.provider == "Google" ? " One client serves every Google app." : "")
          + (changing ? " Accounts signed in with the old one may need to sign in again." : ""))
    }
  }

  private var provider: String { app.provider.isEmpty ? app.title : app.provider }
}

// MARK: - Token apps

/// Adds an account to a token app: signed in on a Mac where the app offers it, or pasted. What is
/// pasted goes to Axo, which checks it with the service and seals it; the phone never sees it again.
private struct TokenAccountForm: View {
  let model: AppsModel
  let app: AppConnection
  let signIn: TokenSignIn
  /// A new token for this account, rather than a new account.
  let account: String?
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var fields: [String: String] = [:]
  @State private var onMac: Bool
  @State private var mac = ""
  @State private var preset = ""

  init(model: AppsModel, app: AppConnection, signIn: TokenSignIn, account: String?) {
    self.model = model
    self.app = app
    self.signIn = signIn
    self.account = account
    _onMac = State(initialValue: signIn.mac != nil)
    _name = State(initialValue: account ?? "")
    _preset = State(initialValue: signIn.mac?.presets.first?.id ?? "")
  }

  private var provider: String { app.provider.isEmpty ? app.title : app.provider }
  private var onlineMacs: [HostConnectionInfo] { model.macs.filter(\.isOnline) }

  var body: some View {
    NavigationStack {
      Form {
        if signIn.mac != nil {
          Picker("How", selection: $onMac) {
            Text("On a Mac").tag(true)
            Text("Paste a key").tag(false)
          }
          .pickerStyle(.segmented)
          .listRowBackground(Color.clear)
        }
        if signIn.named {
          Section {
            TextField("Name, e.g. personal", text: $name)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
              .disabled(account != nil)
              .accessibilityIdentifier("account-name")
          } footer: {
            Text("Lowercase letters, digits, dots, dashes and @.")
          }
        }
        if onMac, let offer = signIn.mac { macSignIn(offer) } else { paste }
      }
      .navigationTitle(account.map { "New token for \($0)" } ?? "Add a \(app.title) account")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(onMac ? (signIn.mac?.title ?? "Sign in") : "Add") { submit() }
            .disabled(!canSubmit || model.isBusy)
            .accessibilityIdentifier("add-account")
        }
      }
      .onAppear { if mac.isEmpty { mac = onlineMacs.first?.name ?? "" } }
      .appsNotice(model)
    }
  }

  @ViewBuilder private var paste: some View {
    Section {
      ForEach(signIn.fields) { field in
        Group {
          if field.secret {
            SecureField(field.label, text: binding(field.name))
          } else {
            TextField(field.label, text: binding(field.name))
              .textInputAutocapitalization(.never).autocorrectionDisabled()
          }
        }
        .accessibilityIdentifier("token-field-\(field.name)")
      }
    } footer: {
      VStack(alignment: .leading, spacing: 6) {
        Text(signIn.fields.map(\.help).filter { !$0.isEmpty }.joined(separator: " "))
        if let url = URL(string: signIn.helpUrl) { Link("Open \(provider)", destination: url) }
        Text("Axo checks it with \(provider), keeps it encrypted, and never shows it again.")
      }
    }
  }

  @ViewBuilder private func macSignIn(_ offer: MacSignInOffer) -> some View {
    Section("What Axo may do") {
      Picker("Permissions", selection: $preset) {
        ForEach(offer.presets) { preset in
          VStack(alignment: .leading, spacing: 2) {
            Text(preset.label)
            if !preset.description.isEmpty { Text(preset.description).font(.caption).foregroundStyle(.secondary) }
          }
          .tag(preset.id)
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    }
    Section {
      Picker("Sign in on", selection: $mac) {
        if onlineMacs.isEmpty { Text("No Mac is online").tag("") }
        ForEach(onlineMacs, id: \.name) { Text($0.name).tag($0.name) }
      }
    } footer: {
      Text("\(provider)'s sign-in page opens in the browser on that Mac. Axo then gets a key with only these permissions, and keeps it encrypted.")
    }
  }

  private func binding(_ name: String) -> Binding<String> {
    Binding(get: { fields[name] ?? "" }, set: { fields[name] = $0 })
  }

  private var nameIsValid: Bool {
    guard signIn.named else { return true }
    let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
    return (3...64).contains(trimmed.count) && trimmed.range(of: #"^[a-z0-9][a-z0-9._@-]*$"#, options: .regularExpression) != nil
  }

  private var canSubmit: Bool {
    guard nameIsValid else { return false }
    if onMac { return !mac.isEmpty && !preset.isEmpty }
    return signIn.fields.allSatisfy { !(fields[$0.name] ?? "").isEmpty }
  }

  private func submit() {
    let account = signIn.named ? name : nil
    Task {
      if onMac {
        await model.startMacSignIn(for: app, on: mac, preset: preset, account: account)
        if model.macFlow != nil { dismiss() }
      } else if await model.addToken(to: app, account: account, fields: fields) {
        dismiss()
      }
    }
  }
}

// MARK: - Phone apps

/// Sets up a phone app's API client (Telegram's): created by the person at the service, its ID
/// and hash entered here once and kept encrypted with the account.
private struct PhoneClientSection: View {
  let model: AppsModel
  let app: AppConnection
  let offer: PhoneSignInOffer
  let changing: Bool
  let done: () -> Void
  @State private var apiId = ""
  @State private var apiHash = ""

  private var provider: String { app.provider.isEmpty ? app.title : app.provider }

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 6) {
        Text("1. Create an API ID for yourself").font(.callout.weight(.semibold))
        if !offer.clientHelp.isEmpty {
          Text(offer.clientHelp).font(.caption).foregroundStyle(.secondary)
        }
      }
      if let url = URL(string: offer.consoleUrl) {
        Link(destination: url) { Label("Open \(provider)", systemImage: "safari") }
      }
      Text("2. Enter its api_id and api_hash").font(.callout.weight(.semibold))
      TextField("api_id", text: $apiId)
        .keyboardType(.numberPad)
        .accessibilityIdentifier("api-id")
      SecureField("api_hash", text: $apiHash)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .accessibilityIdentifier("api-hash")
      Button("Save") {
        Task {
          if await model.setClient(of: app, clientId: apiId, clientSecret: apiHash) {
            apiId = ""
            apiHash = ""
            done()
          }
        }
      }
      .disabled(model.isBusy || apiId.trimmingCharacters(in: .whitespaces).isEmpty || apiHash.isEmpty)
      if changing { Button("Cancel", role: .cancel, action: done) }
    } header: {
      Text(changing ? "Change \(provider) API ID" : "Set up \(provider)")
    } footer: {
      Text(
        "Axo keeps them encrypted with your account and never shows the hash again."
          + (changing ? " Accounts signed in with the old one may need to sign in again." : ""))
    }
  }
}

/// Signs in to a phone app (Telegram) as a new device of the person's: their number, the code the
/// service sends, then their password if the account has one. Axo keeps the service's state
/// between steps; this form only holds where it is.
private struct PhoneSignInForm: View {
  let model: AppsModel
  let app: AppConnection
  @Environment(\.dismiss) private var dismiss
  @State private var stage: PhoneSignIn?
  @State private var value = ""
  @FocusState private var focused: Bool

  private var provider: String { app.provider.isEmpty ? app.title : app.provider }

  private var label: String {
    switch stage {
    case .code: "Code"
    case .password: "Password"
    default: "Phone number"
    }
  }

  private var hint: String {
    switch stage {
    case .code(_, let viaApp, let error):
      error ?? (viaApp ? "\(provider) sent a code to your \(provider) app on another device." : "\(provider) sent a code by SMS.")
    case .password(_, let hint, let error):
      error ?? "Your account has a password (two-step verification).\(hint.map { " Hint: \($0)." } ?? "")"
    default:
      "Your \(provider) number, with its country code. \(provider) sends a code to your \(provider) app."
    }
  }

  private var isError: Bool {
    switch stage {
    case .code(_, _, let error?), .password(_, _, let error?): !error.isEmpty
    default: false
    }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          field
            .focused($focused)
            .onSubmit(submit)
            .accessibilityIdentifier("phone-sign-in-field")
        } footer: {
          Text(hint)
            .foregroundStyle(isError ? Color.orange : Color.secondary)
            .accessibilityIdentifier("phone-sign-in-hint")
        }
        Section {
          Text("Axo appears in \(provider) › Settings › Devices; ending it there signs Axo out.")
            .font(.footnote).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Sign in to \(provider)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(stage == nil ? "Send code" : "Continue", action: submit)
            .disabled(model.isBusy || value.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("phone-sign-in-next")
        }
      }
      .onAppear { focused = true }
      .appsNotice(model)
    }
  }

  @ViewBuilder private var field: some View {
    switch stage {
    case .code:
      TextField("Code", text: $value)
        .keyboardType(.numberPad)
        .textContentType(.oneTimeCode)
    case .password:
      SecureField("Password", text: $value)
        .textContentType(.password)
    default:
      TextField("+44 7700 900123", text: $value)
        .keyboardType(.phonePad)
        .textContentType(.telephoneNumber)
    }
  }

  private func step() -> PhoneSignInStep? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    switch stage {
    case nil: return .start(phone: trimmed)
    case .code(let flow, _, _): return .code(flow: flow, code: trimmed)
    case .password(let flow, _, _): return .password(flow: flow, password: value)
    case .done, .failed: return nil
    }
  }

  private func submit() {
    guard let step = step(), !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    Task {
      guard let answer = await model.phoneSignIn(app, step: step) else { return }
      switch answer {
      case .code, .password:
        value = ""
        stage = answer
        focused = true
      case .done, .failed:
        dismiss()
      }
    }
  }
}
