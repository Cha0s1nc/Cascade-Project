# Cascade Swift: map

Native Jellyfin music client for iOS and tvOS. Lives in `apple/` of the Cascade-Project repo (it was its own repo, Cascade-Swift, until 2026-09-30); run every command below from `apple/`. New project, not a port of the Electron desktop app, which keeps shipping untouched.

Everything pure and testable lives in `CascadeKit`. The app targets are thin reflections of it, so the phone runs the same compiled code the Apple TV will.

## Layout

- `CascadeKit/` - the shared Swift package. No SwiftUI, no UIKit.
  - `JSON.swift` - the one rule bridging Jellyfin's PascalCase to Swift naming. Use `JSON.decoder` / `JSON.encoder`, never a bare `JSONDecoder()`.
  - `Models.swift` - the Jellyfin shapes this app actually reads.
  - `DeviceProfile.swift` - `DeviceProfile.apple`, what the server negotiates against. Read the comments before changing anything in it.
  - `JellyfinClient.swift` - auth and HTTP. Every call checks the status.
  - `Playback.swift` - PlaybackInfo negotiation, resume, transcode seeking.
  - `PlaybackReporting.swift` - start / progress / stopped.
  - `PlaybackService.swift` - the only place AVPlayer is wired up.
  - `Lyrics.swift`, `LyricSources.swift`, `SpicyLyrics.swift` - parsing and the lyric waterfall (Cascade plugin, Kugou, LRCLIB, Jellyfin).
  - `SmartPlaylists.swift`, `PlayHistory.swift`, `Normalization.swift`, `RemoteControl.swift` - ported from the desktop's `src/core` with its tests.
  - `OfflineIndex.swift` (pure, tested) and `OfflineLibrary.swift` - downloads.
  - `Equalizer.swift` (pure, tested) and `AudioTap.swift` - the EQ and the normalization boost, in an MTAudioProcessingTap per player item.
  - `Crossfade.swift` - the equal-power envelope; the decks are in PlaybackService.
  - `WaterfallProtocol.swift` (pure, tested) and `WaterfallSession.swift` - listen-together rooms.
  - `Video.swift` - the video device profile, movie and show queries, and PlaybackInfo for video. The player (`VideoSession`) and pages are in App/Sources/VideoPlayer.swift and VideoViews.swift.
- `App/Sources/` - both app targets build these same files. SwiftUI covers most of the platform difference; where it does not (tvOS has no `Slider`, and focus replaces touch) the views branch on `#if os(tvOS)` rather than forking.
  - `AppState.swift` - the one session and one player, read from the environment.
  - `Keychain.swift` - the access token lives here, not in UserDefaults.
  - `Components.swift` - `ArtworkView`, `TrackRow`, `ItemGrid`, `LoadingOverlay`.
  - `MainView.swift` - tabs, plus the iOS mini player.
  - One file per screen.
- `project.yml` - xcodegen input. `Cascade.xcodeproj` is generated, not committed; run `xcodegen generate` after cloning.

## Running on a device

`./run-device.sh` builds, installs and launches on a connected iPhone without attaching the debugger. About 7 seconds warm. Xcode's own Run attaches LLDB, which resolves symbols by reading device memory and shows a "taking longer than expected" dialog; `~/.lldbinit` with `settings set target.preload-symbols false` takes the edge off that when you do need breakpoints.

## Tests

`cd CascadeKit && swift test` runs offline in under a second.

Point it at a real server to also run the live suite, which is the only thing that checks the shapes this app sends against the shapes a given Jellyfin version accepts:

```
CASCADE_SERVER=https://host CASCADE_USER=name CASCADE_PASS=pw swift test
```

## Rules carried over from desktop, each of which cost real time to learn

1. Read the response of anything that writes. Five desktop write paths once reported success on an HTTP 403 because nothing checked the status.
2. Never trust an endpoint's shape from memory. The server's own spec is at `/api-docs/openapi.json`.
3. A guessed device profile is worse than none. The server trusts it and hands back something undecodable, which presents as silence, not an error.
4. Comments explain WHY, especially where a bug forced the shape.
5. No em dashes anywhere, code comments and commit messages included.
6. Anything pure and testable belongs in CascadeKit with a test, not in a view.

## Status

Built: skeleton, device profile, auth, PlaybackInfo, AVPlayer playback with seek, audio session, now playing and remote commands. The whole build order in the original brief is done.

Lock screen art is back (2026-09-27). The old trap was Swift 6 isolation: the MPMediaItemArtwork request handler was written inside a @MainActor method, so it inherited main-actor isolation and a runtime check, and MediaPlayer calls it on a background queue. Reproduced in the simulator by calling the handler off main (SIGTRAP with the old closure, returns fine when built in a nonisolated function). Rule: any closure handed to MediaPlayer or AVFoundation that they may call on their own queue must be built outside main-actor isolation. See "Lock screen art" in PlaybackService.swift. The iOS 26.5 simulator shows no Now Playing on its lock screen or Control Center, so the art itself still wants a look on a real phone.

Verified against the live server: FLAC direct plays (no transcode), the stream URL serves bytes, AVFoundation decodes it to the duration Jellyfin reports, and all three reporting endpoints are accepted by 10.11.11.

Verified on real hardware (iPhone 16, iOS 26, free provisioning, 2026-08-27): sign in, FLAC playback, seeking, lock screen controls, audio surviving a screen lock, and playback stopping when the app is swiped away.

Background audio DOES work under free provisioning. That was the one unknown worth answering before building anything on top of it, so it is written down here rather than re-derived.

Not yet verified: anything needing an Apple TV. Real TV performance, tvOS codec limits, tvOS storage limits. The iPhone is a strong proxy for the audio path and no proof at all about video.

Built since: queue with repeat and shuffle, the tvOS target, and every screen. Home, Albums, Artists, Songs, Album detail, Artist detail, Search, Settings, Sign in and Now Playing all build for both platforms.

The tvOS player follows the mapping validated against tvOS Apple Music: it rests with no chrome, the artwork is the focus target, select is play/pause, left and right are previous and next, and the Play/Pause key works whether or not anything is on screen.

Not built at the time: playlists, favorites UI, lyrics, offline downloads. All four exist now; see the dated sections below.

Added on branch `ios-next` (2026-09-23, Xcode 27 / iOS and tvOS 27 SDKs):
- Quick Connect sign-in (`QuickConnect.swift`), verified in the iOS simulator against the live server. Debug builds take `-cascade.autoQuickConnect YES` (with `-cascade.serverUrl <url>`) to start it on launch, for driving simulators without UI automation.
- Lyrics on Now Playing from the server's Cascade plugin (`Lyrics.swift`: `parseLRC` ported with the desktop's tests; plugin probe tries `CascadeServer/Info`, then the pre-rename `CascadeLyrics/Info`). Line sync only, no karaoke word fill yet. (Superseded: see "Lyrics" below.) iOS toggles artwork/lyrics and a tapped line seeks; tvOS shows lyrics in place of the queue.
- Favorite button on iOS Now Playing (not on tvOS yet).
- Playlists tab, read-only: browse, play, shuffle. Verified by a person on the iPhone 16 (iOS 27, free provisioning, Xcode 27, 2026-09-23): Quick Connect sign-in, lyrics on Now Playing (toggle, sync, tap-to-seek), the favorite button sticking server-side, and the Playlists tab. tvOS: builds and reaches the Quick Connect screen; signed-in use not checked yet.

Browsing screens: first used by a person on the iPhone 16 on 2026-09-23, and 59bcb5e fixed what that found (artist counts, doubled back buttons, paging Songs and Albums in 200s).

Cross-library copies (`LibraryMerge.swift`, 2026-09-24): the same song, album or artist in two selected libraries shows once, ported from the desktop's dedupeById with its tests. `itemsAcrossLibraries` tags each item with `sourceLibrary` and merges; `loadPaged` re-merges everything loaded so far, because copies can land on different pages.

tvOS, signed in, first exercised 2026-09-24 in the Apple TV (1080p) simulator, tvOS 26.5, against a throwaway Jellyfin 10.11.11 with two music libraries sharing an album: Quick Connect sign-in, every tab, album detail, playback (confirmed server-side), Now Playing with synced lyrics, Settings. That run found and fixed: no way to reach Now Playing on tvOS at all (it is now a tab, and starting playback switches to it; a tab inserted and selected in one update was never built, so it is always present), "1 tracks", and merged libraries not in server order. The tab bar is wider than its glass: Search and Settings sit past the right edge until focus scrolls to them.

Driving tvOS without a person: the CascadetvOSUITests target (UITests/tvOS/RemoteScript.swift) presses Siri Remote buttons from a TEST_RUNNER_SCRIPT, screenshots to TEST_RUNNER_OUT_DIR, and can approve Quick Connect itself. xcodebuild sometimes never exits after the test passes; wait for "Test Suite 'Selected tests' passed" in its output instead of its exit.


Browsing and playlists (branch `overnight/swift-browse`, 2026-09-27):
- Sorting: `BrowseSort.swift` maps each screen's choice to a server sortBy; `sortedLikeServer` must handle every key used (a test enforces it), or several libraries come back concatenated. `loadPaged` takes sortOrder. `SortMenu` (App/Sources/BrowseControls.swift) is a Menu on iOS and a confirmation dialog on tvOS, where a Menu took focus but never opened. Albums "Recently Played" comes from played tracks: Jellyfin keeps no album play date.
- Songs Play All / Shuffle: whole library. Shuffle is `randomSongs` (SortBy=Random, capped at 1,000). Play waits for one full fetch until PlaybackService can extend a queue.
- Genres: under Albums (`GenresView.swift`), not a tab.
- Playlist editing: `PlaylistEditing.swift` (routes checked on 10.11.11), `AddToPlaylistSheet(tracks:)` for any screen to present. 10.11 sets PlaylistItemId to the track id and refuses duplicates.
- Driving the iOS simulator with nobody there: a throwaway XCUITest target like the tvOS one (tap by accessibility label, screenshot to a folder) works when the simulator tap tool is not granted.

Once out of scope for v1: EQ, crossfade, offline downloads, video. All four are built (below).

Driving iOS without a person: the CascadeiOSUITests target (UITests/iOS/TapScript.swift) taps, long-presses, drags, locks and screenshots from a TEST_RUNNER_SCRIPT, the phone's counterpart of the tvOS RemoteScript. Steps are separated by `|`; see the file's header.

Gapless (2026-09-27): PlaybackService plays through an AVQueuePlayer. While a track plays, the one advanceOnEnd would pick is resolved and enqueued behind it (syncPreload), and at the end the player moves onto it by itself; the service only catches up its bookkeeping and reports (handOver). Anything that changes what plays next must call syncPreload. Measured in the simulator against a local server, from the end notification to the next item's clock running: 180 to 445 ms before, -36 to +21 ms after (flac, m4a, mp3 and an HLS transcode). DEBUG builds log it as HANDOVER.

Queue actions (2026-09-27): long-press any track row (TrackRow, and album detail rows) for Play Next, Add to Queue, Instant Mix, Favorite, Go to Album and Go to Artist (`TrackMenu.swift`; the menu is in sections, and Add to Playlist belongs next to Favorite). Go to pushes through `openItem`, an environment action set by `TabStack`, each tab's NavigationStack with a path. The order logic is `QueueActions.swift` (pure, tested); PlaybackService's playNext / addToQueue / moveQueueItems / removeQueueItems / jump apply it and re-sync the gapless preload. iOS Now Playing has a Queue button opening `QueueView`: tap to jump, drag to reorder, swipe or Edit to remove (never the playing row).

Streaming quality (2026-09-27): Settings > Playback, Original / 320 / 256 / 192 / 128 / 96 kbps (`StreamingQuality.swift`), with a separate cellular setting on iOS that applies while Network reports the path as expensive. PlaybackService caps the device profile per resolve (`currentProfile`). Stored values go through `StreamingQuality(stored:)`, so garbage reads as Original.

Lyrics (2026-09-28/29): SpicyLyrics through the Cascade plugin (syllable fill, duets, background vocals, held notes that swell by length, and the credit the API's terms require), then Kugou, LRCLIB and Jellyfin as the desktop's waterfall does, unless Settings > Server-Only Lyrics (on by default) keeps it to the plugin. Untimed lyrics show as a still page. Style Tuning (Now Playing > ... > Style Tuning, every build) holds every lyric and background knob; the defaults are the user's own tuning. Direct streams are opened with AVURLAssetPreferPreciseDurationAndTimingKey: without it a FLAC with no SEEKTABLE seeked 1 to 4 s off, so tapping a line landed early or late.

Desktop parity batch (2026-09-29): menus on album, artist and playlist tiles; the artist page (bio, top songs, similar artists); filtering; History; smart playlists (Favorites, Most Played, a rule builder, stored on the device as the desktop does); volume normalization (attenuation only: AVPlayer's volume stops at 1, so a boost waits for the EQ's audio tap); remote control both ways (castable from Jellyfin clients over the socket, and Control Devices to drive another session). The server's device list names this app iPhone, iPad or Apple TV, not "Cascade".

Offline downloads (2026-09-29, iOS only; tvOS storage is a purgeable cache):
- Download from an album or playlist's long-press menu, or the button on its page; the Downloads screen (toolbar, every tab) works with no server.
- One index (`OfflineIndex`, relative paths, validated when read) under Application Support/offline, excluded from backup. A track shared by two downloads is stored once; removing one deletes only files nobody else holds. Launch reconciles the index with the files on disk.
- Files are `/Items/{id}/Download` (honors the admin's download switch; not `/File`, which ignores it) through one background URLSession created at launch. A finished download is kept only on a 2xx with the full length: background sessions "finish" error pages too.
- PlaybackService plays a downloaded track from disk (`stream(for:)`, used by load and the gapless preload) and takes its gain from the saved item. Start and stopped reports go out in order without being awaited, so an unreachable server no longer holds a track change for a minute.
- Jellyfin counts a play on the START report (SessionManager.OnPlaybackStart at 10.11.11), so a failed one is queued and replayed as `/UserPlayedItems/{id}?datePlayed=` once a later report succeeds or the app next launches; the server then shows the real play time.
- Verified in the iOS 27 simulator against the local 10.11.11: a 7-song playlist downloaded with sizes matching the server; with the server URL pointed at an unroutable address, Downloads, covers and playback worked, audio started 0.2 s after the tap, the handover between local files was gapless, and two plays were queued; reconnecting replayed both (counts up one each, LastPlayedDate the offline time); removal emptied the folder.
- Not verified yet: background downloads with the app suspended or killed on a real iPhone under free provisioning (expected to need no entitlement), and downloads surviving a re-sign. Check both on the phone deploy. Not built: transcoded downloads, favorites made offline, lyrics offline, an offline mode for the library tabs.
- Testing tip: the app's preferences live in the simulator's cfprefsd; set the server URL with `xcrun simctl spawn <udid> defaults write
  <container>/Library/Preferences/xyz.chaosinc.cascade.ios cascade.serverUrl
  <url>`. Editing the plist file directly is silently undone.

Equalizer (2026-09-29): the desktop's five peaking bands (60 Hz to 12 kHz, Q 1, +-12 dB), presets and automatic preamp, Settings > Playback > Equalizer. `AudioTap.attach` puts an MTAudioProcessingTap (post-effects) on a player item; `TapContext` holds the settings behind a lock the audio thread only try-takes, and filters without allocating. The tap also carries the normalization gain, so boosts work there (AVPlayer's volume stops at 1). Tested by pushing sine waves through `TapContext.process`.
- Taps cost the gapless handover, so items are tapped only while the EQ is on. Measured on the player's clock (not a recording: nothing here can capture the simulator's output): 58-78 ms untapped, 422/430 ms with pre-effects taps, 256/262 ms with post-effects ones. The screen says so.
- An HLS transcode cannot be tapped: a capped streaming quality plays flat, with attenuation-only normalization through the player's volume.

Crossfade (2026-09-29): 1 to 15 s, Settings > Playback, off by default. PlaybackService has two decks (`player`, `otherDeck`); `player` is always the deck playing `item`. With a crossfade set, the next track is resolved as usual but parked (`Preload.parked`) instead of queued, and a boundary observer at the end minus the fade starts it on the other deck, swaps the decks and runs the handover at once; the old deck plays on as `tail`, ramped under Crossfade.gains every 20 ms. Seek, skip, pause and stop cut the tail (`endCrossfade`, which never re-arms: arming inside the window starts a fade on the spot). Re-armed by a finished fade, a landed seek and a resume. A fade with too little left is skipped and the parked track follows at the end. Off keeps the gapless path; measured 57 and 116 ms after the deck change.

Waterfall (2026-09-29): the desktop's listen-together rooms through the same relay (`Waterfall.defaultRelay`, overridable in the room screen) and the same messages, so phones and desktops share rooms. Settings > Waterfall, and Listen Together in the Devices sheet.
- The host polls rather than hooks: `hostTick` (1 s) publishes the queue when its ids change and the state on a pause, skip, index change or jump of more than 1.5 s, plus a 4 s heartbeat.
- A guest mirrors the queue (`PlaybackService.adoptQueue`, placeholders for songs its account cannot see), loads the host's track and seeks with a lead, corrects drift past 1.5 s, and follows pause. Its buttons, lock screen and remote commands go through `PlaybackService.transportGate`, which sends them to the host (or explains why not); the session's own calls pass because it sets `applying`.
- Checked against scripted Node peers on the live relay (a script that hosts, one that joins). Not handled, as on the desktop: a guest is not told when the host leaves (the relay drops the idle socket after a while and it then sees "The room closed"). Expected on a phone but not yet seen: hosting with the screen locked or the app in the background will likely lose the socket when iOS suspends the app.

Waiting on the phone (things the simulator could not settle): background downloads with the app suspended and killed; whether gapless is audible with the EQ off and on; crossfade by ear (a dip mid-fade, pause and seek during one); Waterfall hosting with the phone locked; lock screen controls as a guest going to the host; during a movie, AirPods or Control Center play/pause (the music service's handlers are still registered and might wake the paused song), what the lock screen shows, the subtitle list in the player's menu, and picture in picture.

Video (2026-09-29): movies and shows, the desktop's video half. A Music / Video switch (`AppState.browseMode`: top left on iOS, and Settings > Browse) swaps the tabs for Home, Movies and Shows.
- Playback is `VideoSession`, apart from the music PlaybackService (no gapless decks, no music lock screen). tvOS shows it in AVPlayerViewController; iOS in Cascade's own player (`VideoControls.swift`, below). Starting a video pauses music. Reports go out with MediaType Video.
- Resume is a seek after the stream loads, for direct play and transcodes alike. No start position goes to the server (`VideoPlayback.resolve` strips StartTimeTicks off the transcode URL): Jellyfin's HLS playlist always covers the whole film, and a transcode asked to start partway made AVPlayer request segments from the top, which 10.11 answered with HTTP 400, so every resume of a transcoded film failed (2026-10-02, verified on a 10.11 server: Infinity Castle at 1:10:45 and Hotel Transylvania 2 at 20:14 both resume). Music keeps `withStartTicks` for its own transcodes.
- `DeviceProfile.appleVideo` claims MP4/MOV with H.264/HEVC for direct play; everything else comes as HLS (TS, H.264, AAC/AC-3/E-AC-3 up to 6 channels). Text subtitles are `Hls`: the server lists every one in the manifest's subtitle group (named in the playlist, e.g. "English Signs - ASS"; `mediaTrackLabel` shows that without the codec) and the player's menu offers them. AVPlayerLayer draws the selected one itself. A `CC` entry of type `clcp` is a closed-caption track, often empty after a transcode. Picture subtitles (PGS, VobSub) are burned in.
- An audio track choice is honored only with the media source id beside it (checked on 10.11.11); the transcode then carries that track alone, which is why the picker is on the movie page, not in the player.
- Jellyfin keeps no resume point for anything under 5 minutes, or under 5% in: short test clips always come back "played" or at 0.
- Pages refetch on `AppState.videoRevision`, bumped once a closed video's stopped report has landed; refetching as the player closed raced it.
- JfItem equals any copy with the same id, so a row given a refetched item was not redrawn: rows take watched state and progress as plain values.
- Checked in the iOS simulator against generated media (a direct MP4, an MKV with two audio tracks and embedded plus external SRT, a two-episode show, a 7-minute movie for resume). tvOS, driven by RemoteScript: focus reaches the tiles, select resumes in the native player, and Menu twice returns to Home with the position saved. A Waterfall guest who starts a video leaves the room first, rather than pausing it through the gate. Not built: video search, a subtitle picker outside the player, per-library selection for video. Trickplay and the lock screen during video came later (below).

Reverse proxy headers and client certificate (2026-10-01, written in a cloud session with no Swift toolchain; audited 2026-09-30 on a Mac: the kit tests pass and both apps build, nothing has run on a device):
- `ProxyHeaders.swift` (pure, tested) validates and parses headers and decides which URLs may carry them (the server's own origin only, `ws`/`wss` counted as `http`/`https`). `ProxyConnection.swift` applies them: `ProxyConnection.shared.session` is the API session (headers as `httpAdditionalHeaders`, rebuilt on an edit, so never keep it), `session(for: url)` hands any other host `URLSession.shared`, and `asset(url:base:)` is the only way an AVURLAsset may be made (AVPlayer does its own networking, so missing it makes sign-in work and playback fail). `JellyfinClient`, `authenticate`, `QuickConnect`, the remote-control socket, artwork and the offline downloads all go through it. The background download session adds the headers per request, since that session is created once at launch.
- The asset header key is the string `AVURLAssetHTTPHeaderFieldsKey`: AVFoundation does not export it as a Swift symbol. Whether AVPlayer sends those headers on every HLS segment request is unchecked.
- Client certificate: `ClientIdentity` keeps an imported .p12 in the keychain and `ProxySessionDelegate` answers the challenge for the server's host. iOS only UI (Settings and sign-in, `ProxySettingsView.swift`). AVPlayer may not use it at all: check playback on a device, and if it fails, do not describe it as supported.
- Headers live in the keychain under `proxyHeaders`. There is no multi-line editor: tvOS gets the same add-a-header rows.

Lyrics translation on device (2026-10-01, iOS only, written in a cloud session with no Swift toolchain; audited 2026-09-30 on a Mac: the kit tests pass and both apps build, nothing has run on a device):
- `LyricTranslation.swift` (pure, tested): `detectLanguage` (NaturalLanguage's `NLLanguageRecognizer` over the whole lyric at once, nil under 12 characters or 0.6 confidence; the desktop uses franc), `sameLanguage` (Chinese scripts apart, a bare `zh` matches either), `needsTranslation`, `order` (current line, onward, then back to the start), and `TranslationCache` (25 days from when an entry was made, newest 5000, validated when read, keyed by source>target|line so languages never mix). The cache file is Caches/lyric-translations.json.
- `LyricsTranslation.swift` (App, `#if os(iOS)`: the Translation framework has no tvOS version) holds the model. The framework only hands a `TranslationSession` to a view's `.translationTask`, so the model keeps the `Configuration` and `lyricsTranslationTask(_:)` attaches the task to the lyrics panel. `TranslationSession` is not Sendable, so `run` is nonisolated (the session never leaves the task the framework gave it) and only strings hop to the main actor; Swift 6 refuses it otherwise. `session.prepareTranslation()` is where the framework prompts to download a missing language; declining turns the feature off. A pair `LanguageAvailability` calls unsupported gets no menu entry. Target is the device's language.
- Nothing leaves the phone: lyric text is only ever given to the framework.
- UI: Now Playing ··· menu, "Translate Lyrics" / "Hide Translation", shown only when the lyrics are in another supported language. Each translation is drawn under its line at 60% size.

Video chapters, Skip Intro, trickplay and the iOS player (2026-10-02, kit tests pass, both apps build, checked in the iOS 27 simulator against a 10.11 server):
- `Chapters.swift` (pure, tested): `Chapters.list` is the desktop's `chapterList` (sorted, deduplicated, past-the-end dropped, blank names numbered, fewer than two is none), `current(in:at:)` and `tickFractions` for the scrubber. `Trickplay.swift` (pure, tested): `JellyfinClient.videoDetails(for:)` asks for `Fields=Chapters,Trickplay` once per video; `Trickplay.pick` chooses the media source (case-insensitively, since the manifest's keys went through the JSON case rule) and a width near 320; `frame(atSeconds:)` is the sheet and crop; sheets come through `trickplaySheet` (the API session: the route wants the token). A library with trickplay off sends `Trickplay: {}` and the scrubber shows time and chapter only.
- tvOS keeps AVPlayerViewController (`VideoPlayerView`): chapters become `navigationMarkerGroups`, Skip Intro / Skip Credits is a `contextualActions` button. Those APIs are tvOS only.
- iOS draws its own player (`CascadeVideoPlayer` in `VideoControls.swift`) over an AVPlayerLayer: close, title with the chapter playing, subtitle and audio menus from the stream's media selection groups (audio only with more than one track), speed, AirPlay (`AVRoutePickerView`), picture in picture (`AVPictureInPictureController(playerLayer:)`, also automatic on leaving the app), back and forward 10 s, a scrubber with chapter ticks and, while dragging, the trickplay frame with time and chapter above the finger, and Skip Intro bottom right. Controls hide after 3.5 s while playing, never while paused or scrubbing; menus stay open when they fade. VoiceOver labels on every button, and the scrubber is adjustable by 10 s. `VideoSession` feeds it: `time`/`duration`/`isPlaying` from a periodic observer (which stops firing when playback stalls, so a failed item is caught by a status watch and shown as an error).
- Landscape lock: a landscape video (its MediaStreams size, else `presentationSize`) holds the app in landscape through `OrientationLock`, which `AppDelegate.application(_:supportedInterfaceOrientationsFor:)` reports; closing allows portrait again and turns the screen back if the phone is upright. A vertical video may still turn.
- Not checked: picture in picture and AirPlay (the simulator offers neither), trickplay frames (the test server has none), landscape on a real phone, Skip Intro (no segments on the titles tried). Lock screen: while a video is open it owns Now Playing (title, show and episode or year, poster, time, rate) and the remote commands (play, pause, skip 10 s, scrub); `PlaybackService.lockScreenSuspended`, set by AppState, makes the music player's targets stand aside and stop writing until the video closes. Checked in the simulator by its Now Playing log; the lock screen itself needs a phone.

