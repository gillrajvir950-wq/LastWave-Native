import SwiftUI
import WebKit

/// Authenticated YouTube Music web playback is the dependable fallback when
/// native stream URLs require a fresh PO token. It shares the persistent web
/// data store with the Google login screen.
struct YouTubeFallbackPlayer: View {
    @ObservedObject var player: PlayerStore

    var body: some View {
        if let videoID = player.webVideoID {
            PlayerWebView(videoID: videoID, command: player.webCommand,
                          commandSerial: player.webCommandSerial,
                          stateChanged: player.updateWebPlayback)
                .frame(width: 390, height: 260)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private let lastWaveBridgeScript = """
(function () {
  if (window.__lastWaveBridgeInstalled) return;
  window.__lastWaveBridgeInstalled = true;
  window.__lastWaveWantsPlayback = true;
  function media() { return document.querySelector('video, audio'); }
  function report() {
    var item = media(); if (!item) return;
    try { window.webkit.messageHandlers.lastWave.postMessage({
      state: item.paused ? 2 : 1,
      elapsed: Number.isFinite(item.currentTime) ? item.currentTime : 0,
      duration: Number.isFinite(item.duration) ? item.duration : 0
    }); } catch (_) {}
  }
  window.lastWavePlay = function () {
    window.__lastWaveWantsPlayback = true;
    var item = media();
    if (item) { item.muted = false; item.volume = 1; item.play().catch(function(){}); }
  };
  window.lastWavePause = function () {
    window.__lastWaveWantsPlayback = false;
    var item = media(); if (item) item.pause();
  };
  window.lastWaveStop = function () {
    window.__lastWaveWantsPlayback = false;
    var item = media(); if (item) { item.pause(); item.currentTime = 0; }
  };
  window.lastWaveSeek = function (seconds) {
    var item = media(); if (item) item.currentTime = seconds;
  };
  setInterval(function () {
    var item = media();
    if (item && window.__lastWaveWantsPlayback && item.paused) {
      item.muted = false; item.volume = 1; item.play().catch(function(){});
    }
    report();
  }, 500);
})();
"""

#if os(iOS)
private struct PlayerWebView: UIViewRepresentable {
    let videoID: String
    let command: String
    let commandSerial: Int
    let stateChanged: (Bool, Double, Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(stateChanged: stateChanged) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(WKUserScript(
            source: lastWaveBridgeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator, name: "lastWave")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"
        view.isOpaque = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.update(view: view, videoID: videoID, command: command, serial: commandSerial)
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
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(WKUserScript(
            source: lastWaveBridgeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator, name: "lastWave")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(view: view, videoID: videoID, command: command, serial: commandSerial)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "lastWave")
        view.stopLoading()
    }
}
#endif

private final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let stateChanged: (Bool, Double, Double) -> Void
    private var loadedVideoID: String?
    private var handledSerial = -1

    init(stateChanged: @escaping (Bool, Double, Double) -> Void) { self.stateChanged = stateChanged }

    func update(view: WKWebView, videoID: String, command: String, serial: Int) {
        if loadedVideoID != videoID {
            loadedVideoID = videoID
            handledSerial = serial
            let safeID = videoID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            if let url = URL(string: "https://music.youtube.com/watch?v=\(safeID)") {
                view.load(URLRequest(url: url))
            }
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(lastWaveBridgeScript + ";window.lastWavePlay();")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let state = (body["state"] as? NSNumber)?.intValue ?? -1
        let elapsed = (body["elapsed"] as? NSNumber)?.doubleValue ?? 0
        let duration = (body["duration"] as? NSNumber)?.doubleValue ?? 0
        DispatchQueue.main.async { [stateChanged] in stateChanged(state == 1, elapsed, duration) }
    }
}
