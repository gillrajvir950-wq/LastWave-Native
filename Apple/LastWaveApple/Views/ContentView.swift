import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ContentView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    @State private var showImporter = false
    @State private var showPlayer = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryView(showImporter: $showImporter)
                .tag(0)
                .tabItem { Label("Library", systemImage: "music.note.list") }
            OnlineSearchView()
                .tag(1)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            TrackCollectionView(title: "Favourites", tracks: library.favorites, emptyIcon: "heart",
                                emptyMessage: "Songs you favourite appear here.")
                .tabItem { Label("Favourites", systemImage: "heart.fill") }
                .tag(2)
            PlaylistsView()
                .tabItem { Label("Playlists", systemImage: "music.note.list") }
                .tag(3)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(4)
        }
        .safeAreaInset(edge: .bottom) {
            if player.current != nil { MiniPlayer(showPlayer: $showPlayer) }
        }
        .sheet(isPresented: $showPlayer) { FullPlayerView() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await library.importFiles(urls) }
            case .failure(let error): library.errorMessage = error.localizedDescription
            }
        }
        .alert("LastWave", isPresented: Binding(
            get: { library.errorMessage != nil || player.errorMessage != nil || library.noticeMessage != nil },
            set: { if !$0 { library.errorMessage = nil; player.errorMessage = nil; library.noticeMessage = nil } }
        )) {
            Button("OK") { library.errorMessage = nil; player.errorMessage = nil; library.noticeMessage = nil }
        } message: {
            Text(library.errorMessage ?? player.errorMessage ?? library.noticeMessage ?? "")
        }
        .task { player.restore(from: library) }
        .onChange(of: selectedTab) { _, _ in dismissKeyboard() }
    }

    private func dismissKeyboard() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

private struct OnlineSearchView: View {
    @EnvironmentObject private var player: PlayerStore
    @State private var query = ""
    @State private var results: [CatalogTrack] = []
    @State private var searching = false
    @State private var error: String?
    @State private var searchPresented = false

    var body: some View {
        NavigationStack {
            List {
                if searching { HStack { Spacer(); ProgressView("Searching…"); Spacer() } }
                else if let error { ContentUnavailableView("Search failed", systemImage: "wifi.exclamationmark", description: Text(error)) }
                else if results.isEmpty { ContentUnavailableView("Search music", systemImage: "waveform", description: Text("Find songs from the online music catalogue.")) }
                else { ForEach(results) { song in
                    Button { Task { await player.playOnline(song) } } label: {
                        HStack(spacing: 12) {
                            RemoteArtwork(url: song.artworkURL, size: 50)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(song.title).font(.headline).lineLimit(1)
                                Text([song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if player.isLoading { ProgressView().controlSize(.small) }
                            else { Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.tint) }
                        }
                    }.buttonStyle(.plain)
                } }
            }
            .navigationTitle("Search")
            .searchable(text: $query, isPresented: $searchPresented, prompt: "Songs, artists, albums")
            .scrollDismissesKeyboard(.interactively)
            .onSubmit(of: .search) { runSearch() }
            .toolbar { Button("Search", systemImage: "magnifyingglass") { runSearch() }.disabled(query.trimmingCharacters(in: .whitespaces).isEmpty) }
        }
    }
    private func runSearch() {
        searching = true; error = nil; searchPresented = false
        Task { do { results = try await YouTubeMusicService.shared.search(query) } catch { self.error = error.localizedDescription }; searching = false }
    }
}

private struct RemoteArtwork: View {
    let url: String?; let size: CGFloat
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else { ZStack { Color.purple.opacity(0.25); Image(systemName: "music.note") } }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }
}

private struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @Binding var showImporter: Bool
    @State private var search = ""

    private var filtered: [Track] {
        guard !search.isEmpty else { return library.tracks }
        return library.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(search) ||
            $0.artist.localizedCaseInsensitiveContains(search) ||
            $0.album.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            TrackList(tracks: filtered, emptyIcon: "music.note.list", emptyMessage: "Import audio files to start listening.")
                .searchable(text: $search, prompt: "Songs, artists, albums")
                .navigationTitle("LastWave")
                .toolbar { Button("Import audio", systemImage: "plus") { showImporter = true } }
        }
    }
}

private struct TrackCollectionView: View {
    let title: String
    let tracks: [Track]
    let emptyIcon: String
    let emptyMessage: String

    var body: some View {
        NavigationStack {
            TrackList(tracks: tracks, emptyIcon: emptyIcon, emptyMessage: emptyMessage)
                .navigationTitle(title)
        }
    }
}

private struct TrackList: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    let tracks: [Track]
    let emptyIcon: String
    let emptyMessage: String
    var playlist: Playlist?

    var body: some View {
        List {
            if tracks.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: emptyIcon, description: Text(emptyMessage))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(tracks) { track in
                    Button { player.play(track, in: tracks, from: library) } label: {
                        TrackRow(track: track)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(library.isFavorite(track) ? "Remove Favourite" : "Add Favourite",
                               systemImage: library.isFavorite(track) ? "heart.slash" : "heart") {
                            library.toggleFavorite(track)
                        }
                        if !library.playlists.isEmpty {
                            Menu("Add to Playlist", systemImage: "text.badge.plus") {
                                ForEach(library.playlists) { item in
                                    Button(item.name) { library.add(track, to: item) }
                                }
                            }
                        }
                        if let playlist {
                            Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive) {
                                library.remove(track, from: playlist)
                            }
                        }
                        Button("Delete from Library", systemImage: "trash", role: .destructive) {
                            if player.current?.id == track.id { player.stop() }
                            library.remove(track)
                        }
                    }
                }
            }
        }
    }
}

private struct TrackRow: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    let track: Track

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: track, size: 48, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.headline).lineLimit(1)
                Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if library.isFavorite(track) { Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption) }
            if player.current?.id == track.id { Image(systemName: player.isPlaying ? "waveform" : "speaker.fill").foregroundStyle(.tint) }
        }
        .contentShape(Rectangle())
    }
}

private struct PlaylistsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showCreate = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                if library.playlists.isEmpty {
                    ContentUnavailableView("No playlists", systemImage: "music.note.list",
                                           description: Text("Create a playlist, then add songs from their menu."))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(library.playlists) { playlist in
                        NavigationLink(value: playlist) {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(playlist.name).font(.headline)
                                    Text("\(library.tracks(in: playlist).count) songs").font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "music.note.list").frame(width: 44, height: 44)
                                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .contextMenu {
                            Button("Delete Playlist", systemImage: "trash", role: .destructive) { library.delete(playlist) }
                        }
                    }
                }
            }
            .navigationTitle("Playlists")
            .navigationDestination(for: Playlist.self) { playlist in
                TrackList(tracks: library.tracks(in: playlist), emptyIcon: "music.note",
                          emptyMessage: "Add songs from the Library song menu.", playlist: playlist)
                    .navigationTitle(playlist.name)
            }
            .toolbar { Button("New playlist", systemImage: "plus") { name = ""; showCreate = true } }
            .alert("New Playlist", isPresented: $showCreate) {
                TextField("Playlist name", text: $name)
                Button("Create") { library.createPlaylist(named: name) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Choose a name for the playlist.") }
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var equalizer: EqualizerStore
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("lossless.addonURL") private var addonURL = ""
    @AppStorage("lossless.addonSecret") private var addonSecret = ""
    @AppStorage("lossless.quality") private var losslessQuality = "lossless"

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }
                Section("Library") {
                    LabeledContent("Songs", value: "\(library.tracks.count)")
                    LabeledContent("Favourites", value: "\(library.favorites.count)")
                    LabeledContent("Playlists", value: "\(library.playlists.count)")
                }
                Section("Lossless audio") {
                    TextField("Addon server URL", text: $addonURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Signing secret (only if required)", text: $addonSecret)
                    Picker("Preferred quality", selection: $losslessQuality) {
                        Text("Hi-Res 24/192").tag("max")
                        Text("Hi-Res 24/96").tag("hires")
                        Text("Lossless 16/44.1").tag("lossless")
                        Text("High AAC/MP3").tag("high")
                    }
                    Text(addonURL.isEmpty ? "Add an Android-compatible LastWave addon URL to enable FLAC/Hi-Res. Online playback falls back to YouTube when it is blank or unavailable." : "Lossless addon enabled; YouTube remains the automatic fallback.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Equalizer") {
                    Toggle("15-band EQ", isOn: $equalizer.enabled)
                    Picker("Preset", selection: Binding(get: { equalizer.presetName }, set: { name in
                        if let preset = EqualizerStore.presets.first(where: { $0.name == name }) { equalizer.apply(preset) }
                    })) { ForEach(EqualizerStore.presets) { Text($0.name).tag($0.name) } }
                    NavigationLink("Fine tune bands") { EqualizerView() }
                }
                Section("About") {
                    LabeledContent("App", value: "LastWave Apple")
                    LabeledContent("Version", value: "0.4 development")
                    Text("Local files, online catalogue playback, lossless addon fallback, playlists, lyrics and 15-band EQ controls.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct EqualizerView: View {
    @EnvironmentObject private var equalizer: EqualizerStore
    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(EqualizerStore.frequencies.indices, id: \.self) { index in
                    VStack {
                        Text(String(format: "%+.1f", equalizer.gains[index])).font(.caption2.monospacedDigit())
                        Slider(value: Binding(get: { Double(equalizer.gains[index]) }, set: { equalizer.set(Float($0), at: index) }), in: -8...8)
                            .rotationEffect(.degrees(-90)).frame(width: 180, height: 28).padding(.vertical, 76)
                        Text(label(EqualizerStore.frequencies[index])).font(.caption2)
                    }.frame(width: 34)
                }
            }.padding()
        }
        .navigationTitle("Equalizer")
        .toolbar { Toggle("Enabled", isOn: $equalizer.enabled).labelsHidden() }
    }
    private func label(_ value: Float) -> String { value >= 1000 ? "\(Int(value / 1000))K" : "\(Int(value))" }
}

private struct MiniPlayer: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    @Binding var showPlayer: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let track = player.current { ArtworkView(track: track, size: 46, cornerRadius: 11) }
            Button { showPlayer = true } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.title ?? "").font(.headline).lineLimit(1)
                    Text(player.current?.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let quality = player.playbackQuality { Text(quality).font(.caption2).foregroundStyle(.purple).lineLimit(1) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            Button("Previous", systemImage: "backward.fill") { player.playPrevious() }.labelStyle(.iconOnly)
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                if player.isPlaying { player.pause() } else { player.resume() }
            }.labelStyle(.iconOnly).font(.title3)
            Button("Next", systemImage: "forward.fill") { player.playNext() }.labelStyle(.iconOnly)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal)
        .padding(.bottom, 4)
    }
}

private struct FullPlayerView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Double?
    @State private var showLyrics = false
    @State private var showQueue = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let track = player.current {
                    ArtworkView(track: track, size: 280, cornerRadius: 28)
                        .shadow(color: .black.opacity(0.25), radius: 24, y: 14)
                    VStack(spacing: 5) {
                        Text(track.title).font(.title2.bold()).lineLimit(2).multilineTextAlignment(.center)
                        Text(track.artist).foregroundStyle(.secondary)
                        if let quality = player.playbackQuality { Text(quality).font(.caption).foregroundStyle(.purple) }
                    }
                    Slider(value: Binding(get: { scrubbing ?? min(player.elapsed, max(player.duration, 1)) }, set: { scrubbing = $0 }),
                           in: 0...max(player.duration, 1), onEditingChanged: { editing in
                        if !editing, let value = scrubbing { player.seek(to: value); scrubbing = nil }
                    })
                    HStack {
                        Text(format(player.elapsed)); Spacer(); Text("−\(format(max(0, player.duration - player.elapsed)))")
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    HStack(spacing: 34) {
                        Button("Shuffle", systemImage: "shuffle") { player.toggleShuffle() }
                            .foregroundStyle(player.shuffleEnabled ? Color.accentColor : Color.primary)
                        Button("Previous", systemImage: "backward.fill") { player.playPrevious() }.font(.title2)
                        Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.circle.fill" : "play.circle.fill") {
                            if player.isPlaying { player.pause() } else { player.resume() }
                        }.font(.system(size: 58)).labelStyle(.iconOnly)
                        Button("Next", systemImage: "forward.fill") { player.playNext() }.font(.title2)
                        Button("Repeat", systemImage: player.repeatMode.icon) { player.cycleRepeat() }
                            .foregroundStyle(player.repeatMode == .off ? Color.primary : Color.accentColor)
                    }.labelStyle(.iconOnly)
                    HStack {
                        Button(library.isFavorite(track) ? "Favourite" : "Add Favourite",
                               systemImage: library.isFavorite(track) ? "heart.fill" : "heart") { library.toggleFavorite(track) }
                        Spacer()
                        Button("Queue", systemImage: "list.bullet") { showQueue = true }
                        Button("Lyrics", systemImage: "text.quote") { showLyrics = true }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("Now Playing")
            .toolbar { Button("Done") { dismiss() } }
            .sheet(isPresented: $showLyrics) { LyricsView() }
            .sheet(isPresented: $showQueue) { QueueView() }
        }
        .frame(minWidth: 340, minHeight: 600)
    }

    private func format(_ value: Double) -> String {
        guard value.isFinite else { return "0:00" }
        let total = max(0, Int(value)); return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

private struct QueueView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(player.queue) { track in
                Button {
                    player.play(track, in: player.queue, from: library)
                    dismiss()
                } label: {
                    HStack {
                        ArtworkView(track: track, size: 42, cornerRadius: 10)
                        VStack(alignment: .leading) {
                            Text(track.title).lineLimit(1)
                            Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if player.current?.id == track.id { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint) }
                    }
                }.buttonStyle(.plain)
            }
            .navigationTitle("Up Next")
            .toolbar { Button("Done") { dismiss() } }
        }
        .frame(minWidth: 320, minHeight: 400)
    }
}

private struct ArtworkView: View {
    @EnvironmentObject private var library: LibraryStore
    let track: Track
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let remote = track.artworkURL, track.isRemote {
                RemoteArtwork(url: remote, size: size)
            } else if let url = library.artworkURL(for: track) {
                #if os(iOS)
                if let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable() }
                else { placeholder }
                #elseif os(macOS)
                if let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable() }
                else { placeholder }
                #endif
            } else { placeholder }
        }
        .scaledToFill().frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [.purple.opacity(0.8), .blue.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note").font(.system(size: size * 0.34, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
        }
    }
}

private struct LyricsView: View {
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.dismiss) private var dismiss
    @State private var lyrics: LyricsResult?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if loading { ProgressView("Finding lyrics…") }
                    else if let error { ContentUnavailableView("Lyrics unavailable", systemImage: "wifi.exclamationmark", description: Text(error)) }
                    else if let lyrics {
                        if lyrics.instrumental { Text("Instrumental track").foregroundStyle(.secondary) }
                        else if !lyrics.lines.isEmpty {
                            ForEach(lyrics.lines) { line in
                                Button { player.seek(to: line.time) } label: {
                                    Text(line.text).font(.title3.weight(.semibold))
                                        .foregroundStyle(player.elapsed >= line.time ? .primary : .secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                            }
                        } else if let plain = lyrics.plain { Text(plain).textSelection(.enabled) }
                        else { Text("No lyrics found.").foregroundStyle(.secondary) }
                    } else { Text("No lyrics found for this song.").foregroundStyle(.secondary) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(player.current?.title ?? "Lyrics")
            .toolbar { Button("Done") { dismiss() } }
        }
        .frame(minWidth: 320, minHeight: 350)
        .task(id: player.current?.id) {
            lyrics = nil; error = nil; loading = true
            if let track = player.current {
                do { lyrics = try await LyricsService.fetch(for: track) }
                catch { self.error = error.localizedDescription }
            }
            loading = false
        }
    }
}
