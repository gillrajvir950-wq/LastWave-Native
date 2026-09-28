import Foundation

struct LyricLine: Identifiable, Sendable {
    let time: TimeInterval
    let text: String
    var id: TimeInterval { time }
}

struct LyricsResult: Sendable {
    let plain: String?
    let lines: [LyricLine]
    let instrumental: Bool
}

enum LyricsService {
    private struct Record: Decodable {
        let trackName: String?
        let artistName: String?
        let plainLyrics: String?
        let syncedLyrics: String?
        let instrumental: Bool?
    }

    static func fetch(for track: Track) async throws -> LyricsResult? {
        guard track.artist != "Unknown Artist" else { return nil }
        let exactItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist)
        ]
        if let record: Record = try await request(path: "get", items: exactItems) {
            return result(from: record)
        }
        let query = URLQueryItem(name: "q", value: "\(track.artist) \(cleanTitle(track.title))")
        let records: [Record] = try await request(path: "search", items: [query]) ?? []
        let wantedTitle = normalize(cleanTitle(track.title))
        let wantedArtist = normalize(track.artist)
        let best = records.max { left, right in
            score(left, title: wantedTitle, artist: wantedArtist) < score(right, title: wantedTitle, artist: wantedArtist)
        }
        return best.map { result(from: $0) }
    }

    private static func request<T: Decodable>(path: String, items: [URLQueryItem]) async throws -> T? {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")!
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("LastWaveApple/0.1 (https://github.com/Clash-Projects/LastWave-Native)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func result(from record: Record) -> LyricsResult {
        LyricsResult(plain: record.plainLyrics,
                     lines: parseLRC(record.syncedLyrics ?? ""),
                     instrumental: record.instrumental ?? false)
    }

    private static func score(_ record: Record, title: String, artist: String) -> Int {
        let candidateTitle = normalize(cleanTitle(record.trackName ?? ""))
        let candidateArtist = normalize(record.artistName ?? "")
        var value = 0
        if candidateTitle == title { value += 8 }
        else if !candidateTitle.isEmpty && (candidateTitle.contains(title) || title.contains(candidateTitle)) { value += 3 }
        if candidateArtist == artist { value += 6 }
        else if !candidateArtist.isEmpty && (candidateArtist.contains(artist) || artist.contains(candidateArtist)) { value += 2 }
        if !(record.syncedLyrics ?? "").isEmpty { value += 1 }
        return value
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func cleanTitle(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s*[\(\[].*?(feat\.?|ft\.?|official|video|audio).*?[\)\]]"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseLRC(_ input: String) -> [LyricLine] {
        let pattern = #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return input.components(separatedBy: .newlines).flatMap { row -> [LyricLine] in
            let range = NSRange(row.startIndex..<row.endIndex, in: row)
            let matches = regex.matches(in: row, range: range)
            guard !matches.isEmpty else { return [] }
            let text = regex.stringByReplacingMatches(in: row, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return matches.compactMap { match in
                guard let minutesRange = Range(match.range(at: 1), in: row),
                      let secondsRange = Range(match.range(at: 2), in: row),
                      let minutes = Double(row[minutesRange]),
                      let seconds = Double(row[secondsRange]) else { return nil }
                var fraction = 0.0
                if let part = Range(match.range(at: 3), in: row) {
                    let digits = String(row[part])
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                return LyricLine(time: minutes * 60 + seconds + fraction, text: text)
            }
        }.sorted { $0.time < $1.time }
    }
}
