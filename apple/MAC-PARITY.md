# Mac native parity

One line per feature in `docs/mac-native-plan.md`, as of the merge of `mac/actions` (8f21cad) plus the integrations work. Status comes from the merged sections of `apple/CODEMAP.md` and the code; "built" means the code exists and its build and tests pass, not that it was checked by eye on a real library. Notes after the dash are the caveats the CODEMAP sections record.

Status: built / partial / not built.

## Phase 1: playback

- Media keys and Control Center with artwork: built
- Output device picker, vanished-device fallback, `outputDeviceId`: built
- Volume and mute through one choke point, slider keys: built
- Last-queue restore (queue, shuffle, repeat, volume, output device): built
- Auto-mix toggle in the queue panel: built
- Sleep timer: built
- Queue panel meta line and history with Clear: built
- Radio (Live TV channels): built - verified to the route level only, the test server has no tuner
- Ownership shared by cast and Waterfall: built
- Streaming quality steps and bitrate mapping: built
- Separate Music and Video EQ profiles: built - the Video EQ taps direct streams only, an HLS transcode (such as an MKV) plays flat

## Phase 2: library and browsing

- Home (greeting, recently played, recently added, continue watching): built
- Sort and filter with per-view prefs (Favorites, Genre, Decade, Played): built - artists have no genre filter, as on the desktop
- Songs table and Shuffle All: built
- Genres, History, artist page: built
- Search including movies and shows, Command-K: built
- Library pickers, per-kind video libraries, collapsible groups, `sectionMode`: built
- Context menus item for item: built
- Permissions and admin gating: built
- Playlists (drag reorder, bulk edit, choke point, Save as a Playlist): built
- Smart playlists in the desktop's storage shape: built
- Devices panel: built
- Waterfall modal and relay and guest settings: built

## Phase 3: Now Playing, lyrics, theme

- Overlay with queue and lyrics panels, idle fade: built
- Background with light-theme ranges and tuning: built
- Lyrics view, side panel, source pill and forced source, plugin notice: built
- Spotify link sheet and credit links: built
- Mouse wheel manual browsing: built
- Theme panel, UI font, lyric style knobs: built
- `npTuning.lyricScale`: partial - no control, import maps it onto the Lyrics page's Text size
- Playing-row EQ bars: built
- Translation (Apple only): built - only an installed language translates

## Phase 4: windows and integrations

- Miniplayer: partial - floating window, 300 wide, saved height, hover traffic lights, minimize and restore, wheel volume, Lyrics and Up Next tabs, 2.6 s fade; a restyled window rather than a true NSPanel, and none of it seen running yet
- Lyrics editor and LRC parse and export: built - LRC and enhanced LRC in CascadeKit with tests, word pills, inspector, Stamp mode, own player with speed, plugin save (request shape tested only: the test server has no plugin); no unsaved-changes prompt, not seen running yet
- Metadata editor: built
- Discord Rich Presence with iTunes art: built - checked by frame, activity, backoff and throttle tests only, never connected to a real Discord
- Cha0s Stream control server: built - run against the real port and token, all four routes with and without the token
- Touch Bar: built - compiles, not run on Touch Bar hardware or the simulator
- Debug panel: built
- Keyboard: partial - Command-K, Settings tab arrows and slider keys built; Esc closes the history and side lyrics panels, the overlay and the video player close themselves, and menus, sheets and popovers keep the system Esc
- First-run wizard: built
- Settings, six tabs, EQ panels with presets, Auto preamp, drag-point graph: built
- Client certificate (mutual TLS): built - pick a keychain identity or import a .p12 in Settings > Account and on the sign-in screen; API, covers, sockets, downloads and AVPlayer (direct and HLS) present it, checked against a local nginx with `ssl_verify_client`. Importing the same .p12 twice is handled by message only, not exercised
- `CascadeMacUITests` target: not built

## Phase 5: video

- AVPlayerView player with custom Mac controls: built
- Pickers (audio, subtitles), chapters and chapter keys: built - the test media has no chapters or subtitles, so ticks and the subtitle picker are unexercised
- Video keys, idle controls, fullscreen: built
- Remote commands do not wake the paused song during a video: built
- Audio decode check (`_armAudioDecodeCheck`): not built - deliberate, the AVFoundation profile is declarative

## Phase 6: migration, updater, release

- Settings import from Electron's `config.json`, and back: built
- Updater window, sha256 check, in-place installer, beta channel: built - a debug build never installs in place
- Switch between the Electron and native builds, `macBuild`: built
- Native DMG build, `versions.json` `mac` key, `### Mac` changelog section: built
- Real-hardware performance comparison with Electron (idle and playing memory, CPU, energy): not built - the debug panel and the `task_info` numbers it needs exist

## Personality v1 (the redesign)

The Penpot file "Cascade Personality v1" (pages SwiftUI / Mac and SwiftUI / iPhone), following the running Flutter app where it moved off the mockups. Seen on this Mac against jellyfin12 on 2026-11-21, in Dark and Light, at the default 1100x700 window.

- Colors and type: built - `App/Sources/Personality.swift` (Cx colors in Dark and Light, Flutter's lighter text3; the type tokens as `.cx(...)`, View > Zoom included). Hanken Grotesk and Inter are bundled from `flutter/assets/fonts` (one copy for both apps; their name tables now give each weight its own PostScript name). Inter is the window's default body font unless the Theme panel's UI font is set. The accent stays the theme's
- Sidebar: built - Your Cascade as Home, Library, Listening and Video groups with every section at once (picking one switches the Music / Video mode, which search still reads), accent-tint rows, Downloads and Settings at the foot. The Music / Video picker is gone from the toolbar. Rediscover not yet (no page)
- Title bar: built - on bg, with the centered "Search your library" field and its shortcut. Back and forward buttons not yet
- Player bar: built - surface with a top line, 48 pt art, the solid accent play button, a 4 pt scrubber, the track-colored volume bar
- Home: built - one Home for both modes: greeting, the voice line (HomeVoice, worded as Flutter's), Recently played as the Home card (Last played, Previously queued from the restore offer, which no longer shows in the corner on Home, or Now playing, with the art stack behind it) beside eight song tiles, Continue watching, Recently added. The card's "From <playlist>" line is missing (the player does not keep where a queue came from), and there is no Rediscover shelf
- Now Playing: built - the Player bar stays layout (the default, as the Penpot "Mac / Now Playing" board and Flutter's `bar`): between the title bar and the player bar, the art stack with the next songs behind, the title (opens the album), artist and album links, the quality line (NowPlayingQuality, Flutter's qualityOf with AAC for a transcode), and lyrics or the queue on the right. The player bar's Lyrics and Queue open it on that panel or close it, the bar itself toggles it, its cover steps aside while it shows, and the side lyrics panel moved to a button of its own. The old full-window look is the Controls under the art layout. Both under Flutter's `nowPlayingLayout` key, picked in the Theme panel beside Flutter's "Show what's next behind the art" (`showArtStack`). Seen on jellyfin12 with a queue loaded paused (the `load` step of `-cascade.debugNP`), with and without album-art accent. Flutter's Focus layout not built (a stored `focus` reads as the player bar layout). Lyrics keep the system font, as Flutter's renderer does, not the board's Hanken Grotesk
- Not restyled yet: every other page, Settings, the miniplayer, and the iPhone and Apple TV apps (they get the tokens and fonts, nothing else yet)
- Changed on purpose, as Flutter's desktop does: no Music / Video picker in the toolbar (the sidebar shows both, search covers both); the Mac's Home no longer has Recent Playlists and Frequently Played, and Video Home (Recently Added Movies and Episodes) is not reachable from the Mac
- Known gap: the sidebar is buttons now, not a List, so arrow keys no longer move through it; Tab reaches the rows only with Full Keyboard Access on

