# LastWave for iOS and macOS

Version 0.4 is a native SwiftUI client based on the LastWave Android repository. It includes local imports, online YouTube Music catalogue search and playback, an Android-compatible lossless-addon client, a real-time 15-band EQ, playlists, favourites, queue controls, lock-screen controls, themes, and synced LRCLIB lyrics. Supported deployment targets: iOS 17+ and macOS 14+.

The Search tab anonymously queries the same private InnerTube surfaces used by the Android client and falls back across several direct-stream client profiles. These private endpoints can change without notice. Last.fm login/scrobbling, account-backed YouTube libraries, remote playlist import and offline downloads are not included yet.

## Open on a Mac

1. Install Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2. In this directory, run `xcodegen generate`.
3. Open `LastWaveApple.xcodeproj` in Xcode. Select **LastWave-iOS** or **LastWave-macOS** and run. A personal signing team may be necessary to run on an iPhone. Simulator builds do not need an Apple Developer account.
4. Use **Search** for online playback, or press **+** to import local audio. Song menus provide favourites, playlists, and deletion. Open Lyrics for synced lines when LRCLIB has a matching recording.

## Lossless and EQ

Open **Settings → Lossless audio** and paste the same LastWave addon base URL used on Android. If the URL is protected, also enter its signing secret. Select Hi-Res, Lossless, or compressed quality. For each online song the app tries the addon first and automatically falls back to YouTube when no match or stream is available. The addon is an external requirement: the repository does not contain or operate a lossless music server.

The 15-band EQ uses the Android app's frequencies, ±8 dB range, and all twelve curated presets. Its audio-processing tap runs after AVPlayer effects, so it applies to both imported files and online streams. Changes apply when the next track is loaded; restart the current track to apply a newly selected curve.

Xcode project files and generated Info.plist files are derived from `project.yml`; edit that file and regenerate after changing project settings.

## Unsigned IPA for Feather or AltStore

The repository includes `.github/workflows/build-unsigned-ipa.yml`. Push the project to GitHub, open the repository's **Actions** tab, select **Build unsigned iOS IPA**, and choose **Run workflow**. When the run finishes, download the `LastWave-unsigned-IPA` artifact and extract it once to get `LastWave-unsigned.ipa`. Import that IPA into Feather or AltStore; those tools apply the signing identity used for installation.

The workflow builds on a GitHub-hosted Mac and intentionally disables signing. An unsigned IPA cannot be installed directly from Files. Free Apple IDs usually require periodic re-signing, while the exact duration depends on the signing method/account used by Feather or AltStore.

## Architecture and next milestones

| Android code | Apple counterpart / status |
| --- | --- |
| `data/music/InnerTubeMusicApi.kt` | `YouTubeMusicService.swift` implements anonymous WEB_REMIX search and multi-client direct audio resolution. Account-only surfaces and PoToken flows remain. |
| Media3 playback service | `PlayerStore.swift` uses AVPlayer with queue, next/previous, shuffle/repeat, saved position, and iOS media commands. Audio interruption and route testing remain. |
| Room / DataStore | `LibraryStore.swift` uses a version-tolerant JSON store, copies imported files, extracts artwork, and saves favourites/playlists. A database migration is optional at larger scale. |
| `LrclibLyricsApi.kt` | `LyricsService.swift` implements exact lookup, search fallback, simple match scoring, and timed LRC parsing. |
| Compose screens | `ContentView.swift` implements search, library, favourites, playlists, lossless and EQ settings, mini/full player, queue, and lyrics interfaces. |
| Last.fm auth/scrobbling | Not implemented. Requires API credentials, OAuth flow, consent, and playback event handling. |
| Android cross-app media scrobbler | No equivalent system-wide integration promised for iOS/macOS. |

Recommended next milestones are account-backed libraries, remote playlist import, Last.fm auth/scrobbling, offline downloads, and broader device/route testing.

## What can be prepared on the phone

No phone setup is required before the first Xcode build. For quick testing, keep two or three DRM-free MP3/M4A files in the iPhone Files app. After Xcode first installs the development build, iOS may ask to enable Developer Mode and trust the developer identity; follow that on-device prompt then. Apple Music subscription downloads are DRM-protected and cannot be imported as ordinary files.

## Licensing and distribution

This directory lives inside the original GPL-3.0 repository. Keep the repository's LICENSE and source attribution if you redistribute a derivative. Before any public release or App Store submission, review the GPL distribution obligations and the terms applicable to the chosen music source. No Apple signing credentials, app listing, or private keys are needed for this starter.

## Verification

The code was prepared in a Linux workspace without Xcode, Swift, iOS Simulator, or macOS SDK. It needs compilation and device testing on a Mac; no successful Apple build is claimed here.
