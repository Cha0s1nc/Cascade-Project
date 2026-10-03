# Native macOS app plan

Written 2026-10-03 against `mac-swift-port` at `45616d3`. Line numbers drift; re-grep before trusting one. This is the roadmap for replacing the Electron build on macOS with a native Swift app in `apple/`, with full feature parity, and for shipping both Mac builds during the transition.

## Context

Mac users run the Electron app today: `main.js` (1.7k lines), `renderer.js` (12.5k lines), `index.html`, four secondary windows, and `src/core/*.ts`. The goal is to replace it on macOS with a native Swift app for performance, with full feature parity. The iOS/tvOS Swift app in `apple/` already ports most of the pure logic into `CascadeKit`. Its playback engine (AVQueuePlayer two-deck gapless and crossfade, the MTAudioProcessingTap EQ and normalization) and its SwiftUI screens are shared between iOS and tvOS. This plan adds a third target that reuses all of that, then fills in everything that exists only on desktop.

Decisions already made:
- A **native macOS target** (`CascadeMac`) in `apple/project.yml`. It shares CascadeKit and reuses App/Sources where they fit. Mac-only UI lives in `apple/App/Mac/`.
- **Ad-hoc signed DMG** on GitHub Releases, updated by a Swift port of `mac-update.js`. No Developer ID, no Sparkle, no App Store, no sandbox.
- **macOS 15 minimum.** APIs that exist only on macOS 26 go behind `#available`.
- **Apple Translation only.** Bergamot, the model downloads and `cascade-model://` are dropped.
- **Scope is macOS only.** Windows and Linux stay on Electron. The `signaling/` Cloudflare Worker and the Node CI scripts are unaffected.

House rules, from both CODEMAPs, apply throughout:
- Read the response of every write.
- Check endpoint shapes against `/api-docs/openapi.json`.
- No em dashes.
- Comments explain why.
- Anything pure goes in CascadeKit, with a test.

## Where things stand

- **CascadeKit already compiles on macOS.** `Package.swift` declares `.macOS(.v14)` and `swift test` runs on the macOS CI host. `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter` compile there, so the media keys and Control Center work as soon as an app hosts them.
- **App/Sources does not compile for macOS.** These are the blockers:
  - `Components.swift` (UIImage throughout `ArtworkCache` / `ArtworkView`)
  - `NowPlayingBackground.swift:24`
  - `MainView.swift:19,95,100,126` (fullScreenCover, tabViewBottomAccessory, tabBarMinimizeBehavior)
  - `NowPlayingView.swift:258,498,517,634,652` (AVAudioSession, SystemVolumeSlider, RoutePicker, editMode)
  - `QueueView.swift:18-21` (navigationBarTitleDisplayMode, EditButton, topBar placements)
  - `SignInView.swift:24,54` (textInputAutocapitalization)
  - `VideoPlayer.swift:139-155` (AVPlayerViewController)
- **iOS-only features that would vanish on Mac:**
  - Search, Settings, Devices, Downloads and the Music/Video toggle have no entry point, because `LibraryToolbar` in `Navigation.swift:60-113` is iOS-only.
  - `DevicesView`, `SpotifyLinkSheet` and the `StyleTuningSheet` UI are `#if os(iOS)`.
  - Playlist reorder/remove and Songs sort/filter are `#if os(iOS)`.
  - `PlaybackService.swift:1381-1445` gives no Now Playing artwork without UIKit.
- **Desktop modules missing from CascadeKit:**
  - radio
  - permissions (`canDeleteMedia`)
  - translation-models / translation-cache / language
  - itunes-art
  - update-release
  - changelog
  - eq (the visualizer)
  - persisted queue restore (part of queue.ts)
  - chapters, `withoutAudioCodecs` / `neededAudioStreamIndex` (playback.ts)
  - per-library video selection (`splitVideoLibraryIds`, `onePerSeries` in jellyfin.ts)
  - bulk playlist edit
  - the light-theme half of album-colors
  - browse-mode `sectionMode` auto-switch
  - the unified cast-vs-Waterfall owner (ownership.ts)
- **Desktop main-process features with no Swift equivalent:**
  - miniplayer, lyrics editor, metadata editor and updater windows
  - Discord RPC
  - the Cha0s Stream control server (127.0.0.1:47847)
  - Kugou over main (CascadeKit already does Kugou itself)
  - Touch Bar
  - the debug sentinel panel and metrics
  - Apple Translation
  - the electron-store settings

## Architecture

- **`project.yml`: a new `CascadeMac` target.**
  - `platform: macOS`, `deploymentTarget: "15.0"`, sources `App/Sources` plus `App/Mac`.
  - Bundle id `xyz.chaosinc.cascade`, the same as Electron's `appId`. The existing swap installer's bundle-id check then accepts either build, so users can switch between Electron and native in place, in both directions.
  - Generated Info.plist:
    - `LSApplicationCategoryType public.app-category.music`
    - `NSAppTransportSecurity.NSAllowsArbitraryLoads true`, because Electron reaches plain-http LAN servers today
    - `LSMinimumSystemVersion`
    - `CFBundleShortVersionString` / `CFBundleVersion` from build settings, as the other targets do
  - Signing: `CODE_SIGN_IDENTITY "-"`, no entitlements and no sandbox (needed for Discord's socket, the localhost server and the `~/.cascade-control-token` file).
  - An AppIcon built from `assets/icon.icns`.
- **Platform shims, so shared views stop referencing UIKit:**
  - `App/Sources/PlatformImage.swift` with `typealias PlatformImage = UIImage / NSImage`, plus `Image(platformImage:)`, `decode(data:)` and `cgImage`.
  - A no-op `View` extension for iOS-only modifiers (`.inlineTitle()`, `.noAutocaps()`), so call sites stop branching.
- **CascadeKit fixes:**
  - `PlaybackService` gets an `NSImage` artwork path for `MPMediaItemArtwork`. Build the closure outside main-actor isolation, per the lock screen art note in `apple/CODEMAP.md`.
  - The `JellyfinClient` device name gets a macOS branch ("Mac").
  - `OfflineLibrary` storage is scoped under the bundle id.
  - A `DeviceProfile.apple` bitrate cap for Mac, matching the desktop's 140M "Original".
- **Mac shell (`App/Mac/MacRootView.swift`):**
  - `NavigationSplitView` with a sidebar: Home, Albums, Artists, Songs, Playlists, Genres, History, Radio, Movies, TV Shows, and Settings pinned at the bottom.
  - Toolbar: the Music/Video segmented toggle, a `.searchable` field with ⌘K focus, and the theme button.
  - The bottom player bar sits in `.safeAreaInset(edge: .bottom)`.
  - The Now Playing overlay is a full-window layer over the split view.
  - The window opens at 1100x700 with a minimum of 800x560, and SwiftUI restores its frame.
  - Keep `applicationShouldTerminateAfterLastWindowClosed = true`, since closing the window quits today.
- **Reuse policy:**
  - Data loading, view models and row/tile components are shared.
  - Where the iOS layout does not suit a desktop, the Mac gets its own presentation in `App/Mac/`. That covers a `Table` for Songs and playlists (sortable columns, multi-select, drag), the player bar, the overlay and the Theme panel.
  - tvOS stays untouched.
- **Scenes in `CascadeApp`:**
  - the main `WindowGroup`
  - `Window("Miniplayer")`, `Window("Lyrics Editor")`, `Window("Metadata Editor")` and `Window("Update Available")`
  - `Settings {}`, so ⌘, opens the same settings the sidebar entry shows
  - `.commands`: a Playback menu (play/pause, next, previous, shuffle, repeat, volume, sleep timer) and View items. Electron only has the stock menus, so this is a small step beyond parity.
- **Persistence:**
  - `UserDefaults` for settings, using the same key names as electron-store where they exist, which keeps migration a straight mapping.
  - The access token goes in a 0600 file under Application Support, not the Keychain. Ad-hoc signatures change with every update, so the legacy file keychain would prompt after each update, and the data-protection keychain needs a team-signed build. This matches what Electron does today, since electron-store keeps the token in `config.json`. iOS and tvOS keep `Keychain.swift`.

## Parity work, by phase

Each phase ends with something usable. Every new pure module gets a test file in `CascadeKit/Tests`, porting the matching `test/*.test.ts` cases where they exist.

### Phase 0: it builds and plays
- Add the `CascadeMac` target and fix the compile blockers listed above, through the shims.
- Sign-in works on Mac: server URL, password, and Quick Connect (CascadeKit already has `QuickConnect.swift`).
- A minimal shell: the sidebar, a library view, and the player bar wired to `PlaybackService`.
- In `apple.yml`, add `xcodebuild -scheme CascadeMac -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build`.

### Phase 1: playback engine parity
- Media keys and Control Center through `MPRemoteCommandCenter` (replaces `globalShortcut`), with artwork.
- **Output device picker:**
  - Use `AVPlayer.audioOutputDeviceUniqueID` on both decks, with the device list from CoreAudio (`kAudioHardwarePropertyDevices`).
  - Fall back to the system default when the device vanishes, and say so.
  - Persist it as `outputDeviceId`.
- Volume and mute through the app's own volume, the single choke point. Arrow / PageUp / PageDown on the slider.
- **Last-queue restore:**
  - Port the save/restore half of `queue.ts` into `Queue.swift`: save every 5 s and on quit, then restore shown but paused after sign-in.
  - Also restore shuffle, repeat and the unshuffled order.
- **Auto-mix (∞):** append an instant mix of 25 when the queue runs out, toggled in the queue panel.
- **Sleep timer:** 15/30/45/60 minutes or end of track, if PlaybackService does not already have it; check before building.
- **Queue panel meta:** "12 of 40 · 1h 5m · ends 10:12 PM" (`queueRemainingSec` / `formatQueueSpan`, `queueSourceFallback`), plus history with Clear.
- **Radio:**
  - Port `src/core/radio.ts` to `Radio.swift`.
  - Live TV channels with a LiveStreamId that is closed on switch or stop.
  - Kept out of prefetch, lyrics, played reports and crossfade, as on desktop.
  - The opt-in setting is gated on the account's Live TV policy.
- **Ownership:** port `ownership.ts` so that remote control (cast target) and Waterfall share one owner check. Today `RemoteControl.apply` calls the player directly.
- Streaming quality steps match desktop (Original / 320 / 192 / 128 / 96). Keep the existing extra steps if wanted, but map stored `maxStreamingBitrate` values.

### Phase 2: library and browsing parity
- **Home:**
  - Greeting, Recently played (24), Recently added (24), Continue watching / Next Up (one card per series, `onePerSeries`).
  - The music shelves hide in Video mode.
- **Albums, Artists, Playlists, Movies, Shows:**
  - The shared sort and filter: Favorites, Genre, Decade, and Played (Any/Unplayed/Played).
  - Preferences persist per view (`<view>Prefs`).
  - Extend `BrowseSort.swift` / `BrowseFilter` with Decade and Played.
- **Songs:** a virtualized `Table` with the full sort set (Title, Artist, Album, Date added, Date last played) and Shuffle All.
- Genres (tile, detail, songs in chunks of 300 with Show more), History grouped by day, artist page (bio More/Less, Top Songs, Albums with Play All, Similar Artists): mostly reuse.
- **Search:**
  - Desktop runs Songs 10, Albums 8, Artists 8, plus Movies and Shows 8 each when video is enabled, with a 300 ms debounce.
  - Add video search, which the iOS app lacks.
- **Libraries:**
  - Music library picker with single-library mode.
  - Movie and TV library selection grouped per kind (port `splitVideoLibraryIds`).
  - Collapsible per-library poster groups, persisted in `collapsedLibs`.
  - `sectionMode` auto-switches the mode on deep links.
- **Context menus (right-click, `.contextMenu`), item for item from `src/core/context-menu.ts` and the track and now-playing menus:**
  - Play now / next / last.
  - Play on device.
  - Favorite.
  - Instant mix (use 50 for track rows and 25 for the More menu, or unify the two).
  - Add to playlist.
  - Media info sheet (all 14 fields).
  - Download: `NSSavePanel` plus a URLSession download of `/Items/{id}/Download`.
  - Copy stream URL (Audio or Video by type).
  - View album / artist.
  - Refresh metadata, Edit metadata, Edit images (opens Jellyfin web).
  - Edit lyrics.
  - Remove from playlist.
  - Delete media (confirm).
  - Mark played/unplayed (`/UserPlayedItems`).
  - Stop and Clear queue (fix the desktop bug where Clear neither stops nor redraws).
- **Permissions:**
  - Port `permissions.ts` (`canDeleteMedia`) and the admin gating.
  - Gated items stay visible but dimmed with an "Admin only" note.
  - Handlers re-check permissions.
- **Playlists:**
  - Drag reorder (`/Items/{entry}/Move/{to}`).
  - Edit mode with multi-select, select-all, move to top or bottom, remove, rename and public.
  - Saves go through one whole-Ids `POST`; add a bulk API to `PlaylistEditing.swift`.
  - One mutation choke point, like `playlistMutated`.
  - The refresh button, and the "Added (server)" / "Plays" extra column.
  - "Save as a Playlist" for smart playlists.
  - New playlist from Add to Playlist seeds the target item, fixing the desktop's `atpCreatePlaylist` bug.
- **Smart playlists:**
  - The rule builder already exists (`SmartPlaylistsView`). Check that every desktop rule field and the sort/limit options are present.
  - Reuse the `smartPlaylists` storage shape, so migrated definitions load.
- **Devices panel:** enable `DevicesView` on macOS. It needs a poll every 3 s while open, the transport, seek and volume controls, and "Play current queue here".
- **Waterfall:** the Mac modal (code, Copy, role, members, Leave) using the existing `WaterfallSession`. Add the relay URL and guest permission settings.

### Phase 3: Now Playing, lyrics, theme
- **Overlay:**
  - Opens by clicking the player bar, closes with Esc or the chevron.
  - Left column: art with Favorite / Add to playlist / View album hover buttons, transport, volume, and More.
  - Right panel: queue (virtualized, drag handle, remove, "added by X", read-only for Waterfall guests), switching to lyrics.
  - Controls fade after 3 s idle.
- **Background:**
  - Reuse `NowPlayingBackground` and `AlbumColors`.
  - Port the light-theme blob ranges (`BLOB_L_RANGE`) and the multiply blend.
  - Background dim and blend knobs (`npTuning`).
  - Single choke point with skip-if-unchanged, as `setOverlayBackgroundImage` does.
- **Lyrics:**
  - Reuse `LyricsView`: karaoke fill, duets, held-note swell, background vocals, credits.
  - Add the side lyrics panel.
  - Source pill and dropdown: Auto / Kugou / LRCLIB / Jellyfin, or Karaoke Only / Synced Only in server-only mode, with status badges and `lyricsForcedSource`.
  - The one-time plugin notice.
  - Enable `SpotifyLinkSheet` on Mac.
  - Credit links on Mac (today they are `#if os(iOS)`).
  - Mouse wheel enters manual browsing, returning to the current line after 2.2 s.
- **Theme panel (popover):**
  - Dark/Light mode.
  - Gradient start/end with the 8 presets.
  - The album-art accent toggle, with the gradient controls locked while it is on.
  - UI font: System, Helvetica, Georgia, Monospace or a custom family (sanitized).
  - Lyrics page: every `lyric-style.ts` knob, with per-knob reset and Reset all.
  - Mac UI for the `StyleTuning` model. Today only `StyleTuningSheet` exists, and it is iOS-only.
  - The accent drives the app's tint.
- **Playing-row EQ bars:**
  - Animate them from levels published by `AudioTap` when a tap is attached. Otherwise use a canned animation, which is what desktop does when there is no signal.
  - Do not attach a tap only for the bars: `apple/CODEMAP.md` measured that a tap costs the gapless handover.
- **Translation:**
  - `Translation.swift` in CascadeKit: port `translationLanguageFor` (Chinese script and Russian/Ukrainian heuristics) and the language keys from `translation-models.ts`, plus `translation-cache.ts` (5,000 entries, 25-day TTL, saved to disk).
  - Sheet language detection uses `NaturalLanguage`, as a replacement for franc in `language.ts`.
  - Translation itself:
    - macOS 15 uses SwiftUI `.translationTask` on the lyrics view.
    - macOS 26 uses `TranslationSession(installedSource:target:)`, the same API as `native/apple-translate/main.swift`.
  - Two switches, as on desktop: `lyricsTranslationEnabled` and `lyricsTranslateOn`.
  - Lines stream in starting from the one being sung.
  - The install prompt opens Language & Region (`x-apple.systempreferences:com.apple.Localization-Settings.extension`). Drop its "Use Cascade's model" option.

### Phase 4: desktop-only windows and integrations
- **Miniplayer:**
  - A `Window` scene hosted in a floating `NSPanel` (`.floating` level, not in the window cycle, vibrancy).
  - Width fixed at 300, height 100-900, persisted as `miniplayerHeight`.
  - Traffic lights only on hover. Opening it minimizes the main window; closing it restores the main window.
  - Art, title, like, scrubber, transport.
  - Wheel over the cover sets volume, with an on-screen readout.
  - Space, the arrow keys, Up and Down.
  - Lyrics tab (karaoke, click to seek, auto-follow) and Up Next tab (50 items, Autoplay / Shuffle / Repeat).
  - Fades after 2.6 s idle.
  - Ship it enabled. It is "coming soon" in packaged Electron builds.
- **Lyrics editor (largest single item):**
  - A port of `lyrics-editor.html`.
  - Put the LRC / enhanced-LRC parse and export in CascadeKit with tests.
  - Line rows, word pills (drag across lines, inline edit), inspector, and Stamp mode (Space stamps, auto-filling the previous word's end).
  - Its own AVPlayer with speed 0.25-2x, the j/l and arrow keys, and a karaoke preview.
  - Saves to the plugin's lyrics route, then reloads lyrics in the main window.
  - Never seed it from SpicyLyrics.
- **Metadata editor:**
  - The 8 fields.
  - Admin only.
  - `POST /Items/{id}` with the whole fetched item.
  - Refreshes the views and the now-playing info after a save.
- **Discord Rich Presence:**
  - A native client in `App/Mac/DiscordRPC.swift`: a Unix socket at `$TMPDIR/discord-ipc-{0..9}` with the opcode + length frame and a HANDSHAKE followed by SET_ACTIVITY.
  - Port the behavior from `main.js:139-255`:
    - type 2 for listening and 3 for watching, `status_display_type`
    - one update per 5 s at most
    - reconnect backoff from 15 s up to 60 s
    - clear on pause
  - Art comes from a port of `itunes-art.ts` into CascadeKit (public URLs only, never the Jellyfin URL, which carries the token), waiting up to 800 ms before a follow-up.
  - Default client id `1512373702522835004`.
  - A status dot in Settings.
- **Cha0s Stream control server:**
  - `NWListener` on 127.0.0.1:47847.
  - Byte-compatible with `main.js:263-325`: a token in `~/.cascade-control-token` (64 hex, mode 600) checked against the `x-cascade-token` header, and `POST /cascade/control`, `GET /cascade/status`, `GET /cascade/jellyfin` and `GET /cascade/now-playing`.
- **Touch Bar:** an `NSTouchBar` with the track label and prev/play/next.
- **Debug panel:**
  - Shown when the `.cascade-debug` sentinel exists in the app dir or Application Support.
  - Shows the play method, codecs, decks and crossfade state, prefetch and gapless handover timing, tap state, and memory/CPU from `task_info`.
  - Shift-click copies.
  - It is how performance gets compared against Electron.
- **Keyboard:**
  - ⌘K search.
  - Esc closes menus, panels and the overlay in that order.
  - Arrow keys move between Settings tabs.
  - The slider keys.
- **First-run wizard:**
  - Steps: libraries, crossfade, quality, theme, translation.
  - Keyed off `wizardSeenRevision` with per-step revisions.
  - Every step seeds from the live value and writes through the same setters as Settings.
  - The video intro is shown once.
- **Settings parity:**
  - Six tabs: Library, Playback (with the EQ panels for Music and Video, presets, Auto preamp, and a drag-point response graph), Lyrics, Integrations, Account (server, user, password, Quick Connect approve, sign out), About (version, Beta updates, Check for updates).
  - Desktop has separate Music and Video EQ profiles (`eqMusic` / `eqVideo`). CascadeKit has one profile, so add the second.

### Phase 5: video parity
- **Player:** an `AVPlayerView` behind `NSViewRepresentable`, wrapped by the existing `VideoSession`, in a Mac `VideoPlayer.swift` branch.
- **Pickers outside the player** (also a gap on iOS):
  - Subtitle picker (Off, or a track; default/forced first; remembers your last pick for C).
  - Audio track picker that restarts at the same position with the media source id (already the documented shape).
- **Chapters:** fetch, tick marks, list, and ⌥←/⌥→.
- **Video keys, from `VIDEO_KEYS`:**
  - Space or K play/pause; J/L ±10 s; arrows ±5 s, batched on transcodes.
  - Up/Down volume with a readout; M mute; F or double-click fullscreen.
  - 0-9 jump to tenths.
  - , and . step a frame while paused (`AVPlayerItem.step(byCount:)`).
  - < and > change speed.
  - Shift+P/N previous/next episode.
  - ? shows the list.
- **While video plays:**
  - Hide the traffic lights while the controls are idle (`standardWindowButton(...).isHidden`).
  - The cursor hides when idle.
  - Episodes queue the whole season.
  - Resume and play-from-start.
- **Remote commands:** the music service's commands must not wake the paused song during a video. This is a known iOS gap; fix it in the shared code.
- **Decode check:** the desktop's `_armAudioDecodeCheck` exists because Chromium's codec claims can lie. The AVFoundation profile is declarative, so this is not ported. Record the decision in `apple/CODEMAP.md`.

### Phase 6: migration, updater, release, cutover
- **Settings import (one shot, on first launch):**
  - Read electron-store's `~/Library/Application Support/Cascade/config.json`.
  - Map every key from the electron-store inventory: identity/session, libraries, onboarding, view prefs, playback, lyrics, look, integrations, `smartPlaylists`, `spotifyLinks`, `windowState`.
  - Treat values as untrusted: they are often stringified JSON or `'true'`, so validate each one.
  - Keep `deviceId`, so the server does not see a new device and remote control and history stay continuous.
  - Drop the Bergamot keys and `appleTranslationMozillaChosen`.
  - Mark the import done, and never delete the Electron file.
  - Logic in CascadeKit (`ElectronSettingsImport.swift`) with fixture tests.
- **Updater:**
  - Port `src/core/update-release.ts` (versions.json parsing, `isNewerVersion` with `-bN`, asset picking) and `changelog.ts` `notesBetween` into CascadeKit, with tests.
  - The `Update Available` window: notes in the safe Markdown subset of `release-notes.js`, download with progress and the sha256 check against GitHub's asset digest, Install, Later and View on GitHub.
  - Port `mac-update.js` to Swift (`MacUpdateInstaller.swift`):
    - Refuse from a translocated copy, from `/Volumes`, or from an unwritable parent folder.
    - `hdiutil attach -nobrowse -readonly`, then `ditto` to a staging copy.
    - Check `codesign --verify --strict`, the bundle id and the version.
    - A detached swap script with rollback and a log at `$TMPDIR/cascade-update.log`.
    - Fall back to opening the DMG on any failure.
  - The beta channel follows `betaUpdates`.
- **Release pipeline and the two Mac DMGs:** see the next section.

## Shipping both Mac DMGs (Electron and native)

**Recommendation: yes, ship both in every release for a transition period.** Each Mac holds one `Cascade.app` at a time, with an opt-in switch that works in both directions. The switch is not a second app installed beside the first.

Why one app at a time rather than both installed side by side:
- **Same bundle id.** Both builds use `xyz.chaosinc.cascade`. That means:
  - The existing swap installer (`mac-update.js`, which checks bundle id, signature and version) can move a user either way with no special case.
  - The Dock, Login Items, Now Playing identity and the `/Applications/Cascade.app` path stay the same.
  - The native app can import the Electron settings.
- **Side by side would need a second bundle id and name.** The two copies would also fight over control-server port 47847, both drive Discord presence, and both claim the media keys. That doubles the support surface for little gain.

### Asset naming (load-bearing)

Updaters already in users' hands pick the first `.dmg` containing `arm64` whose name carries the desktop version (`pickInstaller`, `src/core/update-release.ts`).
- The Electron DMG keeps its current name, `Cascade-<desktop>-arm64.dmg`.
- The native DMG is named **without `arm64`**, for example `Cascade-Native-<mac>.dmg`.

Every Electron updater ever shipped therefore keeps getting Electron and can never be handed the native app by accident. The native app is arm64-only, like the current build, and says so on the release page.

### versions.json and the updaters

- **versions.json** gains a `mac` key for the native version, beside `desktop` (Electron, all three OSes). Example: `{ "desktop": "2.4.0", "mac": "2.4.0", "apple": ..., "android": ... }`. The two versions can differ when only one Mac build changed.
- **Mac build preference:** both apps read a store key, `macBuild` (`electron` | `native`).
- **Bridge Electron release (ships first):**
  - Settings > About gets "Try the native Mac app".
  - It sets `macBuild = native`, then makes `desktopBuildOf` / `pickInstaller` read `mac` and the `Cascade-Native-` asset.
  - It then runs the existing download, sha256 check and in-place swap.
  - With the preference unset, nothing changes.
- **Native app:**
  - Its updater follows `mac` by default.
  - Settings > About gets "Switch back to the Electron build". That downloads `Cascade-<desktop>-arm64.dmg` for the current `desktop` version and swaps through the same Swift installer.
- **Settings across a switch:**
  - Electron to native: the one-shot import above.
  - Native back to Electron: write the shared keys back into `config.json` with the same mapping run in reverse.
  - Keep the mapping as one bidirectional table in `ElectronSettingsImport.swift`, tested both ways. Then nothing set in either app is lost by switching back.
  - The Electron `config.json` is never deleted.

### Release tooling

- **`src/core/release-plan.ts`:** add a `mac` platform.
  - Its `PLATFORM_FILES` pattern is `Cascade-Native-*.dmg`.
  - `platformOf` must test `mac` before `desktop`, because desktop's `*.dmg` would also match.
  - Changed paths under `apple/` mean `apple` and `mac`.
  - Carry-over works per platform, as it already does: a release that rebuilds only Electron carries over the last published native DMG, and vice versa.
- **`build.yml`:** add a `build-mac-native` job on `xcode-27`.
  - `xcodegen`, then `xcodebuild archive -scheme CascadeMac`, then `codesign --force --deep --sign -` and `--verify --strict`.
  - `hdiutil create` produces `Cascade-Native-<ver>.dmg`.
  - Keep the Electron `build-mac` job unchanged.
- **Publishing:**
  - `publish.yml` mirrors the native DMG to `mac/<ver>/`.
  - `site-data.ts` lists both, labelled "Mac (native)" and "Mac (Electron)".
- **`CHANGELOG.md`:** gains a `### Mac` section beside `### Desktop`, read by the native updater's notes.

### Defaults and sunset

1. **Beta.** The native DMG ships as a `[BETA]` prerelease, mac only. Electron stays the default download and the default update. The bridge release's "Try the native Mac app" is the only way in.
2. **Parity reached** (`apple/MAC-PARITY.md` all ticked, and a few stable releases without regressions):
   - The website and README make the native DMG the primary Mac download, with Electron listed as "Classic".
   - Existing Electron users get a one-time, dismissible in-app offer to switch. They are never switched automatically.
3. **Sunset Electron on Mac**, announced at least two minor releases ahead:
   - Stop building the Electron DMG and retire the Electron `build-mac` job and `scripts/build-apple-translate.js`.
   - The bridge updater then sends remaining Electron Mac users to the native DMG, because no Electron DMG matches any more.
   - Windows and Linux keep Electron.
4. **Cost while both ship:**
   - One extra macOS runner job per release.
   - About 120 MB more per release on GitHub, and on the OCI mirror (20 versions kept).
   - Two Mac builds to triage bugs on. Bug reports need a "build: Electron/native" field in `.github/ISSUE_TEMPLATE`.
5. **Docs:** update `CODEMAP.md`, `apple/CODEMAP.md`, `README.md` and `docs/release-pipeline-plan.md` (new phase) at each step.

## Known desktop quirks: copy or fix

Decide each one explicitly rather than porting it by accident:
- `atpCreatePlaylist` seeds the now-playing track instead of the target item: **fix**.
- Clear queue does not stop or redraw: **fix**.
- Instant mix asks for 25 or 50 depending on where it starts: **unify**.
- Toasts show only in dev builds: use a native transient banner everywhere, and `showNotice` for anything that must be read.
- The miniplayer lyric lead (0.225 s) differs from the main window's (0.35 s): **one value**.
- `tctx-copy-url` always builds an Audio URL: **fix**.

## Verification

- `cd apple/CascadeKit && swift test` stays green. Every module added here (Radio, Translation, TranslationCache, ITunesArt, UpdateRelease, Changelog, ElectronSettingsImport, LRC export, bulk PlaylistEditing, the Queue persistence and meta helpers, the BrowseFilter additions) ports the cases from the matching `test/*.test.ts`.
- **Live suite:** run with `CASCADE_SERVER=... swift test` against a throwaway Jellyfin 10.11.11, extended for the radio, chapters, bulk playlist and metadata write paths. Every write checks the status code.
- **CI:** `apple.yml` builds `CascadeMac` on each push, and `build.yml`'s native job produces an ad-hoc signed DMG that passes `codesign --verify --strict`.
- **Mac UI script target (`CascadeMacUITests`):** the counterpart of `TapScript` / `RemoteScript`. It clicks by accessibility label and takes screenshots, to drive each screen without a person.
- **Parity checklist:** turn the renderer and main-process inventories into `apple/MAC-PARITY.md`, one line per feature. Tick each one off on a real Mac against the live server, side by side with the Electron app.
- **Migration test:**
  1. Install the current Electron DMG, sign in, and change settings (EQ, theme, smart playlists, Spotify links, libraries, a queue).
  2. Update to the bridge release, then switch to the native build through "Try the native Mac app".
  3. Confirm the in-place swap, every imported setting, the same DeviceId in the server's device list, and the queue restored paused.
  4. Change settings in the native app, then "Switch back to the Electron build". Confirm the swap and that the changes appear in Electron.
  5. Install an Electron updater from before the bridge against a release carrying both DMGs. Confirm it is offered and installs only `Cascade-<ver>-arm64.dmg`.
  6. Test `release-plan.ts` and `update-release.ts` with both DMG names present: `platformOf`, carry-over, `pickInstaller` per `macBuild`.
- **Integrations:**
  - `curl` all four control-server endpoints with and without the token.
  - Confirm Discord shows Listening/Watching with art and clears on pause.
  - Confirm the media keys, Control Center and the Touch Bar (in the simulator in Xcode).
  - Waterfall between the native Mac app, the Electron desktop and an iPhone in one room.
- **Performance (the reason for doing this):**
  - Record idle and playing memory, CPU and energy for Electron (from the debug panel's `app-metrics`) and for the native app (`task_info`, Activity Monitor), playing the same FLAC, with the overlay open and closed.
  - Measure gapless handover and crossfade by ear and on the player clock, as `apple/CODEMAP.md` does.
