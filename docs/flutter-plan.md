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
- **Rediscover** (a shelf and a sidebar entry for albums not played in a year) is in the mockups but is a new feature, not a parity item. It waits until it is specified for all the apps.
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
- Personality v1 as the default theme (see Design), then the theme panel, presets, server style, fonts; the customization editor and Style Tuning.
- Announcements.

### Phase 4: windows and integrations

- The in-line title bar on Windows and Linux (see Design).
- Miniplayer (a second window), lyrics editor, metadata editor.
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

- Packages: a Windows installer, a Linux AppImage or deb, an Android APK.
- An updater on Windows and Linux following `src/core/update-release.ts`.
- Versions in lockstep with the other apps; a release marker and changelog section.
- Importing settings from Electron's `config.json`.

## Verification

Every change: `flutter analyze` clean and `flutter test` passing. Every phase: run on `winvm`, `mintvm` and the Fire, then update `flutter/PARITY.md` honestly ("built" means the code exists and passes; say so when something was not seen running).
