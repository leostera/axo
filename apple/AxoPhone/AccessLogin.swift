import SwiftUI
import WebKit
import Security
import AxoCore

/// Access login lives in this cookie store, not Safari's unrelated cookie jar.
struct AccessLogin: UIViewRepresentable {
    let endpoint: RelayEndpoint
    let onAuthenticated: (String) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: endpoint.loginURL))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: AccessLogin
        private var completed = false
        init(_ parent: AccessLogin) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !completed, webView.url?.host == parent.endpoint.baseURL.host,
                  webView.url?.path == "/login" else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, let host = self.parent.endpoint.baseURL.host else { return }
                guard let cookie = cookies.first(where: {
                    $0.name == "CF_Authorization" && $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host && $0.isSecure
                }) else { return }
                self.completed = true
                self.parent.onAuthenticated(cookie.value)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.onFailure("Could not load Access login. Check the endpoint and network.")
        }
    }
}

enum AccessCredential {
    static func save(_ token: String, host: String) throws {
        let query = attributes(host)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ProtocolError.malformed }
    }

    static func load(host: String) -> String? {
        var query = attributes(host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func attributes(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.leostera.axo.access",
         kSecAttrAccount as String: host]
    }
}
