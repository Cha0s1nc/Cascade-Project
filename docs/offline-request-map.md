# Offline Mode request map (phase 0)

Every request the desktop and Apple apps send to the Jellyfin server, per screen, with the params each uses, and a decision for every write. This is the list the offline query engine (`src/core/offline-query.ts`, `CascadeKit/OfflineQuery.swift`) is built to in phase 1, and nothing beyond it. The plan is `docs/offline-mode-plan.md`.

**Describes `offline-mode` at `8b17d3e`**: `dev` at `39f5a9d` plus the plan, a test fix and the move to Jellyfin's current item routes (section "Jellyfin 12"). Line numbers are for that commit. They rot: re-grep the function name before trusting one.

How it was made: every `jfGet`, `jfGetMerged`, `jfGetAllPaged`, `jfItemsByIds`, `jfClient.*` and `fetch(` in `renderer.js`, `waterfall.js`, `main.js`, `offline.js` and the editor windows; every `get`, `getData`, `post`, `postRaw`, `sendBody`, `delete` and `URLSession` call in `apple/CascadeKit/Sources` and `apple/App`; then each helper traced to the screens that call it.

## What this changes in the plan

These came out of the inventory and are now folded into `docs/offline-mode-plan.md`. Each is small, but the engine is wrong without it.

1. **One dialect, now.** The desktop used to ask `/Users/{userId}/Items`, `/Users/{userId}/Items/{id}` and `/Users/{userId}/Views`, which Jellyfin 12 marks Obsolete; Apple asked `/Items`, `/Items/{id}` and `/UserViews`. Commit `8b17d3e` moved the desktop (and Apple's last two holdouts) to the current routes, so both apps send the same paths. Param names still differ in case (`IncludeItemTypes` on the desktop, `includeItemTypes` on Apple); Jellyfin binds query names case-insensitively, and the engine must too. Shared fixture cases include both spellings.
2. **Library fan-out uses `ParentId` = a library id.** Both apps send one request per selected library with `ParentId` set to the library (`getMerged`, `getAllPaged`, `getGrouped` on the desktop; `itemsAcrossLibraries`, `videoGroups`, `continueWatchingMerged` on Apple), and merge the answers. So `ParentId` means two things: a library view, or an album, playlist, series or season. The catalog records, per item, the library it was downloaded from, and the engine answers `ParentId = <library id>` with that library's downloaded items. Without it every music screen answers empty for anyone who selected libraries. Downloads from before catalog v2 go to a placeholder library (section "Decisions").
3. **`/UserViews` keeps the real library ids.** Saved library selections (`jf.libraryIds`, `cascade.movieLibraryIds`, `cascade.showLibraryIds`) are ids. The offline answer is the libraries the downloaded items came from, with their real ids, names and `CollectionType`, stored in the catalog, not invented "Downloaded Music" views.
4. **Routes the plan did not list but the screens send:** `/Artists/AlbumArtists` (Apple's Artists tab and similar artists), `/MusicGenres` (both Genres screens), `/Genres` (Apple's video genre filter), `/Items/Filters` (Apple's decade filter), `/Items/Latest` (Apple's video Home; answers a bare array, not an `Items` envelope), `/Shows/NextUp` (both video Homes), `/Users/{id}` (the session check and permissions), `/Playlists/{id}` (Apple's playlist page, a `PlaylistDto`), `/MediaSegments/{id}` (intro skip, both). `/Items/{id}` carries chapters (and trickplay on Apple) by itself.
5. **Params the plan did not list:** `AlbumArtistIds` (Apple's artist page), `Genres` and `Artists` by name (smart playlists, Apple's genre filter), `Years`, `IsFavorite` and `IsPlayed` as their own params (not only inside `Filters`), `SeasonId`, `EnableResumable`, `GroupItems`, `EnableImages`, `EnableUserData`. `AlbumIds` and `SeriesId`, which the plan listed, are sent by no screen.
6. **`SortBy` keys in use:** `SortName`, `Name`, `DateCreated`, `DatePlayed`, `PlayCount`, `ProductionYear`, `Album`, `AlbumArtist`, `ParentIndexNumber`, `IndexNumber`, `Random`, comma-joined (Apple appends `SortName,AlbumArtist,Album` as tiebreakers, `withTiebreakers` in `Library.swift`). The engine needs all of them, with `SortOrder`.
7. **Paging.** The desktop's `getAll` reads `TotalRecordCount` from the first page and asks the rest by `StartIndex`; Apple pages until a page comes back short (`videoGroups` in 300s, `loadPaged` in 200s). The engine honors `StartIndex` and `Limit` and always returns `TotalRecordCount`.
8. **Fields the catalog must keep, because screens read them:** listed in full in the plan, section 1. The ones today's `slimItem` drops: `UserData` (on nearly every list), `MediaSources` (bitrate for the cross-library merge, and the source id video needs), `MediaStreams`, `Chapters`, `Genres` and `GenreItems`, `ArtistItems` and `AlbumArtists`, `DateCreated`, `Overview`, `CanDelete`, and the video fields.
9. **The desktop swap point does not cover everything.** `jfClient` carries the reads, but about 30 calls in `renderer.js` are raw `fetch` to the server (most of the writes, every Cascade plugin call, two lyrics sources), and the editor windows, `offline.js`, `<img>`, `<video>` and `<track>` have their own. Swapping `jfClient` alone leaves those hitting the network. The plan, section 2, now has the guard: every raw call moves to one `jfFetch`, and main blocks the server's origin as a backstop.
10. **The Apple swap point is `JellyfinClient.send`, not `get`.** There are 45 `get` and 5 `getData` call sites (not the plan's 34), plus `post`, `postRaw`, `sendBody` and `delete`, and every one passes through `send`. One gate there catches every API call. What it does not see: images (`ArtworkView` and friends fetch through `ProxyConnection.shared.session(for:)`), AVPlayer streams, the background download session, `LyricsSave`, `QuickConnect`, `ServerMessages` and `LibraryActions.download`; the plan says what each does offline.
11. **Not everything is JSON.** Art, streams, subtitles, trickplay sheets and lyrics are separate reads (section "Reads that are not JSON"). The desktop already maps covers to `cascade-offline://` in `artUrl()`; posters, backdrops, stills, playlist art and Apple's `imageUrl(itemId:type:width:height:)` still need the same treatment.

## Jellyfin 12

Checked against the server's own source at the `v12.0` tag (`Jellyfin.Api/Controllers/*.cs`, `RequestHelpers.cs`, `AuthorizationContext.cs`), not from memory, and against `v10.11.0` where behavior had to match.

**Routes the apps used that 12 marks Obsolete:**

| Route | 12 says | What Cascade does now |
|---|---|---|
| `GET /Users/{userId}/Items` | Obsolete (`GetItemsByUserIdLegacy`) | Desktop moved to `GET /Items` in `8b17d3e`. |
| `GET /Users/{userId}/Items/{id}` | Obsolete (`GetItemLegacy`, which only calls `GetItem`) | Desktop and Apple (`mediaDetail`, `videoDetails`) moved to `GET /Items/{id}`. |
| `GET /Users/{userId}/Views` | Obsolete (`GetUserViewsLegacy`) | Desktop moved to `GET /UserViews`. |
| `GET /Artists` | Obsolete, "Use GetPersons" | Still used (desktop Artists, similar artists, search; Mac search). See below. |
| `GET /Artists/AlbumArtists` | Obsolete, "Use GetPersons" | Still used (Apple Artists, similar artists). See below. |
| `GET /MusicGenres` | Obsolete, "Use GetGenres instead", and hidden from the OpenAPI document | Still used (both Genres screens, Apple's genre filter for music). See below. |
| `POST /Items/{id}/PlaybackInfo` with `UserId` in the query | The query params are `[ParameterObsolete]`; the body is read when they are absent (10.11 too) | Left as is: Apple's `resolveStream` carries a comment that the body alone failed on some proxied setups, and 12 still binds the param. |

Dropping `userId` from the moved calls is safe: `RequestHelpers.GetUserId` falls back to the signed-in user when none is sent, identically in 10.11.0 and 12.0. 12.0 itself deleted other routes it had marked Obsolete (`/Users/{userId}/EasyPassword`, `/Items/{id}/CriticReviews`, `GET /QuickConnect/Initiate` among them), so Obsolete here means "going".

**Why `/Artists`, `/Artists/AlbumArtists` and `/MusicGenres` stay for now.** Their named replacements are not drop-in. `GetPersons` takes `parentId` and `personTypes` (12's `PersonKind` has `Artist` and `AlbumArtist`) but no `sortBy` or `sortOrder`, and answers people, not `MusicArtist` items, so artist pages, ids and `ArtistIds` filters may not line up. `GetGenres` takes `includeItemTypes` and `parentId`, but whether its ids work in `GenreIds` on music items, as `/MusicGenres` ids do, needs a live check. Both need the jellyfin12 test server (rogserver), which this session cannot reach. Until then the engine answers both the old and the new routes, so moving later needs no engine change.

**Everything else the apps send is current in 12:** `/Items`, `/Items/{id}`, `/Items/Latest`, `/Items/Filters` (still there, named `GetQueryFiltersLegacy` beside a newer `/Items/Filters2`, not marked Obsolete), `/UserViews`, `/Users/{id}`, `/Genres`, `/Playlists/*`, `/Shows/*`, `/MediaSegments/{id}`, `/Items/{id}/InstantMix`, `/Artists/{id}/Similar`, `/Items/{id}/Download`, `/Audio/{id}/universal`, `/Audio/{id}/Lyrics`, `/Videos/{id}/stream`, the subtitle and trickplay routes, `/Videos/ActiveEncodings`, `/LiveStreams/Close`, `/Sessions/*`, `/UserPlayedItems/{id}`, `/UserFavoriteItems/{id}`, `/Library/Refresh`, `/Users/Password`, `/QuickConnect/*` (both apps already `POST` to `Initiate`), `/Branding/Configuration`, `/System/Info/Public`.

**Authentication.** 12 turns legacy authorization off by default and on upgrade: with it off, the server reads only `Authorization: MediaBrowser ..., Token="..."` and the `ApiKey` query param, and ignores `X-Emby-Authorization`, `X-Emby-Token`, `X-MediaBrowser-Token`, `api_key` and the `Emby` scheme name. Both apps already send exactly the accepted two (`authHeader()` in `src/core/jellyfin.ts`, the editor windows' `jfAuthorization`, Apple's `authHeader`; image and stream URLs use `ApiKey`). Nothing to change.

**`GET /Items` behavior changes in 12** that the engine copies: a request with `includeItemTypes` on a library defaults to `recursive=true`; `includeItemTypes=Playlist` with a `ParentId` that is not a playlist lists the playlists holding that parent's items; an invalid set of filters answers 400.

## Desktop

All in `renderer.js` unless named. `jfGetMerged` and `jfGetAllPaged` fan out per selected music library with `ParentId`; video calls pass the movie or show library ids explicitly. `uid` is `jf.userId`.

### Launch and session

| What | Request | Params | Where |
|---|---|---|---|
| Token check, permissions | `GET /Users/{uid}` | none | `connect()` 832 |
| Libraries | `GET /UserViews` | none | `connect()` 823, `populateLibraryPicker()` 1375 |
| Login disclaimer (sign-in screen) | `GET /Branding/Configuration` | none | `fetchLoginDisclaimer()` in `src/core/server-messages.ts` |
| Sign in | `POST /Users/AuthenticateByName`, `/QuickConnect/*`, `/Users/AuthenticateWithQuickConnect` | | `src/core/jellyfin.ts` |
| Cascade plugin probe | `GET /CascadeServer/Info`, then `/CascadeLyrics/Info` on 404 | none | `probeCascadePlugin()` 11070 |
| Server style | `GET /CascadeServer/Style` | none | `fetchServerStyle()` 11368 |
| Remote control | WebSocket `/socket`, `POST /Sessions/Capabilities/Full` | | `src/core/remote-control.ts` |
| Restore last queue | `GET /Items` | `Ids` (100 per request), `Fields=AlbumId,AlbumPrimaryImageTag,UserData,MediaStreams,MediaSources` | `restoreLastQueue()` 5146 via `jfItemsByIds()` |
| Replay offline plays | `POST /UserPlayedItems/{id}` | `userId`, `datePlayed` | `replayOfflinePlays()` 8099 |

### Home (`data-view="home"`)

| What | Request | Params | Where |
|---|---|---|---|
| Recently played | `GET /Items`, merged | `SortBy=DatePlayed`, `SortOrder=Descending`, `IncludeItemTypes=Audio`, `Filters=IsPlayed`, `Limit=24`, `Recursive`, `Fields=AlbumId,AlbumPrimaryImageTag,UserData` | `loadRecentlyPlayed()` 2186 |
| Recently added | `GET /Items`, merged | `SortBy=DateCreated`, `SortOrder=Descending`, `IncludeItemTypes=MusicAlbum`, `Limit=24`, `Recursive` | `loadRecentlyAdded()` 2227 |
| Continue watching | `GET /Items`, merged over movie and show libraries | `SortBy=DatePlayed`, `SortOrder=Descending`, `IncludeItemTypes=Movie,Episode`, `Filters=IsResumable`, `Recursive`, `Limit=24`, `Fields=UserData,ProductionYear,SeriesPrimaryImageTag` | `loadContinueWatching()` 4858 |
| Next up | `GET /Shows/NextUp`, merged over show libraries | `UserId`, `Limit=24`, `EnableResumable=false`, same `Fields` | `loadContinueWatching()` 4865 |

### Albums (`albums`)

| What | Request | Params | Where |
|---|---|---|---|
| Grid | `GET /Items`, all pages | `SortBy=SortName`, `SortOrder=Ascending`, `IncludeItemTypes=MusicAlbum`, `Recursive`, `Fields=SortName,Genres,ProductionYear,UserData`, `Limit=500` | `loadAlbums()` 2479 |
| Album page | `GET /Items/{albumId}` | none | `openAlbum()` 2562 |
| Album tracks (page, menus, download) | `GET /Items` | `ParentId={albumId}`, `SortBy=ParentIndexNumber,IndexNumber,SortName`, `IncludeItemTypes=Audio`, `Recursive`, `Fields=AlbumId,AlbumPrimaryImageTag` | `fetchAlbumTracks()` 2541 |

Sorting and filtering on the grid are local (`src/core/library-browse.ts`), never a refetch.

### Artists (`artists`)

| What | Request | Params | Where |
|---|---|---|---|
| Grid | `GET /Artists`, all pages | `UserId`, `SortBy=SortName`, `SortOrder=Ascending`, `Fields=SortName,DateCreated,UserData`, `Limit=500` | `loadArtists()` 2639 |
| Artist item (bio) | `GET /Items/{artistId}` | `Fields=Overview` | `openArtist()` 2746 |
| Artist albums | `GET /Items`, merged | `ArtistIds`, `IncludeItemTypes=MusicAlbum`, `Recursive`, `SortBy=ProductionYear,SortName`, `SortOrder=Descending` | `openArtist()` 2747 |
| Artist songs (page, top songs, menus) | `GET /Items`, merged | `ArtistIds`, `IncludeItemTypes=Audio`, `Recursive`, `SortBy=Album,ParentIndexNumber,IndexNumber`, `Fields=AlbumId,AlbumPrimaryImageTag` | `fetchArtistSongs()` 2653 |
| Similar artists | `GET /Artists/{id}/Similar` plus `GET /Artists` (all pages, `Limit=500`) | `UserId`, `Limit=24` | `fetchSimilarArtists()` 2699, 2700. Hidden offline. |

### Songs (`songs`)

| What | Request | Params | Where |
|---|---|---|---|
| Every song | `GET /Items`, all pages | `SortBy=SortName`, `SortOrder=Ascending`, `IncludeItemTypes=Audio`, `Recursive`, `Fields=AlbumId,AlbumPrimaryImageTag,UserData,DateCreated`, `Limit=500` | `fetchAllSongs()` 2871 |

### Playlists (`playlists`)

| What | Request | Params | Where |
|---|---|---|---|
| Grid | `GET /Items` (not merged) | `SortBy=SortName`, `SortOrder=Ascending`, `IncludeItemTypes=Playlist`, `Recursive`, `Fields=ChildCount,DateCreated,UserData` | `loadPlaylists()` 3106 |
| Playlist description | `GET /Items/{id}` | `Fields=Overview` | `openPlaylist()` 3707 |
| Playlist tracks | `GET /Playlists/{id}/Items` | `UserId`, `Fields=AlbumId,AlbumPrimaryImageTag,DateCreated` | `fetchPlaylistTracks()` 3165 |
| Edit check | `GET /Items/{id}` | `Fields=Overview`, reads `CanDelete` | `exitPlEditMode()` 3265 |
| Favorites (smart) | `GET /Items`, merged | `IncludeItemTypes=Audio`, `Recursive`, `Filters=IsFavorite`, `SortBy=SortName`, `SortOrder=Ascending`, `Fields=AlbumId,AlbumPrimaryImageTag` | `SMART_PLAYLISTS.favorites` 3728 |
| Most played (smart) | `GET /Items`, merged | `IncludeItemTypes=Audio`, `Recursive`, `SortBy=PlayCount`, `SortOrder=Descending`, `Limit=200`, same `Fields` | `SMART_PLAYLISTS['most-played']` 3744 |
| User smart playlist | `GET /Items`, all pages | `IncludeItemTypes=Audio`, `Recursive`, `Fields=AlbumId,AlbumPrimaryImageTag,Genres,DateCreated`, plus `toItemsQuery()`: `Genres` (a name), `Artists` (a name), `Years`, `IsPlayed`, `IsFavorite` | `fetchUserSmartPlaylist()` 3803 |
| Playlist art | `GET /Items/{id}/Images/Primary` | `fillHeight`, `fillWidth`, `quality`, `ApiKey` | `playlistArtUrl()` 3347 |

Smart playlist definitions are local; the rules are re-checked client-side (`applySmartPlaylistRules`), so the engine only has to prefilter correctly or not at all.

### Genres (`genres`)

| What | Request | Params | Where |
|---|---|---|---|
| Grid | `GET /MusicGenres`, merged | `UserId` | `loadGenres()` 4135 |
| Genre item | `GET /Items/{genreId}` | none | `openGenre()` 4202 |
| Genre albums | `GET /Items`, all pages | `GenreIds`, `IncludeItemTypes=MusicAlbum`, `Recursive`, `Fields=SortName,ProductionYear,UserData`, `SortBy=SortName`, `SortOrder=Ascending`, `Limit=500` | `fetchGenreAlbums()` 4150 |
| Genre songs | `GET /Items`, all pages | `GenreIds`, `IncludeItemTypes=Audio`, `Recursive`, `Fields=AlbumId,AlbumPrimaryImageTag,UserData,DateCreated,SortName`, `SortBy=SortName`, `SortOrder=Ascending`, `Limit=500` | `fetchGenreSongs()` 4161 |

### History (`history`)

| What | Request | Params | Where |
|---|---|---|---|
| Played songs | `GET /Items`, all pages | `SortBy=DatePlayed`, `SortOrder=Descending`, `IncludeItemTypes=Audio`, `Filters=IsPlayed`, `Recursive`, `Fields=AlbumId,AlbumPrimaryImageTag,UserData,SortName`, `Limit=500` | `loadHistory()` 4255 |

### Radio (`radio`)

`GET /LiveTv/Channels` (`userId`) in `loadRadio()` 1589; playing a station is `POST /Items/{id}/PlaybackInfo` and `POST /LiveStreams/Close` (`src/core/radio.ts`). Hidden offline.

### Movies and Shows (`movies`, `shows`)

| What | Request | Params | Where |
|---|---|---|---|
| Grid, one library | `GET /Items`, all pages | `SortBy=SortName`, `SortOrder=Ascending`, `IncludeItemTypes=Movie` or `Series`, `Recursive`, `Fields=UserData,ProductionYear,Genres`, `Limit=500`, `ParentId` per library | `loadPosterGrid()` 4826 |
| Grid, grouped by library | same, `getAllGrouped` | same | `loadPosterGrid()` 4823 |
| Movie page | `GET /Items/{id}` | `Fields=Overview,MediaStreams,MediaSources,Genres` | `openMovie()` 4927 |
| Series page | `GET /Items/{id}` | `Fields=Overview,Genres` | `openSeries()` 4972 |
| Seasons | `GET /Shows/{id}/Seasons` | `UserId`, `Fields=UserData` | `openSeries()` 4973 |
| Every episode (Continue button) | `GET /Shows/{id}/Episodes` | `UserId`, `EnableImages=false` | `openSeries()` 4975 |
| Season episodes | `GET /Shows/{id}/Episodes` | `SeasonId`, `UserId`, `Fields=Overview,MediaStreams,MediaSources,UserData` | `loadEpisodes()` 5047, Continue 5024 |

### Search (the top bar dropdown, every view)

`runSearch()` 13253 to 13260, all at once:

| Kind | Request | Params |
|---|---|---|
| Songs | `GET /Items`, merged | `SearchTerm`, `Recursive`, `Limit=10`, `IncludeItemTypes=Audio`, `Fields=AlbumId,AlbumPrimaryImageTag` |
| Albums | same | `SearchTerm`, `Recursive`, `Limit=8`, `IncludeItemTypes=MusicAlbum` |
| Artists | `GET /Artists`, merged | `SearchTerm`, `UserId`, `Limit=8` |
| Movies | `GET /Items`, merged over movie libraries | `SearchTerm`, `Recursive`, `Limit=8`, `IncludeItemTypes=Movie`, `Fields=ProductionYear` |
| Shows | same over show libraries | `IncludeItemTypes=Series`, otherwise the same |

### Downloads (`downloads`)

No server reads: the view reads the index over IPC. Downloading reads the item lists above (`fetchAlbumTracks`, `fetchPlaylistTracks`), then `offline.js` fetches `GET /Items/{id}/Download` (160) and `GET /Items/{id}/Images/Primary?maxWidth=600&quality=90&format=Jpg` (265).

### Settings (`settings`)

`GET /UserViews` (library picker), the plugin probe and server style above, Quick Connect approval (`POST /QuickConnect/Authorize`), library scan (`POST /Library/Refresh`, 1340), server style publish (`PUT`/`DELETE /CascadeServer/Style`, 11430).

### Playback, Now Playing and the queue

| What | Request | Params | Where |
|---|---|---|---|
| Stream negotiation | `POST /Items/{id}/PlaybackInfo` | body: `UserId`, `MaxStreamingBitrate`, `DeviceProfile`, `AutoOpenLiveStream`, `AudioStreamIndex` | `resolveStream()` in `src/core/playback.ts`, skipped for a downloaded track (`resolveTrackStream()` 575) |
| Stop a transcode | `DELETE /Videos/ActiveEncodings` | `deviceId`, `playSessionId` | `stopActiveEncoding()`, renderer 5924 |
| Reports | `POST /Sessions/Playing`, `/Progress`, `/Stopped` | | `src/core/playback-reporting.ts` |
| Chapters | `GET /Items/{id}` | `Fields=Chapters` | `loadChapters()` 5289 |
| Intro and credits | `GET /MediaSegments/{id}` | none | `loadSegments()` 5335 |
| Normalization gain | `GET /Items/{id}` | none, reads `NormalizationGain` | `_normalizationDb()` 8367 |
| Instant mix (menus, queue) | `GET /Items/{id}/InstantMix` | `UserId`, `Limit=50` or `25`, `Fields=AlbumId,AlbumPrimaryImageTag` | `instantMixAndPlay()` 4398, `ctx-instant-mix` 10378. Hidden offline. |
| Auto-mix at the end of the queue | `GET /Items/{id}/InstantMix` | `UserId`, `Limit=25` | `continueWithAutoMix()` 6237. Off offline. |
| Refresh the playing item after a metadata save | `GET /Items` | `Ids`, `Fields=AlbumId,AlbumPrimaryImageTag,UserData` | 12038 |
| Media info dialog | `GET /Items/{id}` | none | `openMediaInfoFor()` 10556 |
| Lyrics | see "Lyrics" below | | `_lyricsWaterfall()` |

### Add to playlist dialog

`GET /Items` (`IncludeItemTypes=Playlist`, `Recursive`, `SortBy=SortName`) in `atpLoadPlaylists()` 10417, and per playlist `GET /Items` (`ParentId={playlistId}`, `EnableImages=false`, `EnableUserData=false`, `Fields=`) in `_atpMarkContaining()` 10461. Hidden offline, since adding is a write.

### Remote control, devices and Waterfall

- Casting to this app: `jfItemsByIds()` with `Fields=AlbumId,AlbumPrimaryImageTag,UserData,MediaStreams,MediaSources` (931).
- Devices panel: `GET /Sessions` (`controllableByUserId`, 1043), `POST /Sessions/{id}/Playing/{command}`, `/Command`, `/Playing`.
- `waterfall.js`: `GET /System/Info/Public` (127), `GET /Items` with `Ids` and `Fields=PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag,UserData` (340, 408), and the relay.

All hidden offline (plan section 3).

### Cascade plugin reads

`GET /CascadeServer/AnimatedArt/{id}` and a `HEAD` on the video it names (`pluginCoverVideoUrl()` 476, 508), `POST /CascadeServer/Explicit/Query` (`_flushExplicit()` 11486), `GET /CascadeServer/SpotifyId/{id}` (11630), `GET /CascadeServer/SpicyLyrics/{id}` (11799).

### Editor windows

- `metadata-editor.html`: `GET /Items/{id}` (260), `POST /Items/{id}` (313), its art.
- `lyrics-editor.html`: art, `GET /Audio/{id}/universal` (674) to play along, `POST` to the plugin lyrics route (1466).

## Apple (iOS, tvOS, Mac)

Helpers are in `CascadeKit`; screens are in `App/Sources` (all platforms) and `App/Mac`. `itemsAcrossLibraries` fans out per selected music library with `parentId`. `uid` is `currentConfig.userId`. Every `/Items` call carries `userId`.

### Launch and session

| What | Request | Params | Where |
|---|---|---|---|
| Sign in | `POST /Users/AuthenticateByName`, `/QuickConnect/*` | | `JellyfinClient.authenticate`, `QuickConnect.swift` |
| Login disclaimer | `GET /Branding/Configuration` | | `ServerMessages.swift` |
| Permissions | `GET /Users/{uid}` | none, reads `Policy` | `userPolicy()` (`Permissions.swift`), `AppState` 470 |
| Live TV access (Mac radio) | `GET /Users/{uid}` | none | `hasLiveTvAccess()` (`Radio.swift`), `AppState` 474 |
| Server style | `GET /CascadeServer/Style` | none | `AppState` 506 |
| Remote control | WebSocket, `POST /Sessions/Capabilities/Full` | | `RemoteControl.swift` |
| Restore last queue (Mac) | `GET /Items` | `ids` (chunked), `fields=DateCreated,PrimaryImageAspectRatio,MediaSources` | `restoredItems(ids:)` (`QueuePersistence.swift`), `PlaybackPersistence` 121 |
| Replay offline plays | `POST /UserPlayedItems/{id}` | `userId`, `datePlayed` | `OfflineLibrary.replayPlays` |
| Libraries (also inside every merged query when none are chosen) | `GET /UserViews` | `userId` | `views()` (`Library.swift`) |

### Home, Music mode (`HomeView`)

| What | Request | Params | Helper |
|---|---|---|---|
| Recently added | `GET /Items`, merged | `recursive`, `includeItemTypes=MusicAlbum`, `sortBy=DateCreated`, `sortOrder=Descending`, `limit=24` | `recentlyAdded()` |
| Recently played | `GET /Items`, merged | `recursive`, `includeItemTypes=Audio`, `sortBy=DatePlayed`, `sortOrder=Descending`, `filters=IsPlayed`, `fields=DateCreated,PrimaryImageAspectRatio`, `limit=24` | `recentlyPlayed()` |
| Frequently played | `GET /Items`, merged | same with `sortBy=PlayCount`, `limit=20` | `frequentlyPlayed()` |
| Playlists row | `GET /Items` | `includeItemTypes=Playlist`, `recursive`, `sortBy=SortName`, `sortOrder=Ascending`, `fields=ChildCount` | `playlists()` |

### Home, Video mode (`VideoBrowse.swift`)

| What | Request | Params | Helper |
|---|---|---|---|
| Continue watching | `GET /Items` per movie and show library | `includeItemTypes=Movie,Episode`, `filters=IsResumable`, `recursive`, `parentId`, `sortBy=DatePlayed`, `sortOrder=Descending`, `fields=UserData,ProductionYear,SeriesPrimaryImageTag`, `limit=24` | `continueWatchingMerged()` |
| Next up | `GET /Shows/NextUp` per show library | `parentId`, `fields` as above, `limit=24`, `enableResumable=false` | `continueWatchingMerged()` |
| Latest movies, latest episodes | `GET /Items/Latest` per library (bare array reply) | `includeItemTypes=Movie` or `Episode`, `parentId`, `limit=20`, `groupItems=false`, `fields=ProductionYear,DateCreated,SeriesPrimaryImageTag` | `latestVideo(_:libraryIds:)` |

### Albums (`AlbumsView`)

| What | Request | Params | Helper |
|---|---|---|---|
| Grid, paged in 200s | `GET /Items`, merged | `recursive`, `includeItemTypes=MusicAlbum`, `sortBy` (with tiebreakers), `sortOrder`, `limit`, `startIndex`, filter: `isFavorite`, `genres` (name), `years`, `isPlayed` | `albums(...)` |
| Recently played sort | `GET /Items`, merged, twice | played tracks: `includeItemTypes=Audio`, `sortBy=DatePlayed`, `sortOrder=Descending`, `filters=IsPlayed`, `limit=1000`; then their albums: `includeItemTypes=MusicAlbum`, `ids`, filter | `recentlyPlayedAlbums()` |
| Sort and filter menus | `GET /MusicGenres` merged (`sortBy=SortName`), `GET /Items/Filters` per library (`parentId`, `includeItemTypes`, `recursive`, reads `Years`) | | `genres()`, `years(of:)`, `BrowseControls` 106, 110 |
| Album page | `GET /Items` | `parentId={albumId}`, `sortBy=ParentIndexNumber,IndexNumber,SortName`, `fields=DateCreated,PrimaryImageAspectRatio` | `tracks(inAlbum:)`, `AlbumDetailView` 41 |

### Artists (`ArtistsView`, `ArtistDetailView`)

| What | Request | Params | Helper |
|---|---|---|---|
| Grid | `GET /Artists/AlbumArtists`, merged | `sortBy`, `sortOrder`, `isFavorite`, `limit`, `startIndex`, filter | `artists(...)` |
| Artist item | `GET /Items/{id}` | `userId` | `item(id:)` |
| Albums | `GET /Items`, merged | `albumArtistIds`, `includeItemTypes=MusicAlbum`, `recursive`, `sortBy=ProductionYear,SortName`, `sortOrder=Descending` | `albums(byArtist:)` |
| Songs (top songs, play) | `GET /Items`, merged | `artistIds`, `includeItemTypes=Audio`, `recursive`, `sortBy=Album,ParentIndexNumber,IndexNumber`, `fields`, `limit=500` | `tracks(byArtist:)` |
| Similar | `GET /Artists/{id}/Similar` (`limit=24`) and `GET /Artists/AlbumArtists` merged (`enableImages=false`, `enableUserData=false`) | | `similarArtists(to:)`. Hidden offline. |

### Songs (`SongsView`, Mac `SongsTable`)

| What | Request | Params | Helper |
|---|---|---|---|
| List, paged | `GET /Items`, merged | `recursive`, `includeItemTypes=Audio`, `sortBy` (with tiebreakers), `sortOrder`, `fields=DateCreated,PrimaryImageAspectRatio`, `limit`, `startIndex`, filter | `songs(...)` |
| Shuffle all | same | `sortBy=Random`, `limit=1000` | `randomSongs()` |

### Playlists (`PlaylistsView`, `SmartPlaylistsView`, Mac `MacPlaylistDetail`)

| What | Request | Params | Helper |
|---|---|---|---|
| List | `GET /Items` (not merged) | `includeItemTypes=Playlist`, `recursive`, `sortBy`, `sortOrder`, `fields=ChildCount` | `playlists()` |
| Tracks | `GET /Playlists/{id}/Items` | `userId`, `fields=DateCreated,PrimaryImageAspectRatio` | `tracks(inPlaylist:)` |
| Current name (Mac) | `GET /Items` | `ids={playlistId}` | `items(ids:)`, `MacPlaylistDetail` 215 |
| Public and editable (Mac) | `GET /Playlists/{id}` (reads `OpenAccess`) and `GET /Items/{id}` (`userId`, reads `CanDelete`) | | `playlistInfo()` |
| Favorites | `GET /Items`, merged | `recursive`, `includeItemTypes=Audio`, `filters=IsFavorite`, `sortBy=SortName`, `sortOrder=Ascending` | `favoriteSongs()` |
| Most played | `GET /Items`, merged | `recursive`, `includeItemTypes=Audio`, `sortBy=PlayCount`, `sortOrder=Descending`, `limit=200` | `mostPlayedSongs()` |
| User smart playlist | `GET /Items`, merged | `recursive`, `includeItemTypes=Audio`, `sortBy=SortName`, `fields=Genres,DateCreated,SortName,ProductionYear`, plus the playlist's prefilter: `genres`, `artists`, `years`, `isPlayed`, `isFavorite` | `songs(matching:)` |
| Genre list for the rule builder | `GET /MusicGenres`, merged | | `genres()`, `SmartPlaylistsView` 212 |

### Genres (`GenresView`)

| What | Request | Params | Helper |
|---|---|---|---|
| List | `GET /MusicGenres`, merged | `sortBy=SortName` | `genres()` |
| Genre albums | `GET /Items`, merged | `includeItemTypes=MusicAlbum`, `genreIds`, `limit=1000` | `albums(limit:genreId:)` |
| Genre songs, paged | `GET /Items`, merged | `includeItemTypes=Audio`, `genreIds`, `limit`, `startIndex` | `songs(...)` |
| Play, shuffle | same | `sortBy=AlbumArtist,Album,ParentIndexNumber,IndexNumber`, no limit; or `sortBy=Random`, `limit=1000` | `songs(inGenre:)`, `randomSongs(genreId:)` |

### History (`HistoryView`)

`GET /Items`, merged: `recursive`, `includeItemTypes=Audio`, `filters=IsPlayed`, `sortBy=DatePlayed`, `sortOrder=Descending`, `fields=DateCreated,PrimaryImageAspectRatio`, `limit=1000` (`playHistory()` in `PlayHistory.swift`).

### Movies and Shows (`VideoGridView`, `VideoViews.swift`)

| What | Request | Params | Helper |
|---|---|---|---|
| Grid, per library, paged in 300s | `GET /Items` | `includeItemTypes=Movie` or `Series`, `recursive`, `parentId`, `sortBy`, `sortOrder`, `fields=ProductionYear,Genres`, `limit=300`, `startIndex`, filter | `videoGroups(...)` |
| Filter menus | `GET /Genres` per library (`includeItemTypes`, `parentId`, `sortBy=SortName`), `GET /Items/Filters` per library | | `genreNames()`, `years(of:libraryIds:)` |
| Library lists | `GET /UserViews` | | `videoLibraries()`, `VideoLibrarySelection` 35 |
| Movie page (refetched on `videoRevision`) | `GET /Items/{id}` | `userId` | `item(id:)`, `VideoViews` 153 |
| Seasons | `GET /Shows/{id}/Seasons` | `userId` | `seasons(of:)` |
| Episodes | `GET /Shows/{id}/Episodes` | `userId`, `seasonId` (or none for all), `fields=Overview,ProductionYear,OfficialRating,CommunityRating,BackdropImageTags,SeriesId,SeasonId,MediaStreams,MediaSources` | `episodes(of:season:)`, also `AppState.playVideoItem` 129 |

### Search (`SearchView`)

- iOS and tvOS, Music mode: `GET /Items`, merged, `searchTerm`, `includeItemTypes=Audio,MusicAlbum,MusicArtist`, `recursive`, `fields`, `limit=60` (`search()`).
- iOS and tvOS, Video mode: `GET /Items`, `searchTerm`, `includeItemTypes=Movie,Series,Episode`, `recursive`, the video fields, `limit=60` (`searchVideo(_:limit:)`).
- Mac (`searchEverything()`): songs (`limit=10`), albums (`limit=8`) on `/Items` merged; artists on `GET /Artists` merged (`limit=8`); movies and shows per library (`searchTerm`, `includeItemTypes`, `recursive`, `parentId`, `fields=ProductionYear`, `limit=8`).

### Downloads (`DownloadsView`)

No server reads. Starting a download reads `tracks(inAlbum:)` or `tracks(inPlaylist:)`, then `OfflineLibrary` downloads `GET /Items/{id}/Download` through the background session and the cover through `ProxyConnection`.

### Settings

`views()` for the library pickers (`SettingsView` 208, Mac `LibrarySettings` 76, `FirstRunWizard` 34), `GET /Users/{uid}` for the user name (`SettingsView` 198, `MacSettings` 402), Quick Connect approval, password change (`POST /Users/Password`, Mac), library scan (`POST /Library/Refresh`, Mac), server style publish.

### Radio (Mac `RadioView`)

`GET /LiveTv/Channels` (`userId`, `enableImages`), `POST /Items/{id}/PlaybackInfo`, `POST /LiveStreams/Close`. Hidden offline.

### Playback, Now Playing, menus

| What | Request | Params | Where |
|---|---|---|---|
| Music stream | `POST /Items/{id}/PlaybackInfo` | body with the device profile | `resolveStream()` (`Playback.swift`), skipped for downloads (`PlaybackService.stream(for:)`) |
| Video stream | `POST /Items/{id}/PlaybackInfo` | body with `mediaSourceId`, `audioStreamIndex` | `VideoPlayback.resolve`, `VideoPlayer` 131 |
| Stop a transcode | `DELETE /Videos/ActiveEncodings` | | `stopActiveEncoding()` |
| Reports | `POST /Sessions/Playing`, `/Progress`, `/Stopped` | | `PlaybackReporting.swift` |
| Chapters and trickplay | `GET /Items/{id}` | `userId` (the route returns both by itself) | `videoDetails(for:)`, `VideoPlayer` 209 |
| Trickplay sheet | `GET /Videos/{id}/Trickplay/{width}/{n}.jpg` | `mediaSourceId` | `trickplaySheet()`. Skipped offline (plan section 6). |
| Intro and credits | `GET /MediaSegments/{id}` | | `mediaSegments()`, `VideoPlayer` 341 |
| Next episode | `GET /Shows/{id}/Episodes` | `seasonId` | `AppState.playVideoItem` |
| Instant mix, auto-mix | `GET /Items/{id}/InstantMix` | `userId`, `limit=50` or `25` | `instantMix()`, `PlaybackService` 500, 1364. Hidden offline. |
| Go to album or artist | `GET /Items/{id}` | `userId` | `item(id:)`: `TrackMenu` 157, 246, 376; `MacTrackMenu` 304; `NowPlayingOverlay` 274 |
| Play album, playlist or artist from a menu | the tracks helpers above | | `TrackMenu` 285 to 287, `MacItemMenu` 69 |
| Media info (Mac) | `GET /Items/{id}` | `userId` | `mediaDetail()` |
| Lyrics | see "Lyrics" below | | `LyricsWaterfall.fetchDetailed`, `LyricsView` 78 |
| Cast to this app | `GET /Items` | `ids` | `items(ids:)` (`RemoteControl.swift`) |
| Devices sheet | `GET /Sessions` (`controllableByUserId`, `activeWithinSeconds=960`), `POST /Sessions/{id}/Playing...`, `/Command` | | `DevicesView`. Hidden offline. |
| Waterfall | `GET /System/Info/Public`, the relay | | `WaterfallSession`. Hidden offline. |

### Cascade plugin reads

`GET /CascadeServer/AnimatedArt/{id}` (`coverVideo`, `Components` 451), `POST /CascadeServer/Explicit/Query` (`Explicit.swift`), `GET /CascadeServer/SpotifyId/{id}`, the plugin probe (`CascadeServer/Info`, `CascadeLyrics/Info`), the Mac lyrics editor's `GET` of the plugin lyrics route (`LyricsEditorModel` 53).

### Helpers no screen calls

`movies()`, `shows()`, `nextUp()`, `continueWatching()` (`/UserItems/Resume`) and `latestVideo(_:limit:)` in `Video.swift` have no caller in `App/`. The engine does not need `/UserItems/Resume`.

## Lyrics (both)

Server-only mode (on by default on Apple, a setting on the desktop) asks only the plugin; otherwise the waterfall runs:

1. Plugin: `GET /CascadeServer/Lyrics/{id}` (or `/Audio/{id}/CascadeLyrics` on the legacy plugin), with `syllable=true`, `spicyOnly`, `spotifyId` for SpicyLyrics.
2. Kugou (`lyrics.kugou.com`, desktop through main.js IPC), LRCLIB (`lrclib.net`).
3. Jellyfin: `GET /Audio/{id}/Lyrics`.

Offline, the catalog answers with the lyrics stored at download time (plan section 1) and none of these run. The SpicyLyrics 25-day rule applies to what was stored.

## Reads that are not JSON

| What | URL | Offline |
|---|---|---|
| Covers, 600px | `/Items/{id}/Images/Primary?fillHeight&fillWidth&quality&ApiKey` (`artUrl`, Apple `imageUrl(itemId:size:)`) | Desktop already serves `cascade-offline://local/art/<id>.jpg`; Apple's `ArtworkView` needs the same lookup. |
| Artist art | `artistArtUrl()`, no tag | Placeholder unless stored. |
| Posters, backdrops, stills | Apple `imageUrl(itemId:type:width:height:)`; desktop `artUrl()` and `SeriesPrimaryImageTag` | Store at download (plan section 1). |
| Playlist art | `playlistArtUrl()` | Store with the playlist. |
| Original cover (animated) | `originalArtUrl()` | Fall back to the stored still. |
| Audio and video streams | from PlaybackInfo; `/Audio/{id}/universal`, `/Videos/{id}/stream?static=true` (copy stream URL) | The local file. |
| Subtitles | `/Videos/{id}/{source}/Subtitles/{index}/Stream.vtt` (`applySubtitles()` 5402) | `subs/<id>.<index>.vtt` (phase 3). |
| Trickplay | `/Videos/{id}/Trickplay/...` | None at first. |

## Writes, and what each does offline

"Refuse" means the control is hidden or disabled with "Not available offline" and the handler checks too (house style: a disabled control is also guarded in its handler). "Queue" means it becomes pending user data (plan section 5).

| Write | Desktop | Apple | Offline |
|---|---|---|---|
| Favorite on, off (`POST`/`DELETE /UserFavoriteItems/{id}`) | `toggleLike()` 6984 | `setFavorite()` | Queue |
| Mark played, unplayed (`POST`/`DELETE /UserPlayedItems/{id}`) | `setItemPlayed()` 10908 | `setPlayed()` | Queue |
| Play counted (`POST /UserPlayedItems/{id}?datePlayed`) | `replayOfflinePlays()` | `OfflineLibrary.replayPlays` | Queue (exists today) |
| Playback start, progress, stopped (`/Sessions/Playing*`) | `playback-reporting.ts` | `PlaybackReporting.swift` | Not sent. Start becomes a queued play (as today); the last position and a finished item become queued user data. |
| Stop transcode (`DELETE /Videos/ActiveEncodings`) | `stopActiveEncoding()` | `stopActiveEncoding()` | Not sent (nothing is transcoding). |
| Remote control registration (`POST /Sessions/Capabilities/Full`) and the socket | `remote-control.ts` | `RemoteControl.swift` | Not sent. |
| Create playlist (`POST /Playlists`) | 3868, 4034, 10513 | `createPlaylist()` | Refuse |
| Add to playlist (`POST /Playlists/{id}/Items`) | 10433 | `addToPlaylist()` | Refuse |
| Remove from playlist (`DELETE /Playlists/{id}/Items`) | 4537 | `removeFromPlaylist()` | Refuse |
| Move in playlist (`POST /Playlists/{id}/Items/{entry}/Move/{to}`) | 3685 | `movePlaylistEntry()` | Refuse |
| Rewrite playlist, rename, public (`POST /Playlists/{id}`) | `savePlaylistIds()` 3298, details 3463 | `setPlaylistItems()`, `renamePlaylist()`, `updatePlaylist()` | Refuse |
| Playlist description (plugin `PUT /CascadeServer/Playlists/{id}/Details` or `POST /Items/{id}`) | 3366, 3379 | `setPlaylistOverview()` | Refuse |
| Playlist picture (plugin `/CascadeServer/Playlists/{id}/Image` or `/Items/{id}/Images/Primary`, `POST`/`DELETE`) | `_savePlaylistArt()` 3389 | `setPlaylistImage()`, `removePlaylistImage()` | Refuse |
| Delete item or playlist (`DELETE /Items/{id}`) | `deleteItemFromServer()` 10632 | `deleteItem()`, `deletePlaylist()` | Refuse. Removing a download is the download manager's job, not this. |
| Refresh metadata (`POST /Items/{id}/Refresh`) | `refreshItemMetadata()` 4495 | `refreshMetadata()` | Refuse |
| Edit metadata (`POST /Items/{id}`) | `metadata-editor.html` 313 | `updateItem()` | Refuse |
| Save lyrics (plugin `POST`) | `lyrics-editor.html` 1466 | `LyricsSave.saveLyrics` | Refuse |
| Spotify link (`POST`/`DELETE /CascadeServer/SpotifyId/{id}`) | `_spotifyLinkRequest()` 11647 | `spotifyId` set, `removeSpotifyLink()` | Refuse |
| Server style publish (`PUT`/`DELETE /CascadeServer/Style`) | `publishServerStyle()` 11430 | `publishServerStyle()` | Refuse |
| Library scan (`POST /Library/Refresh`) | 1340 | `MacSettings.scan` | Refuse |
| Quick Connect approval (`POST /QuickConnect/Authorize`) | 1316 | `authorizeQuickConnect()` | Refuse |
| Change password (`POST /Users/Password`) | none | `changePassword()` (Mac) | Refuse |
| Explicit lookup (`POST /CascadeServer/Explicit/Query`, a read sent as POST) | `_flushExplicit()` | `Explicit.swift` | Not sent. Proposed: store the flag in the catalog at download time so the badge still shows. |
| Control another device (`POST /Sessions/{id}/...`) | `_dp*` 1138 to 1172 | `DevicesView` | Hidden |
| Radio (`PlaybackInfo` for a channel, `POST /LiveStreams/Close`) | `radio.ts` | `Radio.swift` | Hidden |
| Save file to disk (`/Items/{id}/Download` to a chosen folder) | `window.cascade.download` 4435, 10537, 10875 | `LibraryActions.download` (Mac) | Refuse (the file may already be in the catalog, but copying it out is not part of this plan). |

## Network calls that are not the Jellyfin server

Phase 2's "nothing is sent to the network" in Offline Mode reaches these too:

| Call | Where | Proposed offline |
|---|---|---|
| iTunes Search (`itunes.apple.com`, art and Discord) | renderer 344 to 395, `ITunesArt.swift` | Not asked. |
| MusicBrainz (Spotify link search) | renderer 11771 | Not asked (the dialog is a write anyway). |
| LRCLIB, Kugou | lyrics waterfall | Not asked; lyrics come from the catalog. |
| Waterfall relay | `waterfall.js`, `WaterfallSession.swift` | Hidden. |
| Translation model downloads | main.js `downloadTranslationModel()` | Not offered; installed models still work. |
| Updater (GitHub releases, versions.json, CHANGELOG) | main.js, Mac `UpdateWindow.swift` | Skipped while Offline Mode is on, and checked as soon as it turns off (decided; plan section 4). |
| Discord RPC | local socket | Not network; unaffected. |

## The engine's scope, as a checklist

Built in phase 1 (`src/core/offline-query.ts`, `CascadeKit/OfflineQuery.swift`), each item tested in `test/fixtures/offline-query.json`.

What phase 1 builds and tests, both platforms, from the tables above. Params match case-insensitively. Both apps send only the current item routes since `8b17d3e`, so the obsolete `/Users/{uid}/Items...` forms are not answered.

- `GET /Items`: params `IncludeItemTypes` (`Audio`, `MusicAlbum`, `MusicArtist`, `Playlist`, `Movie`, `Series`, `Episode`, comma lists), `ParentId` (a library, album, playlist, series or season id), `Ids`, `ArtistIds`, `AlbumArtistIds`, `GenreIds`, `Genres`, `Artists`, `Years`, `SearchTerm`, `Recursive`, `Filters` (`IsPlayed`, `IsFavorite`, `IsResumable`), `IsFavorite`, `IsPlayed`, `SortBy` (keys in finding 6), `SortOrder`, `StartIndex`, `Limit`; `Fields`, `EnableImages`, `EnableUserData` accepted and ignored. Reply `{ Items, TotalRecordCount, StartIndex }`.
- `GET /Items/{id}`: one item with everything the catalog holds (`Overview`, `Genres`, `MediaStreams`, `MediaSources`, `Chapters`, `NormalizationGain`, `CanDelete`, `UserData`). A genre id answers the genre. Unknown id: 404-shaped refusal.
- `GET /Playlists/{id}/Items` (`UserId`, `Fields`): the stored order.
- `GET /Playlists/{id}`: `{ OpenAccess, ItemIds }` from the catalog.
- `GET /UserViews`: the stored libraries that have downloads, plus the placeholder library while it holds anything.
- `GET /Users/{uid}`: the stored user (`Name`, `Policy`), so permissions and the user name still read.
- `GET /Artists`, `GET /Artists/AlbumArtists` (both Obsolete in 12, still sent; see "Jellyfin 12"), and `GET /Persons` with `personTypes=Artist` or `AlbumArtist` for when the apps move: derived from the downloaded tracks (`ArtistItems` and `AlbumArtists`), with `ParentId`, `SearchTerm`, `SortBy`, `SortOrder`, `IsFavorite`, `StartIndex`, `Limit`.
- `GET /MusicGenres` (Obsolete in 12, still sent) and `GET /Genres`: derived from the downloaded items' `GenreItems`, with `ParentId`, `IncludeItemTypes`, `SortBy`.
- `GET /Items/Filters`: `{ Years }` from the downloaded items, with `ParentId`, `IncludeItemTypes`.
- `GET /Items/Latest`: a bare array, newest `DateCreated` first, with `ParentId`, `IncludeItemTypes`, `Limit`.
- `GET /Shows/{id}/Seasons`, `GET /Shows/{id}/Episodes` (`SeasonId`, or none for the whole show).
- `GET /Shows/NextUp`: per downloaded series, the first unplayed episode after the last played one (`ParentId`, `Limit`, `EnableResumable=false`; `SeriesId` is sent by no screen).
- `GET /MediaSegments/{id}`: the stored segments.
- Anything else: an empty result marked offline, never a network call. That covers `/Items/{id}/InstantMix`, `/Artists/{id}/Similar`, `/Sessions`, `/LiveTv/Channels`, `/System/Info/Public` and the plugin routes, which the UI also hides.

## Decisions

Settled with the maintainer after the first version of this map; the details are in the plan.

1. **Jellyfin 12 compatibility:** the desktop's obsolete item routes are gone from both apps (`8b17d3e`); `/Artists`, `/Artists/AlbumArtists` and `/MusicGenres` move once checked on the jellyfin12 server (section "Jellyfin 12").
2. **Downloads from before catalog v2** go to a placeholder library until the app is next online and can fill in the real one (plan section 1, "Library ids").
3. **History catch-up by snapshot:** the app keeps a snapshot of the server's play history; on reconnect it replays the plays made offline only if the server's history still matches that snapshot (plan section 5).
4. **The updater** is skipped while Offline Mode is on and checks as soon as it turns off (plan section 4).
5. **The desktop guard:** every raw server `fetch` moves to one `jfFetch`, with main blocking the server's origin as a backstop (plan section 2).
