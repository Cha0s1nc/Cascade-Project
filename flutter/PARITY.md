# Flutter parity

One line per feature in `docs/flutter-plan.md`. Status: built / partial / not built. "Built" means the code exists and `flutter analyze` and `flutter test` pass; notes after the dash say what was seen running and where (W: Windows VM, L: Linux VM, A: the Fire HD 8). Last checked against the code on 2026-11-15 (9afc986).

## Phase 0: foundation

- Folder layout (core, engine, platform, ui): built
- Full Jellyfin client (merged and paged requests, checked writes): built - merged, grouped and paged queries, the cross-library dedupe and read error messages, tested against the desktop's own cases; not yet run against a server since the port
- Settings store with electron-store key names: partial - `libraryIds`, `movieLibraryIds` and `showLibraryIds` are read; nothing writes them until Settings exists
- Library selection: partial - saved choices applied with the desktop's rules; no picker yet
- Permissions: built - the user's policy, `canDelete` and `canDownload`; nothing is gated on them yet
- Desktop back and forward history: built - per-tab history ported from `nav-history.ts`, plus Forward, the mouse's side buttons and Alt+Left/Right; the pages themselves are phase 2
- Phone layout: built - Music and Video modes (browseMode key) with their own navigation bars, the Library tab's rows into every view, search with its own field, the same pages as desktop at phone width; Home, Library, Artists and Settings seen on A
- Phone per-tab navigation: built - Android's Back walks the tab, then goes Home, then leaves; not yet tried on A
- Linux build: built - seen starting on L
- `flutter` in the root `npm test`: built

## Phase 1: playback engine

- Two decks, preload, equal-power crossfade, skip fade: built - heard on W and A; a skip fades the old song from the press (10 ms quarter-cosine) and other song changes over 60 ms, heard on W
- Playback reports and resume points, `CASCADE_NO_REPORTS`: built - start, progress and stop seen in jellyfin12's log from A with the right positions; the switch is a setting ("Do not report playback") and the environment variable
- Stream negotiation, transcoding, quality: built - direct play and 128 kbps transcodes seen on A (the server's ffmpeg), starting mid-track through StartTimeTicks; a skipped transcode is stopped on the server. Unlike the desktop, a transcode is progressive MP3, not AAC over HLS: mpv rejected Jellyfin 12's HLS stream
- Crossfade setting (1-15 s, off): built - not heard yet; off still keeps a 1 s overlap to hide the gap
- Auto-mix: built - not seen running
- Normalization (track or album): built - not heard yet
- Music EQ with presets: built - mpv lavfi filters with the desktop's bands and presets; not heard yet
- Video EQ: built - the Video graph in Settings > Equalizer applies to videos; not heard yet
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

- Personality v1 theme (colors, type, bundled fonts): built - seen on W, L and A. Since then a Light mode and System (follows the OS, live) in the Style menu, repainting in place; in the build tested on W
- In-line title bar (Windows, Linux): built - window_manager hides the OS bar, Cascade draws the window buttons; the Linux runner always uses a hidden header bar so GTK keeps the shadow and resize edges; seen on W (caption buttons) and L (round buttons, Cinnamon). Windows 11's snap layouts flyout on Maximize is not there (it needs native hit testing)
- Home: built - seen on W and A
- Albums, Artists, Songs, Playlists, Genres, History: built - Artists seen on A against the test server; the rest not yet looked at on a device. Albums, artists and songs are cached on disk per server, user and library choice and refreshed with only what changed
- Movies, TV Shows: partial - poster grids and movie and series pages with seasons and episodes; playing them waits for the video player (phase 5)
- Sort and filter with per-view preferences: built - albums, artists and playlists under the desktop's store keys (albumsPrefs and so on), songs under songsSort
- Album, artist and playlist pages: built on desktop - album with discs and format, artist with top songs, bio, albums, appears on and similar artists
- Search and Ctrl+K: built on desktop - typing in the title bar opens Search; songs, albums, artists, movies and shows. The field sits centered or tucks into a pill that widens, as on the desktop; clear button, Esc, recent searches
- Context menus: built on desktop - songs, albums, artists, playlists (right click or long press); song rows also have a More button and open the menu from the Menu key or Shift+F10
- Admin gating: partial - Delete only shows with deletion rights
- Playlist editing, Save as a Playlist: built - create, add, reorder, remove, rename and delete; Save as a playlist from Now Playing's queue
- Smart playlists: built - a row on Playlists, their page, and a rule editor; stored under the desktop's smartPlaylists key in its format
- Favorites and played state on the server: built - likes go to /UserFavoriteItems and show at once, put back if the server refuses
- Library pickers and grouping: partial - Settings > Library switches for music, movie and show libraries (same store keys; the last music library cannot be turned off; a server with only video hides the music side); Movies and TV Shows with two or more libraries chosen show a section per library that folds away (the desktop's collapsedLibs key), not yet seen with such a server; the desktop's single-library mode for music not yet
- Devices panel and remote control: built - send the queue to another Jellyfin client and drive it; and the other way, the command socket lets the dashboard and other apps control this one (seen on L: controllable session, a dashboard message shown)
- Waterfall: built - create or join a room on the shared relay, the host's queue and position followed by guests (placeholders for songs a guest cannot see), guest additions and guest control as the host allows; seen with W hosting and L joining, both playing in step
- Rediscover (new, not a parity item): built on desktop - Used to love, Never played, Forgotten favorites, the daily reshuffle and the mix; tested in core/rediscover.dart
- Queue editing (play next, add to queue, remove, move, clear): built in the player - also Move up and down by keyboard (Alt+Up and Down) and Undo after removing or clearing

## Phase 3: Now Playing, lyrics, theme

- Now Playing with queue and lyrics panels: built (all three desktop layouts seen on L, the bar layout on W, the phone view on A) - desktop layer with the three layouts (player bar stays, controls under the art, Focus with idle hiding), the phone's full screen view with Lyrics, Queue and More; the queue reorders, removes, clears and saves as a playlist. Since then, seen on W: it slides up and back down, the player bar's cover steps aside, title, artist and album open their pages, hovering the cover shows Favorite, Add to playlist and View album, the Lyrics and Queue switch only shows in the layout without a player bar, and the cover changes by the Style menu's choice (Toss by default; push, fade, none)
- Art background and tuning: partial - the blurred cover behind Now Playing with Background dim and a color fade between songs; lyric dimming, blur, past scale and the follow position come from shared/tuning-defaults.json (desktop column on desktop, iPhone column on phones); album color extraction (the albumColors tuning section) not yet
- Lyrics sources and karaoke rendering: built (LRCLIB seen on L and W, SpicyLyrics word by word on L, A and W) - SpicyLyrics through Cascade Server, Kugou (KRC decrypted in Dart), LRCLIB and Jellyfin raced like the desktop, forced source from the pill, background vocals and duets, the next song's lyrics fetched ahead. Drawn as the desktop draws them: its spring, looks by distance, ripple, the soft-edged word wipe and lift, and held notes that swell letter by letter; a wheel or drag moves the sheet and it springs back. Server-only mode and the app-side SpicyLyrics key not yet
- Translation: not built
- Theme panel, presets, server style, fonts: partial - the Style menu replaces the Theme page: it opens inside Now Playing beside the live lyrics with Appearance, Now Playing, Lyrics, Crossfade (with a cover animation preview) and Presets tabs, Reset this tab and Undo; seen on W. Presets shares a look as text (copy, paste); named presets, server style and a font choice not yet
- Customization editor and Style Tuning: partial - the lyric knobs live in the Style menu's Lyrics tab, stored under lyricStyle; album color knobs not yet
- Announcements: built - the site's announcements (cached for offline starts) and Cascade Server's, with seen and dismissed kept under the desktop's keys

## Phase 4: windows and integrations

- Miniplayer: partial - the main window shrinks to a small always-on-top player and back; not a second window as on the desktop; not yet seen on a device
- Lyrics editor: not built
- Metadata editor: not built
- Discord Rich Presence: built - Discord's IPC on a Windows named pipe or a Linux socket (plain, Flatpak, Snap), off by default as on the desktop; no cover art yet
- Cha0s Stream control server: not built
- Keyboard shortcuts: built - Space, Ctrl+arrows (songs, volume), Ctrl+K or F, Alt+arrows (history, queue moves), Esc, Delete, Ctrl plus, minus and 0 (interface size), and ? for the full list (also in Settings > About); they work in the phone layout on a computer too. Not checked against the desktop's full list
- First-run wizard: built - after the first sign-in: libraries (when there is a choice), crossfade, streaming quality and the Now Playing look; not yet seen on a device
- Full Settings: partial - Electron's six tabs as pill tabs with sliding panes and group cards, plus an Equalizer group with the desktop's graph editors; Library (pickers, Radio, scan, refresh), Playback (crossfade, quality, normalization, EQ, output, auto-mix, auto-skip, sleep, Now Playing layout and art stack), Lyrics (source), Integrations (Discord switch only), Account (sign out after asking, Quick Connect approve with a six-digit field), About; tips, messages and client certificates not yet
- Client certificates and custom headers: partial - reverse proxy headers on the sign-in screen and in Settings > Account (the desktop's customHeaders key and rules), sent with every request to the server (API, images, streams, downloads, the remote socket) and nowhere else; not yet tried behind a real proxy. Client certificates not built: Dart cannot use the OS certificate store as Electron does, so it needs a certificate file
- Debug panel: partial - Settings > About shows and copies the recent log; the desktop's live tuning knobs are the Style menu's

## Phase 5: video

- Video player with Cascade's controls: built (seen on W: resume, subtitles, chapter marks, Esc; reports stayed off) - media_kit video, direct play only (no transcode fallback yet), resume, reports, the desktop's keys, full screen
- Audio and subtitle pickers, chapters, trickplay: partial - the file's own audio and subtitle tracks and chapter marks with Ctrl+arrows; external subtitle files and trickplay thumbnails not yet
- Skip Intro, resume, next episode: built - from /MediaSegments, with the auto-skip setting; next episode on outro, near the end and at the end

## Phase 6: offline and Local mode

- Downloads and the download manager: built - kept as the desktop's offline catalog (collections, each item's library from its ancestors, covers, the user); original files, one at a time; seen on L; video downloads and stored lyrics not yet
- Offline Mode (four phases): partial - manual switch (offlineMode key) and the unreachable fallback with a backoff probe; the library is answered from the catalog by the shared query engine; likes queue and sync back with the per-item rule, plays queue and replay only when the history snapshot still matches; server-only features hidden. Seen on L: manual on, Home and album from the catalog, playing the file, a like queued then sent when switched off, and the fallback with the server unreachable. Not yet: offline lyrics, video, resume positions, the held-plays prompt, the storage limit
- Local mode: not built

## Across the app

Not phase items in the plan, but built since and worth tracking.

- Electron's look: built - the desktop's glass page buttons (Buttons setting: overlay, push, labeled), the player bar's brighten-on-hover buttons, the song's format, bit depth, sample rate and bitrate in Now Playing, the sidebar's three modes (expanded, slide-out rail, icon rail), pages that slide by direction; seen on W and L
- Interface size: built - 80 to 150 percent, everything scales together; seen on W
- Window sizes: built - a test opens every main screen at 13 sizes from 420x520 (phone layout on a computer) to 2560 wide and at 150 percent; checked on L
- Keyboard and screen readers: built - every button and row in the Tab order with a focus ring, labels for screen readers, "Now playing" announced, focus moves to a new page, 44 px touch targets. Closing a dialog with a screen reader on crashed Windows and macOS (Flutter 3.44's Slider portals broke the engine's tree); every Slider now goes through safeSlider and a test guards it; seen on W with Narrator
- Reduce motion: built - follows the system or the Style menu's Auto, On, Off; slides become fades and the lyrics step without the spring
- Contrast: built - dim text at 4.5:1 or better on every surface, in both modes

## Phase 7: release

- Windows installer, Linux package, Android APK: not built - local builds only
- Updater: not built
- Versions in lockstep, release marker, changelog: not built
- Settings import from Electron: built - Settings > About copies the desktop app's config.json settings (not its sign-in) and asks for a restart
