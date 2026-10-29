# Cascade

**Website:** [cascade.chaosinc.xyz](https://cascade.chaosinc.xyz), with screenshots, downloads for your platform and what's new.

---

## What it is

Cascade is a media streaming app, originally prioritized for music streaming. It plays movies and TV shows too, alongside the music library, in one app (think iTunes). While this is mainly for Jellyfin, there's also a completely local option to use a folder on your computer instead of a full Jellyfin server (in case you wanted something a little fancier than VLC or whatever. Love you VLC)

**Fair warning**: this app is mostly vibecoded. I do verify whatever Claude creates myself, but I'm not an asshole who wants to hide his usage of AI. If you don't like that, then feel free not to use this app.

---

## Features

- **Jellyfin playback** - direct plays what it can, only transcodes what it has to, with an optional bitrate cap. [More](#playback)
- **Local mode** - no server needed: point Cascade at a folder and use it like a library, lyrics, crossfade and EQ included. [More](#using-a-folder-instead-local-mode)
- **Crossfade and EQ** - real two-deck crossfade and a 5-band equalizer with separate music and video curves. [More](#playback)
- **Movies and TV** - seasons, episodes, resume, subtitles and chapters in a full-bleed player. [More](#movies-and-tv)
- **Synced lyrics** - line-synced and word-by-word karaoke lyrics from four sources, click any line to seek. [More](#lyrics)
- **Lyrics translation** - English translations under each line, done entirely on your machine. [More](#lyrics-translation)
- **Full-screen now playing** - click the player bar for big album art, controls, a live queue and lyrics
- **Customization** - restyle the Now Playing view as much as you want (app-wide customization coming soon). [More](#theming)
- **Waterfall (beta)** - synced listening rooms with a shared queue, no audio sent between people. [More](#waterfall-beta)
- **Search and playlists** - search grouped by type, smart playlists from your play data, and an edit mode for real playlists
- **Quick Connect** - sign in by approving a code on another device instead of typing a password
- **Remote control target** - shows up in Jellyfin's "Play On" list, so you can drive it from the web UI or your phone
- **Discord Rich Presence** - one toggle, no setup. [More](#discord-rich-presence)
- **Touch Bar** - yes, it actually supports MacBooks with one
- **Cha0s Stream integration** - a local control server (`127.0.0.1:47847`) so [Cha0s Stream](https://github.com/Cha0s1nc/cha0s-stream) (my other tool) can control playback directly
- **Auto-updater** - checks GitHub releases on startup, shows the notes, installs in one click
- **Cross-platform** - Mac (Apple Silicon), Windows and Linux, each with its own native window controls inside Cascade's titlebar

---

## Installation

Download the latest release for your platform from [cascade.chaosinc.xyz](https://cascade.chaosinc.xyz#download), which points you at the right file, or straight from the [Releases](https://github.com/Cha0s1nc/Cascade-Project/releases) page.

- **Mac** - open the `.dmg` and drag the app to your Applications folder. `Cascade-<version>-arm64.dmg` is the Electron app, the default and the one that updates itself. A native Swift Mac app is on its way, starting as a beta and published as `Cascade-Native-<version>.dmg` beside it; when a release has it, Settings, About, **Try the native Mac app** in the Electron app switches over in place. Both are Apple Silicon only.
- **Windows** - run the `.exe` installer
- **Linux** - run the `.AppImage` directly, or install the `.deb` / `.rpm`

On first launch, enter your Jellyfin server URL, username, and password. Cascade signs in, keeps only the session token Jellyfin gives it (never your password), and loads your library automatically.

If your server has Quick Connect enabled, a **Sign in with a code instead** button appears once you've entered the server URL. Approve the code in Jellyfin on a device you're already signed in on (Settings > Quick Connect) and Cascade signs in without ever handling your password.

> **Mac note:** Releases aren't signed with a real Developer ID, but they are ad-hoc signed, so macOS should put Cascade in the "unidentified developer" bucket and give you an **Open Anyway** button in System Settings > Privacy & Security rather than calling the app damaged. If it still refuses to open, `xattr -cr /path/to/Cascade.app` clears the download quarantine.

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

Cascade stores only the session token Jellyfin issues, locally using `electron-store`. Your password is never saved, whichever way you sign in. If the token is revoked (for example, you sign Cascade out from the Jellyfin dashboard), Cascade goes back to the sign-in screen. You can update any of this from the **Settings** view (gear icon in the sidebar).

### Using a folder instead (Local mode)

Choose **Use a folder on this computer** on the setup card (or **Settings > Account > Use a folder**) and pick a folder. Add more in **Settings > Library**: each folder is its own library, like a library on a server, so the music library choices below (merged, or one at a time) work on them. Cascade reads tags with [music-metadata](https://github.com/Borewit/music-metadata), takes cover art from `cover.jpg`, `folder.jpg` or the picture in a song, lyrics from an `.lrc` beside a song or its tags, and subtitles from `.srt` or `.vtt` files beside a video. It only ever reads the folder: favorites, play counts and playlists you make are kept in Cascade's own data. **Settings > Library** rescans, adds or removes folders (removing one keeps its favorites and plays for when it comes back), and lists what this computer cannot play without conversion. **Switch to Jellyfin** goes back to your server.

Nothing goes to a Jellyfin server in Local mode. Lyrics and artwork lookups (Kugou, LRCLIB, iTunes) and translation model downloads work as they do with a server.

**Spicy Lyrics without the plugin:** in Local mode, or with a server that does not have Cascade Server, **Settings > Lyrics > Spicy Lyrics key** takes your own Spicy Lyrics key from an app you make in the Spicy Lyrics dashboard: its secret key (`sl_sk_...`), or a public key (`sl_pk_...`) if the app has the no-origin option on. Cascade does not ship a key, and yours stays on your computer. With one set, for the song playing only, its title, artist and album go to ListenBrainz Labs to find its Spotify id, and that id goes to Spicy Lyrics. Answers are kept on your computer for 25 days.

### Cascade Server plugin

An optional Jellyfin plugin, in [`server/`](server/), that adds what a server can do once for everyone on it: lyrics fetched and kept on the server (Kugou karaoke, LRCLIB, and Spicy Lyrics with the server owner's key), a theme and lyrics look an admin sets for everyone, explicit marks, playlist pictures and descriptions, and animated album covers. Cascade works without it and grays out what needs it. For Jellyfin 12. **How to install it:** see [the plugin's README](server/README.md#install).

### Music libraries

After connecting, open **Settings** to choose which Jellyfin music libraries Cascade uses. Multiple libraries can be selected - their contents are merged into a single view, and a song, album or artist found in more than one of them shows once (keeping the higher-bitrate copy of a song). Or turn on **Single library mode** to browse one at a time. Changes apply immediately: which libraries you browse has nothing to do with your credentials, so nothing reconnects and you are never asked to sign in again.

Movie and TV libraries are chosen separately in the same place and are off by default. Turning one on adds Movies and TV Shows to the sidebar; turning them all off removes video from the app entirely.

**Scan library on server** asks Jellyfin to look for files added or removed outside it, and needs a Jellyfin *admin* account - it is grayed out with an explanation otherwise. **Refresh app** is local, works on any account, and just re-reads everything from the server.

---

## Playback

Cascade negotiates every stream with the server (`PlaybackInfo` plus a device profile), so it direct plays what it can and only transcodes what it has to. To save bandwidth, cap the bitrate in Settings (Original, 320, 192, 128 or 96 kbps) and the server transcodes to fit.

**Crossfade** is a real two-deck crossfade with an equal-power curve, ramped on the audio thread. The next track is prefetched onto the idle deck so a track change does not stall.

**Equalizer:**

| | |
|---|---|
| Bands | 60, 250, 1k, 4k and 12k Hz peaking filters |
| Curves | Separate music and video curves, shown side by side, each with its own on/off switch |
| Presets | Flat, Bass Boost, Vocal, Treble, Loudness |
| Preamp | Automatic, so a boost never clips |

---

## Movies and TV

Off by default; turn it on per library in Settings (see [Music libraries](#music-libraries)). You get separate Movies and TV Shows views with season and episode browsing, resume, and subtitle and audio track selection. Video plays in a full-bleed player with chapters and YouTube-style keyboard shortcuts (press `?` while a video plays to see them all). Continue Watching on Home includes the next episode of shows you're following.

---

## Lyrics

Click the chat-bubble icon in the player bar to open the lyrics panel. Cascade finds lyrics for the current track and they scroll in sync with playback. Click any line to jump to that timestamp.

In the full-screen overlay, toggle lyrics with the lyrics button in the secondary controls. The current line stays in the middle of the view and fills in word by word as it is sung, while the lines around it fade and blur. Lyrics scale up automatically when the window is maximized or full screen.

### Sources

| Source | Needs |
|--------|-------|
| Your Jellyfin server | Nothing |
| LRCLIB | Nothing |
| Kugou | Nothing |
| SpicyLyrics | The [Cascade Server](server/README.md) plugin, with a SpicyLyrics key set on the server |

SpicyLyrics adds word-synced lyrics with background vocals, held notes and duets (the second singer's lines sit on the right). A song SpicyLyrics can't match on its own can be linked to its Spotify track by hand.

The plugin also unlocks **Server Only Mode** (lyrics only from your server) and the built-in lyrics editor. Cascade detects whether the plugin is installed and grays those controls out with an explanation when it is not, so nothing silently fails.

### Lyrics translation

If the lyrics are in a language Cascade can translate, a translate bar appears. Click **Translate** to show an English translation below each original line.

Detection and translation both run **entirely on your machine**: no lyric, and no record of what you are playing, ever leaves it. Language detection is trigram matching (`franc`). There are two translation engines:

| Engine | Languages | Platforms |
|--------|-----------|-----------|
| Apple Translation | Japanese, Korean, Chinese (Simplified and Traditional), Spanish, French, German, Italian, Portuguese, Dutch, Polish, Russian, Ukrainian, Turkish, Arabic, Hindi, Thai, Vietnamese and Indonesian, as long as the language is installed in macOS | macOS 26 or newer, used by default there |
| Mozilla [Firefox Translations](https://github.com/mozilla/firefox-translations-models) on the bergamot WebAssembly runtime | Japanese, Korean, Chinese (Simplified and Traditional), Spanish | Everywhere |

Apple's engine is more accurate, downloads nothing through Cascade, and runs on-device (verified with the network off). If a song's language is not installed in macOS, Cascade offers to open System Settings to install it (recommended) or, for the five languages it has its own models for, to use those instead.

Mozilla models are about 35-70 MB per language and download the first time you translate a song in that language, from Cascade's GitHub releases or Mozilla's servers. Each one is checked against a pinned SHA-256 before use. Models can be removed or redownloaded in Settings, and translation can be switched off entirely.

---

## Waterfall (beta)

Synced listening. One person hosts, everyone else joins with a six character code and hears the same track at the same time.

**No audio crosses the wire.** Every member streams the track from the same Jellyfin server they're already signed in to, and the room only carries "which track, what position, playing or paused" plus the shared queue. That means rooms are same-server only, and joining one hosted on a different Jellyfin is refused.

The host owns the queue. Guests see all of it and can append to it, with each addition labelled with who added it. Two host settings under **Settings > Integrations > Waterfall** control the rest:

| Setting | Default | Effect |
|---------|---------|--------|
| Guests can add to the queue | On | Guests may append tracks. They can never reorder or remove |
| Guests can control playback | Off | Guests may play, pause, skip and seek for the whole room |

Rooms run through a Cloudflare Worker relay, which only ever forwards small control messages. Point it at your own instance in **Settings > Integrations > Waterfall** if you'd rather not use the default - the Worker source is in `signaling/`.

---

## Theming

Click the paintbrush in the top-right of the titlebar to open the theme picker:

- **Dark / Light mode** - switches the entire UI between dark and light
- **Gradient** - pick start and end colors for the accent gradient used throughout the app (active controls, nav bar, buttons)
- **Presets** - eight built-in gradient presets (Default, Sunset, Ocean, Rose, Gold, Mint, Candy, Fire)
- **Font** - changes the font across the whole app
- **Share a look** - export and import your customization. If you're a server admin, you can also offer or enforce a style for every Cascade user on your server
- **Style** - opens Now Playing with a menu to customize its style (global customization coming soon)

**Note**: If you click the paintbrush while already in Now Playing, it automatically opens the **Style** menu.

---

## Discord Rich Presence

Enable in **Settings → Integrations → Discord**. Cascade shows "Listening to Cascade" in Discord with the current track name and artist. Playing a movie or episode switches it to "Watching Cascade", with the year or the series and episode number in place of the artist. No Discord application setup is required - a shared application ID is bundled with the app.

Album art is looked up from the iTunes catalog by artist and album, so it works no matter how your server is reachable - a LAN address, a tailnet address, or nothing public at all. Your Jellyfin URL and token are never sent to Discord. A track with no match in that catalog shows text only, and video presence is text only by design.

---

## Context menu

Right-click the album art in the player bar (or click the **···** button in the full-screen overlay) for:

| Action | Description |
|--------|-------------|
| Stop playback | Stops audio and clears the current track |
| Clear queue | Empties the queue without stopping |
| Instant mix | Generates a Jellyfin instant mix from the current track |
| Favorite | Favorites or unfavorites the current track |
| Sleep timer | Stops playback after a set time, or at the end of the track |
| Add to playlist | Pick a playlist to add the track to |
| Download | Downloads the file via Electron's native download |
| Copy stream URL | Copies the direct stream URL to clipboard |
| Media info | Shows codec, bitrate, sample rate, file size, and play count |
| Refresh metadata | Fires a full metadata refresh on the server. Needs an admin account, and is grayed out otherwise |
| Edit metadata | Opens Cascade's built-in metadata editor |
| Edit images | Opens the item in the Jellyfin web UI |
| Edit lyrics | Opens Cascade's built-in lyrics editor |
| View album / artist | Navigates to the album or artist view |
| View lyrics | Opens the lyrics panel |
| Delete media | Deletes the file from the server (with confirmation). Needs an account Jellyfin has granted deletion rights |

While a movie or episode plays, the rows that only make sense for a song (clear queue, instant mix, playlists, lyrics, album and artist) are hidden. Songs, albums, artists, playlists, movies and shows elsewhere in the app have right-click menus of their own.

---

## Building from source

This builds the desktop app, which lives in [`desktop/`](desktop/). The native iOS, tvOS, and macOS app, still in development, lives in [`apple/`](apple/); see [`apple/CODEMAP.md`](apple/CODEMAP.md) for building and running it with Xcode.

### Prerequisites

- Node.js v22.18 or newer (or v23.6+). The tests run TypeScript directly through Node's type stripping with no flag, which those versions are the first to do by default. v22.6 through v22.17 can run them only with `--experimental-strip-types`
- npm

### Setup

```bash
git clone https://github.com/Cha0s1nc/Cascade-Project.git
cd Cascade-Project/desktop
npm install
```

The desktop needs `desktop/` and `shared/` only. To skip the Apple app, clone just those two:

```bash
git clone --filter=blob:none --sparse https://github.com/Cha0s1nc/Cascade-Project.git
```
```bash
cd Cascade-Project && git sparse-checkout set desktop shared
```

### Run in dev mode

```bash
npm start
```

The portable parts of Cascade (Jellyfin client, lyrics parsing, queue logic, stream negotiation, the Waterfall protocol) live in `desktop/src/` as TypeScript and are bundled to `desktop/build/` by esbuild. `npm start` and every `build:*` script run that first, so there's no separate step to remember. `renderer.js` stays plain JS and calls into the bundle through a `CascadeCore` global.

```bash
npm run typecheck   # tsc on src/ and the tests
npm test            # node --test
npm run build:ts    # bundle src/ to build/ on its own
```

From the repo root, `npm test` runs every app's tests that are checked out, each with its own tool (`node --test` for the desktop, `swift test` for the Apple core). `npm test desktop` or `npm test apple` runs one.

To run a second instance side by side (useful for testing Waterfall), use `npm run dev:second` - it uses a separate user data directory so it gets its own Jellyfin session.

`npm run demo` opens Cascade in full screen for demos and screen recordings, on an external monitor when one is connected.

### Generate icons

Put the artwork in `shared/assets/` as either `source.svg` or `source.png` (1024×1024 square minimum), then:

```bash
npm run icons
```

That generates `icon.png`, `icon.ico` and `icon.icns`. The source is named `source.*` rather than `icon.*` because those three are outputs - a source sharing one of their names would be overwritten by its own output mid-run.

If both sources exist the SVG wins, and the script says so rather than choosing silently. To force the other one, or to use a file from anywhere else:

```bash
npm run icons -- ../shared/assets/source.png
```

A raster source smaller than 1024×1024 is rejected rather than upscaled. Needs `sharp` (installed by `npm install`), and `iconutil` on macOS for the `.icns`.

### Build installers

```bash
npm run build:mac      # macOS .dmg (Apple Silicon)
npm run build:win      # Windows .exe
npm run build:linux    # Linux .AppImage, .deb and .rpm
npm run build          # Current platform
```

Output goes to `desktop/dist/`.

---

## Releases

Builds are attached to [GitHub Releases](https://github.com/Cha0s1nc/Cascade-Project/releases). The built-in auto-updater checks for new releases on startup and will prompt you to download and install. A release's `versions.json` says which version of each app it holds (`desktop` is Electron on every OS, `mac` is the native Mac app, `apple` is iOS and tvOS), because a release can carry the other apps' files over unchanged.

Every release and beta, with its notes and downloads, is also listed on the [releases page](https://cascade.chaosinc.xyz/releases/), which mirrors the last 20 versions of each app.

---

## Website

[cascade.chaosinc.xyz](https://cascade.chaosinc.xyz) is Cascade's home page. It shows the app on whatever you're visiting from (macOS, Windows, Linux or iPhone, Mac if it can't tell), with short clips of the lyrics in motion, and its download buttons always point at the latest release. The screenshots come from a test server, not anyone's personal library.

It also hosts the **announcements** you see under the bell in every Cascade app. The apps fetch them from [announcements.cascade.chaosinc.xyz](https://announcements.cascade.chaosinc.xyz) at launch, which is a plain read of one JSON file, with no account, library or server details attached. They're posted from a panel on the site that only maintainers can sign in to, with GitHub.

The whole site is one Cloudflare Worker in [`site/`](site/). [site/NOTES.md](site/NOTES.md) covers running it locally, setting it up and deploying it.

---

## Contributing

Bug reports, ideas and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers setting up, where the code lives and how changes get in, and everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md). Security problems go through [private reporting](SECURITY.md), not public issues.

---

## License

The source code is [GPL-3.0](LICENSE) © 2026 Cha0s, with one added permission: it may also be distributed through app stores such as Apple's App Store and Google Play, whose terms the GPL alone does not allow, as long as the source stays available to everyone under the GPL. The exact wording is at the top of the [LICENSE](LICENSE).

Lyric translation uses Mozilla's [bergamot-translator](https://github.com/browsermt/bergamot-translator) runtime (bundled) and [Firefox Translations models](https://github.com/mozilla/firefox-translations-models) (downloaded on first use), both under the [Mozilla Public License 2.0](https://www.mozilla.org/MPL/2.0/). Their source is available at those links.

The artwork in `shared/assets/` (the app icon and everything else in that folder) is **not** GPL. It is © 2026 Cha0s and Hxney_bun_, all rights reserved, under its own [artwork license](shared/assets/LICENSE). You can share unmodified Cascade builds, but forks and modified versions have to remove it and use their own art. To ask for permission to use the artwork, email [contact@chaosinc.xyz](mailto:contact@chaosinc.xyz).

---

## Credits

Design inspired by: [Cider](https://cider.sh) by the Cider Collective, [Apple Music](https://music.apple.com/) by Apple (obviously dummy), and my other apps on [Github](https://www.github.com/Cha0s1nc)
