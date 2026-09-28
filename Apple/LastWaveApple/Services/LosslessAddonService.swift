import CryptoKit
import Foundation

struct AddonTrack: Decodable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let duration: Double?
    let format: String?
    let audioQuality: String?
    let artworkURL: String?
    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, format, audioQuality
        case artworkURL = "artworkUrl"
    }
}

private struct AddonSearchResponse: Decodable { let tracks: [AddonTrack] }

private struct AddonStream: Decodable {
    let url: String?
    let dataUrl: String?
    let format: String?
    let codec: String?
    let quality: String?
    let sampleRate: Int?
    let bitDepth: Int?
    let bitrate: Int?
}

actor LosslessAddonService {
    static let shared = LosslessAddonService()

    func resolve(_ track: CatalogTrack, baseURL rawBase: String, secret: String, quality: String) async throws -> ResolvedAudioStream? {
        let base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, URL(string: base) != nil else { return nil }
        let query = "\(track.title) \(track.artist)"
        guard var components = URLComponents(string: "\(base)/search") else { throw MusicServiceError.invalidURL }
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "quality", value: quality), URLQueryItem(name: "atmos", value: "none")]
        guard let searchURL = components.url else { throw MusicServiceError.invalidURL }
        let searchData = try await request(searchURL, secret: secret, intent: nil)
        let response = try JSONDecoder().decode(AddonSearchResponse.self, from: searchData)
        guard let match = bestMatch(track, response.tracks) else { return nil }
        let escapedID = match.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? match.id
        guard var streamParts = URLComponents(string: "\(base)/stream/\(escapedID)") else { throw MusicServiceError.invalidURL }
        streamParts.queryItems = [URLQueryItem(name: "quality", value: quality), URLQueryItem(name: "atmos", value: "none")]
        guard let streamURL = streamParts.url else { throw MusicServiceError.invalidURL }
        let streamData = try await request(streamURL, secret: secret, intent: "stream")
        let stream = try JSONDecoder().decode(AddonStream.self, from: streamData)
        guard let raw = stream.url ?? stream.dataUrl, let url = URL(string: raw) else { throw MusicServiceError.invalidURL }
        let label = [stream.quality ?? match.audioQuality ?? quality,
                     stream.bitDepth.map { "\($0)-bit" }, stream.sampleRate.map { "\($0 / 1000) kHz" }]
            .compactMap { $0 }.joined(separator: " · ")
        return ResolvedAudioStream(url: url, quality: label, codec: stream.codec ?? stream.format,
                                   sampleRate: stream.sampleRate, bitDepth: stream.bitDepth)
    }

    private func request(_ url: URL, secret: String, intent: String?) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 12
        request.setValue("LastWave-Apple/0.4", forHTTPHeaderField: "User-Agent")
        if let intent { request.setValue(intent, forHTTPHeaderField: "X-LW-Intent") }
        if !secret.isEmpty, let token = addonToken(url.path) {
            let timestamp = String(Int(Date().timeIntervalSince1970))
            let message = "\(timestamp)\nGET\n\(url.path)\n\(token)"
            let key = SymmetricKey(data: Data(secret.utf8))
            let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
                .map { String(format: "%02x", $0) }.joined()
            request.setValue(timestamp, forHTTPHeaderField: "X-LW-TS")
            request.setValue(signature, forHTTPHeaderField: "X-LW-Sign")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = response as? HTTPURLResponse, (200..<300).contains(status.statusCode) else { throw MusicServiceError.badResponse }
        return data
    }

    private func addonToken(_ path: String) -> String? {
        let pieces = path.split(separator: "/"); guard let index = pieces.firstIndex(of: "a"), pieces.indices.contains(index + 1) else { return nil }
        return String(pieces[index + 1])
    }

    private func bestMatch(_ source: CatalogTrack, _ candidates: [AddonTrack]) -> AddonTrack? {
        func normalized(_ value: String) -> Set<Substring> {
            Set(value.lowercased().replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression).split(separator: " "))
        }
        let wanted = normalized("\(source.title) \(source.artist)")
        return candidates.max { a, b in
            wanted.intersection(normalized("\(a.title) \(a.artist)")).count < wanted.intersection(normalized("\(b.title) \(b.artist)")).count
        }
    }
}
