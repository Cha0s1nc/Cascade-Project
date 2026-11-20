# Flutter app plan

## Context

Decided 2026-11-03:

- **What:** a Flutter Cascade for Windows, Linux and Android, in `flutter/`. The Swift app in `apple/` stays the Apple client.
- **Alongside Electron, not replacing it.** Electron stays the main desktop app with no retirement date. That means three copies of the app logic for a while (TypeScript, Swift, Dart), which is why the shared test fixtures below matter.
- **Full parity first.** Nobody is expected to rely on the Flutter app until it does everything Electron does. Each phase still lands runnable and checked on the test devices, so problems surface as they happen, not at the end.

Where it starts (`0179654`, `12a3de7`): the redesigned Home from the Figma draft (https://www.figma.com/design/5jCQuhu85omAoJsBRC57rs) in a desktop and a phone layout picked by window width; Quick Connect sign-in; Home from the server; playback through media_kit (libmpv) on two decks with a 1 s equal-power crossfade and a 0.3 s skip fade; Windows media controls (smtc_windows) and Android background playback (audio_service). It sends no playback reports yet, Like is local only, and every page but Home is a placeholder.

The feature list is the Swift port's: `docs/mac-native-plan.md`, phase by phase, tracked one line per feature in `flutter/PARITY.md` the way `apple/MAC-PARITY.md` tracks the Mac.

## Architecture

- **Folders in `flutter/lib/`:**
  - `core/`: plain Dart, no widgets. The Jellyfin client, models, and ports of the desktop's rules in `desktop/src/core/` (queue, permissions, browse mode, offline sync and query, smart playlists, normalization, EQ profiles, lyrics parsing, Waterfall protocol). Tested with `flutter test`, against `shared/fixtures/` where a fixture exists, as CascadeKit is.
  - `engine/`: playback. The two media_kit decks, crossfade, EQ (mpv's `af` with lavfi filters), normalization, playback reporting, video.
  - `platform/`: the OS seams. Media controls (SMTC on Windows, MPRIS on Linux, audio_service on Android), extra windows, Discord, the control server.
  - `ui/`: the desktop and phone shells, their views, and the shared widgets.
- **Source of truth for behavior:** the desktop's `src/core/` and `renderer.js`. Where CascadeKit already ported a rule to Swift, that port is the second reference. Rules port with their tests.
- **State:** `ChangeNotifier` with `InheritedNotifier`, as now. No state management package unless this measurably stops working.
- **Persistence:** `shared_preferences`, using electron-store's key names where they exist, so importing Electron's `config.json` is a straight mapping (the Swift app did the same).
- **Identity:** `Client="Cascade Flutter"` on every OS, `Device` the machine (`Windows`, `Linux`, `Android`), following the edition labels in `CODEMAP.md`.
- **Testing against servers:** the jellyfin12 copy for anything that plays or writes. A `CASCADE_NO_REPORTS` switch (like the Swift app's `-cascade.noReports`) turns playback reports off, so a test run on the real server cannot touch history or resume points.
- **Test devices:** Windows on `winvm`, Linux on `mintvm`, Android on the Fire HD 8 (8th gen, Fire OS 7, Android 9) over USB with `adb reverse` to the test server. `flutter test` runs from the root `npm test` as `flutter`.

## Design

Decided 2026-11-04: the Flutter app takes the **Personality v1** look, the same one the Swift app is moving to, so Cascade has one brand instead of three. The mockups are in Penpot (https://penpot.hp.chaosinc.xyz, file "Cascade Personality v1", page "Flutter"): the chosen boards are "Flutter / Desktop / Home (Windows)", "(Linux)" and "Flutter / Android / Home (Personality v1)". The boards marked "not chosen" are the look the app has today (the Figma draft's palette in `flutter/lib/ui/widgets.dart`).

- **Layouts stay.** The desktop shell (top bar, sidebar, rounded panels, player bar) and the Android shell (search bar, five-tab navigation bar, mini player) keep their structure. What changes is color, type and a few Personality v1 touches.
- **Colors and type come from the shared design, not from `widgets.dart`.** The Penpot library colors under `Cascade` (`bg` `#0A0E13`, `surface`, `surface-2`, `accent` `#7CC4FF`, `accent-tint`, `ink` and the rest) and the type tokens (`font.display`, now Hanken Grotesk, for headings and lyrics; `font.body` for everything else) are the source. When they change in Penpot, they change for both apps.
- **The Home card has two states.** When a queue was saved (last-queue restore, phase 1), it reads "Previously queued": the song you stopped on, where the queue came from and how many songs are left ("From Late Night Drive · 12 left"), Resume and Shuffle, and the stepped art stack with the queue's next songs falling in behind the current art. When the last thing was a single song with no queue, it reads "Last played" with that song's plain art and Play. The stack only ever shows real queue items, never decoration.
- **Personality v1 touches:** the solid accent Play button with dark text, accent-tint for the active sidebar row and Android's nav indicator, and copy with a voice ("4,212 songs on your server. 61 of them played this week.").
- **Rediscover** is a new feature, not a parity item, specified here for all the apps. It needs nothing new on the server: it works from the play counts and last-played dates Jellyfin keeps per song, rolled up per album.
  - Used to love: albums played 20 times or more that haven't been played in a year.
  - Never played: albums in the library six months or more with no plays.
  - Forgotten favorites: liked songs and albums not played in six months.
  - A page with those three shelves, a sidebar entry, a Home shelf (Used to love), and a "Rediscover mix" that shuffles across all three. The shelves reshuffle daily. "On this day" is out: Jellyfin keeps only the last play and a count, not a history; the CascadeServer plugin could start recording plays later, without the past.
- **Android keeps Music and Video as separate modes,** like the Swift iPhone app: a button in the top bar switches them, and the navigation bar follows the mode (Music: Home, Library, Downloads, Settings; Video: Home, Movies, Shows, Downloads, Settings).
- **Settings uses Electron's six tabs** on every Flutter platform: Library, Playback, Lyrics, Integrations, Account, About. On desktop Settings is a page in the main window, not a separate window, the same as the Swift Mac app.
- **Now Playing has one way in on each platform.** Desktop: a layer over the window body that slides up from the player bar (title bar and player bar stay), with the art stack on the left and a Lyrics/Queue switch on the right; Esc, the close button or the mouse's back button closes it, before Back navigates. Android: a full-screen view from the mini player, closed by the back gesture, with Lyrics, Queue, Devices, Sleep and More (Add to playlist, Go to album, Go to artist, Download, Sleep timer, Equalizer, Listen together, Song info).
- **The stepped art stack is a setting,** "Show what's next behind the art", on by default, in Settings and in Now Playing's customize panel. Off, the art stands alone everywhere the stack appears (Now Playing, the Home card). With an empty queue it is a single cover either way. One stored key for every app, like the rest of the theme settings.
- **Now Playing layouts,** a setting with a few presets rather than free-form layout. Each preset multiplies testing across three apps, so ship the first three and add more only when someone asks:
  1. **Player bar stays** (default, as in the mockups, and like Spotify's Now Playing view): the layer covers the window body; the player bar and its controls stay at the bottom.
  2. **Controls under the art** (Electron today, Apple Music's full-screen player): the layer covers the whole window including the player bar, and the transport and seek bar move up under the art. Opening animates the bar's controls up into place; closing drops them back.
  3. **Focus**: lyrics take the window, with small art or none; controls hide after `controlsIdleSeconds` (already tuned at 3 s on desktop) and come back on mouse movement.
  - Later, if wanted: **Side panel** (Spotify's right-hand Now Playing panel; the Swift Mac app's lyrics side panel already works this way), a resizable panel beside the library instead of a takeover; and **Cover**, a big-art view with minimal text for listening across the room, which is where a visualizer would go.
  - Phones keep one layout with the controls in the thumb zone at the bottom; the setting there is only art size (large art, or compact art for more lyrics).
  - The layout setting and the art stack toggle apply to the Swift apps too, with the same stored keys, so a layout looks the same wherever it exists.
- **Lyrics and motion start from the tuned values** in `shared/tuning-defaults.json` (past and upcoming line opacity and blur, unsung word opacity, current line position). Flutter gets its own key there rather than copied numbers.
- **The full screen set** (desktop library pages, album, artist and playlist pages, Search, History, Radio, Rediscover, Downloads, Movies, TV Shows, Settings, Sign in, Server unreachable, Now Playing with lyrics and with the queue, and the Controls under the art and Focus layouts; Android Home, Library, Album, Search, Video Home, Settings, Now Playing, its More sheet and Lyrics) is on the Penpot Flutter page. The Linux desktop boards differ only in the window buttons.
- **In-line title bar on Windows and Linux,** as Electron does with `titleBarOverlay`: Cascade's top bar is the window's title bar, with no OS bar above it.
  - The OS still draws the window buttons: on Windows, minimize, maximize and close in the top right (138 px); on GNOME, round buttons (about 108 px). Other window managers vary and tiling ones show none, so the reserved space comes from the OS, not a constant (Electron uses `env(titlebar-area-width)`).
  - Empty space in the bar drags the window and a double-click maximizes it; buttons and the search field do not drag.
  - The search field stays centered on the window, so the left group matches the right group's width.
  - Today the app uses the OS frame, so this needs a hidden title bar, for example through `window_manager`, and checking on `winvm` and `mintvm` (GNOME and a non-GNOME window manager).

## Phases

### Phase 0: foundation

- Folders as above; the slice's files move into them.
- The full Jellyfin client: requests merged across the selected libraries and paged as `getMerged` and `getAllPaged` do, every write checking its response (CODEMAP rule 1), endpoints checked against the server's OpenAPI spec (rule 2).
- Settings store, library selection, permissions (admin, deletion, downloads).
- Navigation: the desktop's back and forward history, the phone's per-tab stacks.
- A Linux build on `mintvm`.
- `flutter` in the root test runner.

### Phase 1: playback engine

- Playback reports and resume points, with `CASCADE_NO_REPORTS`.
- Stream negotiation through `PlaybackInfo`, transcoding, quality steps and bitrates.
- The crossfade length as a setting (1 to 15 s, off, as on the desktop); auto-mix.
- Volume normalization; music and video EQ profiles with presets.
- Output device picker with fallback; last-queue restore; sleep timer; radio (Live TV channels).
- Media controls on all three: SMTC (done), MPRIS on Linux, Android's notification (done) and lock screen.
- Ownership of playback shared with cast and Waterfall.

### Phase 2: library and browsing

- First, before any page: Personality v1 as the default theme (the Cascade colors and type tokens, Hanken Grotesk and Inter bundled) and the in-line title bar on Windows and Linux (see Design). Every page sits on both, so doing them later would mean restyling every page.
- Albums, Artists, Songs (a table on desktop), Playlists, Genres, History, Radio, Movies, TV Shows.
- Sort and filter with per-view preferences; album, artist (bio, top songs, similar) and playlist pages.
- Search across music and video with Ctrl+K.
- Context menus item for item; permissions and admin gating.
- Playlists: create, reorder, bulk edit, Save as a Playlist; smart playlists in the desktop's storage shape.
- Favorites and played state on the server; library pickers and grouping.
- Devices panel: remote control both ways.
- Waterfall (listen together).

### Phase 3: Now Playing, lyrics, theme

- The Now Playing view with queue and lyrics panels, the art background and its tuning.
- Lyrics: the Cascade plugin's SpicyLyrics (syllable fill, duets, background vocals), then Kugou, LRCLIB and Jellyfin; the source pill and forced source; untimed lyrics.
- Translation (the desktop's local models).
- The theme panel, presets, server style, fonts; the customization editor and Style Tuning (the default theme itself lands at the start of phase 2).
- Announcements.

### Phase 4: windows and integrations

- Miniplayer (a second window), lyrics editor (see Lyrics editor below), metadata editor.
- Discord Rich Presence (Windows, Linux); the Cha0s Stream control server.
- Keyboard shortcuts, first-run wizard, the full Settings.
- Client certificates and custom headers for reverse proxies.
- Debug panel.

### Phase 5: video

- media_kit's video player with Cascade's controls; audio and subtitle pickers; chapters; trickplay; Skip Intro from media segments; resume and next episode.

### Phase 6: offline and Local mode

- Downloads and the download manager; Offline Mode's four phases (`docs/offline-mode-plan.md`), checked against `shared/fixtures/offline-*`.
- Local mode: a folder instead of a server (`docs/local-mode-plan.md`).

### Phase 7: release

- Packages: a Windows installer, Linux packages (AUR, deb, Flatpak; each must require WebKitGTK once the lyrics editor's window is in, see Lyrics editor), an Android APK.
- An updater on Windows and Linux following `src/core/update-release.ts`.
- Versions in lockstep with the other apps; a release marker and changelog section.
- Importing settings from Electron's `config.json`.

### Versions (decided 2026-11-18)

- **2.5** is the first Flutter release, shipped alongside Electron: it does not wait for strict parity. It is released before the remaining parity work, as early real-world testing (installs, the updater) finds what the VMs cannot.
- **3.0** is the release that sunsets Electron, once Flutter has full parity: a big enough change for a major version.
- What 3.0 still needs that 2.5 may lack: the lyrics editor, the metadata editor and lyrics translation (real gaps no other Jellyfin client fills, so they stay in scope), Local mode, and the rest of PARITY.md. The Cha0s Stream control server is the one personal feature; it can come last or stay Electron-only until the sunset.

### Lyrics editor (decided 2026-11-19)

One editor for every Cascade app, served by the Cascade Server plugin and opened by the apps in a window of their own. Seamless: clicking Edit lyrics opens the editor on that song, with no code to type and no second sign-in.

**The editor itself**

- A fork of [amll-dev/amll-ttml-tool](https://github.com/amll-dev/amll-ttml-tool) (GPL-3.0, the syllable-level editor), not of Spicy Lyrics' fork of it ([spicylyrics/ttml-tool](https://github.com/spicylyrics/ttml-tool), AGPL-3.0, whose network clause would bind a page the plugin serves).
- Served by the plugin as a standalone web page (something like `/CascadeServer/Editor`), so Flutter, Electron, the Swift apps and a plain browser all open the same editor. Kept out of the apps' own code, so the app-store permission in Cascade's license never has to cover it.
- It loads the song's current lyrics and audio and saves lyrics back to the server. Confirm the save route against Jellyfin 12's API or the plugin's own lyric store before building it.
- Never seeded with or saving SpicyLyrics data: its terms allow keeping it 30 days at most and forbid building an archive (the desktop's openLyricsEditorFor already refuses this).
- The plugin lists a `lyrics-editor` capability in `/CascadeServer/Info`; the apps offer Edit lyrics only when it is there.

**Opening it from Flutter**

- A separate native window with a web view, through `desktop_webview_window` (check the package is still maintained before building on it): WebView2 on Windows (Edge's engine, built into Windows 11, on Windows 10 through updates), WebKit on macOS, WebKitGTK 4.1 on Linux. On Android, an in-app web view page. One piece of Flutter code for the desktop platforms; winvm can test the Windows side.
- Linux: the web view links against WebKitGTK when the app is built, so the whole app needs it, not only people who open the editor. The packages declare it: `webkit2gtk-4.1` in the AUR package, `libwebkit2gtk-4.1-0` in the deb, and Flatpak's GNOME runtime already has it. An AppImage or bare tarball cannot count on it, so those open the editor in the browser instead.

**Signing in: an editor-only token**

1. On Edit lyrics, the app asks the plugin for an editor session for that song, with the Jellyfin sign-in it already has (no password sent again). The plugin checks the sign-in (`[Authorize]`); any signed-in user may edit their own copy, and Save for everyone needs an admin.
2. The plugin answers with an editor token: random, accepted only by the plugin's editor routes (this song's lyrics and audio, saving its lyrics), refused by Jellyfin's own API, and good for this one editor session only (see How long a session lasts). A leaked token can touch nothing else.
3. In the app's window, the app hands the token straight to the page's code as the window opens (a script run before the page's own), and the page sends it in a request header. Not in the URL and not in the user agent: both end up in browser history and in reverse proxies' access logs (nginx's default log format records every user agent).
4. In a browser (the fallback), the page is served from the Jellyfin server's own address, so it reuses Jellyfin web's saved sign-in in that browser when there is one; otherwise the person signs in with Jellyfin as usual. Either way the page trades that sign-in for an editor token the same way.
5. The plugin passes the song's audio through to the editor itself, since Jellyfin's stream will not take the editor token.

**Who saves what (decided 2026-11-19)**

- Every signed-in user can edit and save their own copy of a song's lyrics. Their copy lives in the plugin's own data folder (`DataDir.Root`), one file per user per song, so the music folder can stay read-only to Jellyfin and two people's saves never clash.
- Admins also get Save for everyone, which writes the `.slrc` next to the audio file (the plugin's existing sidecar, unchanged in format), so every user gets it.
- Which lyrics a user sees: their own copy first, then the one saved for everyone, then the plugin's usual sources. A user can drop their own copy and go back to the shared one.

**How long a session lasts (decided 2026-11-19)**

- The editor token is good for one editor session: one use to open it, then valid while that editor stays open, and over when it closes. Opening the editor again gets a new token.
- The page tells the plugin when it closes. A window that crashes or a laptop that sleeps never says so, so the plugin also ends a session that has not been heard from in a few minutes (the page checks in while open).
- Closing with unsaved changes asks first: Save, Don't save, or Cancel. The editor's own close button and the app's window both ask (the app asks the page whether anything is unsaved before letting the window close; confirm the web view package can hold a window's close, and if it cannot, the editor's own button and the browser's leave-page prompt cover it). In a browser, closing the tab gets the browser's own "Leave site?" prompt, since browsers allow nothing more custom there.

**Still to decide**

- The saved format: the editor works in TTML, which keeps background vocals and duet singers that the `.slrc`'s word-level LRC cannot. Either store TTML (per-user copies and a TTML next to the `.slrc` for everyone) and teach the apps to read it, or convert to `.slrc` on save and accept the loss.

## Verification

Every change: `flutter analyze` clean and `flutter test` passing. Every phase: run on `winvm`, `mintvm` and the Fire, then update `flutter/PARITY.md` honestly ("built" means the code exists and passes; say so when something was not seen running).
