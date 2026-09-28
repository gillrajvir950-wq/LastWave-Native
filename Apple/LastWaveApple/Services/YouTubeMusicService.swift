import Foundation

enum MusicServiceError: LocalizedError {
    case badResponse, noResults, noPlayableStream, invalidURL
    var errorDescription: String? {
        switch self {
        case .badResponse: "Music service returned an invalid response."
        case .noResults: "No songs found."
        case .noPlayableStream: "No playable audio stream was found."
        case .invalidURL: "The audio service returned an invalid URL."
        }
    }
}

actor YouTubeMusicService {
    static let shared = YouTubeMusicService()
    private let session: URLSession
    private var webKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
    private var webVersion = "1.20260707.12.00"
    private var configured = false

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["Accept-Language": "en-US,en;q=0.9"]
        session = URLSession(configuration: config)
    }

    func search(_ query: String) async throws -> [CatalogTrack] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        await bootstrap()
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": webVersion, "hl": "en", "gl": "US"]],
            "query": clean,
            "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA=="
        ]
        let json = try await postJSON("https://music.youtube.com/youtubei/v1/search?key=\(webKey)", body: body,
                                     headers: ["Origin": "https://music.youtube.com"])
        var renderers: [[String: Any]] = []
        collect(key: "musicResponsiveListItemRenderer", in: json, into: &renderers)
        var seen = Set<String>()
        return renderers.compactMap { renderer in
            guard let videoID = firstVideoID(in: renderer), seen.insert(videoID).inserted else { return nil }
            let columns = renderer["flexColumns"] as? [[String: Any]] ?? []
            let firstRuns = runs(in: columns.first)
            guard let title = firstRuns.first?["text"] as? String, !title.isEmpty else { return nil }
            let allRuns = columns.flatMap { runs(in: $0) }
            let artist = allRuns.first(where: { browseID($0)?.hasPrefix("UC") == true })?["text"] as? String ?? "Unknown Artist"
            let album = allRuns.first(where: { browseID($0)?.hasPrefix("MPRE") == true })?["text"] as? String ?? ""
            let duration = allRuns.compactMap { ($0["text"] as? String).flatMap(parseDuration) }.first
            return CatalogTrack(videoID: videoID, title: title, artist: artist, album: album,
                                artworkURL: largestThumbnail(in: renderer), durationSeconds: duration)
        }
    }

    func resolve(_ track: CatalogTrack) async throws -> ResolvedAudioStream {
        let clients: [(String, Int, String, String, String, [String: Any])] = [
            ("VISIONOS", 101, "0.1", "AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc", "Mozilla/5.0 (Apple Vision; CPU OS 1_3 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15", ["osName":"visionOS", "osVersion":"1.3.21O771", "deviceMake":"Apple", "deviceModel":"RealityDevice14,1"]),
            ("ANDROID_VR", 28, "1.65.10", "AIzaSyD-p045F_WzU-vA_YgX20SCx4KAo", "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip", ["osName":"Android", "osVersion":"12", "deviceMake":"Oculus", "deviceModel":"Quest 3", "androidSdkVersion":32]),
            ("TVHTML5", 7, "7.20260308.08.00", "AIzaSyAO_FJ2SlqAz8GlBg1fA54p0wDE7Xk80mU", "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version", [:])
        ]
        for (name, id, version, key, userAgent, extras) in clients {
            var client: [String: Any] = ["clientName": name, "clientVersion": version, "clientNameId": id, "hl":"en", "gl":"US"]
            extras.forEach { client[$0] = $1 }
            let body: [String: Any] = ["context": ["client": client], "videoId": track.videoID,
                                       "contentCheckOk": true, "racyCheckOk": true]
            if let json = try? await postJSON("https://www.youtube.com/youtubei/v1/player?key=\(key)", body: body,
                                              headers: ["User-Agent": userAgent, "Origin": "https://www.youtube.com"]),
               let stream = bestAudio(in: json) { return stream }
        }
        throw MusicServiceError.noPlayableStream
    }

    private func bootstrap() async {
        guard !configured else { return }; configured = true
        guard let url = URL(string: "https://music.youtube.com"),
              let (data, _) = try? await session.data(from: url), let html = String(data: data, encoding: .utf8) else { return }
        if let key = capture("\\\"INNERTUBE_API_KEY\\\":\\\"([^\\\"]+)", in: html) { webKey = key }
        if let version = capture("\\\"INNERTUBE_CONTEXT_CLIENT_VERSION\\\":\\\"([^\\\"]+)", in: html) { webVersion = version }
    }

    private func postJSON(_ value: String, body: [String: Any], headers: [String: String]) async throws -> Any {
        guard let url = URL(string: value) else { throw MusicServiceError.invalidURL }
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MusicServiceError.badResponse }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func collect(key: String, in value: Any, into output: inout [[String: Any]]) {
        if let object = value as? [String: Any] {
            if let match = object[key] as? [String: Any] { output.append(match) }
            object.values.forEach { collect(key: key, in: $0, into: &output) }
        } else if let array = value as? [Any] { array.forEach { collect(key: key, in: $0, into: &output) } }
    }
    private func runs(in column: [String: Any]?) -> [[String: Any]] {
        guard let renderer = column?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
              let text = renderer["text"] as? [String: Any] else { return [] }
        return text["runs"] as? [[String: Any]] ?? []
    }
    private func browseID(_ run: [String: Any]) -> String? {
        (((run["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String)
    }
    private func firstVideoID(in value: Any) -> String? {
        if let object = value as? [String: Any] {
            if let watch = object["watchEndpoint"] as? [String: Any], let id = watch["videoId"] as? String { return id }
            for child in object.values { if let id = firstVideoID(in: child) { return id } }
        } else if let array = value as? [Any] { for child in array { if let id = firstVideoID(in: child) { return id } } }
        return nil
    }
    private func largestThumbnail(in value: Any) -> String? {
        var urls: [(String, Int)] = []
        func walk(_ item: Any) {
            if let object = item as? [String: Any] {
                if let url = object["url"] as? String, url.hasPrefix("http") { urls.append((url, object["width"] as? Int ?? 0)) }
                object.values.forEach(walk)
            } else if let array = item as? [Any] { array.forEach(walk) }
        }
        walk(value); return urls.max(by: { $0.1 < $1.1 })?.0
    }
    private func bestAudio(in json: Any) -> ResolvedAudioStream? {
        guard let root = json as? [String: Any], let streaming = root["streamingData"] as? [String: Any] else { return nil }
        let formats = (streaming["adaptiveFormats"] as? [[String: Any]] ?? []) + (streaming["formats"] as? [[String: Any]] ?? [])
        let audio = formats.filter { ($0["mimeType"] as? String)?.hasPrefix("audio/") == true && $0["url"] is String }
        guard let best = audio.max(by: { ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0) }),
              let raw = best["url"] as? String, let url = URL(string: raw) else { return nil }
        let mime = best["mimeType"] as? String
        return ResolvedAudioStream(url: url, quality: "YouTube \((best["bitrate"] as? Int ?? 0) / 1000) kbps",
                                   codec: mime, sampleRate: Int(best["audioSampleRate"] as? String ?? ""), bitDepth: nil)
    }
    private func parseDuration(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }; guard parts.count == 2 || parts.count == 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
    private func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }; return String(text[range])
    }
}
