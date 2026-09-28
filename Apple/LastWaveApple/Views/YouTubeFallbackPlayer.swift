import SwiftUI
import WebKit

/// Keeps an official YouTube iframe alive as a last-resort player when public
/// stream resolver services are unavailable. The view is deliberately tiny,
/// while LastWave's own now-playing UI remains visible to the user.
struct YouTubeFallbackPlayer: View {
    @ObservedObject var player: PlayerStore

    var body: some View {
        if let videoID = player.webVideoID {
            PlayerWebView(videoID: videoID,
                          command: player.webCommand,
                          commandSerial: player.webCommandSerial,
                          stateChanged: player.updateWebPlayback)
                .frame(width: 2, height: 2)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

#if os(iOS)
private struct PlayerWebView: UIViewRepresentable {
    let videoID: String
    let command: String
    let commandSerial: Int
    let stateChanged: (Bool, Double, Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(stateChanged: stateChanged) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "lastWave")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.update(view: view, videoID: videoID,
                                   command: command, serial: commandSerial)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "lastWave")
        view.stopLoading()
    }
}
#elseif os(macOS)
private struct PlayerWebView: NSViewRepresentable {
    let videoID: String
    let command: String
    let commandSerial: Int
    let stateChanged: (Bool, Double, Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(stateChanged: stateChanged) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "lastWave")
        return WKWebView(frame: .zero, configuration: configuration)
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(view: view, videoID: videoID,
                                   command: command, serial: commandSerial)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "lastWave")
        view.stopLoading()
    }
}
#endif

private final class Coordinator: NSObject, WKScriptMessageHandler {
    private let stateChanged: (Bool, Double, Double) -> Void
    private var loadedVideoID: String?
    private var handledSerial = -1

    init(stateChanged: @escaping (Bool, Double, Double) -> Void) {
        self.stateChanged = stateChanged
    }

    func update(view: WKWebView, videoID: String, command: String, serial: Int) {
        if loadedVideoID != videoID {
            loadedVideoID = videoID
            handledSerial = serial
            view.loadHTMLString(Self.html(videoID: videoID), baseURL: URL(string: "https://www.youtube.com"))
            return
        }
        guard handledSerial != serial else { return }
        handledSerial = serial
        let javascript: String
        if command == "play" { javascript = "window.lastWavePlay && window.lastWavePlay();" }
        else if command == "pause" { javascript = "window.lastWavePause && window.lastWavePause();" }
        else if command == "stop" { javascript = "window.lastWaveStop && window.lastWaveStop();" }
        else if command.hasPrefix("seek:"), let seconds = Double(command.dropFirst(5)) {
            javascript = "window.lastWaveSeek && window.lastWaveSeek(\(seconds));"
        } else { return }
        view.evaluateJavaScript(javascript)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let state = (body["state"] as? NSNumber)?.intValue ?? -1
        let elapsed = (body["elapsed"] as? NSNumber)?.doubleValue ?? 0
        let duration = (body["duration"] as? NSNumber)?.doubleValue ?? 0
        DispatchQueue.main.async { [stateChanged] in
            stateChanged(state == 1, elapsed, duration)
        }
    }

    private static func html(videoID: String) -> String {
        let safeID = videoID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>html,body,#player{margin:0;width:100%;height:100%;background:#000;overflow:hidden}</style>
        </head><body><div id="player"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        var player;
        function report() {
          if (!player || !player.getPlayerState) return;
          try { window.webkit.messageHandlers.lastWave.postMessage({
            state: player.getPlayerState(), elapsed: player.getCurrentTime() || 0,
            duration: player.getDuration() || 0
          }); } catch (_) {}
        }
        function onYouTubeIframeAPIReady() {
          player = new YT.Player('player', {videoId:'\(safeID)', playerVars:{
            autoplay:1, playsinline:1, controls:0, rel:0, origin:'https://www.youtube.com'
          }, events:{onReady:function(e){e.target.playVideo();report();},onStateChange:report}});
        }
        window.lastWavePlay=function(){if(player&&player.playVideo)player.playVideo();};
        window.lastWavePause=function(){if(player&&player.pauseVideo)player.pauseVideo();};
        window.lastWaveStop=function(){if(player&&player.stopVideo)player.stopVideo();};
        window.lastWaveSeek=function(s){if(player&&player.seekTo)player.seekTo(s,true);};
        setInterval(report,500);
        </script></body></html>
        """
    }
}
