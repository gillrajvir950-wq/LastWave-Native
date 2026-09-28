import Foundation

/// A locally imported recording. The id stays stable when the app relaunches.
struct Track: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var artist: String
    var album: String
    var filename: String
    var videoID: String?
    var artworkURL: String?
    var sourceQuality: String?

    init(id: UUID = UUID(), title: String, artist: String = "Unknown Artist", album: String = "", filename: String,
         videoID: String? = nil, artworkURL: String? = nil, sourceQuality: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.filename = filename
        self.videoID = videoID
        self.artworkURL = artworkURL
        self.sourceQuality = sourceQuality
    }

    var isRemote: Bool { videoID != nil }
}

struct CatalogTrack: Identifiable, Equatable, Sendable {
    let videoID: String
    let title: String
    let artist: String
    let album: String
    let artworkURL: String?
    let durationSeconds: Int?
    var id: String { videoID }

    var playbackTrack: Track {
        Track(id: Self.stableID(videoID), title: title, artist: artist, album: album,
              filename: "", videoID: videoID, artworkURL: artworkURL)
    }

    private static func stableID(_ text: String) -> UUID {
        var bytes = Array(text.utf8.prefix(16)); bytes += Array(repeating: 0, count: max(0, 16 - bytes.count))
        bytes[6] = (bytes[6] & 0x0f) | 0x40; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

struct CatalogShelf: Identifiable, Equatable, Sendable {
    let title: String
    let tracks: [CatalogTrack]
    var id: String { title + tracks.map(\.videoID).joined() }
}

struct ResolvedAudioStream: Sendable {
    let url: URL
    let quality: String
    let codec: String?
    let sampleRate: Int?
    let bitDepth: Int?
    var headers: [String: String] = [:]
}

struct Playlist: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var trackIDs: [UUID]
    let createdAt: Date

    init(id: UUID = UUID(), name: String, trackIDs: [UUID] = [], createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.createdAt = createdAt
    }
}

struct LibraryState: Codable, Sendable {
    var tracks: [Track] = []
    var favoriteIDs: Set<UUID> = []
    var playlists: [Playlist] = []
}
