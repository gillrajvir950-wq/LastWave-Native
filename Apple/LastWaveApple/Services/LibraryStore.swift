import AVFoundation
import Foundation
import UniformTypeIdentifiers

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var favoriteIDs: Set<UUID> = []
    @Published private(set) var playlists: [Playlist] = []
    @Published var errorMessage: String?
    @Published var noticeMessage: String?

    private let files = FileManager.default
    private let directory: URL
    private let artworkDirectory: URL
    private let index: URL

    init() {
        let documents = files.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Music", isDirectory: true)
        artworkDirectory = documents.appendingPathComponent("Artwork", isDirectory: true)
        index = documents.appendingPathComponent("library.json")
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try files.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
            try load()
        } catch {
            errorMessage = "Could not load the library: \(error.localizedDescription)"
        }
    }

    var favorites: [Track] { tracks.filter { favoriteIDs.contains($0.id) } }

    func tracks(in playlist: Playlist) -> [Track] {
        playlist.trackIDs.compactMap { id in tracks.first { $0.id == id } }
    }

    func track(id: UUID) -> Track? { tracks.first { $0.id == id } }
    func url(for track: Track) -> URL { directory.appendingPathComponent(track.filename) }

    func artworkURL(for track: Track) -> URL? {
        let url = artworkDirectory.appendingPathComponent("\(track.id.uuidString).artwork")
        return files.fileExists(atPath: url.path) ? url : nil
    }

    func isFavorite(_ track: Track) -> Bool { favoriteIDs.contains(track.id) }

    func toggleFavorite(_ track: Track) {
        if favoriteIDs.contains(track.id) { favoriteIDs.remove(track.id) }
        else { favoriteIDs.insert(track.id) }
        save()
    }

    @discardableResult
    func createPlaylist(named rawName: String) -> Playlist? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let playlist = Playlist(name: name)
        playlists.append(playlist)
        save()
        return playlist
    }

    func rename(_ playlist: Playlist, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].name = name
        save()
    }

    func delete(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
        save()
    }

    func add(_ track: Track, to playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }),
              !playlists[index].trackIDs.contains(track.id) else { return }
        playlists[index].trackIDs.append(track.id)
        save()
    }

    func remove(_ track: Track, from playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].trackIDs.removeAll { $0 == track.id }
        save()
    }

    func importFiles(_ urls: [URL]) async {
        errorMessage = nil
        noticeMessage = nil
        var importedCount = 0
        for source in urls {
            let ext = source.pathExtension.lowercased()
            let allowed = ["mp3", "m4a", "mp4", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac"]
            let declaredAudio = UTType(filenameExtension: ext)?.conforms(to: .audio) == true
            guard allowed.contains(ext) || declaredAudio else {
                errorMessage = "Unsupported audio file: \(source.lastPathComponent)"
                continue
            }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                let id = UUID()
                let filename = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
                let destination = directory.appendingPathComponent(filename)

                var coordinatorError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinatorError) { readableURL in
                    do { try files.copyItem(at: readableURL, to: destination) }
                    catch { copyError = error }
                }
                if let copyError { throw copyError }
                if let coordinatorError { throw coordinatorError }

                // Save a playable entry first. Missing or unusual metadata must
                // never make a successfully copied audio file disappear.
                tracks.append(Track(id: id,
                                    title: source.deletingPathExtension().lastPathComponent,
                                    artist: "Unknown Artist", album: "", filename: filename))
                do { try persist() }
                catch {
                    tracks.removeAll { $0.id == id }
                    try? files.removeItem(at: destination)
                    throw error
                }
                importedCount += 1

                let asset = AVURLAsset(url: destination)
                let metadata = (try? await asset.load(.commonMetadata)) ?? []
                let title = await stringValue(for: .commonIdentifierTitle, in: metadata)
                let artist = await stringValue(for: .commonIdentifierArtist, in: metadata)
                let album = await stringValue(for: .commonIdentifierAlbumName, in: metadata)
                if let artwork = await dataValue(for: .commonIdentifierArtwork, in: metadata) {
                    try? artwork.write(to: artworkDirectory.appendingPathComponent("\(id.uuidString).artwork"), options: .atomic)
                }
                if let index = tracks.firstIndex(where: { $0.id == id }) {
                    tracks[index].title = title?.isEmpty == false ? title! : tracks[index].title
                    tracks[index].artist = artist?.isEmpty == false ? artist! : tracks[index].artist
                    tracks[index].album = album ?? ""
                    try? persist()
                }
            } catch {
                errorMessage = "Could not import \(source.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if importedCount > 0 {
            noticeMessage = importedCount == 1 ? "Song imported successfully." : "\(importedCount) songs imported successfully."
        }
    }

    func remove(_ track: Track) {
        guard tracks.contains(where: { $0.id == track.id }) else { return }
        do {
            if files.fileExists(atPath: url(for: track).path) { try files.removeItem(at: url(for: track)) }
            if let artwork = artworkURL(for: track) { try? files.removeItem(at: artwork) }
            tracks.removeAll { $0.id == track.id }
            favoriteIDs.remove(track.id)
            for index in playlists.indices { playlists[index].trackIDs.removeAll { $0 == track.id } }
            try persist()
        } catch {
            errorMessage = "Could not remove the track: \(error.localizedDescription)"
        }
    }

    private func load() throws {
        guard files.fileExists(atPath: index.path) else { return }
        let data = try Data(contentsOf: index)
        if let state = try? JSONDecoder().decode(LibraryState.self, from: data) {
            tracks = state.tracks.filter { files.fileExists(atPath: directory.appendingPathComponent($0.filename).path) }
            let valid = Set(tracks.map(\.id))
            favoriteIDs = state.favoriteIDs.intersection(valid)
            playlists = state.playlists.map { item in
                var cleaned = item
                cleaned.trackIDs = item.trackIDs.filter { valid.contains($0) }
                return cleaned
            }
        } else {
            tracks = try JSONDecoder().decode([Track].self, from: data)
                .filter { files.fileExists(atPath: directory.appendingPathComponent($0.filename).path) }
            try persist()
        }
    }

    private func save() {
        do { try persist() }
        catch { errorMessage = "Could not save the library: \(error.localizedDescription)" }
    }

    private func persist() throws {
        let state = LibraryState(tracks: tracks, favoriteIDs: favoriteIDs, playlists: playlists)
        try JSONEncoder().encode(state).write(to: index, options: .atomic)
    }

    private func stringValue(for identifier: AVMetadataIdentifier, in items: [AVMetadataItem]) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first else { return nil }
        return try? await item.load(.stringValue)
    }

    private func dataValue(for identifier: AVMetadataIdentifier, in items: [AVMetadataItem]) async -> Data? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first else { return nil }
        return try? await item.load(.dataValue)
    }
}
