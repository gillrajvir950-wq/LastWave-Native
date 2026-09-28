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
        if let piped = await resolveWithPiped(track.videoID) { return piped }
        let clients: [(String, Int, String, String, String, [String: Any])] = [
            ("VISIONOS", 101, "0.1", "AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc", "Mozilla/5.0 (Apple Vision; CPU OS 1_3 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15", ["osName":"visionOS", "osVersion":"1.3.21O771", "deviceMake":"Apple", "deviceModel":"RealityDevice14,1"]),
            ("ANDROID_VR", 28, "1.65.10", "AIzaSyD-p045F_WzU-vA_YgX20SCx4KAo", "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip", ["osName":"Android", "osVersion":"12", "deviceMake":"Oculus", "deviceModel":"Quest 3", "androidSdkVersion":32]),
            ("TVHTML5", 7, "7.20260308.08.00", "AIzaSyAO_FJ2SlqAz8GlBg1fA54p0wDE7Xk80mU", "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0) AppleWebKit/537.36 TV Safari/537.36", [:]),
            ("IOS_MUSIC", 26, "7.27.0", "AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc", "com.google.ios.youtubemusic/7.27.0 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X;)", ["osName":"iOS", "osVersion":"17.5.1.21F90", "deviceMake":"Apple", "deviceModel":"iPhone16,2"]),
            ("ANDROID_TESTSUITE", 30, "1.9", "AIzaSyD-p045F_WzU-vA_YgX20SCx4KAo", "com.google.android.youtube/1.9 (Linux; U; Android 12) gzip", ["osName":"Android", "osVersion":"12"]),
            ("TVHTML5_SIMPLY_EMBEDDED_PLAYER", 85, "2.0", "AIzaSyAO_FJ2SlqAz8GlBg1fA54p0wDE7Xk80mU", "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0) AppleWebKit/537.36 TV Safari/537.36", [:])
        ]
        for (name, id, version, key, userAgent, extras) in clients {
            var client: [String: Any] = ["clientName": name, "clientVersion": version, "hl":"en", "gl":"US"]
            extras.forEach { client[$0] = $1 }
            var context: [String: Any] = ["client": client]
            if name.contains("EMBEDDED") { context["thirdParty"] = ["embedUrl": "https://www.youtube.com/embed/\(track.videoID)"] }
            let body: [String: Any] = ["context": context, "videoId": track.videoID,
                                       "contentCheckOk": true, "racyCheckOk": true,
                                       "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]]]
            let origin = name.contains("TVHTML5") ? "https://www.youtube.com" : "https://www.youtube.com"
            let requestHeaders = ["User-Agent": userAgent, "Origin": origin,
                                  "Referer": name.contains("EMBEDDED") ? "https://www.youtube.com/embed/\(track.videoID)" : "https://www.youtube.com/",
                                  "X-YouTube-Client-Name": String(id), "X-YouTube-Client-Version": version]
            if let json = try? await postJSON("https://www.youtube.com/youtubei/v1/player?key=\(key)", body: body,
                                              headers: requestHeaders),
               let stream = bestAudio(in: json, headers: requestHeaders) { return stream }
        }
        throw MusicServiceError.noPlayableStream
    }

    /// Public Piped APIs perform the player-JavaScript deciphering that raw
    /// InnerTube responses increasingly require. Race several documented
    /// instances so one unavailable host does not block playback.
    private func resolveWithPiped(_ videoID: String) async -> ResolvedAudioStream? {
        let instances = [
            "https://pipedapi.leptons.xyz",
            "https://pipedapi.kavin.rocks",
            "https://pipedapi.nosebs.ru"
        ]
        return await withTaskGroup(of: ResolvedAudioStream?.self) { group in
            for base in instances {
                group.addTask { await Self.pipedStream(videoID: videoID, base: base) }
            }
            for await candidate in group {
                if let candidate { group.cancelAll(); return candidate }
            }
            return nil
        }
    }

    private nonisolated static func pipedStream(videoID: String, base: String) async -> ResolvedAudioStream? {
        guard let url = URL(string: "\(base)/streams/\(videoID)") else { return nil }
        var request = URLRequest(url: url); request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LastWave-Apple/0.6", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = response as? HTTPURLResponse, (200..<300).contains(status.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let streams = root["audioStreams"] as? [[String: Any]] else { return nil }
        let usable = streams.filter { item in
            guard let raw = item["url"] as? String, URL(string: raw) != nil else { return false }
            return item["videoOnly"] as? Bool != true
        }
        guard let best = usable.max(by: { Self.number($0["bitrate"]) < Self.number($1["bitrate"]) }),
              let raw = best["url"] as? String, let streamURL = URL(string: raw) else { return nil }
        let bitrate = Self.number(best["bitrate"])
        let codec = best["codec"] as? String ?? best["format"] as? String ?? best["mimeType"] as? String
        return ResolvedAudioStream(url: streamURL,
                                   quality: bitrate > 0 ? "Online \(bitrate / 1000) kbps" : "Online audio",
                                   codec: codec, sampleRate: nil, bitDepth: nil,
                                   headers: ["User-Agent": "Mozilla/5.0", "Referer": "\(base)/"])
    }

    private nonisolated static func number(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
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
    private func bestAudio(in json: Any, headers: [String: String]) -> ResolvedAudioStream? {
        guard let root = json as? [String: Any], let streaming = root["streamingData"] as? [String: Any] else { return nil }
        let formats = (streaming["adaptiveFormats"] as? [[String: Any]] ?? []) + (streaming["formats"] as? [[String: Any]] ?? [])
        let audio = formats.filter { ($0["mimeType"] as? String)?.hasPrefix("audio/") == true && $0["url"] is String }
        if let best = audio.max(by: { ($0["bitrate"] as? Int ?? 0) < ($1["bitrate"] as? Int ?? 0) }),
           let raw = best["url"] as? String, let url = URL(string: raw) {
            let mime = best["mimeType"] as? String
            return ResolvedAudioStream(url: url, quality: "YouTube \((best["bitrate"] as? Int ?? 0) / 1000) kbps",
                                       codec: mime, sampleRate: Int(best["audioSampleRate"] as? String ?? ""), bitDepth: nil,
                                       headers: headers)
        }
        guard let rawHLS = streaming["hlsManifestUrl"] as? String, let hlsURL = URL(string: rawHLS) else { return nil }
        return ResolvedAudioStream(url: hlsURL, quality: "YouTube HLS", codec: "HLS", sampleRate: nil, bitDepth: nil,
                                   headers: headers)
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
