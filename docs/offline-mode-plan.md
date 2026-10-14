# Offline Mode plan (desktop and Apple)

Written 2026-10-14 against `dev` at `39f5a9d`. File and line references describe that commit; check `git log` before trusting them later.

## What we are building

An **Offline Mode** for music, movies and TV on the Electron desktop app and the Apple apps (Mac and iPhone; not Apple TV, whose storage the system may purge at any time).

Decisions already made with the maintainer:

- **Offline Mode is a switch in Settings.** When it is on, the app is the normal app (same screens, same mode switcher) showing only what is downloaded. No second set of screens.
- **It also turns on by itself** when the server cannot be reached at launch or drops mid-session, with a banner, and turns back off when the server returns. A manual switch stays on until the person turns it off.
- **A download manager** sits just above Settings in the sidebar, in both Music and Video modes: what is downloading, what is downloaded, how much space it takes, and removing things. It replaces today's music-only Downloads item.
- **Video downloads** go through the server first: the original file when this device can play it, otherwise a fast server remux (container and audio only), and a full re-encode only when unavoidable. A local ffmpeg on the desktop is an optional later phase.

## What exists today

Music downloads already work on both platforms, built on one index of what is downloaded:

- **Desktop:** `offline.js` (main process: files under `userData/offline/<userId>/`, the download queue, the `cascade-offline://` protocol that plays them) and `src/core/offline-index.ts` (pure, tested: the index, `slimItem`, `addCollection`, `markReady`, `removeCollection`, `reconcile`, queued plays). Downloads fetch `/Items/{id}/Download`, the original file. The renderer's Downloads view is `data-view="downloads"`, Music mode only (`index.html` around line 261). `enterOfflineMode()` / `leaveOfflineModeIfReachable()` in `renderer.js` (around line 8040) open the Downloads view when the server is unreachable at launch.
- **Apple:** `CascadeKit/OfflineIndex.swift` (pure, tested) and `CascadeKit/OfflineLibrary.swift` (a background `URLSession`, files, replaying plays), wired in `App/Sources/AppState.swift` (around line 156, iOS and macOS only). `App/Sources/DownloadsView.swift` is the screen; the Mac shows it as a Music-mode sidebar section (`App/Mac/MacRootView.swift` around line 192).
- **Both** record plays made offline and replay them to the server later (`OfflinePlay`, `/UserPlayedItems`).
- **Nothing for video** on either platform.

## The design

### 1. One local catalog

Today's index holds tracks and the albums or playlists they came from, cut down to the fields a queue row needs (`slimItem`). It grows into a catalog of everything downloaded, still one file, still one source of truth:

- **Items:** every downloaded item with the fields its screens show: tracks, albums, artists (derived from the tracks), playlists, movies, series, seasons, episodes. Extend `slimItem`'s field list rather than storing whole DTOs; the index is rewritten on every change. Add what video needs: `SeriesId`, `SeasonId`, `SeriesName`, `Overview`, `OfficialRating`, `CommunityRating`, `Genres`, chapters, and the media segments (intro and credits skip) fetched at download time.
- **Files:** per item, the media file, its bytes, and for video the external subtitle files (`subs/<id>.<index>.vtt`) and which audio track the file holds.
- **Collections:** what the person asked for (an album, a playlist, a movie, a season, a whole series), so removing one removes exactly what nothing else still needs. This rule exists and is tested; it extends to seasons and series.
- **Art:** covers today; add posters, backdrops and episode stills.
- **Lyrics:** downloaded with each track (the waterfall result, stored as the parsed lines), so lyrics work offline. Spicy Lyrics lyrics stay under their terms: they are refetched or dropped after 25 days like the plugin's cache, never kept for good.
- **Pending user data:** plays (exist today), plus resume positions, played and unplayed marks and favorites changed offline (section 5).
- **Schema version 2,** read from version 1 without losing anything.

### 2. An offline stand-in for the server

The key to "same screens, downloaded data" is that both apps already read the library through one place:

- **Desktop:** every screen reads through `jfClient` (`get`, `getMerged`, `getAll`, `getAllPaged`, `getGrouped`; `src/core/jellyfin.ts` around line 410, aliased as `jfGet` in `renderer.js` line 764).
- **Apple:** almost every read goes through `JellyfinClient.get<T>` (`CascadeKit/JellyfinClient.swift` line 168, 34 call sites).

So Offline Mode swaps what answers those calls, not the screens. A pure **offline query engine** (`src/core/offline-query.ts`, `CascadeKit/OfflineQuery.swift`, both tested against the same fixture cases) takes a request (path plus params) and answers it from the catalog in Jellyfin's response shape:

- `/Users/{id}/Items` with the params the screens use: `IncludeItemTypes`, `ParentId`, `Ids`, `AlbumIds`, `ArtistIds`, `GenreIds`, `SearchTerm`, `Recursive`, `SortBy`, `SortOrder`, `StartIndex`, `Limit`, `Filters` (`IsFavorite`, `IsPlayed`, `IsResumable`), `Fields` (ignored). Sorting and filtering reuse the existing local rules (`src/core/library-browse.ts`, `CascadeKit/BrowseSort.swift`).
- `/Users/{id}/Items/{id}`, `/Playlists/{id}/Items`, `/Shows/{id}/Seasons`, `/Shows/{id}/Episodes`, `/Users/{id}/Views` (the downloaded kinds as libraries), `/Artists`, `/Genres`, and Home's recently played and recently added.
- Anything it does not know answers an empty result with an "offline" marker, never a network call.

Then:

- **Desktop:** an `OfflineClient` with `jfClient`'s methods, swapped in while Offline Mode is on.
- **Apple:** `JellyfinClient.get` asks the engine first while Offline Mode is on, encodes the answer as JSON and decodes it as `T` exactly as it would a server reply, so the 34 call sites need no change.
- **Writes** (rename, delete, add to playlist, edit metadata) are refused with a clear "not available offline" instead of failing on the network. The few that make sense offline (favorite, mark played) queue as pending user data.

Phase 0 below makes the full list of requests each screen sends, so the engine covers exactly that and nothing speculative.

### 3. What Offline Mode hides

Features that cannot work without the server are hidden, not left to fail: similar artists, instant mix and auto-mix, radio, Waterfall rooms, playing on other devices, remote control, the server's messages, the metadata and lyrics editors' saving, smart playlists over the whole library (they could run over downloads later), artist bios, and sign-out confirmation flows that need the server. Search searches the catalog.

### 4. The switch itself

One state on each platform: `online`, `offline (manual)`, `offline (unreachable)`.

- **Manual:** the Settings switch. No server requests at all while on, playback reports included (they queue as pending user data).
- **Unreachable:** entered when sign-in or the first library request finds no server; probed again on a network change and on a backoff timer (30 s, doubling to 5 minutes); left by itself when the server answers. A 401 or 403 means the session expired, not that the server is gone: that asks to sign in again, as `leaveOfflineModeIfReachable` already does.
- **Shown:** a small "Offline" pill in the top bar (desktop) or navigation bar (Apple), and a banner when it turned on by itself.
- **Mode switcher:** unchanged. Music and Video both show their downloaded side.

### 5. Syncing what happened offline

Extend today's queued plays into a queue of user-data changes, each with its time:

- plays (exist), resume positions and played marks from watching or listening, favorites, and explicit mark played or unplayed.
- Replayed on reconnect, oldest first, coalesced per item (only the last position matters). Positions and played marks go through `POST /UserItems/{id}/UserData`; plays through `/UserPlayedItems` as today.
- **Conflict rule:** a change made offline wins only if the server's value is older than it (compare `LastPlayedDate`), so watching on the TV while the phone was offline is not overwritten by the phone's stale position.

### 6. Video downloads

Asked per item: a movie, an episode, a season or a whole series (later episodes added as they arrive, optional).

1. **Ask the server** with PlaybackInfo and a **download device profile**: an MP4 container, the video codecs this device decodes in hardware, AAC (Apple: also AC3 and E-AC3), external text subtitles.
2. **Three outcomes:**
   - **Direct play:** the original file plays here: download `/Items/{id}/Download` at full network speed.
   - **Remux:** only the container or audio needs changing (the usual case for an MKV with H.264 or HEVC): download the server's progressive transcode with video copied. Close to network speed, since the server does no video work.
   - **Re-encode:** the video codec is unplayable here, or image subtitles (PGS) must be burned in: the same progressive download, slower. The download manager says so ("Converting on the server") with an estimate, and the person can cancel.
3. **Subtitles:** text subtitles saved as WebVTT beside the file; image subtitles offered only as burned in.
4. **Quality:** a setting for video downloads: Original (default on desktop and Mac), 1080p or 720p (default 1080p on iPhone, for space). Anything below original forces the re-encode path.
5. **Playback:** the desktop plays the file through `cascade-offline://` with the subtitle tracks added as `<track>` elements; Apple plays the local file with `AVPlayer` and the subtitles side-loaded. Resume, chapters and intro skip come from the catalog. Trickplay thumbnails are skipped offline at first.

Open question for phase 3's start: a progressive transcode saved to disk is a fragmented MP4, which both players accept, but seeking in it can be slow without an index. Test on real files first; if it is a problem, remux the finished file locally (desktop: the optional ffmpeg; Apple: `AVAssetExportSession` with passthrough, which handles MP4 to MP4).

### 7. The download manager

Above Settings in the sidebar on the desktop and the Mac, in both modes; on the iPhone, a row at the top of Settings and in the Library tab.

- **Downloading:** each item with progress, speed, the outcome from section 6 (Downloading, Converting on the server), pause, resume and cancel.
- **Downloaded:** grouped Music, Movies, TV, with sizes, play, and remove.
- **Storage:** total used, free space on the disk, and a storage limit setting (no limit by default on desktop and Mac; asked on the iPhone). Option to remove watched episodes after a day.
- **Where:** desktop downloads move to a folder the person can choose (default as today).

### 8. Platform notes

- **Desktop:** downloads stay in the main process (`offline.js`), which already streams to disk, resumes and survives the renderer reloading. Video files reuse the same queue with a lower parallelism (one video at a time beside music).
- **Apple:** `OfflineLibrary`'s background `URLSession` keeps downloading with the app in the background on the iPhone; video uses the same session. The Mac gets video downloads too.
- **Apple TV:** left out.
- **Android port:** not part of this plan; the handoff doc (`docs/android-handoff.md`) can add it once the desktop and Apple versions settle the catalog format.

## Phases

Each phase lands on the desktop and Apple together, behind no flag, with its tests.

| Phase | What | Rough size per platform |
|---|---|---|
| 0 | Request inventory: every library request each screen sends, written to a map file and committed | half a day |
| 1 | Catalog v2 (schema, migration, video fields, lyrics) and the offline query engine, pure and tested | 2 to 3 days |
| 2 | Offline Mode switch, automatic offline, the swap point, hiding what cannot work, the download manager for music | 3 to 4 days |
| 3 | Video downloads (direct, remux, re-encode), subtitles, offline video playback | about 1 week |
| 4 | Syncing user data done offline, storage limit, remove watched | 2 to 3 days |
| 5 | Optional: local ffmpeg on the desktop (download originals, remux or re-encode with the hardware encoder locally) | 3 to 5 days |

### Phase 0: request inventory

List, per screen, every request it sends and the params it uses, on both platforms, into `docs/offline-request-map.md`, with the commit it describes. The engine is built to exactly that list. Also list every write, so each gets a decision: refuse offline, or queue.

### Phase 1: catalog and engine

- `src/core/offline-index.ts` and `OfflineIndex.swift`: version 2 with migration from version 1 (tested with a real version 1 file), the wider `slimItem`, video collections (movie, season, series) and their removal rules, per-item subtitle files, lyrics.
- `src/core/offline-query.ts` and `CascadeKit/OfflineQuery.swift`: the engine, tested case by case from the phase 0 map. Shared fixture cases (the same catalog and request, the same expected answer) keep the two in step.

### Phase 2: the switch, the swap and the manager

- Settings switch, the three states, the probe, the pill and the banner.
- Desktop: `OfflineClient` swapped into `jfClient`; Apple: the engine inside `JellyfinClient.get`.
- Hide what section 3 lists; refuse writes clearly.
- Download manager for music on all three (desktop, Mac, iPhone), replacing the Downloads view.
- Lyrics download with tracks.
- Done when: with Offline Mode on and the network cable out, every music screen shows only downloaded music and plays it, and nothing is sent to the network (check with the network log on the desktop and a proxy on Apple).

### Phase 3: video

- Download profiles (desktop from the existing Electron device profile; Apple from `DeviceProfile.swift`'s video profile), the three outcomes, subtitles, quality setting.
- Offline playback on both, with resume, chapters and intro skip from the catalog.
- Done when: a movie in MKV with H.264 and DTS downloads as a remux at close to network speed and plays offline with its text subtitles on the desktop, the Mac and the iPhone; an HEVC file downloads as the original where the device decodes HEVC.

### Phase 4: sync and storage

- The user-data queue, coalescing and the conflict rule, tested.
- Storage limit and remove-watched.
- Done when: an episode watched halfway offline shows that position on the server after reconnecting, and does not overwrite a newer position set elsewhere.

### Phase 5 (optional): local ffmpeg on the desktop

Bundle a GPL ffmpeg build per platform (compatible with Cascade's GPLv3), about 60 to 80 MB each. Download originals at full speed, then remux, or re-encode with VideoToolbox, NVENC or QuickSync, locally. Only worth it if phase 3 shows the server-side re-encode path is common and slow.

## Testing rules

- Never write to the production server (`jellyfin.chaosinc.xyz`); use jellyfin12 on rogserver for live checks, and block playback reports while testing (see the project's notes).
- Pure logic (catalog rules, the engine, sync coalescing and conflicts) is tested in `test/` and `CascadeKit/Tests` before any screen uses it.
- Each phase ends with a check on real hardware for what tests cannot see: background downloads on the iPhone, playback, subtitles, and no network traffic in Offline Mode.

## Questions for the maintainer before phase 3

- Video download quality defaults (proposed above: Original on desktop and Mac, 1080p on iPhone).
- Whether a series download should keep pulling new episodes as they arrive.
- Whether removing watched episodes should be on by default on the iPhone.
