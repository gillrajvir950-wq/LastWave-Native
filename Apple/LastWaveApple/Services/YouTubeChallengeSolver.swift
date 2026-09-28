import Foundation
import JavaScriptCore

struct YouTubePlayerScript: Sendable {
    let source: String
    let signatureTimestamp: Int?
}

actor YouTubeChallengeSolver {
    static let shared = YouTubeChallengeSolver()

    private var cachedPlayer: YouTubePlayerScript?
    private var cachedAt: Date?

    func currentPlayer() async throws -> YouTubePlayerScript {
        if let cachedPlayer, let cachedAt, Date().timeIntervalSince(cachedAt) < 21_600 { return cachedPlayer }
        let iframeURL = URL(string: "https://www.youtube.com/iframe_api")!
        var iframeRequest = URLRequest(url: iframeURL)
        iframeRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (iframeData, _) = try await URLSession.shared.data(for: iframeRequest)
        let iframe = String(decoding: iframeData, as: UTF8.self)
        guard let playerID = Self.capture(#"player\\?/([A-Za-z0-9_-]+)/"#, in: iframe)
                ?? Self.capture(#"player/([A-Za-z0-9_-]+)/"#, in: iframe) else {
            throw SolverError.playerNotFound
        }
        let scriptURL = URL(string: "https://www.youtube.com/s/player/\(playerID)/player_ias.vflset/en_US/base.js")!
        var scriptRequest = URLRequest(url: scriptURL)
        scriptRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: scriptRequest)
        guard (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) == true else {
            throw SolverError.playerNotFound
        }
        let source = String(decoding: data, as: UTF8.self)
        let stamp = Self.capture(#"signatureTimestamp\s*[:=]\s*(\d+)"#, in: source).flatMap(Int.init)
        let result = YouTubePlayerScript(source: source, signatureTimestamp: stamp)
        cachedPlayer = result
        cachedAt = .now
        return result
    }

    func solve(signature: String?, throttling: String?, using player: YouTubePlayerScript) throws -> (signature: String?, throttling: String?) {
        guard signature != nil || throttling != nil else { return (nil, nil) }
        guard let libraryURL = Bundle.main.url(forResource: "yt.solver.lib.min", withExtension: "js"),
              let coreURL = Bundle.main.url(forResource: "yt.solver.core.min", withExtension: "js"),
              let library = try? String(contentsOf: libraryURL, encoding: .utf8),
              let core = try? String(contentsOf: coreURL, encoding: .utf8),
              let context = JSContext() else { throw SolverError.assetsMissing }

        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript(library)
        context.evaluateScript(core)
        if let exception { throw SolverError.javaScript(exception) }

        var requests: [[String: Any]] = []
        if let signature { requests.append(["type": "sig", "challenges": [signature]]) }
        if let throttling { requests.append(["type": "n", "challenges": [throttling]]) }
        let payload: [String: Any] = ["type": "player", "player": player.source,
                                      "requests": requests, "output_preprocessed": false]
        guard let function = context.objectForKeyedSubscript("jsc"),
              let output = function.call(withArguments: [payload]),
              !output.isUndefined, !output.isNull else {
            throw SolverError.javaScript(exception ?? "Solver returned no result")
        }
        guard let root = output.toDictionary() as? [String: Any],
              let responses = root["responses"] as? [[String: Any]] else {
            throw SolverError.invalidResult
        }
        var solvedSignature: String?
        var solvedThrottling: String?
        for (index, request) in requests.enumerated() where responses.indices.contains(index) {
            guard responses[index]["type"] as? String == "result",
                  let data = responses[index]["data"] as? [String: Any],
                  let challenge = (request["challenges"] as? [String])?.first,
                  let answer = data[challenge] as? String else { continue }
            if request["type"] as? String == "sig" { solvedSignature = answer }
            if request["type"] as? String == "n" { solvedThrottling = answer }
        }
        return (solvedSignature, solvedThrottling)
    }

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

enum SolverError: LocalizedError {
    case playerNotFound, assetsMissing, invalidResult, javaScript(String)
    var errorDescription: String? {
        switch self {
        case .playerNotFound: "YouTube player script could not be loaded."
        case .assetsMissing: "The built-in YouTube challenge solver is missing."
        case .invalidResult: "YouTube challenge solver returned an invalid result."
        case .javaScript(let message): "YouTube challenge solver failed: \(message)"
        }
    }
}
