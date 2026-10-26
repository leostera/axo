import AxoClient
import SwiftUI
import WebKit

/// Cloudflare Access's own sign-in page, in a web view. When it finishes, Access has set the
/// `CF_Authorization` cookie; its value is the token native requests send in `cf-access-token`.
/// The web view's cookie jar is separate from the app's requests, which never use cookies.
struct SignInView: UIViewRepresentable {
  let endpoint: RelayEndpoint
  let onToken: (AccessToken) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(endpoint: endpoint, onToken: onToken) }

  func makeUIView(context: Context) -> WKWebView {
    let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    view.navigationDelegate = context.coordinator
    view.load(URLRequest(url: endpoint.origin.appendingPathComponent("app")))
    return view
  }

  func updateUIView(_ view: WKWebView, context: Context) {}

  final class Coordinator: NSObject, WKNavigationDelegate {
    private let endpoint: RelayEndpoint
    private let onToken: (AccessToken) -> Void
    private var finished = false

    init(endpoint: RelayEndpoint, onToken: @escaping (AccessToken) -> Void) {
      self.endpoint = endpoint
      self.onToken = onToken
    }

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
      guard !finished, view.url?.host == endpoint.origin.host else { return }
      view.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
        guard let self, !self.finished,
          let cookie = cookies.first(where: {
            $0.name == "CF_Authorization" && self.endpoint.origin.host?.hasSuffix($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) == true
          }),
          let token = AccessToken(cookie.value)
        else { return }
        self.finished = true
        DispatchQueue.main.async { self.onToken(token) }
      }
    }
  }
}
