# Android port: handoff

Written 2026-10-12 for the agent starting the Android app. Base commit: `52616dc` on `dev` (the `android-port` branch starts there plus this doc). Line numbers and file lists below describe that commit; check `git log` before trusting them later.

## What you are building

A native Android client for Cascade, a Jellyfin music player (video is secondary). Cascade already ships as:

- **Desktop (Electron):** the repo root. `renderer.js` (one large file), `index.html`, `styles/`, and the pure, tested logic in `src/core/*.ts` (bundled as the global `CascadeCore`). This is the original and the feature reference.
- **Apple (Swift):** `apple/`. iOS, tvOS and a native Mac app. `apple/CascadeKit/` is a Swift package of pure logic ported from `src/core` with its tests; `apple/App/Sources/` is the SwiftUI app shared by iOS and tvOS; `apple/App/Mac/` is Mac-only. Read `apple/CODEMAP.md` first: it is the closest model for what you are doing (a native app built from the desktop's logic).

The Android app goes in **`android/`**, as a standard Gradle project with the wrapper checked in and the app module at `android/app`. Use the application id `xyz.chaosinc.cascade.android`, following the Apple apps (`xyz.chaosinc.cascade.ios`, `xyz.chaosinc.cascade.tvos`). Use **Kotlin, Jetpack Compose and Media3 (ExoPlayer plus MediaSessionService)**. An older Flutter attempt exists in a separate local repo (`Cascade-Android`, never finished, described by its own last commit as broken); it is not the base and nothing should be copied from it.

## Ground rules (from the maintainer)

- Work on the `android-port` branch. Never push to `stable` and never merge into `dev` yourself; the maintainer reviews a PR.
- **Never write a release marker in a commit subject line**: no `[BETA]`, no `Release (x.x.X)`, no bracketed platform list like `[android]`. Markers in a first line on `dev` or `stable` trigger real builds and releases (one leaked once). PRs into `dev` are checked for them.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. No session links in commits.
- No em dashes anywhere, code and comments included. American English. Do not hard-wrap Markdown: one paragraph per line.
- Comments explain why, in plain sentences, at the density the existing code uses. Read a few files in `apple/CascadeKit/Sources/CascadeKit/` for the tone.
- No new dependencies beyond the obvious Android stack (AndroidX, Compose, Media3, Kotlin coroutines and serialization, OkHttp or Ktor, Coil, JUnit). Ask in the PR before adding anything else.
- License is GPLv3 with an app store exception (see `LICENSE`). Keep dependencies GPL-compatible.

## Release pipeline: already waiting for you

`.github/workflows/build.yml` has a `build-android` job (around line 430) that skips itself until `android/` exists. It runs on `ubuntu-latest` with Temurin Java 17 and calls:

```
./gradlew --no-daemon assembleRelease bundleRelease -PversionName="$NAME" -PversionCode="$BUILD"
```

then copies `app/build/outputs/apk/release/*.apk` and `app/build/outputs/bundle/release/*.aab` into `android/dist/`. So:

- `android/app/build.gradle(.kts)` must read `versionName` and `versionCode` from those Gradle properties, with local defaults (versions are shared across platforms; `versionCode` is the CI run number and only goes up).
- Release builds come out unsigned until a keystore exists; do not add signing secrets. Debug builds are fine for testing.
- Platform detection lives in `src/core/release-plan.ts` (`android/` paths map to the `android` platform). You should not need to touch it. Docs: `docs/release-pipeline-plan.md`.
- There is no Android CI on PRs yet. Adding a small workflow that runs `./gradlew test assembleDebug` on pushes touching `android/**` (like `apple.yml` does for `apple/**`) is welcome.

## Talking to Jellyfin (get these right first)

- **Auth header:** every request sends `Authorization: MediaBrowser Client="Cascade Android", Device="<device name>", DeviceId="<stable id>", Version="<app version>"`, plus `, Token="<token>"` once signed in. Jellyfin 12 refuses `X-Emby-Token`, `X-Emby-Authorization` and the `api_key` query parameter by default. Where a URL must carry the token (image loaders, media URLs, anything without headers) use **`ApiKey=`**, never `api_key=`. This exact bug shipped once (video covers 401ed on Jellyfin 12). Models: `src/core/jellyfin.ts` around line 56 and `apple/CascadeKit/Sources/CascadeKit/JellyfinClient.swift` around line 34.
- **Edition name:** `Client` is the edition the server's device list shows. The others are "Cascade Electron", "Cascade iOS", "Cascade tvOS", "Cascade Mac". Use "Cascade Android".
- **Sign-in:** username and password (`/Users/AuthenticateByName`), Quick Connect (`QuickConnect.swift`), and optional reverse-proxy headers (`ProxyHeaders.swift`, `ProxyConnection.swift`) for servers behind Cloudflare Access or similar. Store the token in Android Keystore-backed storage, not plain preferences. The server's login disclaimer is shown on the sign-in screen (`ServerMessages.swift`).
- **Playback negotiation:** POST `/Items/{id}/PlaybackInfo` with a device profile, then direct play, direct stream or transcode. The Apple profile is `DeviceProfile.swift`; read its comments before writing Android's (ExoPlayer plays FLAC, Opus, Vorbis, AAC, MP3 and ALAC natively, so most music should direct play). Transcode seeking restarts the stream with a start offset (`Playback.swift`).
- **Reporting:** `/Sessions/Playing`, `/Progress`, `/Stopped` (`PlaybackReporting.swift`). Respect it exactly: the server's resume points and play history depend on it.

## Cascade Server (the optional plugin)

Many Cascade features come from the maintainer's Jellyfin plugin, CascadeServer (separate repo, `Cha0s1nc/CascadeServer`). Detect it with `GET /CascadeServer/Info`, which returns `{ name, version, capabilities: [...], spotifyLinkServerWide }`. Gate each feature on its capability, never on the version. Capabilities: `lyrics-read`, `lyrics-write`, `karaoke`, `syllable`, `spotify-link`, `server-style`, `explicit`, `animated-art`, `playlist-edit`. A server without the plugin must work fully, just without those extras. Models: `src/core/cascade-plugin.ts`, and how CascadeKit consumes each route.

**Never put a Spicy Lyrics API key in the app.** Spicy Lyrics lyrics reach clients only through the plugin, which holds the server owner's own key (their terms require one key per deployment). The app shows the attribution the lyrics come with (`LyricsCreditView` on Apple).

## Feature scope, in order

Use the **iOS app** (`apple/App/Sources/`) as the scope reference, not the Mac app, which adds desktop-only extras. Port pure logic as Kotlin with its tests first, then the screens on top, the same way CascadeKit was built. Each `src/core/*.ts` file has a test in `test/` and each CascadeKit file a test in `apple/CascadeKit/Tests/`; port the tests with the logic, they are the spec.

**Phase 1, a usable music player:**
1. Sign-in (password, Quick Connect, proxy headers), server and library selection.
2. Library: Home (recently played, recently added), Albums, Artists, Songs (Shuffle All, Play All, paging 200 at a time), Playlists, Genres, Search, album and artist pages. Sorting and filtering (`BrowseSort.swift`, `LibraryPrefs.swift`). Artwork caching.
3. Playback in a `MediaSessionService`: the queue (`Queue.swift`, `QueueActions.swift`, `QueuePersistence.swift`), shuffle, repeat, gapless (ExoPlayer playlists), notification and lock screen controls, Bluetooth and headset buttons, audio focus. Restore the last queue on launch, paused.
4. Now Playing: a mini player bar plus the full screen (art, scrubber, controls, queue). The iPhone's `NowPlayingView.swift` is the design.
5. Lyrics: the waterfall in `LyricSources.swift` (Cascade Server, then Kugou, then LRCLIB, then Jellyfin, with a Server-only mode), parsing in `Lyrics.swift` and `SpicyLyrics.swift`, and the karaoke view in `LyricsView.swift`: word fill, held-note emphasis, duets on opposite sides, background vocals, the line spring, tap a line to seek, untimed lyrics as a still page. Style values: `StyleTuning.swift` and `src/core/lyric-style.ts`.

**Phase 2, parity:** crossfade (`Crossfade.swift`) and the crossfade cover transition (`CoverSlice.swift`, settings in `DisplayPrefs.swift`), volume normalization (`Normalization.swift`), the equalizer (`Equalizer.swift`), downloads and offline (`OfflineIndex.swift`, `OfflineLibrary.swift`), smart playlists, history, favorites, playlist editing, sleep timer, auto-mix (instant mix when the queue ends), streaming quality on Wi-Fi vs cellular, radio (Live TV channels), remote control and "Play on device" (`RemoteControl.swift`), server messages, explicit marks, video covers, server style.

**Phase 3:** Android Auto (Media3 makes the browse tree the main work), Waterfall listen-together rooms (`WaterfallProtocol.swift`), on-device lyric translation, video playback.

Desktop-only things not to port: Discord presence, the miniplayer window, the control server, the updater, Touch Bar.

## Settings keys

Apple stores settings under the desktop's store key names (prefixed `cascade.`) so settings can move between apps (`ElectronSettingsImport.swift`). Use the same key names and value formats on Android, for example `coverSlice`, `coverSliceStyle`, `colorFade`, `explicitMarks`, `videoCovers`, `lyricStyle`. Ranges and allowed values are in `renderer.js` (`displayPrefs`) and the Swift files.

## Testing

- JVM unit tests for every pure port, mirroring the existing tests. `./gradlew test` must pass offline.
- There is no Jellyfin server you can reach from the cloud: the maintainer's servers are on a private network, and their production server must never be written to anyway. Mock HTTP for client tests. For a live smoke test, Jellyfin's public demo server (demo.jellyfin.org) can be used if it is up; nothing may depend on it.
- You likely cannot run an emulator. Say so in the PR: list what was built and unit-tested versus what still needs eyes on a device. The maintainer tests on hardware.

## How to report back

Open a PR from `android-port` into `dev` (do not merge it). In the description, by phase: what is built, what is tested, what is untested, and any decision you made that the maintainer should check (dependency choices, anything that differs from the Apple app). Keep commits focused, one feature or fix each.
