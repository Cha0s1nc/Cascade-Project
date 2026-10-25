# Local mode (Electron): plan, and what was built

## Status on the `local-mode` branch

Built: tier 1 (music), tier 1b (video, Chromium-playable only, sidecar subtitles) and tier S (SpicyLyrics from the app). Tier 2 (ffmpeg) is not built, as the plan recommends: decide on it after living with tier 1. The testing guide is `docs/local-mode-testing.md`.

Where the build went beyond, or differs from, the plan below:
- **The tag reader is `music-metadata`**, approved by the maintainer on 2026-10-25 (MIT, about 2 MB with its own dependencies, loads from `app.asar` in a packaged Mac build). Without it Local mode still runs, naming everything from folders and listing anything whose codec it cannot tell.
- **User playlists** are answered at `jfFetch`: in Local mode the Jellyfin playlist writes the screens already send (create, add, remove, move, rename, delete) become operations on Cascade's own playlists (`src/core/local-writes.ts` `playlistOpFor`), so no playlist screen changed. A playlist entry's id in the catalog is its track's id (`offline-query.ts`), so removing one of two copies of a track removes both. An `.m3u` is read-only.
- **An empty playlist** is answered by `localQuery`, a wrapper around the engine: the engine lists only playlists holding something ready, and it has a Swift twin tested against a shared fixture, so it was left alone.
- **Several folders** (added after the first build, 2026-10-25): each folder added is its own library, like a folder added to Jellyfin, so the merge and single-library choices apply. A folder's key comes from its name and starts every scanned path; ids include it. Not auto-detected from subfolders: a library folder and an artist folder look the same.
- **Switching modes, or folders, reloads the window**: the one re-init that leaves nothing of the other library behind. The saved queue is per mode (`lastQueue`, `localLastQueue`).
- **Albums** are a folder's tracks naming one album, with Various Artists when they share no artist and carry no album artist tag, so a compilation stays one album. Ids are as planned.
- **Lyrics**: the song's `.lrc`, else its tagged lyrics, sit where Jellyfin's lyrics sat in the waterfall (after Kugou and LRCLIB), as the plan says.
- **Spicy Lyrics** takes the person's own key, secret (`sl_sk_`) or public (`sl_pk_`, with the no-origin option on). It first took only a public key; changed 2026-10-25 because SpicyLyrics' own catalog template for Rakki, a native Jellyfin player, issues a secret key. Only the song playing asks; look-aheads and download lyrics never do, and their answers are not cached, so the song asks once it plays.
- **`.mov`** is treated as not playable (no direct-play profile names it). Worth checking on a Mac.
- **Swift**: no shared fixture covers `offline-mode.ts`, so `OfflineMode.swift` is unchanged.

Not verified, because this cloud session could not reach the hosts: the Spicy Lyrics dashboard (the key header, `Authorization: Bearer`, now matches their Keys page for both key types; the code follows CascadeServer's `SpicyLyricsClient.cs`: `Authorization: Bearer <key>`), ListenBrainz Labs' rate limit (one lookup a second, Retry-After and X-RateLimit-Reset-In honored), and macOS and Windows themselves. The real app was run on Linux under Xvfb.

---


Describes `dev` at `71add16`. Scope decided: Electron only, and Local is a separate mode from Jellyfin (picked at setup, switchable in Settings), not merged into a server library.

## Context

The ask: let someone point Cascade at a folder and use it like a Jellyfin library, so it can replace VLC/a plain player and still get Cascade's lyrics, crossfade, EQ, theming, translation and so on. Music and video have to be told apart automatically. Spicy Lyrics would need to work without the CascadeServer plugin.

## Verdict

**Music: very doable, and cheaper than it sounds.** Offline Mode (phases 1 to 4) already built a fake Jellyfin. `src/core/offline-query.ts` answers every GET the screens send (`/Items`, `/Artists`, `/MusicGenres`, `/Shows/...`, `/Playlists/...`, `/UserViews`, `/Users/{id}`) from an `OfflineIndex` catalog, and `jfClient.setOfflineSource()` (renderer.js ~8545) swaps it in so every screen renders from the catalog unchanged. Albums and artists are already derived from tracks' `AlbumId` / `ArtistItems` (`Catalog` in offline-query.ts:121). So Local mode is mostly "build an `OfflineIndex` from a folder scan instead of from downloads" plus plumbing.

**"Instead of VLC" for video: not true without ffmpeg, and I'd push back on selling it that way.** With no server to transcode, playback is limited to what Chromium decodes, per `src/core/profiles/electron.ts`: audio containers `opus,mp3,aac,flac,wav,ogg,webm`, m4a with `aac,mp3,flac,opus` (no ALAC), video `h264,vp8,vp9,av1` (+HEVC only in mp4, never in mkv), video audio `aac,mp3,opus,flac,vorbis` (AC3/EAC3 only where the host probes yes). So ALAC music, HEVC MKVs, anything with DTS/TrueHD, AVI/Xvid/WMV, and every embedded MKV subtitle track (Chromium exposes none of them, PGS especially) just won't play. VLC plays all of that. A typical movie folder would be maybe half playable. Real VLC parity needs the bundled ffmpeg that is already parked as Offline Mode phase 5 (60 to 80 MB per platform, GPL, compatible with GPLv3).

**Spicy Lyrics client-side: medium, not simple, and the key problem is already decided.** The pieces exist: `convertSpicyLyrics`, `spicyFitsTrack` (src/core/spicy-lyrics.ts), the 25-day expiry (`SPICY_LYRICS_DAYS`, `lyricsOf()` in offline-index.ts), and the plugin's keyless ListenBrainz Labs `spotify-id-from-metadata` lookup, which can move to the client. The catch: per the 2026-09-23 decision with spikerko, Cascade does not bundle a key. Each Local user creates their own SpicyLyrics dashboard app with the no-origin option and pastes an `sl_pk_` key, and the request has to go out from main (no Origin header). That's a real setup hurdle for a "just point at a folder" user, so Spicy is an opt-in extra, not part of the core pitch. Bonus: the same path serves Jellyfin users whose server lacks CascadeServer. ListenBrainz Labs' rate limit is unverified; check it before leaning on it.

## Rough size

| Tier | What | Size |
|---|---|---|
| 1 | Music Local mode, Chromium-playable files only | ~1.5 weeks |
| 1b | Video in Local mode, Chromium-playable only, sidecar subs | +3 to 4 days |
| 2 | Bundled ffmpeg: playback of everything, embedded subs, plus probing/tags/art | +1 to 1.5 weeks |
| S | Client-side Spicy Lyrics (own key) | 2 to 3 days, independent |

Recommendation: build tier 1 first, decide on tier 2 after living with it. Don't market video as a VLC replacement until tier 2 exists.

## Tag reading: the one dependency decision

`package.json` has no tag parser and the repo rule is no new dependency without asking. Options, pick at implementation time:
- **`music-metadata`** (MIT, pure JS, ESM, run from main via dynamic import): tags, embedded art, replay gain, embedded USLT/SYLT lyrics, duration, and whether an mp4 has a video track. Best fit for tier 1.
- **ffprobe** (if tier 2 ships): covers tags, codecs, audio vs video, embedded art in one tool, and would make `music-metadata` redundant.
- Hand-rolled ID3/Vorbis/MP4 parsing: no. Too many formats, too many edge cases.

## Design

### 1. A fourth state, not "offline"

`webFetch` is literally `jfFetch` (renderer.js:791), and both refuse while `jfClient.offline`. Reusing `manual` would block LRCLIB, Kugou, MusicBrainz, iTunes art, translation model downloads and update checks. Local mode is "no server, but internet":
- Add `'local'` to `OfflineState` in `src/core/offline-mode.ts`. `isOffline('local')` true (so the engine swap and server-feature hiding apply), `blocksServer` false (there is no server origin), `checksUpdates` true, no probe.
- Split `webFetch` from `jfFetch` so `webFetch` refuses only in `manual` / `unreachable`.
- Mirror the state in `CascadeKit/OfflineMode.swift` only if a shared fixture covers it (offline-mode rules are shared); otherwise leave Swift alone.

### 2. Scanner and catalog (main process, new `local-library.js`, no semicolons)

- Owns `userData/local/{index.json,art/}` with the chosen root path in the store (`localLibraryRoot`). Picked with `dialog.showOpenDialog({ properties: ['openDirectory'] })`; one root for v1 (multiple roots later, if asked).
- Walk the tree, skip dot-files and symlink escapes. Incremental: keep `{relPath: [mtimeMs, size]}` and re-read only what changed; rescan at launch and from a Settings button. `fs.watch` recursive is a later nicety, not v1.
- Emit the existing `OfflineIndex` shape through existing helpers (`emptyIndex`, `slimItem`, `setLibraries`, `markReady`). Libraries: one `music`, one `movies`, one `tvshows` view, created only when they hold something.
- **Ids:** sha1 hex (first 32 chars) of the normalized relative path for files, of normalized album artist + album for `AlbumId`, of normalized name for artist and genre ids. All pass `isSafeId`. Known ceiling: moving or renaming a file loses its plays and favorites; noted in a `ponytail:` comment, fix later by fingerprint if it bites.
- **Music vs video:** extension first (audio list vs video list). Ambiguous containers (`.mp4`, `.m4v`, `.webm`, `.mkv`, `.mka`) decided by whether the file has a video track (tag reader in tier 1, ffprobe in tier 2). Music videos are out of scope.
- **Movie vs episode:** Jellyfin's naming conventions. `S01E02` / `1x02` in the file name, or a `Season NN` folder, makes an Episode with `SeriesId` / `SeasonId` from the show folder name; series and season items go into `containers`. Everything else in a video file is a Movie, name and year from `Name (2010)` folder/file patterns.
- **Art:** `cover.jpg` / `folder.jpg` / `poster.jpg` sidecars, then embedded art, written once to `art/<id>.jpg`.
- **Tags to fields:** title, album, album artist, artists, track and disc number, year, genres, duration to `RunTimeTicks`, replay gain to `NormalizationGain` (normalization then just works).

### 3. Serving files

`cascade-offline://` only serves flat `media/<name>` under userData (`isSafeMediaPath` forbids slashes), so it can't point at a user folder. Add a `cascade-local` scheme registered beside it in main.js:59 (`stream: true`), handler serving only paths listed in the local index, resolved under the root through `serveWithin` (main.js:71), with `parseByteRange` and `contentTypeForFile` from offline-index.ts and the same `access-control-allow-origin` header (the EQ graph needs it). `resolveTrackStream` (renderer.js:579) and `artUrl` (renderer.js:259) already prefer a local URL; feed them from the local summary.

### 4. Renderer wiring

- Setup overlay gets a third choice, "Use a folder on this computer". `init()` (renderer.js:7812): if `localLibraryRoot` is set and mode is local, skip `connect()`, set a stub `jf` (`url: ''`, `userId: 'local'`), `setOfflineState('local')`, load Home.
- Settings: show the folder, Rescan, Change folder, and "Switch to Jellyfin" / "Use a local folder". Switching is a full re-init, the two catalogs never mix.
- Hidden in Local mode (same list Offline Mode hides, plan section 3): Waterfall rooms, devices and remote control, Quick Connect, server messages, metadata and lyrics editors' saving, instant mix, similar artists, artist bios, radio, downloads manager. Copy that says "offline" needs a Local-mode wording where it would show.
- User data: favorites, plays, positions and History write straight into the local catalog's UserData and survive rescans (keyed by id). They must not go through `changes` / `plays`, which exist to sync to a server and are capped.
- Playlists: Jellyfin playlist writes are refused offline. v1 reads `.m3u`/`.m3u8` files in the folder as playlists and keeps user-made playlists in the local catalog; smart playlists already live locally and work as is.

### 5. Lyrics in Local mode

Waterfall (`fetchLyricsWaterfall`, renderer.js ~13126 area): the `Jellyfin` source becomes local, reading a sidecar `.lrc` (then embedded SYLT/USLT). Kugou and LRCLIB keep working once `webFetch` is split. Plugin-backed sources (`cascade-karaoke`, `cascade-synced`, plugin Spicy) are skipped. Translation works unchanged.

### 6. Client-side Spicy Lyrics (independent, also helps Jellyfin users)

- Settings field for the user's own key (`sl_sk_`, or `sl_pk_` with no-origin on), with a link to the dashboard and a note to enable the no-origin option. Stored like the token.
- Main-process IPC does the fetch (no Origin header): ListenBrainz Labs lookup for up to 3 Spotify candidates, `GET api.spicylyrics.org/v1/lyrics/{id}`, `spicyFitsTrack` duration check, 429 backoff with fall-through to Kugou/LRCLIB.
- Cache per item with the 25-day expiry reused from `SPICY_LYRICS_DAYS`; fetch on play only, never a library crawl (terms section 5). Attribution already renders from `credit`.
- Used when the plugin path is absent: Local mode always, Jellyfin mode when `_cascadePluginAbsent`.

### 7. Video (tier 1b and tier 2)

Tier 1b: index only files the device profile says Chromium can play; list the rest in a "Can't play these without ffmpeg" note in Settings instead of letting them silently fail (rule: a playback URL that never loads sits at readyState 0 with no error). Sidecar `.vtt` as is, `.srt` converted to WebVTT (small pure function in src/core with a test), added via the existing `applySubtitles` `local` path.

Tier 2: an ffmpeg/ffprobe that Cascade can run (see "Getting ffmpeg" below), probe everything, remux on the fly to fragmented MP4 for anything not directly playable (most MKVs become copy remuxes, cheap), ALAC to FLAC (lossless, cheap), DTS/TrueHD audio to AAC or Opus with video copied, extract embedded text subs to VTT, burn in PGS only on request.

### Getting ffmpeg

Neither OS ships it. macOS has AVFoundation and Windows has Media Foundation, which are native media APIs, not ffmpeg, and using them from Electron means a native helper per OS (like `native/apple-translate`), twice the work, and still worse coverage: AVFoundation has no MKV at all, and Windows' HEVC decoder is a paid Store extension. Electron itself carries a stripped `libffmpeg` with only the royalty-free codecs, which is exactly why Chromium's limits are what they are. Some Linux distros and Homebrew/winget users have ffmpeg installed, but nothing can count on it.

So the choice is bundle versus opt-in download. Recommended: **opt-in download, using the translation-model pattern that already exists.**
1. First, use an ffmpeg already on the system if one is found (`PATH`, `/opt/homebrew/bin`, `/usr/local/bin`) and its `-version` answers. Free for people who have it.
2. Otherwise, when Local mode meets a file it can't play, offer "Install the video add-on (about 30 to 80 MB)". Main downloads a pinned per-platform build, checks its size and sha256 against a manifest in the repo, writes to a `.partial` directory and renames only once verified, exactly like `downloadTranslationModel()` (main.js ~1041). Hashes are not optional for the same reason: `downloadFile()` resolves on a truncated stream.
3. Host the binaries as a release in a **separate repo**, never `Cascade-Project`, for the same reason the translation models live elsewhere: the updater reads this repo's releases as app updates.

Why not bundle: it adds 60 to 80 MB to every installer for a feature most Jellyfin-mode users never touch, and every ffmpeg security fix becomes an app release. Bundling is still the fallback if the download flow turns out clunky.

Licensing: Cascade is GPLv3, so a GPL ffmpeg build is compatible, but distributing the binaries means offering the matching source (link the exact upstream tag and build config in that release). An LGPL build covers everything here that matters (all the decoders, copy remuxing, AAC/Opus/FLAC encoding, and the hardware video encoders VideoToolbox, NVENC, QSV and AMF); only libx264/x265 software encoding needs GPL. Start with LGPL builds and skip the question unless software re-encoding turns out to be needed.

## Where the work happens

Not in this checkout: the maintainer is working on other things locally on `dev`. Implementation goes to its own session on a new branch `local-mode` cut from `dev` at `71add16` (verify the base sha before starting), in a separate worktree so nothing touches the main checkout. A cloud session also fits, since Local mode needs no Jellyfin server; the trade-off is that the real-app check on the Mac would then wait for the maintainer. Open a PR into `dev` per tier and never merge it from the session. No release markers in commit subjects. Ask in the PR before adding the tag-parser dependency.

## Files

- New: `local-library.js` (main), `src/core/local-scan.ts` (pure: id hashing, music/video/episode classification, naming parsers, `.srt` to VTT), `test/local-scan.test.ts`.
- Changed: `main.js` (scheme, IPC, folder picker), `src/core/offline-mode.ts` (`local` state), `renderer.js` (init branch, `webFetch` split, setup and Settings UI, lyrics source, hiding), `index.html` (setup choice, Settings rows), `src/preload.ts` (IPC surface), `package.json` (`build.files`, `build:main` entry, the tag-parser dependency once approved).
- Reused as is: `offline-query.ts`, `offline-index.ts` helpers, `serveWithin`, `parseByteRange`, `contentTypeForFile`, `resolveTrackStream`/`artUrl` local paths, `applySubtitles`, `convertSpicyLyrics`, `spicyFitsTrack`.

## Verification

- `npm run build:ts && npm run typecheck && npm test`; new tests cover classification (album track, `Show/Season 01/Show S01E01.mkv`, `Movie (2010)/Movie.mkv`, audio-only `.mp4`), id stability, `.srt` conversion. `test/offline-guard.test.ts` still passes after the `webFetch` split.
- Real app with a throwaway profile (per the "test the desktop without creds" note): point at a test folder with mixed mp3/flac/m4a, an ALAC file, an `.lrc` sidecar, a movie and a two-episode show. Check Home, Albums, Artists, Songs, Genres, search, playback with crossfade and EQ, seeking, lyrics from the sidecar and from LRCLIB, favorites and History surviving a rescan, the ALAC and HEVC-MKV files listed as unplayable, and the network log showing no requests to any Jellyfin origin.
- Spicy: with a real key, a known track resolves, shows attribution, and is refetched or dropped after the expiry (clock-shifted test of the rule).
