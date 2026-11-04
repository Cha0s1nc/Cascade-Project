# Flutter parity

One line per feature in `docs/flutter-plan.md`. Status: built / partial / not built. "Built" means the code exists and `flutter analyze` and `flutter test` pass; notes after the dash say what was seen running and where (W: Windows VM, L: Linux VM, A: the Fire HD 8).

## Phase 0: foundation

- Folder layout (core, engine, platform, ui): built
- Full Jellyfin client (merged and paged requests, checked writes): built - merged, grouped and paged queries, the cross-library dedupe and read error messages, tested against the desktop's own cases; not yet run against a server since the port
- Settings store with electron-store key names: partial - `libraryIds`, `movieLibraryIds` and `showLibraryIds` are read; nothing writes them until Settings exists
- Library selection: partial - saved choices applied with the desktop's rules; no picker yet
- Permissions: built - the user's policy, `canDelete` and `canDownload`; nothing is gated on them yet
- Desktop back and forward history: built - per-tab history ported from `nav-history.ts`, plus Forward, the mouse's side buttons and Alt+Left/Right; the pages themselves are phase 2
- Phone per-tab navigation: built - Android's Back walks the tab, then goes Home, then leaves; not yet tried on A
- Linux build: built - seen starting on L
- `flutter` in the root `npm test`: built

## Phase 1: playback engine

- Two decks, preload, equal-power crossfade, skip fade: built - heard on W and A
- Playback reports and resume points, `CASCADE_NO_REPORTS`: not built
- Stream negotiation, transcoding, quality: not built - plays the original file
- Crossfade setting, auto-mix: not built - fixed 1 s
- Normalization: not built
- Music and video EQ with presets: not built
- Output device picker: not built
- Last-queue restore: not built
- Sleep timer: not built
- Radio: not built
- Windows media controls and keys: built - seen on W
- Linux MPRIS: not built
- Android notification, lock screen, background: built - seen on A
- Shared ownership with cast and Waterfall: not built

## Phase 2: library and browsing

- Home: built - seen on W and A
- Albums, Artists, Songs, Playlists, Genres, History: not built
- Movies, TV Shows: not built
- Sort and filter with per-view preferences: not built
- Album, artist and playlist pages: not built
- Search and Ctrl+K: not built
- Context menus: not built
- Admin gating: not built
- Playlist editing, Save as a Playlist: not built
- Smart playlists: not built
- Favorites and played state on the server: not built - Like is local
- Library pickers and grouping: not built
- Devices panel and remote control: not built
- Waterfall: not built

## Phase 3: Now Playing, lyrics, theme

- Now Playing with queue and lyrics panels: not built
- Art background and tuning: not built
- Lyrics sources and karaoke rendering: not built
- Translation: not built
- Theme panel, presets, server style, fonts: not built
- Customization editor and Style Tuning: not built
- Announcements: not built - the bell is a placeholder

## Phase 4: windows and integrations

- Miniplayer: not built
- Lyrics editor: not built
- Metadata editor: not built
- Discord Rich Presence: not built
- Cha0s Stream control server: not built
- Keyboard shortcuts: partial - Ctrl+K focuses search
- First-run wizard: not built
- Full Settings: not built - account and Sign out only
- Client certificates and custom headers: not built
- Debug panel: not built

## Phase 5: video

- Video player with Cascade's controls: not built
- Audio and subtitle pickers, chapters, trickplay: not built
- Skip Intro, resume, next episode: not built

## Phase 6: offline and Local mode

- Downloads and the download manager: not built
- Offline Mode (four phases): not built
- Local mode: not built

## Phase 7: release

- Windows installer, Linux package, Android APK: not built - local builds only
- Updater: not built
- Versions in lockstep, release marker, changelog: not built
- Settings import from Electron: not built
