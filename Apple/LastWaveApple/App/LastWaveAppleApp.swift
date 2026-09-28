import SwiftUI

@main
struct LastWaveAppleApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var player = PlayerStore()
    @StateObject private var equalizer = EqualizerStore()
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(equalizer)
                .tint(.purple)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }
    }
}
