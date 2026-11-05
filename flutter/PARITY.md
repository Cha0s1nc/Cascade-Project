# Flutter parity

One line per feature in `docs/flutter-plan.md`. Status: built / partial / not built. "Built" means the code exists and `flutter analyze` and `flutter test` pass; notes after the dash say what was seen running and where (W: Windows VM, L: Linux VM, A: the Fire HD 8).

## Phase 0: foundation

- Folder layout (core, engine, platform, ui): built
- Full Jellyfin client (merged and paged requests, checked writes): built - merged, grouped and paged queries, the cross-library dedupe and read error messages, tested against the desktop's own cases; not yet run against a server since the port
- Settings store with electron-store key names: partial - `libraryIds`, `movieLibraryIds` and `showLibraryIds` are read; nothing writes them until Settings exists
- Library selection: partial - saved choices applied with the desktop's rules; no picker yet
- Permissions: built - the user's policy, `canDelete` and `canDownload`; nothing is gated on them yet
- Desktop back and forward history: built - per-tab history ported from `nav-history.ts`, plus Forward, the mouse's side buttons and Alt+Left/Right; the pages themselves are phase 2
- Phone layout: built - Music and Video modes (browseMode key) with their own navigation bars, the Library tab's rows into every view, search with its own field, the same pages as desktop at phone width; not yet tried on A
- Phone per-tab navigation: built - Android's Back walks the tab, then goes Home, then leaves; not yet tried on A
- Linux build: built - seen starting on L
- `flutter` in the root `npm test`: built

## Phase 1: playback engine

- Two decks, preload, equal-power crossfade, skip fade: built - heard on W and A
- Playback reports and resume points, `CASCADE_NO_REPORTS`: built - start, progress and stop seen in jellyfin12's log from A with the right positions; the switch is a setting ("Do not report playback") and the environment variable
- Stream negotiation, transcoding, quality: built - direct play and 128 kbps transcodes seen on A (the server's ffmpeg), starting mid-track through StartTimeTicks; a skipped transcode is stopped on the server. Unlike the desktop, a transcode is progressive MP3, not AAC over HLS: mpv rejected Jellyfin 12's HLS stream
- Crossfade setting (1-15 s, off): built - not heard yet; off still keeps a 1 s overlap to hide the gap
- Auto-mix: built - not seen running
- Normalization (track or album): built - not heard yet
- Music EQ with presets: built - mpv lavfi filters with the desktop's bands and presets; not heard yet
- Video EQ: not built - waits for video (phase 5)
- Output device picker with fallback: built - lists mpv's devices, follows the system default while the chosen one is missing; not tried with a second device
- Last-queue restore: built - seen on A, including mid-track on a transcode and after the server was unreachable at launch
- Reconnect when the server comes back: built - tested; seen on A
- Sleep timer: built - not seen firing
- Radio (Live TV channels): built - requests only; the test server has no Live TV
- Windows media controls and keys: built - seen on W
- Linux MPRIS: built - registers on L's session bus; not yet driven from the desktop's media widget
- Android notification, lock screen, background: built - seen on A
- Shared ownership with cast and Waterfall: not built - waits for devices and Waterfall (phase 2)

## Phase 2: library and browsing

- Personality v1 theme (colors, type, bundled fonts): built - desktop shell, pages and the phone's Home; not yet seen on a device
- In-line title bar (Windows, Linux): built - window_manager hides the OS bar, Cascade draws the window buttons; the Linux runner always uses a hidden header bar so GTK keeps the shadow and resize edges; not yet run on W or L. Windows 11's snap layouts flyout on Maximize is not there (it needs native hit testing)
- Home: built - seen on W and A
- Albums, Artists, Songs, Playlists, Genres, History: built on desktop - not yet run against a server; the phone's Library is next
- Movies, TV Shows: partial - poster grids and movie and series pages with seasons and episodes; playing them waits for the video player (phase 5)
- Sort and filter with per-view preferences: built - albums, artists and playlists under the desktop's store keys (albumsPrefs and so on), songs under songsSort
- Album, artist and playlist pages: built on desktop - album with discs and format, artist with top songs, bio, albums, appears on and similar artists
- Search and Ctrl+K: built on desktop - typing in the title bar opens Search; songs, albums, artists, movies and shows
- Context menus: built on desktop - songs, albums, artists, playlists (right click or long press)
- Admin gating: partial - Delete only shows with deletion rights
- Playlist editing, Save as a Playlist: partial - create, add, reorder, remove, rename and delete; Save as a Playlist (from the queue) not yet
- Smart playlists: not built - the rules are ported (core/smart_playlist.dart) with tests
- Favorites and played state on the server: built - likes go to /UserFavoriteItems and show at once, put back if the server refuses
- Library pickers and grouping: partial - Settings > Library picks music, movie and show libraries (same store keys); per-library grouping in the grids not yet
- Devices panel and remote control: partial - send the queue to another Jellyfin client from where it is, then play/pause, skip and volume there; being controlled from other apps (the remote control socket) not yet
- Waterfall: not built
- Rediscover (new, not a parity item): built on desktop - Used to love, Never played, Forgotten favorites, the daily reshuffle and the mix; tested in core/rediscover.dart
- Queue editing (play next, add to queue, remove, move, clear): built in the player

## Phase 3: Now Playing, lyrics, theme

- Now Playing with queue and lyrics panels: built - desktop layer with the three layouts (player bar stays, controls under the art, Focus with idle hiding), the phone's full screen view with Lyrics, Queue and More; the queue reorders, removes, clears and saves as a playlist
- Art background and tuning: partial - the blurred cover behind Now Playing; lyric dimming, blur, past scale and the follow position come from shared/tuning-defaults.json (desktop column on desktop, iPhone column on phones); album color extraction and the background knobs not yet
- Lyrics sources and karaoke rendering: built - SpicyLyrics through Cascade Server, Kugou (KRC decrypted in Dart), LRCLIB and Jellyfin raced like the desktop, forced source from the pill, word fill (a word fades as a whole, not letter by letter), background vocals and duets; server-only mode and the app-side SpicyLyrics key not yet
- Translation: not built
- Theme panel, presets, server style, fonts: not built
- Customization editor and Style Tuning: not built
- Announcements: built - the site's announcements (cached for offline starts) and Cascade Server's, with seen and dismissed kept under the desktop's keys

## Phase 4: windows and integrations

- Miniplayer: not built
- Lyrics editor: not built
- Metadata editor: not built
- Discord Rich Presence: built - Discord's IPC on a Windows named pipe or a Linux socket (plain, Flatpak, Snap), off by default as on the desktop; no cover art yet
- Cha0s Stream control server: not built
- Keyboard shortcuts: partial - Ctrl+K focuses search
- First-run wizard: not built
- Full Settings: partial - Electron's six tabs; Library (pickers, Radio, scan, refresh), Playback (crossfade, quality, normalization, EQ, output, auto-mix, auto-skip, sleep, Now Playing layout and art stack), Lyrics (source), Integrations (Discord switch only), Account (sign out, Quick Connect approve), About; tips, messages, custom headers and client certificates not yet
- Client certificates and custom headers: not built
- Debug panel: not built

## Phase 5: video

- Video player with Cascade's controls: built - media_kit video, direct play only (no transcode fallback yet), resume, reports, the desktop's keys, full screen
- Audio and subtitle pickers, chapters, trickplay: partial - the file's own audio and subtitle tracks and chapter marks with Ctrl+arrows; external subtitle files and trickplay thumbnails not yet
- Skip Intro, resume, next episode: built - from /MediaSegments, with the auto-skip setting; next episode on outro, near the end and at the end

## Phase 6: offline and Local mode

- Downloads and the download manager: built - original files from /Items/{id}/Download, one at a time, a Downloads page by album, Download in the song and album menus and headers; the player plays a downloaded song from its file; video downloads not yet
- Offline Mode (four phases): partial - the rules are ported with the shared fixtures (offline-mode, offline-sync, offline-index, offline-query, offline-video, local-user-data); the app does not switch to them yet
- Local mode: not built

## Phase 7: release

- Windows installer, Linux package, Android APK: not built - local builds only
- Updater: not built
- Versions in lockstep, release marker, changelog: not built
- Settings import from Electron: not built
