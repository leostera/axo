import AxoCore
import Security
import SwiftUI
import WebKit

/// Human Access login for the private control-plane audience, isolated from legacy relay cookies.
enum ControlPlaneAccessCredentialError: Error {
    case keychainFailure
}

struct ControlPlaneAccessLogin: UIViewRepresentable {
    let endpoint: AxoControlPlaneEndpoint
    let onAuthenticated: (AxoControlPlaneAccessCookie) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.accessibilityIdentifier = "control-plane-access-login"
        view.load(URLRequest(url: endpoint.rpcURL))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: ControlPlaneAccessLogin
        private var completed = false

        init(_ parent: ControlPlaneAccessLogin) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !completed, webView.url?.host == parent.endpoint.baseURL.host,
                  webView.url?.path == "/v1/rpc" else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                DispatchQueue.main.async {
                    guard let self, let host = self.parent.endpoint.baseURL.host,
                          let cookie = cookies.first(where: {
                              $0.name == "CF_Authorization" &&
                              $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host &&
                              $0.isSecure
                          }) else { return }
                    do {
                        let credential = try AxoControlPlaneAccessCookie(cookie.value)
                        self.completed = true
                        self.parent.onAuthenticated(credential)
                    } catch {
                        self.completed = true
                        self.parent.onFailure("Cloudflare returned a token for a different or expired application. Sign in again.")
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        private func report(_ error: Error) {
            let error = error as NSError
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
            parent.onFailure("Could not complete Cloudflare Access sign-in. Check the network and try again.")
        }
    }
}

enum ControlPlaneAccessCredential {
    private static let service = "dev.leostera.axo.private-control-plane.access"

    static func save(_ credential: AxoControlPlaneAccessCookie, host: String) throws {
        let query = attributes(host)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(credential.valueForKeychainStorage.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw ControlPlaneAccessCredentialError.keychainFailure
        }
    }

    static func load(host: String) -> AxoControlPlaneAccessCookie? {
        var query = attributes(host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data,
              let jwt = String(data: data, encoding: .utf8),
              let credential = try? AxoControlPlaneAccessCookie(jwt) else {
            remove(host: host)
            return nil
        }
        return credential
    }

    static func remove(host: String) {
        SecItemDelete(attributes(host) as CFDictionary)
    }

    private static func attributes(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: host]
    }
}
