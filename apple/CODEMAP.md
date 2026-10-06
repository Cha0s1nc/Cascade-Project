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
- Playback is `VideoSession` on AVPlayerViewController, apart from the music PlaybackService (no gapless decks, no music lock screen): the player brings controls, subtitles, AirPlay and picture in picture. Starting a video pauses music. Reports go out with MediaType Video.
- `DeviceProfile.appleVideo` claims MP4/MOV with H.264/HEVC for direct play; everything else comes as HLS (TS, H.264, AAC/AC-3/E-AC-3 up to 6 channels). Text subtitles are `Hls`: the server lists every one in the manifest's subtitle group and the player's own menu offers them. Picture subtitles (PGS, VobSub) are burned in.
- An audio track choice is honored only with the media source id beside it (checked on 10.11.11); the transcode then carries that track alone, which is why the picker is on the movie page, not in the player.
- Jellyfin keeps no resume point for anything under 5 minutes, or under 5% in: short test clips always come back "played" or at 0.
- Pages refetch on `AppState.videoRevision`, bumped once a closed video's stopped report has landed; refetching as the player closed raced it.
- JfItem equals any copy with the same id, so a row given a refetched item was not redrawn: rows take watched state and progress as plain values.
- Checked in the iOS simulator against generated media (a direct MP4, an MKV with two audio tracks and embedded plus external SRT, a two-episode show, a 7-minute movie for resume). tvOS, driven by RemoteScript: focus reaches the tiles, select resumes in the native player, and Menu twice returns to Home with the position saved. A Waterfall guest who starts a video leaves the room first, rather than pausing it through the gate. Not built: video search, a subtitle picker outside the player, per-library selection for video, trickplay thumbnails, and the lock screen during video (the music service's remote commands stay registered; fixed in the Mac playback section below).

Mac browsing (branch `mac/browsing`, 2026-10-03):
- Sort and filter live in `LibraryPrefs` (CascadeKit) and persist as `cascade.<view>Prefs` in the desktop's JSON shape (field, dir, favorite, genre name, decade, played): albums, artists, movies, shows. Songs keeps the desktop's `cascade.songsSortField` / `cascade.songsSortDir` plus an app-only `cascade.songs.filter`. The old `cascade.albums.sort` style keys are not read, so those prefs reset once. `BrowseFilter.genre` is a genre NAME (`genres=` param). Jellyfin filters artists by the artist's own genre metadata, which is empty, so artists have no genre filter, as on the desktop.
- Movie and TV libraries are chosen apart from music (`cascade.movieLibraryIds`, `cascade.showLibraryIds`, string arrays; a missing key means never chosen and browses every library of that kind, an empty array means none). `VideoLibrarySelection` (AppState.videoLibraries) holds them; `VideoLibraries` (CascadeKit) ports splitVideoLibraryIds, effectiveLibraryIds and onePerSeries. Several chosen libraries show as collapsible groups, collapse state in `cascade.collapsedLibs` (JSON array).
- Search is `searchEverything`: songs 10, albums 8, artists 8 (the /Artists route), movies and shows 8 each from the chosen video libraries. The Mac shows `SearchResultsView` under the toolbar field (Command-K); results open through the `showLibraryItem` environment action, which switches Music/Video mode first (`BrowseModeLogic`, ported from browse-mode.ts) and pushes the item via `TabStack(opening:)`.
- Songs on the Mac is a `Table` (App/Mac/SongsTable.swift); the server still sorts, the column headers only report the click.
- The screen was locked while this was built, so none of the Mac screens were looked at; builds, unit tests and the live suite are the evidence.

Mac playback (2026-10-03, branch `mac/playback`, agent P):
- Pure, in CascadeKit with the desktop's tests: `Ownership.swift` (ownership.ts; `RemoteControl.accepts(_:in:)` applies it and AppState feeds it the Waterfall room, so a cast never drives a room and remote volume is refused in one), `Radio.swift` (radio.ts plus `/LiveTv/Channels`, `/LiveStreams/Close` and the policy read), `QueuePersistence.swift` (the save and restore half of queue.ts, validated field by field from JSONSerialization; `cascade.lastQueue` is JSON text like the desktop's `lastQueue`), `AudioOutputDevices.swift` (CoreAudio list and listener, the vanished-device rule), `StreamingQuality(electronBitrate:)`, `EQKind` (music is `cascade.eq`, video `cascade.eqVideo`).
- PlaybackService: `playRadio` is its own path beside `load` (closes its LiveStreamId on switch, stop, retune and a superseded resolve; kept out of reports, prefetch, normalization and queue save; a dropped stream re-tunes after 1 s; resume re-tunes). `autoMix` acts only when the queue ends on a music track, never for a guest. `outputDeviceId` sets `audioOutputDeviceUniqueID` on both decks; a vanished device falls back to the default with `outputNotice`. `adoptRestoredQueue` shows a queue without loading anything; the first play loads it at the saved position. `isVideoActive` gates every MPRemoteCommand handler and a cast's transport commands. `debugLines()`, `measureHandovers` and `lastHandover` work in release builds too. On the Mac, Now Playing sets `playbackState` (the system picks the media-key app from it) and uses NSImage art built in a nonisolated function.
- Mac: `App/Mac/PlaybackPersistence.swift` saves the queue every 5 s and on quit, plus volume, repeat and output device, macOS only. The device name is "Mac", Original is the desktop's 140M cap, and OfflineLibrary's folder is under the bundle id (macOS only; iOS keeps its path or its downloads would be orphaned).
- Test server facts: `GET /Items?ids=` answers 500 for a few near-zero ids (`000...01`) but 200 for any random id, so a deleted track restores fine. The server has no Live TV tuner, so radio is verified to the route level only.

Mac Now Playing, lyrics and theme (branch `mac/nowplaying`, 2026-10-03, agent N1):
- Pure, in CascadeKit with tests ported from the desktop: `QueueMeta.swift` (queueRemainingSec, formatQueueSpan, queueSourceFallback, the "12 of 40 · 1h 5m · ends 10:12 PM" line), `NPTuning.swift` (npTuning clamps, AppFont sanitizing and resolving), `ThemeModel.swift` (ThemeSettings with validated store values, the eight presets, the album-art accent from a palette), `Translation.swift` (`LyricTranslation`: NaturalLanguage detection in place of franc, translationLanguageFor with the Chinese script and Russian/Ukrainian heuristics, the Apple-only engine choice, `TranslationPlan`, the line-being-sung-first order), `TranslationCache.swift` (5,000 lines, 25 days, the desktop's `[[key, text, at]]` file), `AlbumColors` light theme (`light:` on extractTopColors and driftedBlobs, `lightnessRange`, `baseLight`), and `LyricsSourceChoice` / `LyricsWaterfall.fetchDetailed` (forced source, per-source status). The type is `LyricTranslation`, not `Translation`, because Apple's framework is a module of that name.
- Settings use the desktop's store key names under `cascade.`: `theme` and `npTuning` (JSON strings, the desktop's shapes), `uiFont` (JSON string `{"preset","custom"}`), `lyricsForcedSource`, `lyricsTranslationEnabled`, `lyricsTranslateOn`, `cascadePluginNoticeSeen`. The lyric look stays under the existing `cascade.styleTuning` (a `[knob key: Double]` dictionary whose keys are the desktop's `lyricStyle` keys, so the import is a copy). Electron's `npTuning.lyricScale` has no control on the Mac: the Lyrics page's Text size knob (`lyricSize`, default 30) is the size, so import it as `lyricSize = 30 * lyricScale`.
- Environment flows inward: `macThemed()` reads AppState, so it must be applied before `.environment(state)` in the chain. The other order crashes at launch with an EnvironmentValues assertion.
- `Color.accentColor` ignores `.tint`; the Mac views read `MacTheme.shared.accent`. The sidebar selection (system list) stays the system blue.
- The overlay draws nothing while closed. Lyrics are fetched only while something shows them (overlay on its lyrics half, or the side panel). The window toolbar stays over the overlay: hiding it took the traffic lights too.
- A mouse wheel gives a scroll view no phase, so on the Mac the lyrics enter manual browsing from an NSEvent scroll monitor scoped to the lyrics view (2.2 s settle; iOS keeps scroll phases and 2.5 s).
- Translation: macOS 26+ uses `TranslationSession(installedSource:target:)` with no view; macOS 15 needs a `.translationTask` host (`translationHost`). Neither prompts to download: only an installed language translates, a supported one opens Language & Region from the install prompt.
- Checking without UI scripting: launch a debug build with `-cascade.debugNP play,open,lyrics,light` (comma list, see NowPlayingDebug.swift) and `screencapture -l <window id>`. Several agents' debug builds share one bundle id, so computer-use tools target whichever is first: find your own window by pid.


Mac settings and updater (branch `mac/settings`, 2026-10-03, agent I2):
- Settings: `App/Mac/MacSettings.swift` is the six-tab view (Library, Playback, Lyrics, Integrations, Account, About) for both the `Settings` scene and the sidebar entry; `SettingsView` on macOS just returns it. Arrow keys move between tabs while the tab strip has focus, Command-1 to 6 jump. Settings and the first-run wizard both write through `SettingsActions` (same file). `EQPanel.swift` is the per-profile editor with the drag-point graph; its geometry is `EQGraph` in CascadeKit (ports `eq-profile.ts`). The Video profile is `VideoEqualizer` in `EQPanel.swift`, persisting `cascade.eqVideo` with a marked hook for playback to wire live.
- Wizard: `FirstRunWizard.swift`, steps and revisions in CascadeKit's `SetupWizard` (`cascade.wizardSeenRevision`, per-step `since`). Each step seeds from the live value; the video intro is a one-step run of the same sheet.
- Settings import: `ElectronSettingsImport.swift` is one table, Electron key to `cascade.<key>` with a validator each way (some rows fold several keys: crossfade, normalization, the two EQ profiles). It keeps `deviceId`, drops Chromium-only and Mozilla keys, never deletes the Electron file, writes back with `macBuild: electron` and a one-time `config.json.cascade-native-backup`. The path is always injected; `MacSettingsImport.swift` resolves it. A DEBUG build only touches a file named by `CASCADE_ELECTRON_CONFIG` or `-cascade.electronConfig`, never the real one. Runs once from `AppState.init` before the session restores.
- Updater: `UpdateRelease` (versions.json with `desktop` and `mac`, `-bN` ordering, `Cascade-Native-<ver>.dmg` and the Electron arm64 DMG), `Changelog` (now with a `### Mac` section), `ReleaseNotes` (safe Markdown subset to blocks), all in CascadeKit with tests. `MacUpdateInstaller` (CascadeKit, macOS only) is mac-update.js: its tests build throwaway signed bundles and DMGs in a temp folder and run the swap script with `/usr/bin/true` as the relaunch. `UpdateWindow.swift` has `UpdateService` (check, download with sha256, install) and the Update Available window. A DEBUG build never installs in place.
- Debug launch flags: `-cascade.updatePreview YES` (fake offer, nothing downloaded), `-cascade.openSettings YES`, `-cascade.settingsTab <tab>`, `-cascade.showWizard YES`, `-cascade.forceSignIn YES`.

Mac video (2026-10-06, branch `mac/video`, agent V):
- `VideoSession` (App/Sources/VideoPlayer.swift, shared) now owns position, rate, chapters, subtitle and audio choices, next/previous episode, batched skips on transcodes, frame step, the shared app volume (Mac: `follow(player)`) and the Video EQ tap (direct streams only: AVFoundation will not tap an HLS transcode, so an MKV plays flat). The Mac draws its own controls (App/Mac/MacVideo.swift: host, key monitor, idle timer, traffic lights, toolbar and fullscreen restore in `detach`; MacVideoControls.swift: bar, chapter ticks, pickers, `?` panel) over an AVPlayerView with `controlsStyle = .none`. iOS and tvOS keep AVPlayerViewController unchanged.
- Fixed in `VideoPlayback.resolve`: an HLS playlist spans the whole item and ignores StartTimeTicks (checked on 10.11.11), so a resumed transcode now carries `startTicks` 0 and is seeked like a direct file. Before, it started at 0 and reported start plus clock.
- Pure and tested in CascadeKit: `Chapters.swift` (chapterList/At/Target, `JellyfinClient.chapters(of:)` through `/Items/{id}`, which has no `fields` parameter and returns Chapters by itself), `VideoControls.swift` (skip, tenths, rates, frame, subtitle order, the C toggle), `neededAudioStreamIndex`, `DeviceProfile.withoutAudioCodecs` and `isHlsUrl` in Playback.swift.
- Audio picker restarts at the same position with the media source id; an explicit pick follows to the next episode by language. Subtitles use AVMediaSelectionGroup (`.legible`), default and forced first, last pick remembered by label.
- Decision: the desktop's `_armAudioDecodeCheck` is not ported. Chromium's codec claims can lie; the AVFoundation profile (`DeviceProfile.appleVideo`) is declarative, so a claimed codec decodes. `neededAudioStreamIndex` covers the multi-track default case, and `withoutAudioCodecs` is there for a future fallback.
- The test media has no chapters or subtitles, so ticks and the subtitle picker are unexercised on real data.

Mac library actions (branch `mac/actions`, 2026-10-06, agent L2):
- CascadeKit: `Permissions.swift` (`UserPolicy`, `Permissions.canDeleteMedia(policy:)`, `isAdmin`, `client.userPolicy()`), `ContextMenu.swift` (`menuItems(for:)`, the desktop's menuItemsForKind), `LibraryActions.swift` (refresh, delete, `fullItem`/`updateItem` over `RawItem` bytes so the metadata POST sends the whole item untouched, download to a file, `MediaInfo.rows`, `copyableStreamURL` which is Video for movies, `MetadataEdit`), bulk playlist editing in `PlaylistEditing.swift` (`PlaylistEdit`, `setPlaylistItems` = one whole-Ids POST, `updatePlaylist`, `playlistInfo`: public is `/Playlists/{id}` OpenAccess, not on the item; `arrangedPlaylists` for `cascade.playlistsPrefs` with fields name, added, count). `SmartPlaylist` now stores the desktop's shape (`match`, `sortDir`, `{field, op, value}` rules) and still reads the old Swift-encoded one; `SmartPlaylist.stored(in:)` accepts Data or the desktop's JSON text.
- AppState: `isAdmin`, `canDelete` (from the Policy, cleared on sign-out), `playlistMutated()` (the one choke point: drops the Playlists list, bumps `playlistRevision`, which open playlist pages reload on), `libraryMutated()`.
- Mac menus: `App/Mac/MacTrackMenu.swift` (`MacTracksMenu`, selection-aware; `trackActionHost()` presents Add to Playlist, Media Info and the delete dialog), `MacItemMenu.swift` (album and playlist tile extras). `TrackMenuItems` delegates to `MacTracksMenu` on macOS and has a `nowPlaying` flag for Stop and Clear Queue (both stop: the desktop's Clear left the song playing). Gated items stay visible, dimmed, with the reason in the title, and every handler re-checks.
- `SongsTable` uses `contextMenu(forSelectionType:)`: the menu acts on the selection when the clicked row is in it.
- `MacPlaylistDetail` is the playlist and smart playlist page on the Mac (List with selection, drag reorder, bulk bar, rename and public, refresh, Added (server) / Plays column, Save as a Playlist). Every reorder or removal is one `setPlaylistItems` then `playlistMutated`.
- Devices (`DevicesSheet`, now on all platforms, Mac seek slider) and the Waterfall room sheet are opened from `MacConnectButtons` in the toolbar. `WaterfallSettingsSection` uses the existing `cascade.wf.*` keys.
- Live tests: `LiveActionsTests` (bulk save, drag move after a bulk save, mark played, metadata POST with restore, refresh, media info, download, delete of a test-made playlist, guest refusals).

Mac integrations (branch `mac/integrations`, 2026-10-06, agent I1):
- CascadeKit, with tests (`IntegrationsTests`, `ITunesArtTests`): `ITunesArt.swift` (itunes-art.ts, plus the `ITunesArt` actor: cached lookups, a 403 or timeout is not remembered, the discography fallback, `art(...within:)` for the 800 ms wait), `DiscordRPC.swift` (frame encode and decode, SET_ACTIVITY JSON with type 2 or 3 and `status_display_type`, `RpcBackoff` 15 s to 60 s, the 5 s send wait), `ControlProtocol.swift` (request parse, token check, the four routes with Electron's JSON key order, `ControlToken`).
- Mac: `App/Mac/DiscordRPC.swift` is the socket (`NWConnection` to `$TMPDIR/discord-ipc-0..9`), `ControlServer.swift` the `NWListener`, `TouchBar.swift` an `NSTouchBar` set on `NSApp`, `DebugPanel.swift` a floating panel (shown at launch when `.cascade-debug` is next to the app or in Application Support) plus `ProcessStats`, `MacIntegrations.swift` the settings section, a 1 s poll that feeds Discord, the Touch Bar and the now-playing document, and `EscapeKeys`.
- Settings keys `cascade.discordRpcEnabled` (Bool) and `cascade.discordClientId` (digits, empty means the default id).
- The token file is never rewritten: an existing one that is not 64 hex leaves the server off. A taken port 47847 (the Electron build) leaves it off quietly.
- Image URLs never go to Discord: art is the iTunes URL or nothing. `/cascade/now-playing` carries ids, not a URL, because a Jellyfin image URL embeds the token.
- Checking the server: `lsof -i :47847` first, then launch the debug app and curl with `x-cascade-token` from `~/.cascade-control-token`.
