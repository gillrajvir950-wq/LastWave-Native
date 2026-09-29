import Foundation
import WebKit

/// Mints YouTube's proof-of-origin token in the same way as Sonora's
/// automatic client: Google's BotGuard challenge runs in an isolated
/// WebKit page, while Create/GenerateIT are kept outside the page.
@MainActor
final class YouTubePoTokenProvider: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = YouTubePoTokenProvider()

    private let requestKey = "O43z0dpjhgX20SCx4KAo"
    private var webView: WKWebView?
    private var ready = false
    private var bootstrapping = false
    private var sessionToken: String?
    private var expiry = Date.distantPast
    private var pendingReady: CheckedContinuation<Void, Error>?
    private var pendingToken: CheckedContinuation<String, Error>?

    private override init() { super.init() }

    func token(for videoID: String) async throws -> (player: String, session: String) {
        try await ensureReady()
        guard let sessionToken else { throw PoTokenError.notReady }
        let player = try await withCheckedThrowingContinuation { continuation in
            pendingToken = continuation
            let bytes = Array(videoID.utf8).map(String.init).joined(separator: ",")
            evaluate("obtainPoToken(new Uint8Array([\(bytes)]))")
        }
        return (player, sessionToken)
    }

    private func ensureReady() async throws {
        if ready, expiry > Date().addingTimeInterval(300) { return }
        if bootstrapping {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pendingReady = continuation
            }
            return
        }
        bootstrapping = true
        ready = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "lastwavePoToken")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        webView = view
        guard let htmlURL = Bundle.main.url(forResource: "po_token", withExtension: "html") else {
            throw PoTokenError.assetMissing
        }
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        view.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com")!)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingReady = continuation
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !ready else { return }
        Task { @MainActor in await self.createChallenge() }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any], let type = payload["type"] as? String else { return }
        switch type {
        case "botguard":
            let response: String
            if let string = payload["response"] as? String {
                response = string
            } else if JSONSerialization.isValidJSONObject(payload["response"] as Any),
                      let data = try? JSONSerialization.data(withJSONObject: payload["response"] as Any),
                      let json = String(data: data, encoding: .utf8) {
                response = json
            } else {
                return fail(PoTokenError.invalidBotGuardResponse)
            }
            Task { @MainActor in await self.generateIntegrityToken(response) }
        case "ready":
            ready = true
            bootstrapping = false
            pendingReady?.resume()
            pendingReady = nil
        case "mint":
            guard let csv = payload["bytes"] as? String else { return failToken(PoTokenError.invalidMintResponse) }
            guard let data = Self.csvToBase64URL(csv) else { return failToken(PoTokenError.invalidMintResponse) }
            pendingToken?.resume(returning: data)
            pendingToken = nil
        case "error":
            let text = payload["message"] as? String ?? "BotGuard failed"
            if !ready { fail(PoTokenError.javascript(text)) }
            else { failToken(PoTokenError.javascript(text)) }
        default: break
        }
    }

    private func createChallenge() async {
        do {
            let body = try JSONSerialization.data(withJSONObject: [requestKey])
            let response = try await post("https://www.youtube.com/api/jnn/v1/Create", body: body)
            let challenge = try Self.parseChallenge(response)
            let encoded = try JSONSerialization.data(withJSONObject: challenge)
            let json = String(decoding: encoded, as: UTF8.self)
            evaluate("runBotGuard(\(json)).then(function(r){ window.webPoSignalOutput=r.webPoSignalOutput; var v=(typeof r.botguardResponse==='string'?r.botguardResponse:JSON.stringify(r.botguardResponse)); window.webkit.messageHandlers.lastwavePoToken.postMessage({type:'botguard',response:v}); }).catch(function(e){ window.webkit.messageHandlers.lastwavePoToken.postMessage({type:'error',message:String(e)}); })")
        } catch { fail(error) }
    }

    private func generateIntegrityToken(_ botguardResponse: String) async {
        do {
            let body = try JSONSerialization.data(withJSONObject: [requestKey, botguardResponse])
            let response = try await post("https://www.youtube.com/api/jnn/v1/GenerateIT", body: body)
            let result = try Self.parseIntegrity(response)
            sessionToken = result.token
            expiry = Date().addingTimeInterval(TimeInterval(max(300, result.lifetime - 300)))
            evaluate("createPoTokenMinter(window.webPoSignalOutput, \(result.tokenU8)).then(function(){ window.webkit.messageHandlers.lastwavePoToken.postMessage({type:'ready'}); }).catch(function(e){ window.webkit.messageHandlers.lastwavePoToken.postMessage({type:'error',message:String(e)}); })")
        } catch { fail(error) }
    }

    private func post(_ urlString: String, body: Data) async throws -> Data {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json+protobuf", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) == true else { throw PoTokenError.http }
        return data
    }

    private func evaluate(_ script: String) { webView?.evaluateJavaScript(script, completionHandler: nil) }

    private func fail(_ error: Error) {
        bootstrapping = false
        pendingReady?.resume(throwing: error); pendingReady = nil
        webView?.stopLoading()
    }

    private func failToken(_ error: Error) { pendingToken?.resume(throwing: error); pendingToken = nil }

    private static func parseChallenge(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any] else { throw PoTokenError.badResponse }
        var challenge: [Any]? = nil
        if root.count > 1, let encoded = root[1] as? String, let decoded = descramble(encoded),
           let nested = try? JSONSerialization.jsonObject(with: decoded) as? [Any] { challenge = nested }
        if challenge == nil, let first = root.first as? [Any] { challenge = first }
        if challenge == nil { challenge = findChallenge(root) }
        guard let slots = challenge, slots.count > 5, let program = slots[4] as? String, let global = slots[5] as? String else { throw PoTokenError.badResponse }
        func firstString(_ value: Any?) -> String? {
            if let s = value as? String { return s }
            if let a = value as? [Any] { return a.compactMap { $0 as? String }.first }
            return nil
        }
        return ["program": program, "globalName": global,
                "interpreterJavascript": ["privateDoNotAccessOrElseSafeScriptWrappedValue": firstString(slots.count > 1 ? slots[1] : nil) ?? "",
                                            "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue": firstString(slots.count > 2 ? slots[2] : nil) ?? ""]]
    }

    private static func findChallenge(_ value: Any) -> [Any]? {
        if let a = value as? [Any], a.count > 5, a[4] is String, a[5] is String { return a }
        if let a = value as? [Any] { for item in a { if let found = findChallenge(item) { return found } } }
        if let d = value as? [String: Any] { for item in d.values { if let found = findChallenge(item) { return found } } }
        return nil
    }

    private static func parseIntegrity(_ data: Data) throws -> (token: String, tokenU8: String, lifetime: Int64) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any], root.count > 1,
              let token = root[0] as? String, let lifetime = (root[1] as? NSNumber)?.int64Value,
              let bytes = base64Bytes(token) else { throw PoTokenError.badResponse }
        let u8 = "new Uint8Array([" + bytes.map(String.init).joined(separator: ",") + "])"
        return (Self.base64URL(bytes), u8, lifetime)
    }

    private static func descramble(_ value: String) -> Data? {
        guard let bytes = base64Bytes(value) else { return nil }
        return Data(bytes.map { UInt8((Int($0) + 97) & 0xff) })
    }

    private static func base64Bytes(_ value: String) -> [UInt8]? {
        var s = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: ".", with: "=")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s).map(Array.init)
    }

    private static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func csvToBase64URL(_ csv: String) -> String? {
        let bytes = csv.split(separator: ",").compactMap { UInt8(String($0).trimmingCharacters(in: .whitespaces)) }
        return bytes.isEmpty ? nil : base64URL(bytes)
    }
}

enum PoTokenError: LocalizedError {
    case assetMissing, notReady, http, badResponse, invalidBotGuardResponse, invalidMintResponse, javascript(String)
    var errorDescription: String? {
        switch self {
        case .assetMissing: "PO-token asset is missing."
        case .notReady: "PO-token generator is not ready."
        case .http: "PO-token service request failed."
        case .badResponse: "PO-token service returned an unexpected response."
        case .invalidBotGuardResponse: "BotGuard returned an invalid response."
        case .invalidMintResponse: "PO-token mint returned invalid bytes."
        case .javascript(let message): "BotGuard JavaScript failed: \(message)"
        }
    }
}
