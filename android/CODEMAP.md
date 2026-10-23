# Cascade Android: map

Native Jellyfin music client for Android, in `android/` of the Cascade-Project repo. Kotlin, Jetpack Compose and Media3 (ExoPlayer in a MediaSessionService). Built from the Apple app's design (`apple/CODEMAP.md`), which was built from the desktop's `src/core`; the iPhone app is the scope reference. Run every command below from `android/`.

Application id `xyz.chaosinc.cascade.android` (debug builds add `.debug`, so both install side by side). The server's device list shows the edition as `Cascade Android` and the device as the phone's model.

## Layout

- `core/` - the pure Kotlin module, the counterpart of CascadeKit. No Android classes, so its tests run on a plain JVM in seconds. Package `xyz.chaosinc.cascade.core`.
  - `Json.kt` - the one rule bridging Jellyfin's PascalCase to Kotlin names (`CascadeJson`). Use it for anything Jellyfin sends or takes. `PlainJson` is for everything whose keys are not Jellyfin's: LRCLIB, Kugou, stored prefs, and the Cascade Server plugin, which answers in camelCase.
  - `Models.kt` - the Jellyfin shapes this app reads. Ticks are `Long` everywhere (2^31 ticks is 214 seconds). `JfItem` equality is structural, unlike CascadeKit's id-only one, so a refetched row redraws; compare `id` where identity is meant.
  - `JellyfinClient.kt` - OkHttp, the `Authorization: MediaBrowser ...` header with the token, every status checked. Image URLs carry the token as `ApiKey`, never `api_key`.
  - `Auth.kt` - password sign-in and Quick Connect (both directions). `ProxyHeaders.kt` - reverse-proxy headers, pure, plus `ProxyConnection`, the network interceptor that adds them to requests for the server's own origin only. `ServerMessages.kt` - the login disclaimer and dashboard messages.
  - `DeviceProfile.kt` - `DeviceProfile.android(decodes)`, built from the decoders the phone reports. `Playback.kt` - PlaybackInfo, the `/universal` fallback, resume, transcode offsets. `PlaybackReporting.kt` - start, progress, stopped. `StreamingQuality.kt`.
  - `Library.kt`, `LibraryMerge.kt`, `BrowseSort.kt`, `LibraryPrefs.kt` - the browsing queries, cross-library merge and sort, filters, prefs in the desktop's shape.
  - `Queue.kt`, `QueueActions.kt`, `QueuePersistence.kt` - queue rules, edits, and `lastQueue`.
  - `Lyrics.kt`, `SpicyLyrics.kt`, `LyricSources.kt`, `LyricStyle.kt` - parsing, the waterfall, and the lyric look's numbers.
- `app/` - the Android application, package `xyz.chaosinc.cascade.android`.
  - `AppState.kt` - the one HTTP client, session and player, reached through `CascadeApp.state`. `data/Settings.kt` (plain preferences under the desktop's `cascade.*` key names; the device id alone sits in `cascade.device`, excluded from backup and device transfer so a restored phone gets its own) and `data/SecureStore.kt` (the token and proxy headers, AES-GCM with an Android Keystore key, excluded from backups).
  - `playback/PlaybackEngine.kt` - the only place ExoPlayer is driven. `playback/ResolvingMediaSource.kt` - a playlist entry that asks PlaybackInfo when the player prepares it, which lazy preparation delays until a period is created for it. `playback/PlaybackService.kt` - the MediaSessionService: notification, lock screen, headset and Bluetooth buttons.
  - `ui/` - Compose, one file per area: `MainScreen.kt` (tabs, mini player, Now Playing overlay), `LibraryScreens.kt`, `DetailScreens.kt`, `SearchScreen.kt`, `SettingsScreen.kt`, `SignInScreen.kt`, `NowPlaying.kt`, `LyricsView.kt`, `LyricsModel.kt`, `Components.kt`.

## Build and test

```
./gradlew test                 # core and app unit tests, offline
./gradlew assembleDebug        # app/build/outputs/apk/debug/app-debug.apk
./gradlew assembleRelease bundleRelease -PversionName=1.2.3 -PversionCode=42
```

The live suite checks the shapes this app sends against a real server, and is skipped without `CASCADE_SERVER`:

```
CASCADE_SERVER=https://host CASCADE_USER=name CASCADE_PASS=pw ./gradlew :core:test --tests '*LiveServerTest*'
```

It only reads unless `CASCADE_LIVE_WRITES=1`, which also sends playback reports. Never point writes at a server whose history matters. Jellyfin's public demo (`https://demo.jellyfin.org/stable`, user `demo`, no password) works for both when it is up; nothing may depend on it.

Release builds are unsigned until a keystore exists. `versionName` and `versionCode` come from the Gradle properties the release workflow passes (`.github/workflows/build.yml`, `build-android`); `android.yml` runs the tests and a debug build on changes to `android/`.

## Decisions worth knowing

1. The ExoPlayer playlist IS the queue. Gapless, the notification's transport, headset buttons and audio focus are then the player's own. The core queue rules decide every change, and `PlaybackEngine` applies each one to the playlist in the same order, so `state.queue` and the player never disagree. Shuffle reorders the playlist (the current track moves to the front) rather than using ExoPlayer's shuffle mode, which would move it somewhere random.
2. Streams resolve when the player prepares an entry (`ResolvingMediaSource`). With lazy preparation (set explicitly in `PlaybackEngine`, and load-bearing) Media3's MaskingMediaSource prepares an entry only once a period is created for it: the playing entry, and the next once the current has buffered to its end (up to about 50 s before the end of a long track, at once for a short one). So a long queue resolves one or two entries, each under the streaming quality in force at that moment: the counterpart of the iPhone's syncPreload, done by the player. Until the answer arrives the entry publishes no timeline; then it builds a progressive child for a file or an HLS child for a transcode. The child keeps the entry's media id and metadata.
3. Transcodes are HLS AAC, so a transcode seeks in the player like a file (an HLS playlist covers the whole item; StartTimeTicks on it changes nothing).
4. The device profile claims only what `MediaCodecList` reports a decoder for, the desktop's injected-probe pattern. ALAC, for one, has no decoder on older Android; claimed anyway, it would direct play into silence.
5. Reports: a start when an entry first plays (waiting for its resolve, so it carries the play session), progress every 10 s and on every pause, resume and seek, and a stopped report with the position the entry was left at (`onPositionDiscontinuity`'s old position). Play sessions are keyed by playlist entry (a tag `mediaItemFor` puts on each MediaItem), not item id, so the same track twice in the queue keeps two. They go out in order through one queue and never hold playback.
6. The media session's artwork is `cascade-art://<itemId>`, turned into the real request by the session's bitmap loader, so other apps reading the session never see a URL with the token in it.
7. Artwork is cached by item id and size, not URL, since the URL carries the token, which changes at every sign-in.
8. Cleartext http is allowed: many Jellyfin servers are reached over plain http on a home network.

## Status (2026-10-13)

Written in a cloud session with no emulator (no KVM) and no device. What is known to work: every core test (port of the CascadeKit and desktop tests, plus MockWebServer client tests), the debug, release and bundle builds, and the live suite against Jellyfin 12.2.0 (the public demo): password sign-in with the MediaBrowser header, browsing, an ApiKey image (200), PlaybackInfo choosing FLAC direct play and the stream answering 206, an HLS transcode under a 128 kbps cap, and all three reports accepted.

Not yet seen on a device, so not yet known to work: everything on screen, actual audio, gapless handovers, the notification and lock screen, Bluetooth and headset buttons, audio focus, background playback, restoring the queue at launch, the karaoke lyrics' look and timing, and Quick Connect approval end to end.

Built (phase 1 of `docs/android-handoff.md`): sign-in (password, Quick Connect, proxy headers, login disclaimer), library selection, Home, Albums (with Genres), Artists, Songs (Play All, Shuffle, paging), Playlists, Search, album, artist, playlist and genre pages, sort and filter, artwork caching, playback with the queue (Play Next, Add to Queue, reorder, remove, shuffle, repeat, Instant Mix), reporting, queue save and restore, mini player and Now Playing, and lyrics (the waterfall with server-only mode and forced sources, karaoke fill, held notes, duets, background vocals, tap to seek, untimed lyrics, Spicy Lyrics credit).

Not built yet: everything in phases 2 and 3 of the handoff (crossfade, normalization, EQ, downloads, smart playlists, history, playlist editing, sleep timer, auto-mix, radio, remote control, Android Auto, Waterfall, translation, video), the album-color background (Now Playing uses the blurred cover), Style Tuning's on-screen panel (the values are read from `cascade.styleTuning`), the lyrics offset slider, Spotify linking, the replay of start reports that failed offline, and extending a Songs queue as later pages load.
