import SwiftUI

#if os(iOS)
import WebKit

struct YouTubeLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = YouTubeSessionStore.shared
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            YouTubeLoginWebView { cookies in
                do {
                    try session.save(cookies: cookies)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Connect YouTube Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("Login incomplete", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
}

private struct YouTubeLoginWebView: UIViewRepresentable {
    let onAuthenticated: ([HTTPCookie]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onAuthenticated: onAuthenticated) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
        let target = "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&passive=false&continue=https%3A%2F%2Fmusic.youtube.com%2F"
        webView.load(URLRequest(url: URL(string: target)!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        weak var webView: WKWebView?
        let onAuthenticated: ([HTTPCookie]) -> Void
        private var completed = false

        init(onAuthenticated: @escaping ([HTTPCookie]) -> Void) { self.onAuthenticated = onAuthenticated }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { inspect(cookieStore) }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            inspect(webView.configuration.websiteDataStore.httpCookieStore)
        }

        private func inspect(_ store: WKHTTPCookieStore) {
            guard !completed else { return }
            store.getAllCookies { [weak self] cookies in
                guard let self,
                      cookies.contains(where: { $0.name == "SAPISID" || $0.name == "__Secure-3PAPISID" }),
                      self.webView?.url?.host?.contains("youtube.com") == true else { return }
                self.completed = true
                DispatchQueue.main.async { self.onAuthenticated(cookies) }
            }
        }
    }
}
#else
struct YouTubeLoginView: View {
    var body: some View { ContentUnavailableView("Use LastWave on iPhone to connect YouTube Music", systemImage: "iphone") }
}
#endif
