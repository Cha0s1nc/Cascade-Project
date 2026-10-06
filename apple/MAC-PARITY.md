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
