# Cascade Server

A Jellyfin plugin that works with the [Cascade](../README.md) music player. It fetches lyrics and keeps them on your server, so every Cascade user on it shares them:

- word-level karaoke lyrics from Kugou,
- synced and plain lyrics from LRCLIB,
- with your own SpicyLyrics key, SpicyLyrics' word-synced lyrics (with background vocals and held notes),
- a lyrics coverage page, and a scheduled task that fetches lyrics for the whole library,
- a theme and lyrics look an administrator sets for everyone (the server style),
- an explicit mark for each song, worked out from the file's own tag, Deezer and iTunes,
- picture and description editing on playlists for the people who own them,
- animated album covers: a `cover.mp4` or animated `cover.gif`, `cover.webp` or `cover.apng` beside the album, or one from TIDAL with your own TIDAL developer app.

Works with Jellyfin 12. Version 1.0.0 also works with Jellyfin 10.11, and a 10.11 server is offered that version.

## Install

1. In Jellyfin, open **Dashboard → Plugins → Repositories** (called **Manage Repositories** in some versions) and add:

   ```
   https://plugins.chaosinc.xyz/manifest.json
   ```

2. Open **Catalog**, install **Cascade Server**, and restart Jellyfin.

   Already added the old address (`raw.githubusercontent.com/Cha0s1nc/CascadeServer/...`)? Replace it with the one above: the plugin moved into the Cascade repository, and new versions are only published there.

Jellyfin picks the right build for your server version by itself, and offers updates the same way as for any other plugin.

## Settings

Open **Dashboard → Plugins → Cascade Server**.

- **Don't write fetched lyrics next to media files.** Keep fetched lyrics in Jellyfin's data folder instead of writing `.slrc`/`.lrc`/`.txt` files beside your audio.
- **SpicyLyrics secret key.** Optional. Get a key starting with `sl_sk_` from [developers.spicylyrics.org](https://developers.spicylyrics.org). Songs are matched to their Spotify track through ListenBrainz, which covers most popular music. SpicyLyrics results are kept for at most 25 days, as its terms require, and never written as files.
- **Who can link songs to Spotify for everyone.** When the automatic match finds nothing, or picks the wrong release, a Cascade user can paste the song's Spotify link. Links from administrators and the users ticked here apply to the whole server. Everyone else's links stay on their own computer and only affect what they see.

- **Server style.** A Cascade preset (Theme panel, Share a look, Copy as text) that everyone on the server gets: as a default for the settings they never changed, or enforced over their own. Dark or light mode and the font always stay the user's.
- **Explicit songs.** Jellyfin has no explicit flag, so each song's rating comes from, first hit wins: one set by hand (administrators and the users ticked here), the advisory tag in the file (`rtng` in M4A, `ITUNESADVISORY` in ID3 and Vorbis/FLAC/Opus, or an `EXPLICIT` comment), then Deezer and iTunes Search, each switchable. A result counts only when artist and title match and the length is within 3 seconds, so karaoke and tribute versions are ignored; no match means unknown, never clean. The lookups send a song's artist and title (and ISRC) to those services, one request per second. Run the **Find explicit songs** scheduled task to cover the library; Cascade also queues songs it asks about. An optional switch also tags explicit songs `Explicit` in Jellyfin for other clients. In testing on Jellyfin 10.11 that tag survived a metadata refresh with "replace all metadata", but Jellyfin's merge code replaces tags with what the refresh produced, so a metadata provider that supplies tags can remove it until the task runs again.
- **Animated album art.** Looks for `cover.mp4` or `cover.webm` (the names are a setting) in the album folder, then an animated `cover.gif`, `cover.webp` or `cover.apng`, which the server turns into an MP4 once with Jellyfin's own ffmpeg (WebP frames are decoded with Jellyfin's SkiaSharp, since its ffmpeg cannot read animated WebP) and keeps until the image changes. A still image under those names is left alone. Cascade can also upload one: it goes in the album folder, or into Jellyfin's data folder when the library is read-only. TIDAL is optional and needs your own app from developer.tidal.com (TIDAL's terms do not let one account be shared): enter its client id and secret and use the Test button. TIDAL is only asked when someone opens an album, never in a library-wide pass. It sends the album's barcode (and sometimes track ISRCs) to TIDAL; the barcode comes from a `BARCODE` or `UPC` tag on the first track, else from MusicBrainz through the album's MusicBrainz release id. Results are kept for at most 25 days (7 days for albums with no video), and deleted when you clear the credentials. See TIDAL's [Developer Terms](https://developer.tidal.com/documentation/guidelines-developer-terms-1_0).

## What it depends on

- **Cascade's icon**, shown at the top of the plugin's dashboard page, is embedded from `shared/assets` at build time. Like all of Cascade's artwork it is not GPL: see [shared/assets/LICENSE](../shared/assets/LICENSE). A fork of the plugin has to remove it.

- **ListenBrainz Labs** matches songs to Spotify tracks. It is an experimental service; if it changes or goes away, automatic matching stops working and Cascade falls back to its other lyric sources. Hand-made links keep working.
- **SpicyLyrics**, **Kugou** and **LRCLIB** are third-party services with their own terms and availability.
- **Deezer** and **iTunes Search** (explicit marks), **MusicBrainz** (album barcodes) and **TIDAL** (animated covers, with your own developer app) are third-party services too. Each is optional, and the plugin works without them.
- **TagLibSharp** reads the advisory and barcode tags from audio files. Jellyfin ships it, so the plugin uses Jellyfin's copy (version 2.3.0).

## Building

From `server/`, with the .NET 10 SDK:

```
dotnet build Jellyfin.Plugin.CascadeServer -c Release
dotnet test Jellyfin.Plugin.CascadeServer.Tests
```

`npm test server` at the repo root runs the same tests. Releases are built and published by GitHub Actions from a `server-v*` tag (`.github/workflows/server.yml` at the repo root): the zip and `manifest.json` go to the plugin catalog at `plugins.chaosinc.xyz`. The `manifest.json` here is the catalog as the old repository last published it, which the first release from this repository starts from; after that the published catalog is the real one.
