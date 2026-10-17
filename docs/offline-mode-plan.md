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

- **Items:** every downloaded item with the fields its screens read: tracks, albums, artists (derived from the tracks), playlists, movies, series, seasons, episodes. Extend `slimItem`'s field list rather than storing whole DTOs; the index is rewritten on every change. The list below is what `docs/offline-request-map.md` found the screens reading; nothing else is kept.
  - **Every item:** `Id`, `Name`, `SortName`, `Type`, `MediaType`, `DateCreated`, `ProductionYear`, `RunTimeTicks`, `ImageTags` (Primary), `Genres` and `GenreItems` (names and ids: the desktop filters by `GenreIds`, smart playlists and Apple's filter by name), `Overview` (artist bios, playlist descriptions, movie and episode pages), `CanDelete` (the desktop's playlist edit check), and the library it came from (below).
  - **UserData,** kept and kept current: `Played`, `PlayCount`, `IsFavorite`, `LastPlayedDate`, `PlaybackPositionTicks`. Nearly every list reads it (History, Recently Played, Most Played, Continue Watching, the favorite hearts, the played checks). Offline changes are applied on top (section 5), so the screens show what the person just did.
  - **Tracks:** `Album`, `AlbumId`, `AlbumPrimaryImageTag`, `AlbumArtist`, `AlbumArtists` and `ArtistItems` (names and ids: `ArtistIds` and `AlbumArtistIds` filters, and the artist list derived from them), `Artists`, `IndexNumber`, `ParentIndexNumber`, `NormalizationGain` (`_normalizationDb`, Apple's gain), the playlist entry id where it came from a playlist (`PlaylistItemId`), and whether the Cascade plugin marked it explicit (the badge, otherwise a `POST` the catalog cannot answer).
  - **Albums and playlists:** `ChildCount`, and for playlists the stored order of entries and `OpenAccess` (Apple's playlist page reads it from `/Playlists/{id}`).
  - **MediaSources,** cut to what is read: the first source's `Id`, `Container`, `Bitrate` and `Size` (the cross-library merge keeps the higher bitrate copy; video needs the source id for subtitles and audio tracks).
  - **Video:** `MediaStreams` cut to `Index`, `Type`, `Codec`, `Language`, `DisplayTitle`, `IsDefault`, `IsForced`, `IsExternal`, `Channels`, `Width`, `Height` (the audio and subtitle pickers, the decodable-codec check); `SeriesId`, `SeriesName`, `SeriesPrimaryImageTag`, `SeasonId`, `SeasonName`, `OfficialRating`, `CommunityRating`, `BackdropImageTags`; `Chapters` (`StartPositionTicks`, `Name`) and the media segments (intro and credits skip), fetched at download time.
- **Library ids:** every item records the library it was downloaded from, and the catalog keeps those libraries' `Id`, `Name` and `CollectionType`. Both apps ask per library with `ParentId` = the library and merge the answers, so without this every screen comes back empty for anyone who has picked libraries. Found at download time with one `GET /Items/{id}/Ancestors` per album, show or movie: the ancestor that is a stored library is the one. (Phase 1 to 2 used `GET /Items?Ids=...&ParentId=<library>` per library; phase 3 found Jellyfin 12.2 ignores `ParentId` when `Ids` is given, which put every download in the last library asked.) Playlists need none (they live in Jellyfin's own playlists collection and no screen fans them out).
- **Placeholder library for older downloads:** items from a version 1 catalog have no library id. The migration puts them in one placeholder library per kind (`cascade-offline-music`, a `music` view named "Downloads"), which the offline `/UserViews` lists while it holds anything and which counts as selected whatever the saved selection says, so those items stay visible. The next time the app is online it runs the same per-library lookup for them and moves each into its real library; an item the server no longer has stays in the placeholder until it is removed.
- **The user:** `Name` and the `Policy` fields the apps read (`IsAdministrator`, `EnableContentDeletion`, `EnableContentDeletionFromFolders`, `EnableContentDownloading`, `EnableLiveTvAccess`), so `/Users/{id}` answers offline and permissions keep reading the same way.
- **History snapshot:** the server's play history as it was when the app was last online (section 5).
- **Files:** per item, the media file, its bytes, and for video the external subtitle files (`subs/<id>.<index>.vtt`) and which audio track the file holds.
- **Collections:** what the person asked for (an album, a playlist, a movie, a season, a whole series), so removing one removes exactly what nothing else still needs. This rule exists and is tested; it extends to seasons and series.
- **Art:** covers today; add posters, backdrops and episode stills.
- **Lyrics:** downloaded with each track (the waterfall result, stored as the parsed lines), so lyrics work offline. Spicy Lyrics lyrics stay under their terms: they are refetched or dropped after 25 days like the plugin's cache, never kept for good.
- **Pending user data:** plays (exist today), plus resume positions, played and unplayed marks and favorites changed offline (section 5).
- **Schema version 2,** read from version 1 without losing anything.

### 2. An offline stand-in for the server

The key to "same screens, downloaded data" is that both apps read the library through one place:

- **Desktop:** every library read goes through `jfClient` (`get`, `getMerged`, `getAllPaged`, `getGrouped`, `getAllGrouped`; `src/core/jellyfin.ts` around line 346, aliased as `jfGet` in `renderer.js` line 770). Writes and Cascade plugin calls do not: see "The desktop guard" below.
- **Apple:** every API call, read or write, goes through `JellyfinClient.send` (`CascadeKit/JellyfinClient.swift` line 150): 45 `get` and 5 `getData` call sites, plus `post`, `postRaw`, `sendBody` and `delete`.

So Offline Mode swaps what answers those calls, not the screens. A pure **offline query engine** (`src/core/offline-query.ts`, `CascadeKit/OfflineQuery.swift`, both tested against the same fixture cases) takes a request (path plus params) and answers it from the catalog in Jellyfin's response shape. Both apps send the same paths since `8b17d3e` (see "Jellyfin 12" in the request map); param names differ only in case, and the engine matches them case-insensitively, as Jellyfin does.

The routes, each checked against Jellyfin 12.0's source (`Jellyfin.Api/Controllers` at the `v12.0` tag):

- `GET /Items` with the params the screens use: `IncludeItemTypes`, `ParentId` (a library, album, playlist, series or season), `Ids`, `ArtistIds`, `AlbumArtistIds`, `GenreIds`, `Genres` and `Artists` (names), `Years`, `SearchTerm`, `Recursive`, `Filters` (`IsFavorite`, `IsPlayed`, `IsResumable`), `IsFavorite`, `IsPlayed`, `SortBy` (`SortName`, `Name`, `DateCreated`, `DatePlayed`, `PlayCount`, `ProductionYear`, `Album`, `AlbumArtist`, `ParentIndexNumber`, `IndexNumber`, `Random`, comma-joined), `SortOrder`, `StartIndex`, `Limit`; `Fields`, `EnableImages`, `EnableUserData` accepted and ignored. Always returns `TotalRecordCount`. Sorting and filtering reuse the existing local rules (`src/core/library-browse.ts`, `CascadeKit/BrowseSort.swift`).
- `GET /Items/{id}` (one item, with chapters; a genre id answers the genre), `GET /Items/Latest` (a bare array), `GET /Items/Filters` (`{ Years }`), `GET /UserViews`, `GET /Users/{id}`.
- `GET /Playlists/{id}/Items`, `GET /Playlists/{id}`.
- `GET /Shows/{id}/Seasons`, `GET /Shows/{id}/Episodes`, `GET /Shows/NextUp`.
- `GET /Genres`, and the music artist and genre lists: `GET /Artists`, `GET /Artists/AlbumArtists` and `GET /MusicGenres`, which 12 marks Obsolete but whose named replacements (`GET /Persons`, `GET /Genres`) are not drop-in (no `sortBy` on `/Persons`; genre ids unverified for music). The apps keep using them until a check on the jellyfin12 server says the replacements work; the engine answers old and new alike, so that move needs no engine change.
- `GET /MediaSegments/{id}`.
- Anything it does not know answers an empty result with an "offline" marker, never a network call.

Then:

- **Desktop:** an `OfflineClient` with `jfClient`'s methods, swapped in while Offline Mode is on.
- **Apple:** `JellyfinClient.send` hands a `GET` to the engine while Offline Mode is on and returns its answer encoded as JSON, so `get<T>` decodes it exactly as it would a server reply and `getData` gets the bytes; no call site changes. Any other method is refused or queued (below) in the same place.
- **Writes** (rename, delete, add to playlist, edit metadata) are refused with a clear "not available offline" instead of failing on the network. The few that make sense offline (favorite, mark played) queue as pending user data. The request map lists every write with its decision.

**The desktop guard.** `jfClient` does not see everything the desktop sends: about 30 calls in `renderer.js` are raw `fetch` to the server (most writes, every Cascade plugin call, two lyrics sources), and `offline.js`, the metadata and lyrics editor windows, and the page's own `<img>`, `<video>` and `<track>` elements reach it too. Two layers:

1. **`jfFetch(path, init)`** in `renderer.js`: the one way the renderer talks to the server outside `jfClient`. It adds the auth header and, while Offline Mode is on, throws an `OfflineError` without touching the network (the caller shows "Not available offline"). Every raw `fetch(`${jf.url}...`)` moves to it; a test greps `renderer.js` for `fetch(` followed by `jf.url` so a new one cannot slip in. The editor windows are not opened offline.
2. **A backstop in main:** while Offline Mode is manual, `session.defaultSession.webRequest.onBeforeRequest` cancels any request to the server's origin (the same origin check `installConnectionHeaders()` already does), which also covers images, media elements and anything missed. In the unreachable state it stays off, since the probe must get through. The renderer tells main the state over IPC.

Apple's equivalent of the backstop is the gate in `send` plus the few paths outside it, each handled where it is: `ArtworkView` and friends read the catalog's art first, `PlaybackService` already plays downloads from disk, the background download session is paused, and `LyricsSave`, `QuickConnect`, `ServerMessages` and `LibraryActions.download` sit behind controls that are hidden offline.

The request map (`docs/offline-request-map.md`) is the full list of requests each screen sends, so the engine covers exactly that and nothing speculative.

### 3. What Offline Mode hides

Features that cannot work without the server are hidden, not left to fail: similar artists, instant mix and auto-mix, radio, Waterfall rooms, playing on other devices, remote control, the server's messages, the metadata and lyrics editors' saving, smart playlists over the whole library (they could run over downloads later), artist bios, and sign-out confirmation flows that need the server. Search searches the catalog.

### 4. The switch itself

One state on each platform: `online`, `offline (manual)`, `offline (unreachable)`.

- **Manual:** the Settings switch. No server requests at all while on, playback reports included (they queue as pending user data).
- **Unreachable:** entered when sign-in or the first library request finds no server; probed again on a network change and on a backoff timer (30 s, doubling to 5 minutes); left by itself when the server answers. A 401 or 403 means the session expired, not that the server is gone: that asks to sign in again, as `leaveOfflineModeIfReachable` already does.
- **Shown:** a small "Offline" pill in the top bar (desktop) or navigation bar (Apple), and a banner when it turned on by itself.
- **Mode switcher:** unchanged. Music and Video both show their downloaded side.
- **Updates:** no update check while Offline Mode is on, either state (the desktop's GitHub and `versions.json` requests in main.js `checkForUpdates()`, and the Mac's `UpdateService.check`). The moment it turns off, the app checks once, as it would at launch, so an update missed while offline shows up right away instead of at the next launch. A launch in Offline Mode defers its launch check the same way.
- **Other services:** iTunes art lookups, LRCLIB, Kugou, MusicBrainz, the Waterfall relay and translation model downloads are not asked while Offline Mode is on (the request map lists each).

### 5. Syncing what happened offline

Extend today's queued plays into a queue of user-data changes, each with its time:

- plays (exist), resume positions and played marks from watching or listening, favorites, and explicit mark played or unplayed.
- Positions and played marks go through `POST /UserItems/{id}/UserData`; plays through `/UserPlayedItems/{id}?datePlayed=` as today; favorites through `/UserFavoriteItems/{id}`. All three are current routes in Jellyfin 12.
- Coalesced per item before sending (only the last position matters, a favorite toggled twice is no change).

**Plays: catch up by snapshot.** Play history is what the person sees in History and Recently Played, and replaying plays blindly can interleave this device's offline listening into history someone else has added to since. So:

1. **While online, keep a snapshot** of the server's play history: the top 200 of `GET /Items?Filters=IsPlayed&SortBy=DatePlayed&SortOrder=Descending&Recursive=true&IncludeItemTypes=Audio,Movie,Episode`, stored as `(Id, LastPlayedDate, PlayCount)` in order. It is retaken a few seconds after each successful playback start report (debounced, one request), on every History or Home load, and right before a manual switch to Offline Mode. A drop into the unreachable state cannot be predicted, so the snapshot is the last one that succeeded; refreshing after each report keeps this device's own plays in it, so they do not read as someone else's.
2. **Offline,** History and Recently Played show the snapshot (downloaded items only, as everything else offline) with the offline plays on top, newest first.
3. **Back online, before sending anything,** the app asks for the same list and compares it with the snapshot.
   - **They match** (same ids, dates and counts, same order): nothing was played on this account anywhere else meanwhile. The app catches up: it replays the offline plays oldest first with their own dates, so the server's history reads exactly as if they had happened online.
   - **They differ:** someone played elsewhere. No catch-up runs. The offline plays stay queued and the download manager says so ("12 plays from while you were offline were not added to your history") with Add and Discard. Today both apps replay plays unconditionally; this replaces that.
4. **Either way,** the app then refreshes the catalog's `UserData` for every downloaded item from the server (`GET /Items?Ids=...`, 100 per request) and takes a new snapshot, so offline lists start from the server's truth next time.

**Positions, played marks and favorites** are not history and keep the per-item rule: a change made offline wins only if the server's value is older than it (compare `LastPlayedDate`), so watching on the TV while the phone was offline is not overwritten by the phone's stale position.

### 6. Video downloads

Asked per item: a movie, an episode, a season or a whole series. Downloading a series offers a toggle, "Download new episodes as they arrive", chosen per series at download time and changeable later from the download manager.

1. **Ask the server** with PlaybackInfo and a **download device profile**: an MP4 container, the video codecs this device decodes in hardware, AAC (Apple: also AC3 and E-AC3), external text subtitles.
2. **Three outcomes:**
   - **Direct play:** the original file plays here: download `/Items/{id}/Download` at full network speed.
   - **Remux:** only the container or audio needs changing (the usual case for an MKV with H.264 or HEVC): download the server's progressive transcode with video copied. Close to network speed, since the server does no video work.
   - **Re-encode:** the video codec is unplayable here, or image subtitles (PGS) must be burned in: the same progressive download, slower. The download manager says so ("Converting on the server") with an estimate, and the person can cancel.
3. **Subtitles:** text subtitles saved as WebVTT beside the file; image subtitles offered only as burned in.
4. **Quality:** a setting for video downloads: Original, 1080p or 720p. Defaults (decided): Original on desktop and Mac, 1080p on iPhone, for space. Anything below original forces the re-encode path.
5. **Playback:** the desktop plays the file through `cascade-offline://` with the subtitle tracks added as `<track>` elements; Apple plays the local file with `AVPlayer` and the subtitles side-loaded. Resume, chapters and intro skip come from the catalog. Trickplay thumbnails are skipped offline at first.

Open question for phase 3's start: a progressive transcode saved to disk is a fragmented MP4, which both players accept, but seeking in it can be slow without an index. Test on real files first; if it is a problem, remux the finished file locally (desktop: the optional ffmpeg; Apple: `AVAssetExportSession` with passthrough, which handles MP4 to MP4).

**Answered (2026-10-15): no local remux.** Jellyfin writes a progressive MP4 in Streaming context as `frag_keyframe+empty_moov+delay_moov`. On a 92 minute fragmented file AVPlayer went from seek to playing in 163 to 243 ms (an indexed copy: 150 to 188 ms) and Chromium in 120 to 382 ms (121 to 292 ms); only opening is slower, by up to a second. The server's own output seeked the same. Two things the test found instead: Jellyfin tags HEVC `hev1` on this path, which AVFoundation refuses outright, so Apple rewrites the sample entry to `hvc1` when a download lands; and the transcode has no Content-Length, so each app checks the last fragment's time against the runtime to catch one cut short.

### 7. The download manager

Above Settings in the sidebar on the desktop and the Mac, in both modes; on the iPhone, a row at the top of Settings and in the Library tab.

- **Downloading:** each item with progress, speed, the outcome from section 6 (Downloading, Converting on the server), pause, resume and cancel.
- **Downloaded:** grouped Music, Movies, TV, with sizes, play, and remove.
- **Storage:** total used, free space on the disk, and a storage limit setting (no limit by default on desktop and Mac; asked on the iPhone). Option to remove watched episodes a day after they are finished: on by default on the iPhone (decided), off on desktop and Mac. On the iPhone it must be disclosed, not only sit in Settings: say it where the person downloads an episode, season or series ("Watched episodes are removed a day after you finish them", with a way to turn it off right there) and beside the setting in the download manager.
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

Done (`docs/offline-request-map.md`). It also moved both apps off the item routes Jellyfin 12 marks Obsolete (`8b17d3e`), so the engine answers one set of paths.

### Phase 1: catalog and engine

- `src/core/offline-index.ts` and `OfflineIndex.swift`: version 2 with migration from version 1 (tested with a real version 1 file, its items landing in the placeholder library), the wider `slimItem` (section 1's field list), library ids and the stored libraries, the stored user, `UserData` with offline changes on top, the history snapshot, video collections (movie, season, series) and their removal rules, per-item subtitle files, lyrics.
- `src/core/offline-query.ts` and `CascadeKit/OfflineQuery.swift`: the engine, tested case by case from the phase 0 map. Shared fixture cases (the same catalog and request, the same expected answer) keep the two in step.

Done on `offline-mode`, with these notes for phase 2:

- Both engines answer every route in the request map's checklist and pass the same 73 cases in `test/fixtures/offline-query.json`. Keep one engine per catalog state (`offlineQuery(index)`, `OfflineQuery.Engine(index)`), not one per request. Measured on 20,000 songs: about 50 ms to build on the desktop, about 115 ms in Swift on Linux, then about 10 ms and 75 ms a request.
- The placeholder libraries only show if the app's fan-out asks for them. While Offline Mode is on, the swap point must add `placeholderLibraryIds()` / `OfflineQuery.placeholderLibraryIds` to the library ids a screen fans out over, so items not yet placed still appear.
- The online library lookup (plan section 1, "Library ids") should also refresh each stored item with the fields version 1 never kept: `ArtistItems`, `GenreItems`, `UserData`, `DateCreated`. Version 1 items have none of them, so offline they are missing from the artist and genre lists until refreshed.
- Not yet verified on a Mac: the Apple half was built and tested on Linux with `scripts/swift-linux-check.sh` (the pure files only). `swift test` and the three schemes must be run before phase 2 builds on it.

### Phase 2: the switch, the swap and the manager

- Settings switch, the three states, the probe, the pill and the banner.
- Desktop: `OfflineClient` swapped into `jfClient`, every raw server `fetch` moved to `jfFetch` (with the grep test), and main's origin block while manual; Apple: the engine inside `JellyfinClient.send`.
- Library ids looked up at download time, and the placeholder library resolved on the first online launch.
- The updater skipped while offline and run when Offline Mode turns off.
- Hide what section 3 lists; refuse writes clearly.
- Download manager for music on all three (desktop, Mac, iPhone), replacing the Downloads view.
- Lyrics download with tracks.
- Done when: with Offline Mode on and the network cable out, every music screen shows only downloaded music and plays it, and nothing is sent to the network (check with the network log on the desktop and a proxy on Apple).

**Phase 2 status (2026-10-14).** Desktop: done and smoke-tested in Electron under Xvfb (manual and unreachable states, zero requests to the server while manual, lyrics read from the catalog). Apple: done. `swift test` and the CascadeMac, CascadeiOS and CascadetvOS schemes pass on Xcode 27. On the Mac, a downloaded album showed in Home, Albums, Artists, Songs, search and Downloads with Offline Mode on, the process opened no socket the whole time, and turning it off placed the download in its real library. Fixed on the Mac: tvOS could drop into the unreachable state with an empty catalog (it now stays online), and Apple's placement now refreshes the fields version 1 never kept and runs right after each download, as the desktop's does. Still to check on real hardware: playback and lyrics offline on the Mac, the unreachable state and its banner (pull the network), the iPhone (background downloads, the pill and banner, Settings), and the desktop against a live server. Offline, the Mac's Music/Video switcher hides itself until a video is downloaded, which phase 3 makes possible.

### Phase 3: video

- Download profiles (desktop from the existing Electron device profile; Apple from `DeviceProfile.swift`'s video profile), the three outcomes, subtitles, quality setting.
- Offline playback on both, with resume, chapters and intro skip from the catalog.
- Done when: a movie in MKV with H.264 and DTS downloads as a remux at close to network speed and plays offline with its text subtitles on the desktop, the Mac and the iPhone; an HEVC file downloads as the original where the device decodes HEVC.

**Phase 3 status (2026-10-15).** Desktop and Apple: done, with the decisions below, plus remove-watched (planned for phase 4, pulled forward with the series toggle it interacts with). `npm test`, `npm run typecheck`, `swift test` and the CascadeMac, CascadeiOS and CascadetvOS schemes pass. Measured on jellyfin12 (12.2): an HEVC/E-AC3 MKV remuxed for Apple at 46 MB/s (ffmpeg copied both streams, 1410x realtime), a 720p re-encode ran at 32x realtime on the server's GPU, and progressive jobs are not throttled. The outcome (direct, remux, re-encode) is read by comparing the source's video stream with the TranscodingUrl, because TranscodeReasons cannot say whether video is copied; the cases are in `test/fixtures/offline-video.json`, shared by both test suites. The done-when cases: asked from the server's own host (a local connection), the H.264/DTS MKV episode is a remux (video copied, DTS to AAC, 976 MB in 16.5 s, ffmpeg at 74.6x), and an HEVC MP4 film (Iron Man) is the original file for both the desktop and Apple profiles. Note for "Original": a server with a remote bitrate limit (jellyfin12 has 6 Mbps, and its NetBird address counts as remote) re-encodes anything above it off the LAN, and the download manager says "Converting on the server". Seen working: on the desktop (Electron, against jellyfin12) an HEVC MKV downloaded as a remux, an H.264 MKV and an MP4 film as originals, placed in TV Shows and Movies, the Music/Video switcher shown in Offline Mode, the episode played from `cascade-offline://` with its WebVTT track showing, a seek in 68 ms, the watched mark, a 720p re-encode showing "Converting on the server · about 3 minutes left" and Cancel stopping the server's ffmpeg (whether the DELETE or the dropped connection stopped it is not told apart), an original MKV played offline with its subtitle track loading, and a 3.7 GB re-encode (estimated 3.66 GB) that kept going while another episode streamed as HLS in the same app and was stopped, then passed the whole-file check. On the Mac, the same HEVC episode downloaded as a remux, retagged `hvc1`, and played from disk in Offline Mode with its subtitle drawn, no sockets open; the switcher and TV Shows showed it. Not seen: the iPhone at all (background transfers of a video, the remove-watched disclosure dialog, 1080p default), the dropped-connection case on a phone going to sleep mid-transcode, burn-in from a desktop episode row (only the movie page offers it), a whole season or show downloaded and followed for real (the rules are tested), burn-in of picture subtitles (no PGS file on jellyfin12), remove-watched actually removing a file a day later, the desktop on Windows and Linux.

### Phase 4: sync and storage

- The user-data queue, coalescing and the conflict rule, tested.
- The history snapshot, the match check and the catch-up (and the Add or Discard prompt when it does not match), tested with recorded server lists; then the `UserData` refresh.
- Storage limit and remove-watched.
- Done when: an episode watched halfway offline shows that position on the server after reconnecting, and does not overwrite a newer position set elsewhere; songs played offline appear in the server's history at their real times when nothing was played elsewhere, and are held for the person's choice when something was.

**Phase 4 status (2026-10-17).** Desktop and Apple: done (branch `offline-mode-phase4`). The pure rules are `src/core/offline-sync.ts` and `CascadeKit/OfflineSync.swift`, both passing `test/fixtures/offline-sync.json`. Remove-watched landed in phase 3. Also in this phase: expired Spicy Lyrics are refetched through the lyrics waterfall when the app is back online, or dropped from the catalog when nothing answers, so they are never kept past their 25 days. Decisions and findings:

- Changes queue only offline (or when a report fails), coalesce per item, and are sent before the plays are replayed. That order matters: a replayed play moves the server's LastPlayedDate, which would otherwise beat a favorite made earlier offline.
- Favorites follow the LastPlayedDate rule as written, but Jellyfin keeps no date for a favorite, so LastPlayedDate is only a stand-in. A favorite made offline loses to anything played on that item elsewhere afterward. Worth revisiting if that bites.
- The snapshot is never retaken while plays wait for the compare. A successful start report no longer replays plays, because that report itself changes the history. A play queued during a short blip online now waits for the next connect.
- Positions are queued for video only. Jellyfin keeps no resume point for songs, and a song's play covers it.
- jellyfin12 (12.2) honors `LastPlayedDate` in a `POST /UserItems/{id}/UserData` body, and leaves fields that are not sent unchanged. It rejects the `X-Emby-Token` header with 401; the full `Authorization: MediaBrowser ... Token=` form works.
- Seen on jellyfin12, desktop (Electron, a throwaway profile):
  - An episode downloaded as the original and watched to 5:55 in manual Offline Mode had that position on the server after reconnecting, with the offline time.
  - A second episode, given a newer position by another write while the app was offline, kept it.
  - Two songs played offline appeared at the top of the server's history at their real times.
  - A song played offline after another play elsewhere was held, Downloads offered Add or Discard, and Discard put the catalog back to the server's counts.
  - A storage limit just above the current use refused a new album before any byte landed.
- Seen on jellyfin12, Mac (a debug copy with reports muted, driven by a temporary hook): the same cases, through `OfflineLibrary.sync`, plus a favorite made offline through `setFavorite`, which was queued and sent.
- Not seen:
  - The Mac's capture from the real video player (the hook recorded the stop the way `VideoPlayer` does).
  - The iPhone at all: the storage limit question, background downloads under a limit.
  - The desktop on Windows and Linux.
  - A refetch of Spicy Lyrics that had actually expired (the rule is tested).
- The first Mac run hit a silent skip: in its second round the queued play was neither replayed nor held, and nothing was logged. That run's test helper was itself broken (401s), and the clean second run did not repeat it, so the cause was not pinned down. It can only have been a sync asked for while one was running, or a history fetch that came back empty. Neither drops a sync any more: one asked for mid-run runs again afterward, a failed compare is retried (three tries, 15 s apart), and debug builds log each decision. Both were checked against a stubbed server in the desktop app.
- Found while testing, not fixed here: on the desktop, songs asked for while a video is downloading wait until the video finishes. The download pump's second worker exits when only videos are pending, and a later request does not wake it.

### Phase 5 (optional): local ffmpeg on the desktop

Bundle a GPL ffmpeg build per platform (compatible with Cascade's GPLv3), about 60 to 80 MB each. Download originals at full speed, then remux, or re-encode with VideoToolbox, NVENC or QuickSync, locally. Only worth it if phase 3 shows the server-side re-encode path is common and slow.

## For the agent building this

- Work on the `offline-mode` branch (made from `dev` for this). Open a pull request into `dev` when a phase is done and do not merge it yourself; never push to `stable`.
- Read this plan, the root `CODEMAP.md` and `apple/CODEMAP.md` first, and write the phase 0 map before changing code.
- **Never write a release marker in a commit subject line**: no `[BETA]`, no `Release (x.x.X)`, no bracketed platform list such as `[desktop]`. Markers in a first line on `dev` or `stable` start real builds and releases. Pull requests into `dev` are checked for them.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, with no session links. No em dashes anywhere, code included. American English. Do not hard-wrap Markdown.
- No new dependencies without asking in the pull request (phase 5's ffmpeg is the one planned exception, and it is optional).
- You cannot reach the maintainer's servers from the cloud, and their production server must never be written to. Mock the network in tests. Jellyfin's public demo server (demo.jellyfin.org) can be used for a read-only smoke test if it is up; nothing may depend on it.
- You likely cannot run the apps' UI or an emulator. In each pull request, list plainly what was built and tested and what still needs checking on a real device by the maintainer.
- Desktop: `npm test` and `npm run typecheck` must pass. Apple: `swift test` in `apple/CascadeKit`, and the `CascadeMac`, `CascadeiOS` and `CascadetvOS` schemes must build (tvOS gets none of this feature but must still compile).

## Testing rules

- Never write to the production server (`jellyfin.chaosinc.xyz`); use jellyfin12 on rogserver for live checks, and block playback reports while testing (see the project's notes).
- Pure logic (catalog rules, the engine, sync coalescing and conflicts) is tested in `test/` and `CascadeKit/Tests` before any screen uses it.
- Each phase ends with a check on real hardware for what tests cannot see: background downloads on the iPhone, playback, subtitles, and no network traffic in Offline Mode.

## Decisions for phase 3 (maintainer, 2026-10-14)

- Video download quality defaults: Original on desktop and Mac, 1080p on iPhone.
- New episodes of a downloaded series: a toggle offered when the series is downloaded, not a global setting.
- Remove watched episodes: on by default on the iPhone, disclosed where episodes are downloaded and in the download manager (section 7).
