# Cascade

---

## What it is

Cascade is a Jellyfin streaming app, originally prioritized for music streaming. Video is in the beta builds now - movies and TV shows alongside the music library, in one app (think iTunes). It is not in a stable release yet (sorry about that, I've been biting off more than I can chew lmao), so for the moment it lives on the beta channel.

---

## Features

- **Jellyfin playback** - browse and play from your library. Cascade negotiates every stream with the server (`PlaybackInfo` plus a device profile), so it direct plays what it can and only transcodes what it has to
- **Movies and TV** - separate movie and TV libraries with season and episode browsing, resume, subtitle and audio track selection, and an ambient blurred backdrop. Off by default, turned on per library in Settings
- **Crossfade** - real two-deck crossfade with an equal-power curve, ramped on the audio thread. The next track is prefetched onto the idle deck so a change does not stall
- **5-band equalizer** - 60/250/1k/4k/12k peaking filters with separate music and video curves, five presets (Flat, Bass Boost, Vocal, Treble, Loudness) and an automatic preamp that stops a boost clipping
- **Search** - songs, albums, artists, movies and series, with results grouped by type
- **Playlists** - smart playlists (Favorites, Most Played) generated from your Jellyfin play data, plus an edit mode on real playlists for renaming, bulk removal, moving a selection, and the public/private toggle
- **Streaming quality** - cap the bitrate (Original, 320, 192, 128 or 96 kbps) and the server transcodes to fit
- **Quick Connect** - sign in by approving a code in Jellyfin on another device instead of typing a password. No password is stored for accounts signed in this way
- **Remote control target** - Cascade appears in Jellyfin's "Play On" list, so you can drive it from the web UI or your phone
- **Waterfall (beta)** - synced listening rooms. Everyone streams the same track from the same Jellyfin server, and the room shares a queue. Guests can add tracks, and optionally control playback. No audio crosses the wire
- **Full-screen now-playing overlay** - click the player bar to expand a full-screen view with large album art, controls, a live queue panel, and synced lyrics. Lyrics scale up automatically when the window is maximised or fullscreened
- **Synced lyrics** - timestamp-synced lyrics from Jellyfin with click-to-seek. Opens as a slide-in panel or in the full-screen overlay. A globe button in the overlay lyrics panel auto-detects non-English tracks and translates to English with one tap (Pulled from a couple sources when online, pulled from sidecar `.slrc` files on "Server Only Mode" - "Server Only Mode" and the built-in lyrics editor need the CascadeSLRC plugin for Jellyfin, which is not publicly released yet. Cascade detects whether it is installed and greys those controls out with an explanation when it is not, so nothing silently fails)
- **Lyrics translation** - auto-detects non-English tracks and shows a translate bar. One click translates to 12 languages via the MyMemory API
- **Album art accent mode** - toggle in the theme picker to automatically match the gradient and full-screen overlay background to the dominant colour of the current album art, updating on every track change
- **Discord Rich Presence** - shows the current track in Discord as "Listening to Cascade", or "Watching Cascade" for a movie or episode. Enable in Settings with one toggle - no setup required
- **Touch Bar** - actually has support for MacBooks with a Touch Bar
- **Cha0s Stream integration** - exposes a local control server (`127.0.0.1:47847`) so [Cha0s Stream](https://github.com/Cha0s1nc/cha0s-stream) (my other tool) can control playback directly without OS key simulation or Jellyfin session API calls
- **Auto-updater** - checks for new GitHub releases on startup and presents an update window with release notes, download progress, and one-click install
- **Native window controls** - macOS gets its traffic lights, Windows and Linux get real OS caption buttons drawn inside Cascade's own titlebar rather than a second one stacked above it
- **Cross-platform** - Mac (`.dmg`, Intel + Apple Silicon), Windows (`.exe`), Linux (`.AppImage`, `.deb`, `.rpm`)

---

## Installation

Download the latest release for your platform from the [Releases](https://github.com/Cha0s1nc/Cascade-Project/releases) page.

- **Mac** - open the `.dmg` and drag the app to your Applications folder
- **Windows** - run the `.exe` installer
- **Linux** - run the `.AppImage` directly, or install the `.deb` / `.rpm`

On first launch, enter your Jellyfin server URL, username, and password. Cascade authenticates, saves your credentials, and loads your library automatically.

If your server has Quick Connect enabled, a **Sign in with a code instead** button appears once you've entered the server URL. Approve the code in Jellyfin on a device you're already signed in on (Settings > Quick Connect) and Cascade signs in without ever handling your password.

> **Mac note:** Releases aren't signed with a real Developer ID, but they are
> ad-hoc signed, so macOS should put Cascade in the "unidentified developer"
> bucket and give you an **Open Anyway** button in System Settings > Privacy &
> Security rather than calling the app damaged. If it still refuses to open,
> `xattr -cr /path/to/Cascade.app` clears the download quarantine.

---

## Configuration

### Connecting to Jellyfin

On first launch, a setup card appears. Fill in:

| Field | Description |
|-------|-------------|
| Server URL | e.g. `http://x.x.x.x:8096` |
| Username | Your Jellyfin username |
| Password | Your Jellyfin password |

Or skip the password entirely with **Sign in with a code instead**, if your server has Quick Connect turned on.

Credentials are stored locally using `electron-store`. Signing in with a code stores no password at all. You can update any of this from the **Settings** view (gear icon in the sidebar).

### Music libraries

After connecting, open **Settings** to choose which Jellyfin music libraries Cascade uses. Multiple libraries can be selected - their contents are merged into a single view, or turn on **Single library mode** to browse one at a time. Changes apply immediately: which libraries you browse has nothing to do with your credentials, so nothing reconnects and you are never asked to sign in again.

Movie and TV libraries are chosen separately in the same place and are off by default. Turning one on adds Movies and TV Shows to the sidebar; turning them all off removes video from the app entirely.

**Scan library on server** asks Jellyfin to look for files added or removed outside it, and needs a Jellyfin admin account - it is greyed out with an explanation otherwise. **Refresh app** is local, works on any account, and just re-reads everything from the server.

---

## Lyrics

Click the chat-bubble icon in the player bar to open the lyrics panel. If Jellyfin has lyrics for the current track they will load and scroll in sync with playback. Click any line to jump to that timestamp.

If the track is detected as non-English, a translate bar appears. Pick a target language and click **Translate** to show translated lines inline below each original line.

In the full-screen overlay, toggle lyrics with the lyrics button in the secondary controls. The overlay shows lyrics in a centered clock-scroll style - the current line is large and centered, with adjacent lines scaled down.

---

## Waterfall (beta)

Synced listening. One person hosts, everyone else joins with a six character
code and hears the same track at the same time.

**No audio crosses the wire.** Every member streams the track from the same
Jellyfin server they're already signed in to, and the room only carries "which
track, what position, playing or paused" plus the shared queue. That means
rooms are same-server only, and joining one hosted on a different Jellyfin is
refused.

The host owns the queue. Guests see all of it and can append to it, with each
addition labelled with who added it. Two host settings under **Settings >
Waterfall** control the rest:

| Setting | Default | Effect |
|---------|---------|--------|
| Guests can add to the queue | On | Guests may append tracks. They can never reorder or remove |
| Guests can control playback | Off | Guests may play, pause, skip and seek for the whole room |

Rooms run through a Cloudflare Worker relay, which only ever forwards small
control messages. Point it at your own instance in **Settings > Waterfall** if
you'd rather not use the default - the Worker source is in `wip-waterfall/`.

---

## Context menu

Right-click the album art in the player bar (or click the **···** button in the full-screen overlay) for:

| Action | Description |
|--------|-------------|
| Stop playback | Stops audio and clears the current track |
| Clear queue | Empties the queue without stopping |
| Instant mix | Generates a Jellyfin instant mix from the current track |
| Add to playlist | Pick a playlist to add the track to |
| Download | Downloads the file via Electron's native download |
| Copy stream URL | Copies the direct stream URL to clipboard |
| Media info | Shows codec, bitrate, sample rate, file size, and play count |
| Refresh metadata | Fires a full metadata refresh on the server. Needs an admin account, and is greyed out otherwise |
| Edit metadata / images | Opens the item in the Jellyfin web UI |
| Edit lyrics | Opens Cascade's built-in lyrics editor |
| View album / artist | Navigates to the album or artist view |
| View lyrics | Opens the lyrics panel |
| Delete media | Deletes the file from the server (with confirmation). Needs an account Jellyfin has granted deletion rights |

---

## Building from source

### Prerequisites

- Node.js v22.18 or newer (or v23.6+). The tests run TypeScript directly
  through Node's type stripping with no flag, which those versions are the
  first to do by default. v22.6 through v22.17 can run them only with
  `--experimental-strip-types`
- npm

### Setup

```bash
git clone https://github.com/Cha0s1nc/Cascade-Project.git
cd Cascade-Project
npm install
```

### Run in dev mode

```bash
npm start
```

The portable parts of Cascade (Jellyfin client, lyrics parsing, queue logic,
stream negotiation, the Waterfall protocol) live in `src/` as TypeScript and are
bundled to `build/` by esbuild. `npm start` and every `build:*` script run that
first, so there's no separate step to remember. `renderer.js` stays plain JS and
calls into the bundle through a `CascadeCore` global.

```bash
npm run typecheck   # tsc on src/ and the tests
npm test            # node --test
npm run build:ts    # bundle src/ to build/ on its own
```

To run a second instance side by side (useful for testing Waterfall), use
`npm run dev:second` - it uses a separate user data directory so it gets its own
Jellyfin session.

### Generate icons

Put the artwork in `assets/` as either `source.svg` or `source.png` (1024×1024
square minimum), then:

```bash
npm run icons
```

That generates `icon.png`, `icon.ico` and `icon.icns`. The source is named
`source.*` rather than `icon.*` because those three are outputs - a source
sharing one of their names would be overwritten by its own output mid-run.

If both sources exist the SVG wins, and the script says so rather than choosing
silently. To force the other one, or to use a file from anywhere else:

```bash
npm run icons -- assets/source.png
```

A raster source smaller than 1024×1024 is rejected rather than upscaled. Needs
`sharp` (installed by `npm install`), and `iconutil` on macOS for the `.icns`.

### Build installers

```bash
npm run build:mac      # macOS .dmg (Intel + Apple Silicon)
npm run build:win      # Windows .exe
npm run build:linux    # Linux .AppImage, .deb and .rpm
npm run build          # Current platform
```

Output goes to `dist/`.

---

## Releases

Builds are attached to [GitHub Releases](https://github.com/Cha0s1nc/Cascade-Project/releases). The built-in auto-updater checks for new releases on startup and will prompt you to download and install.

---

## License

[GPL-3.0](LICENSE) © 2026 cha0s

---

## Theming

Click the gradient dot in the top-right of the titlebar to open the theme picker:

- **Dark / Light mode** - switches the entire UI between dark and light
- **Gradient** - pick start and end colours for the accent gradient used throughout the app (active controls, nav bar, buttons)
- **Presets** - eight built-in gradient presets (Default, Sunset, Ocean, Rose, Gold, Mint, Candy, Fire)
- **Album art accent** - when enabled, the gradient and full-screen overlay background automatically shift to match the dominant colour of the current album art on every track change. While it is on, the gradient pickers and presets are greyed out, since the artwork overrides them anyway. Toggle off to restore your manual gradient

All theme settings are saved and restored on next launch.

---

## Discord Rich Presence

Enable in **Settings → Discord**. Cascade shows "Listening to Cascade" in Discord with the current track name and artist. Playing a movie or episode switches it to "Watching Cascade", with the year or the series and episode number in place of the artist. No Discord application setup is required - a shared application ID is bundled with the app.

Album art is looked up from the iTunes catalogue by artist and album, so it works no matter how your server is reachable - a LAN address, a tailnet address, or nothing public at all. Your Jellyfin URL and token are never sent to Discord. A track with no match in that catalogue shows text only, and video presence is text only by design.

---

## Credits

Design inspired by:
[Cider](https://cider.sh) by the Cider Collective.
[Apple Music](https://music.apple.com/) by Apple (obviously dummy)
My other apps on [Github](https://www.github.com/Cha0s1nc)
