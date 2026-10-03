# Native Mac app: build map

Describes `mac-swift-port` at the commit after `f9d31d0` ("Keep debug builds off the installed app's data"); agents start from that commit. Line numbers drift; re-grep before trusting one. The plan is `docs/mac-native-plan.md`; this map is how the work on it is split, so agents working in parallel never edit the same file.

## Where things are

- `apple/project.yml` has the `CascadeMac` target: macOS 15, sources `App/Sources` + `App/Mac`, bundle id `xyz.chaosinc.cascade`, ad-hoc signed, no sandbox, Info.plist generated to `App/Info-macOS.plist` (gitignored).
- `App/Sources/` is shared by iOS, tvOS and Mac. `MainView.swift` and `NowPlayingView.swift` are wrapped in `#if !os(macOS)`; the Mac has its own shell and Now Playing in `App/Mac/`.
- `App/Sources/PlatformImage.swift`: `PlatformImage` (UIImage / NSImage), `Image(platformImage:)`, `.cgImage`, `.pixelArea`, `preparedForDisplay()`, and the no-op modifiers `.inlineTitle()` / `.noAutocaps()`. Use these instead of `#if` at call sites.
- `App/Sources/Keychain.swift`: on macOS the token is a 0600 file under Application Support/xyz.chaosinc.cascade; same API as iOS.
- `App/Sources/CascadeApp.swift`: on macOS the scenes are the main `WindowGroup(id: "main")`, `Window("Miniplayer", id: "miniplayer")`, `WindowGroup(id: "lyrics-editor", for: String.self)` (item id), `WindowGroup(id: "metadata-editor", for: String.self)` (item id), `Window(id: "update")`, `Settings`, and `.commands { PlaybackCommands(state:) }`. `MacAppDelegate` quits on last window closed. Open windows with `@Environment(\.openWindow)`: `openWindow(id: "lyrics-editor", value: itemId)`.
- `App/Mac/MacRootView.swift`: `NavigationSplitView` sidebar (`MacSection`), each section in a `TabStack` (TrackMenu.swift) keyed by section, `PlayerBar` in the bottom safe-area inset, `NowPlayingOverlay()` and `MacVideoHost()` as full-window overlays, toolbar with the Music/Video segmented picker and `ThemePanelButton()`.
- `AppState.nowPlayingOpen` (Bool) is the overlay's open flag.
- `CascadeKit/Sources/CascadeKit/PlaybackService.swift` has three contract stubs near the top: `autoMix`, `outputDeviceId`, `debugLines()`.

The Electron app you are porting from: `renderer.js` (UI, no semicolons, see the repo-root `CODEMAP.md` for landmarks), `main.js` (Discord RPC ~139-255, control server ~263-325, windows ~683-950, updater ~966-1672), `src/core/*.ts` (pure logic) with `test/*.test.ts` (port those cases into Swift tests), `miniplayer.html`, `lyrics-editor.html`, `metadata-editor.html`, `updater.html`, `release-notes.js`, `mac-update.js`, `styles/*.css`.

## Build and test

From `apple/`:

```
xcodegen generate
xcodebuild -project Cascade.xcodeproj -scheme CascadeMac -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO -jobs 2 build 2>&1 | grep -E "error:|BUILD"
cd CascadeKit && swift test
```

Before you finish, also build `CascadeiOS` (`-destination 'generic/platform=iOS Simulator'`) and `CascadetvOS` (`'generic/platform=tvOS Simulator'`) if you touched anything in `App/Sources` or `CascadeKit`. Several agents build at once on an 8-core, 16 GB laptop: always pass `-jobs 2`, and do not run builds in a loop.

Launch the built app with `open -n <DerivedData>/Build/Products/Debug/Cascade.app` (find the path with `-showBuildSettings | grep BUILT_PRODUCTS_DIR`), screenshot with `screencapture -x <file>` and look at the PNG. Other agents run their own builds at the same time, so kill only yours, matched on your own DerivedData path: `pkill -9 -f '<your BUILT_PRODUCTS_DIR>/Cascade.app/Contents/MacOS/Cascade'` (kill -9, so no stop report goes out). A full-screen capture shows other agents' windows too; capture your own window with `screencapture -x -l <windowid>` (window id from `osascript` or CGWindowList) or crop.

## Live test server

A throwaway Jellyfin 10.11.11 at `http://127.0.0.1:18130` with generated media: 3 artists, 6 albums, 24 tracks (FLAC and MP3, genres Rock/Electronic), 2 movies (one MKV with two audio tracks), a 3-episode show. Credentials are in `/private/tmp/claude-502/-Users-jonathan-VScode-Cascade-Project/6885fdb8-60a7-4f44-8703-667f6537db59/scratchpad/jf-mac/creds.env` (`CASCADE_SERVER`, `CASCADE_USER` is an admin, `CASCADE_GUEST_USER` is not). Source it for `swift test` live runs: `set -a; . <that file>; set +a; swift test`. Never print the passwords. It has no Cascade plugin, so plugin lyrics routes 404 there. Never point anything at the user's real server (jellyfin.chaosinc.xyz).

## Real user data: never touch it

This Mac is the user's own machine. The installed Electron app's settings live in `~/Library/Application Support/Cascade/config.json`, with a real token for their real server. `~/.cascade-control-token` is in use by Cha0s Stream. The Electron app may be running.

- Debug builds of CascadeMac have the bundle id `xyz.chaosinc.cascade.dev` (Release keeps `xyz.chaosinc.cascade`), so they get their own UserDefaults and Application Support folder. All worktrees' debug builds share that one `.dev` domain, so keep app launches to quick smoke checks, and do real verification with builds, `swift test` and the live CascadeKit suite.
- Nothing in this work reads the real `config.json` at runtime in a debug build, and nothing ever writes to it. The Electron config path must be injectable (launch argument or environment variable); tests use fixture files.
- Never regenerate or overwrite an existing `~/.cascade-control-token`. Handle port 47847 already being bound (the Electron app may hold it) without crashing. Never leave Discord presence set after a test.
- Only ever sign in to the test server below.

## House rules

- Read the response of every write; check status codes. Check endpoint shapes against the server's `/api-docs/openapi.json` (the test server serves it).
- No em dashes anywhere, code and comments included. Comments explain why. Match the surrounding style.
- Anything pure goes in CascadeKit with a test, porting the matching `test/*.test.ts` cases.
- tvOS and iOS must keep building and behaving as before.
- New Jellyfin calls go in an `extension JellyfinClient` in a new CascadeKit file you own (for example `PlaylistRoutes.swift`), not in `JellyfinClient.swift` or `Library.swift`, unless you own those.
- A new `JfItem` field only arrives if the request asks for it in `Fields=`; add it to the query you use.
- New persisted settings use `UserDefaults` key `cascade.<electronStoreKey>` with the Electron key's exact name (for example `cascade.outputDeviceId`, `cascade.miniplayerHeight`, `cascade.lyricsForcedSource`, `cascade.eqVideo`, `cascade.albumsPrefs`), holding the same value shape where practical. The settings import maps Electron's `config.json` onto these names, so a different name means a lost setting. Existing keys keep their names (`cascade.eq` is the music EQ, `cascade.libraryIds`, `cascade.crossfadeSeconds`, `cascade.serverOnlyLyrics`, `cascade.spotifyLinks`, `cascade.smartPlaylists`, `cascade.deviceId`, `cascade.browseMode`).
- Known desktop quirks to fix rather than port: the plan's "Known desktop quirks" section.

## Ownership

Each agent edits only the files it owns, plus additive, append-only changes to the shared files listed after the table. Each one works on its own branch in its own worktree, starting from this commit.

| Agent | Plan scope | Owns |
|---|---|---|
| P, playback | Phase 1 (all), plus the CascadeKit fixes in "Architecture" (NSImage artwork, device name "Mac", OfflineLibrary scoping, bitrate cap), separate Music/Video EQ profiles in CascadeKit, Phase 5's "remote commands must not wake the paused song during a video" | `PlaybackService.swift`, `Queue.swift`, `QueueActions.swift`, `Equalizer.swift`, `AudioTap.swift`, `Crossfade.swift`, `DeviceProfile.swift`, `StreamingQuality.swift`, `JellyfinClient.swift`, `OfflineLibrary.swift`, `RemoteControl.swift`, new `Radio.swift`, `Ownership.swift`, `QueuePersistence.swift`; `App/Mac/RadioView.swift`, `PlaybackCommands.swift`, `OutputDevices.swift` |
| L1, browsing | Phase 2: Home, sort and filter (Decade, Played, per-view prefs), Songs `Table`, Genres, History, artist page, Search (with video search), library pickers, `splitVideoLibraryIds`, `onePerSeries`, `collapsedLibs`, `sectionMode`, ⌘K search focus | `BrowseSort.swift`, `Library.swift`, `LibraryMerge.swift`, new `BrowseMode.swift` / `VideoLibraries.swift` in CascadeKit; `HomeView`, `AlbumsView`, `ArtistsView`, `ArtistDetailView`, `AlbumDetailView`, `SongsView`, `GenresView`, `HistoryView`, `SearchView`, `BrowseControls`, `Navigation.swift`, `VideoViews.swift` (grids and Home only; `MovieDetailView` and `SeriesDetailView` belong to V); `App/Mac/MacRootView.swift`, `LibrarySettings.swift`, new Mac browsing files |
| L2, library actions | Phase 2: context menus item for item, permissions and admin gating, media info sheet, download with NSSavePanel, copy stream URL, mark played, playlists (drag reorder, edit mode, bulk save, choke point, Save as Playlist, New playlist seeds the target), smart playlist parity, Devices panel on Mac, Waterfall modal and settings; Phase 4 metadata editor | `PlaylistEditing.swift`, `SmartPlaylists.swift`, `WaterfallSession.swift`, `WaterfallProtocol.swift`, new `Permissions.swift`, `ContextMenu.swift`; `TrackMenu.swift` (except `TabStack`), `AddToPlaylistSheet`, `PlaylistsView`, `SmartPlaylistsView`, `DevicesView`, `WaterfallView`, `DownloadsView`; `App/Mac/MetadataEditor.swift`, new Mac files for these |
| N1, now playing | Phase 3 (all), queue panel meta (`queueRemainingSec`, `formatQueueSpan`, `queueSourceFallback`) and history in the overlay, the auto-mix toggle UI, the player bar (click opens the overlay, slider keys) | `AlbumColors.swift`, `Lyrics.swift` (parse side), `LyricSources.swift`, `SpicyLyrics.swift`, new `Translation.swift`, `TranslationCache.swift`, `NPTuning.swift`, `QueueMeta.swift`; `LyricsView`, `NowPlayingBackground`, `StyleTuning`, `SpotifyLinkSheet`, `QueueView.swift` (QueueList); `App/Mac/NowPlayingOverlay.swift`, `ThemePanel.swift`, `PlayerBar.swift`, new Mac files for these |
| N2, windows | Phase 4: miniplayer and lyrics editor (LRC / enhanced LRC parse and export in CascadeKit) | new `LRCDocument.swift` (or similar) in CascadeKit; `App/Mac/MacWindows.swift`, new `Miniplayer*.swift`, `LyricsEditor*.swift` |
| I1, integrations | Phase 4: Discord RPC (+ `ITunesArt.swift`), Cha0s Stream control server, Touch Bar, debug panel, Esc order; the `CascadeMacUITests` target; `apple/MAC-PARITY.md` | new `ITunesArt.swift`; `App/Mac/MacIntegrations.swift`, new `DiscordRPC.swift`, `ControlServer.swift`, `TouchBar.swift`, `DebugPanel.swift`; `UITests/macOS/`, the UITests target in `project.yml` |
| I2, settings and updater | Phase 4 settings parity (six tabs, Music and Video EQ panels with presets, Auto preamp, the drag-point response graph, Account with Quick Connect approve), first-run wizard, arrow keys between tabs; Phase 6 settings import (bidirectional table), updater window, `MacUpdateInstaller`, beta channel, "Switch back to the Electron build" | new `UpdateRelease.swift`, `Changelog.swift`, `ElectronSettingsImport.swift`, `ReleaseNotes.swift` in CascadeKit; `SettingsView.swift`, `EqualizerView.swift`, `SignInView.swift`; `App/Mac/MacSettings.swift`, new `MacUpdateInstaller.swift`, `UpdateWindow.swift`, `FirstRunWizard.swift` |
| V, video | Phase 5 except the remote-commands fix (P) | `Video.swift`, new `Chapters.swift` in CascadeKit, `withoutAudioCodecs` / `neededAudioStreamIndex` in `Playback.swift`; `VideoPlayer.swift`, `MovieDetailView` and `SeriesDetailView` in `VideoViews.swift`; `App/Mac/MacVideo.swift`, new Mac video files |
| R, release | "Shipping both Mac DMGs" and "Release tooling": Electron bridge release, `release-plan.ts`, `update-release.ts` (`macBuild`, `mac` key, `Cascade-Native-` asset), `build.yml` native job, `publish.yml`, `site-data.ts`, `CHANGELOG.md` `### Mac`, issue template build field, docs | everything outside `apple/` except `.github/workflows/apple.yml` |

Shared files, additive only (append new members; never reorder, rename or reformat existing code): `AppState.swift`, `CascadeApp.swift`, `Models.swift` (new `JfItem` fields), `Components.swift`, `project.yml`, `apple/CODEMAP.md` (add your own dated section at the end). Merges are done by hand afterwards, so small, separate hunks merge cleanly and rewrites do not.

## Contracts between agents

Stub views already exist with these names; the owner replaces the body, everyone else may use them:

- `RadioView()` (P), `OutputDeviceSettings()` (P, a Settings section), `PlaybackCommands(state:)` (P).
- `NowPlayingOverlay()`, `ThemePanelButton()`, `LyricsSettingsSection()`, `PlayingIndicator(itemId:)` (N1). Track lists (L1, L2) put `PlayingIndicator(itemId:)` on rows.
- `MiniplayerView()`, `LyricsEditorView(itemId:)` (N2). Edit lyrics in a menu calls `openWindow(id: "lyrics-editor", value: id)`.
- `MetadataEditorView(itemId:)`, `WaterfallSettingsSection()` (L2).
- `LibrarySettingsSection()` (L1).
- `MacSettingsView()`, `UpdateAvailableView()` (I2). Settings > Playback embeds `OutputDeviceSettings()`, Lyrics embeds `LyricsSettingsSection()`, Integrations embeds `DiscordSettingsSection()` and `WaterfallSettingsSection()`, Library embeds `LibrarySettingsSection()`.
- `MacIntegrations.start(state:)`, `DiscordSettingsSection()` (I1).
- `MacVideoHost()` (V).
- `PlaybackService.autoMix`, `.outputDeviceId`, `.debugLines()` (P implements; N1 binds the auto-mix toggle; I1's debug panel shows the lines). The Video EQ profile: P adds it to PlaybackService and AppState; I2 builds its panel.
- Permissions (L2): `Permissions.canDeleteMedia(policy:)` and an `isAdmin` on AppState (from the user's Policy). Anything admin-only elsewhere reads `state.isAdmin`; until L2 merges, add nothing and leave a note.

If you need something from another agent's file, do not edit it: write a short note at the end of your report saying what and where, and it will be wired at merge.

## Finishing

Commit on your branch in small commits with clear messages (end each with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never a session link). Do not push, do not merge, do not open a PR. Your final message is a report: what you built, what you verified and how (builds, tests, live server, screenshots), every plan bullet in your scope that you did NOT finish (one line each, with why), and any cross-agent notes.
