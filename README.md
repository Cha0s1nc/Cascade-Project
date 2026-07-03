# Cascade

A Jellyfin music client for desktop with a polished dark interface, full playback control, synced lyrics, and a full-screen now-playing experience. Inspired by the Cider Collective.

---

## Features

- **Jellyfin playback** — browse and play from your Jellyfin library with direct play and transcoding fallback
- **Full-screen now-playing overlay** — click the player bar to expand a full-screen view with large album art, controls, a live queue panel, and synced lyrics. Lyrics scale up automatically when the window is maximised or fullscreened
- **Queue management** — drag to reorder, click to remove. Queue updates live in the full-screen overlay with album art thumbnails and current-track highlighting
- **Synced lyrics** — timestamp-synced lyrics from Jellyfin with click-to-seek. Opens as a slide-in panel or in the full-screen overlay. A globe button in the overlay lyrics panel auto-detects non-English tracks and translates to English with one tap (Pulled from a couple sources when online, pulled from sidecar `.slrc` files on "Server Only Mode")
- **Lyrics translation** — auto-detects non-English tracks and shows a translate bar. One click translates to 12 languages via the MyMemory API
- **Album art accent mode** — toggle in the theme picker to automatically match the gradient and full-screen overlay background to the dominant colour of the current album art, updating on every track change
- **Discord Rich Presence** — shows the current track in Discord as "Listening to Cascade". Enable in Settings with one toggle — no setup required
- **Touch Bar** — Actually has support for Macbooks with a Touch Bar
- **Multi-library support** — select and merge multiple Jellyfin music libraries. Albums, artists, and songs are deduplicated across all selected libraries
- **Cha0s Stream integration** — exposes a local control server (`127.0.0.1:47847`) so [Cha0s Stream](https://github.com/Cha0s1nc/cha0s-stream) (my other tool) can control playback directly without OS key simulation or Jellyfin session API calls
- **Auto-updater** — checks for new GitHub releases on startup and presents an update window with release notes, download progress, and one-click install
- **Cross-platform** — Mac (`.dmg`, Intel + Apple Silicon), Windows (`.exe`), Linux (`.AppImage`)

---

## Installation

Download the latest release for your platform from the [Releases](https://github.com/Cha0s1nc/Cascade-Project/releases) page.

- **Mac** — open the `.dmg` and drag the app to your Applications folder
- **Windows** — run the `.exe` installer
- **Linux** — run the `.AppImage` directly

On first launch, enter your Jellyfin server URL, username, and password. Cascade authenticates, saves your credentials, and loads your library automatically.

> **Mac note:** Releases are not signed (something with github workflows breaks my certificate) so you'll have to run xattr -cr /path/to/.app to be able to run the app (WILL BE FIGURED OUT SOON)

---

## Configuration

### Connecting to Jellyfin

On first launch, a setup card appears. Fill in:

| Field | Description |
|-------|-------------|
| Server URL | e.g. `http://x.x.x.x:8096` |
| Username | Your Jellyfin username |
| Password | Your Jellyfin password |

Credentials are stored locally using `electron-store`. You can update them any time from the **Settings** view (gear icon in the sidebar).

### Music libraries

After connecting, open **Settings** to choose which Jellyfin music libraries Cascade uses. Multiple libraries can be selected — their contents are merged into a single view. Changing the selection and saving reconnects immediately.

---

## Lyrics

Click the chat-bubble icon in the player bar to open the lyrics panel. If Jellyfin has lyrics for the current track they will load and scroll in sync with playback. Click any line to jump to that timestamp.

If the track is detected as non-English, a translate bar appears. Pick a target language and click **Translate** to show translated lines inline below each original line.

In the full-screen overlay, toggle lyrics with the lyrics button in the secondary controls. The overlay shows lyrics in a centered clock-scroll style — the current line is large and centered, with adjacent lines scaled down.

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
| Refresh metadata | Fires a full metadata refresh on the server |
| Edit metadata / images / lyrics | Opens the item in the Jellyfin web UI |
| View album / artist | Navigates to the album or artist view |
| View lyrics | Opens the lyrics panel |
| Delete media | Deletes the file from the server (with confirmation) |

---

## Building from source

### Prerequisites

- Node.js v18 or newer
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

### Generate icons

Place `icon.svg` in the `assets/` folder (1024×1024 square), then:

```bash
npm run icons
```

This generates `icon.png`, `icon.ico`, and `icon.icns` from the SVG. Requires `sharp` (installed by `npm install`) and `iconutil` on macOS for `.icns`.

### Build installers

```bash
npm run build:mac      # macOS .dmg (Intel + Apple Silicon)
npm run build:win      # Windows .exe
npm run build:linux    # Linux .AppImage
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

- **Dark / Light mode** — switches the entire UI between dark and light
- **Gradient** — pick start and end colours for the accent gradient used throughout the app (active controls, nav bar, buttons)
- **Presets** — eight built-in gradient presets (Default, Sunset, Ocean, Rose, Gold, Mint, Candy, Fire)
- **Album art accent** — when enabled, the gradient and full-screen overlay background automatically shift to match the dominant colour of the current album art on every track change. Toggle off to restore your manual gradient

All theme settings are saved and restored on next launch.

---

## Discord Rich Presence

Enable in **Settings → Discord**. Cascade shows "Listening to Cascade" in Discord with the current track name and artist. No Discord application setup is required — a shared application ID is bundled with the app.

Album art appears automatically if your Jellyfin server is accessible over HTTPS (e.g. via a Cloudflare Tunnel or reverse proxy). For local HTTP servers the presence shows text only.

---

## Credits

Design inspired by:
[Cider](https://cider.sh) by the Cider Collective.
[Apple Music](https://music.apple.com/) by Apple (obviously dummy)
My other apps on [Github](https://www.github.com/Cha0s1nc)
