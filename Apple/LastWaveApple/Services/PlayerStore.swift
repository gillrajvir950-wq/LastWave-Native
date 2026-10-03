import AVFoundation
import Foundation

#if os(iOS)
import MediaPlayer
import UIKit
#endif

enum RepeatMode: String, CaseIterable, Codable, Sendable {
    case off, all, one

    var icon: String {
        switch self { case .off, .all: "repeat"; case .one: "repeat.1" }
    }
}

@MainActor
final class PlayerStore: ObservableObject {
    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var queue: [Track] = []
    @Published private(set) var shuffleEnabled = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var playbackQuality: String?
    @Published private(set) var webVideoID: String?
    @Published private(set) var webCommand = ""
    @Published private(set) var webCommandSerial = 0

    private weak var library: LibraryStore?
    private var onlineQueue: [CatalogTrack] = []
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endedObserver: NSObjectProtocol?
    private var lastSavedSecond = -1
    private let defaults = UserDefaults.standard

    init() {
        shuffleEnabled = defaults.bool(forKey: "player.shuffle")
        repeatMode = RepeatMode(rawValue: defaults.string(forKey: "player.repeat") ?? "off") ?? .off
        #if os(iOS)
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default) }
        catch { errorMessage = "Audio session unavailable: \(error.localizedDescription)" }
        configureRemoteCommands()
        #endif
    }

    func restore(from library: LibraryStore) {
        guard self.library == nil else { return }
        self.library = library
        let queueIDs = (defaults.array(forKey: "player.queue") as? [String] ?? []).compactMap(UUID.init(uuidString:))
        queue = queueIDs.compactMap(library.track(id:))
        if queue.isEmpty { queue = library.tracks }
        guard let rawID = defaults.string(forKey: "player.current"),
              let id = UUID(uuidString: rawID), let track = library.track(id: id) else { return }
        load(track, autoplay: false, position: defaults.double(forKey: "player.elapsed"))
    }

    func play(_ track: Track, in source: [Track]? = nil, from library: LibraryStore) {
        self.library = library
        if let source, !source.isEmpty { queue = source }
        else if !queue.contains(where: { $0.id == track.id }) { queue = library.tracks }
        load(track, autoplay: true)
    }

    func playOnline(_ catalog: CatalogTrack, queue: [CatalogTrack] = []) async {
        if !queue.isEmpty {
            onlineQueue = queue
        }

        isLoading = true
        errorMessage = nil

        let defaults = UserDefaults.standard
        let addonURL = defaults.string(forKey: "lossless.addonURL") ?? ""
        let addonSecret = defaults.string(forKey: "lossless.addonSecret") ?? ""
        let quality = defaults.string(forKey: "lossless.quality") ?? "lossless"

        if !addonURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let stream = try await LosslessAddonService.shared.resolve(
                    catalog,
                    baseURL: addonURL,
                    secret: addonSecret,
                    quality: quality
                )

                var track = catalog.playbackTrack
                track.sourceQuality = stream.quality

                loadRemote(
                    track,
                    url: stream.url,
                    headers: stream.headers,
                    autoplay: true
                )

                isLoading = false
                return
            } catch {
                // WebView fallback below
            }
        }

        loadWebPlayer(catalog)
        isLoading = false
    }
    func playNext() {
        if let current, current.isRemote, !onlineQueue.isEmpty {
            let next: CatalogTrack?
            if repeatMode == .one {
                next = onlineQueue.first(where: { $0.videoID == current.videoID }) ?? onlineQueue.first
            } else if shuffleEnabled, onlineQueue.count > 1 {
                next = onlineQueue.filter { $0.videoID != current.videoID }.randomElement()
            } else if let index = onlineQueue.firstIndex(where: { $0.videoID == current.videoID }) {
                let candidate = index + 1
                next = candidate < onlineQueue.count ? onlineQueue[candidate] : (repeatMode == .all ? onlineQueue.first : nil)
            } else { next = onlineQueue.first }
            if let next { Task { await playOnline(next, queue: onlineQueue) } }
            else { pause(); seek(to: 0) }
            return
        }
        guard let current, !queue.isEmpty else { return }
        if repeatMode == .one { seek(to: 0); resume(); return }
        let next: Track?
        if shuffleEnabled, queue.count > 1 {
            next = queue.filter { $0.id != current.id }.randomElement()
        } else if let index = queue.firstIndex(where: { $0.id == current.id }) {
            let candidate = index + 1
            next = candidate < queue.count ? queue[candidate] : (repeatMode == .all ? queue.first : nil)
        } else { next = queue.first }
        if let next { load(next, autoplay: true) }
        else { pause(); seek(to: 0) }
    }

    func playPrevious() {
        if let current, current.isRemote, !onlineQueue.isEmpty {
            if elapsed > 3 { seek(to: 0); return }
            let previous: CatalogTrack?
            if shuffleEnabled, onlineQueue.count > 1 {
                previous = onlineQueue.filter { $0.videoID != current.videoID }.randomElement()
            } else if let index = onlineQueue.firstIndex(where: { $0.videoID == current.videoID }) {
                previous = index > 0 ? onlineQueue[index - 1] : (repeatMode == .all ? onlineQueue.last : nil)
            } else { previous = onlineQueue.first }
            if let previous { Task { await playOnline(previous, queue: onlineQueue) } }
            return
        }
        guard let current, !queue.isEmpty else { return }
        if elapsed > 3 { seek(to: 0); return }
        let previous: Track?
        if shuffleEnabled, queue.count > 1 {
            previous = queue.filter { $0.id != current.id }.randomElement()
        } else if let index = queue.firstIndex(where: { $0.id == current.id }) {
            previous = index > 0 ? queue[index - 1] : (repeatMode == .all ? queue.last : nil)
        } else { previous = queue.first }
        if let previous { load(previous, autoplay: true) }
        else { seek(to: 0) }
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
        defaults.set(shuffleEnabled, forKey: "player.shuffle")
    }

    func cycleRepeat() {
        switch repeatMode { case .off: repeatMode = .all; case .all: repeatMode = .one; case .one: repeatMode = .off }
        defaults.set(repeatMode.rawValue, forKey: "player.repeat")
    }

    func resume() {
        if webVideoID != nil {
            sendWebCommand("play")
            // Wait for WebKit to report actual playback; don't show a fake
            // playing state while YouTube is still loading or buffering.
            updateNowPlaying()
            return
        }
        guard player != nil else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        if duration > 0 && elapsed >= duration { seek(to: 0) }
        player?.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        if webVideoID != nil {
            sendWebCommand("pause")
            isPlaying = false
            updateNowPlaying()
            return
        }
        player?.pause()
        isPlaying = false
        persistPlayback()
        updateNowPlaying()
    }

    func stop() {
        if webVideoID != nil { sendWebCommand("stop") }
        clearObservers()
        player?.pause()
        player = nil
        current = nil
        isPlaying = false
        elapsed = 0
        duration = 0
        webVideoID = nil
        defaults.removeObject(forKey: "player.current")
        defaults.removeObject(forKey: "player.elapsed")
        #if os(iOS)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        if webVideoID != nil {
            elapsed = target
            sendWebCommand("seek:\(target)")
            updateNowPlaying()
            return
        }
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        elapsed = target
        persistPlayback()
        updateNowPlaying()
    }

    private func load(_ track: Track, autoplay: Bool, position: Double = 0) {
        guard let library else { return }
        clearObservers()
        let url = library.url(for: track)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Audio file is missing. Remove and import this track again."
            return
        }
        loadPlayer(track, item: AVPlayerItem(url: url), autoplay: autoplay, position: position)
    }

    private func loadRemote(_ track: Track, url: URL, headers: [String: String], autoplay: Bool) {
        webVideoID = nil
        clearObservers()
        var requestHeaders = headers
        if requestHeaders["User-Agent"] == nil { requestHeaders["User-Agent"] = "Mozilla/5.0" }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": requestHeaders])
        loadPlayer(track, item: AVPlayerItem(asset: asset), autoplay: autoplay, position: 0)
    }

    private func loadPlayer(_ track: Track, item: AVPlayerItem, autoplay: Bool, position: Double) {
        webVideoID = nil
        clearObservers()
        if defaults.bool(forKey: "eq.enabled") {
            let gains = (defaults.array(forKey: "eq.gains") as? [NSNumber])?.map(\.floatValue)
                ?? EqualizerStore.presets[0].gains
//            item.audioMix = AudioTapEqualizer.makeMix(gains: gains)
        }
        player = AVPlayer(playerItem: item)
        current = track
        playbackQuality = track.sourceQuality
        elapsed = max(0, position)
        duration = 0
        lastSavedSecond = -1
        if position > 0 { player?.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
        timeObserver = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let seconds = self.player?.currentTime().seconds ?? 0
                self.elapsed = seconds.isFinite ? seconds : 0
                let length = self.player?.currentItem?.duration.seconds ?? 0
                self.duration = length.isFinite ? length : 0
                let whole = Int(self.elapsed)
                if whole % 5 == 0, whole != self.lastSavedSecond {
                    self.lastSavedSecond = whole
                    self.persistPlayback()
                }
                self.updateNowPlaying()
            }
        }
        endedObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.playNext() }
        }
        persistPlayback()
        if autoplay { resume() } else { isPlaying = false; updateNowPlaying() }
    }

    private func loadWebPlayer(_ catalog: CatalogTrack) {
        clearObservers()
        player?.pause()
        player = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        var track = catalog.playbackTrack
        track.sourceQuality = "YouTube Music"
        current = track
        playbackQuality = track.sourceQuality
        elapsed = 0
        duration = Double(catalog.durationSeconds ?? 0)
        webVideoID = catalog.videoID
        isPlaying = false
        sendWebCommand("play")
        updateNowPlaying()
    }

    private func sendWebCommand(_ command: String) {
        webCommand = command
        webCommandSerial += 1
    }

    func updateWebPlayback(isPlaying: Bool, elapsed: Double, duration: Double) {
        guard webVideoID != nil else { return }
        self.isPlaying = isPlaying
        if elapsed.isFinite { self.elapsed = max(0, elapsed) }
        if duration.isFinite, duration > 0 { self.duration = duration }
        updateNowPlaying()
    }

    private func persistPlayback() {
        if current?.isRemote == false { defaults.set(current?.id.uuidString, forKey: "player.current") }
        defaults.set(elapsed, forKey: "player.elapsed")
        defaults.set(queue.map { $0.id.uuidString }, forKey: "player.queue")
    }

    private func clearObservers() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let endedObserver { NotificationCenter.default.removeObserver(endedObserver) }
        timeObserver = nil
        endedObserver = nil
    }

    private func updateNowPlaying() {
        #if os(iOS)
        guard let current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyAlbumTitle: current.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let artworkURL = library?.artworkURL(for: current),
           let image = UIImage(contentsOfFile: artworkURL.path) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    #if os(iOS)
    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.playNext() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.playPrevious() }; return .success }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }
    #endif
}
