# Cascade Server plugin tasks

A brief for an agent working in the **CascadeServer** repository (`Cha0s1nc/CascadeServer`, the Jellyfin plugin), not in this one. It covers the four features that need server work:

- **A. Server style:** a theme and lyrics look an admin sets for everyone, offered as the default or enforced.
- **B. Explicit marking:** Jellyfin has no explicit flag, so the plugin works one out and serves it.
- **C. Playlist picture and description for owners:** Jellyfin only lets admins set them.
- **D. Animated album art:** a looping video cover from an admin's own `cover.mp4` sidecar, or from TIDAL using the admin's own TIDAL developer app.

The Cascade client side is built later, in `Cascade-Project`, against the **Contract** section below. Treat that section as the deliverable: if you change a route or a JSON shape, change it here too, in this file on this branch (`fixes/plan-items` in `Cha0s1nc/Cascade-Project`), so the client is built against what you shipped.

## How the plugin repo works (read first)

- Build both targets; both must compile:
  - `dotnet build Jellyfin.Plugin.CascadeServer -c Release -p:JellyfinTarget=10.11` (.NET 9)
  - `dotnet build Jellyfin.Plugin.CascadeServer -c Release -p:JellyfinTarget=12` (.NET 10, `JELLYFIN12` is defined)
- **Capabilities:** `Api/InfoController.cs` lists them in `Capabilities`. Cascade feature-tests on that list, never on the version number. Each task below adds one.
- **Permissions:** `Api/SpotifyLinkPermission.cs` is the pattern for "admins plus users an admin picked". Use `IAuthorizationContext.GetAuthorizationInfo`, and `PermissionKind.IsAdministrator` for admins.
- **Storage:** plugin data lives under `DataDir.Root(appPaths)` (`{DataPath}/cascade-lyrics`; the old name is kept on purpose, see `LyricStore/DataDir.cs`). `LyricStore/SpotifyIdStore.cs` is the pattern for a small JSON store: a lazy-loaded `ConcurrentDictionary`, a lock, writing to `.tmp` and then moving it into place. Never use the plugin's own `DataFolderPath`, which is replaced on every update.
- **Settings:** `Configuration/PluginConfiguration.cs`, edited on `Web/status.html`. Jellyfin's plugin configuration API is admin-only, which is why secrets can live there.
- **Scheduled tasks:** `Tasks/DownloadLyricsTask.cs` is the pattern for a library-wide pass.
- **House style** (shared with Cascade): no em dashes anywhere, code comments and commit messages included. Comments explain why. Check what every write returns. Never trust an endpoint's shape from memory: confirm Jellyfin internals against Jellyfin's source for **both** 10.11 and 12.
- **Testing:** there is no test project yet. Either add a small xunit project for the pure parts (tag value parsing, lookup matching, preset validation), or test them by hand against a dev server. Say which in your report.
- Bump `PluginVersion` in the csproj and update `README.md` (Settings, What it depends on) when you are done.

## Contract

All routes need a signed-in user (`[Authorize]`), as the existing ones do. Errors are `{ "error": "<message for a person>" }` with the status codes listed. Ids are Jellyfin item GUIDs in any format `Guid.Parse` accepts.

### A. Server style (capability `server-style`)

`GET /CascadeServer/Style`, any user:

```json
{
  "mode": "off",
  "enforce": { "theme": false, "lyrics": false },
  "preset": null,
  "updatedUtc": null
}
```

- `mode` is `"off"`, `"default"` or `"enforced"`. With `"off"`, `preset` is `null`.
- `preset` is a Cascade preset object (format below) or `null`.
- `enforce` says which parts are locked when `mode` is `"enforced"`; both are ignored for `"default"`. With `"off"` both are `false`.
- `updatedUtc` is an ISO 8601 UTC time or `null`. Cascade uses it to notice a change.

`PUT /CascadeServer/Style`, admins only (403 otherwise). The body has the same shape without `updatedUtc`. Answers 204, or 400 when the preset is invalid, when `mode` is `"default"` or `"enforced"` with no preset, or when `mode` is not one of the three. A PUT with `"off"` clears the stored preset and both enforce flags (use it as DELETE). **As built:** `preset`, `updatedUtc` and `enforce` are always present in the GET answer (null when empty).

`DELETE /CascadeServer/Style`, admins only. Back to `off`, answers 204.

**Preset format.** The reference implementation is `src/core/presets.ts` in Cascade-Project; read it. In short:

```json
{
  "format": "cascade-preset",
  "version": 1,
  "name": "Sunset",
  "theme": { "mode": "dark", "gradStart": "#f97316", "gradEnd": "#ec4899", "albumArt": false, "bgDim": 0.16, "bgBlend": true, "font": { "preset": "system", "custom": "" } },
  "lyrics": { "style": { "pastBlur": 1.5 }, "lyricScale": 1.0 }
}
```

`theme` and `lyrics` are each optional; at least one must be present.

**What the server checks.** Cascade clamps every value itself when it applies a preset, so the server only has to:
- refuse anything that is not JSON;
- refuse anything over 64 KB;
- require `format` to be `"cascade-preset"` and `version` to be `1`;
- require at least one of `theme` or `lyrics`, each an object;
- keep only the top-level keys `format`, `version`, `name`, `theme` and `lyrics`.

Store the preset as the JSON text in `PluginConfiguration`, or as a file in the data dir if the XML config makes that awkward.

**Plugin page.** Add a "Server style" section with:
- the mode select and the two enforce checkboxes;
- a textarea to paste a preset (Cascade's Theme panel > Share a look > Copy as text), or a file input for a `.cascadepreset`;
- Save and Clear buttons;
- a small preview of what the preset contains (name, which parts, the two gradient colours).

**What Cascade will do with it** (context, not plugin work):
- **Default:** used for the settings a user never changed.
- **Enforced:** applied over the user's own settings without overwriting them, and the locked controls are dimmed with "Set by your server". Enforcing never covers dark/light mode or the font, so those stay the user's for accessibility. The plugin does not need to know that.

### B. Explicit marking (capability `explicit`)

`POST /CascadeServer/Explicit/Query`, any user. A POST because id lists are long.

```json
{ "ids": ["<item id>", "..."] }
```

At most 500 ids (400 beyond that). Answers 200:

```json
{ "items": { "<item id>": "explicit", "<item id>": "clean" } }
```

- Only songs with a known answer appear in `items`; unknown ones and non-audio ids are left out.
- `"clean"` means a marked clean or edited version, not merely "not known to be explicit".
- This route never runs a lookup inline, so it stays fast: it answers from the store and queues any missing ids for a background lookup.

`GET /CascadeServer/Explicit/{itemId}`, any user. Answers 404 when the item is not audio.

```json
{ "rating": "explicit", "source": "tag", "manual": false }
```

- `rating` is `"explicit"`, `"clean"` or `null` (unknown).
- `source` is `"manual"`, `"tag"`, `"deezer"`, `"itunes"` or `null`.

`PUT /CascadeServer/Explicit/{itemId}`, admins and users listed in a new `ExplicitEditUsers` setting (same shape and check as `ServerWideSpotifyLinkUsers`). Answers 403 for anyone else.

```json
{ "rating": "explicit" }
```

- `rating` is `"explicit"` or `"clean"`; `null` removes the manual override and hands the song back to the automatic sources.
- A manual answer is never overwritten automatically.
- Answers 204, 400 or 404.

Add `canEditExplicit` (bool, for this user) to the `/CascadeServer/Info` response next to `spotifyLinkServerWide`, so Cascade knows whether to offer the control.

**Where the answer comes from, first hit wins:**

1. **Manual:** from the PUT above.
2. **The file's own tag.** Jellyfin's scanner ignores it, so read the file with TagLib#. Jellyfin itself depends on TagLibSharp, so reference the same package and version Jellyfin ships with `PrivateAssets="All"` and `ExcludeAssets="runtime"`; check that this works on both 10.11 and 12.
   - MP4/M4A: the `rtng` atom.
   - ID3v2: the `TXXX:ITUNESADVISORY` frame.
   - Vorbis/FLAC/Opus: the `ITUNESADVISORY` comment, and an `EXPLICIT` comment some taggers write.
   - Values: `1` or `4` is explicit, `2` is clean, `0` or absent is unknown.
3. **Online lookups,** each switchable in settings and both on by default. Like the lyric sources, they send artist and title to a third party; say so on the plugin page.
   - **Deezer:** `https://api.deezer.com/track/isrc:<ISRC>` when the item has an ISRC, otherwise a search. **As built:** the search is the plain text query `https://api.deezer.com/search?q=<artist> <title>&limit=25`, because the `artist:"..." track:"..."` form answered an empty list for every query when tried live (2026-10-07), while the plain form works. The ISRC answer is checked with the same match rule as search results. The fields are `explicit_lyrics` (bool) and `explicit_content_lyrics` (0 not explicit, 1 explicit, 2 unknown, 3 edited, 4 clean, 5 explicit, 6 no advice; confirmed live: HUMBLE. is `1`, a track Deezer has no advice data for is `2` (with `explicit_lyrics` false), a plainly clean one is `0`. The plugin maps 1 and 5 to explicit, 3 and 4 to clean, 0 and 6 to not explicit, 2 and anything else to unknown).
   - **iTunes Search:** `https://itunes.apple.com/search?entity=song&term=<artist title>`, field `trackExplicitness` (`explicit`, `cleaned`, `notExplicit`).
   - **Matching rule.** Accept a result only when the artist and title match after normalising (lowercase, accents removed, bracketed edition words like "(Remastered)" dropped) **and** the duration is within 3 seconds. Port the normalising from `src/core/itunes-art.ts` in Cascade-Project, which was written because taking the first search result picked karaoke and tribute versions.
   - **No confident match means unknown, never clean.**
   - `notExplicit` or Deezer `0` are stored as "not explicit". They answer as unknown in the Query route, since only `clean` means an edited version.
   - When matching results disagree (an explicit and a cleaned edition of one song), the one closest in length wins, and a tie is unknown. A result whose title or artist says karaoke, instrumental, tribute and so on is refused unless the library song says so too. The query answers keys exactly as the ids were sent.

**Store:** `explicit.json` in the data dir, in the `SpotifyIdStore` shape. Each entry is:
- `{ Rating, Source, Manual, CheckedUtc }`;
- a lookup that found nothing is retried after 30 days;
- a tag result is re-read when the file's modification time changes.

**Scheduled task** "Find explicit songs": a library-wide pass over audio items, plus the queue the Query route feeds.
- Rate-limit the online lookups (one request per second per service is plenty).
- Stop cleanly on cancellation.

**Optional mirror** to a Jellyfin tag, behind a `MirrorExplicitTag` setting, default **off**. When on, an `Explicit` tag is added to explicit songs (and removed when that changes), so other Jellyfin clients can filter on it. Before building it, find out whether a metadata refresh with "replace all metadata" wipes plugin-added tags on 10.11 and 12, and write down what you found. If it does, say so on the plugin page rather than fighting it.

### C. Playlist picture and description for owners (capability `playlist-edit`)

This was confirmed against a live Jellyfin 10.11.11:
- `POST /Items/{id}/Images/Primary` and `POST /Items/{id}` both require elevation, so only admins can set a playlist's picture or description.
- `POST /Playlists/{id}` takes only Name, Ids, Users and IsPublic.

**Permission for every route here.** The requester may edit when they are:
- an admin;
- the playlist's owner (`Playlist.OwnerUserId`);
- or in its shares with `CanEdit`.

Confirm those property names in Jellyfin's `Playlist` class for 10.11 and 12. Answer 404 when the item is not a playlist, and 403 when the user may not edit it.

`POST /CascadeServer/Playlists/{id}/Image`: the body is the raw image bytes, with `Content-Type` `image/jpeg`, `image/png` or `image/webp`. At most 10 MB (413 beyond that).
- Check the magic bytes match the declared type (400 otherwise).
- Save it as the Primary image through Jellyfin's provider manager (`IProviderManager.SaveImage`), then persist the item so the image tag changes.
- Answers 204.

`DELETE /CascadeServer/Playlists/{id}/Image`: removes the Primary image, answers 204.

`PUT /CascadeServer/Playlists/{id}/Details`:

```json
{ "overview": "Songs for the drive" }
```

- `overview` is at most 2000 characters; an empty string or `null` clears it.
- Answers 204.
- Name and IsPublic stay on Jellyfin's own `POST /Playlists/{id}`, which owners can already use.

Add `canEditPlaylist` to nothing: Cascade checks per playlist by trying, and shows the 403 message.

### D. Animated album art (capability `animated-art`)

A looping video cover for an album, shown by Cascade's now-playing view. It comes from two sources:

- **A sidecar the admin supplies:** a `cover.mp4` (or another name from the settings) in the album's folder, put there by hand or uploaded through the route below.
- **TIDAL,** looked up with the admin's **own** TIDAL developer app. About 8% of albums have one: a live check of 301 albums found 25.

Cascade already plays animated covers stored as the album's Primary image (GIF or WebP, see `animatedArtUrl` in `renderer.js`), so this adds video covers on top; it does not replace that path.

#### Why the admin brings their own TIDAL app

Confirmed against TIDAL's API docs and its [Developer Terms](https://developer.tidal.com/documentation/guidelines-developer-terms-1_0) (v1.0, 2023-09-12):

- **No shared credentials.** The terms forbid disclosing or transferring a developer account to anyone else (section IV) and letting others "publicly access" the Developer Tools (section II). So Cascade cannot ship one app's credentials, and no one can run a public lookup service for other servers.
- **"Sign in with TIDAL" does not remove the developer app.** TIDAL's official API offers only two ways in: client credentials, and the authorization code flow with PKCE. There is no device-code flow. The authorization code flow still needs a registered app's client id and a redirect URI registered in advance on that app. Every Jellyfin server has a different address, so the redirect cannot point at the server. It would have to be one app (Cascade's) with a fixed redirect, which brings back the shared-app problems above: Cascade's author becomes the TIDAL developer for every server, all servers share one quota, and the app must pass TIDAL's review. A user login also adds nothing here: the catalog, cover art included, works with client credentials alone.
- **Never use TIDAL's own client ids** (the ones the official apps and some open-source libraries use). The terms forbid masking your identity or your offering's identity (section I).
- **So:** the admin creates an app at developer.tidal.com and pastes its client id and secret into the plugin settings, as they do the SpicyLyrics key. Each server is then its own non-commercial developer use with its own quota. Approval is only needed for a quota extension (section IV), which one server looking albums up as they are played should not need.

#### Rules the TIDAL side must follow

From the same terms, section II. These are requirements, not suggestions:

- **On demand only.** Look an album up when a client asks for its art. Never add TIDAL to a library-wide pass like `DownloadLyricsTask`, and never prefetch. The terms forbid spiders and tools that "retrieve, duplicate, or index" TIDAL content.
- **Temporary cache only.** TIDAL allows "temporary caching of metadata and cover art" and says "Do not store TIDAL Content indefinitely". Use the SpicyLyrics pattern (`LyricStore/SpicyLyricsCache.cs` and `Tasks/PruneSpicyLyricsCacheTask.cs`): a 25-day TTL, deleted on read when expired, swept on every write and by a daily task. After expiry, look the album up again, so an album whose video was removed loses it.
- **Never write a TIDAL file into the media folders,** never as a sidecar, and never into the upload store below. Only into the TIDAL cache in the data dir.
- **Do not alter the file.** Picking one of TIDAL's ready-made sizes is fine; cropping, overlays or re-encoding are not.
- **Keep the credentials admin-only.** They live in `PluginConfiguration`, which only admins can read. Never log them or return them from a route.

#### Settings

Added to `PluginConfiguration` and a new "Animated album art" section on `Web/status.html`.

| Setting | Default | Meaning |
|---|---|---|
| `TidalClientId`, `TidalClientSecret` | empty | The admin's TIDAL app. Either empty means TIDAL is off. |
| `TidalCountryCode` | `"US"` | Sent as `countryCode`. The catalog differs by country. |
| `TidalArtSize` | `1080` | Which of TIDAL's square sizes to keep: `320`, `640`, `750`, `1080` or `1280`. Use the nearest available when the exact one is missing. The 1280 file measured about 3.6 MB for 10 seconds. |
| `TidalArtDelivery` | `"cache"` | `"cache"`: download into the 25-day cache and serve it from this server, so clients only ever talk to Jellyfin. `"direct"`: cache only the lookup result and give Cascade TIDAL's own file URL, so no video is stored on the server (TIDAL's file URLs need no login). |
| `AnimatedArtSourceOrder` | `"sidecar-first"` | `"sidecar-first"`, `"tidal-first"`, `"sidecar-only"` or `"tidal-only"`. A sidecar is an admin's deliberate choice, so it wins by default. |
| `AnimatedArtSidecarNames` | `["cover.mp4", "cover.webm"]` | File names looked for in the album folder, in order. The first one is used when saving an `.mp4` upload, the first `.webm` name when saving a WebM. |
| `AnimatedArtMaxUploadMb` | `50` | Largest upload accepted. |
| `AnimatedArtEditUsers` | `[]` | Users besides admins who may upload, remove and link. Same shape and check as `ServerWideSpotifyLinkUsers`. |

Add `canEditAnimatedArt` (bool, for this user) to `/CascadeServer/Info`, next to `canEditExplicit`.

The plugin page says plainly that TIDAL lookups send the album's barcode (and sometimes ISRCs) to TIDAL, and links the TIDAL Developer Terms. It also has a short how-to for creating the TIDAL app and a **Test** button. The button calls `POST /CascadeServer/AnimatedArt/TidalTest` (admins only), which gets a token and fetches one known album. It answers `{ "ok": true }` or `{ "ok": false, "error": "..." }`, following `Api/SpicyLyricsTestController.cs`.

#### Contract

The `{albumId}` in every route is a MusicAlbum id. An Audio id is accepted too and resolved to its album, since Cascade often only has the track. Answer 404 for anything else.

`GET /CascadeServer/AnimatedArt/{albumId}`, any user:

```json
{
  "source": "sidecar",
  "url": "/CascadeServer/AnimatedArt/<albumId>/File",
  "contentType": "video/mp4",
  "width": 1080,
  "height": 1080,
  "updatedUtc": "2026-10-07T12:00:00Z",
  "pending": false
}
```

- `source` is `"sidecar"`, `"tidal"` or `null`. With `null`, every other field except `pending` is `null`.
- `url` is relative to the server, except with `TidalArtDelivery` `"direct"`, where a TIDAL result is TIDAL's absolute `https://resources.tidal.com/...` URL.
- `width` and `height` are `null` for a sidecar unless the plugin can read them cheaply.
- `updatedUtc` changes when the file changes, so Cascade can bust its own cache.
- `pending` is `true` when nothing is ready yet but a TIDAL lookup or download was just queued. Cascade asks again once, a few seconds later.
- This route never waits on a download. A TIDAL lookup is at most two small requests, so it may run inline with a 5-second budget. On timeout, answer `pending: true` and let it finish in the background.

`GET /CascadeServer/AnimatedArt/{albumId}/File`, any user. Streams the file with range support (`PhysicalFile(..., enableRangeProcessing: true)`), with the right `Content-Type`. Answers 404 when there is none.
- A `<video>` element cannot send headers, so this route must accept Jellyfin's `api_key` query parameter. Check that `[Authorize]` does on both 10.11 and 12.
- This route only serves files: a sidecar, an upload, or a TIDAL cache entry that has not expired. Never proxy TIDAL live.

`PUT /CascadeServer/AnimatedArt/{albumId}`, admins and `AnimatedArtEditUsers` (403 otherwise). The body is the raw file, with `Content-Type` `video/mp4` or `video/webm`.
- Check the magic bytes (`ftyp` at offset 4 for MP4, `1A 45 DF A3` for WebM) and answer 400 when they do not match.
- Answer 413 over `AnimatedArtMaxUploadMb`.
- Save it into the album folder under the first matching name from `AnimatedArtSidecarNames`, replacing an existing file of that name. Write to a temporary name and move it into place. **As built:** the other configured sidecar names in that folder (and any data-dir upload) are then deleted when they can be, so the new cover is the one that shows.
- When the folder is not writable (a read-only mount), fall back to `{DataDir}/animated-art/uploads/{albumId}.mp4` (or `.webm`), as `SaveLyrics` falls back to the data dir. The GET then reports it as `"sidecar"` all the same.
- Answers 204.

Finding the album folder: a MusicAlbum's `Path` is normally its folder. When it is null, or the album's tracks span more than one folder, use the folder of the first track by disc and track number. Confirm against Jellyfin's `MusicAlbum` on 10.11 and 12.

`DELETE /CascadeServer/AnimatedArt/{albumId}`, same permission. Removes the sidecar or upload only, never the TIDAL cache. Answers 204, or 404 when there was none. **As built:** 409 with `{ "error" }` when the sidecar is in a folder the server cannot write to.

`PUT /CascadeServer/AnimatedArt/{albumId}/TidalAlbum`, same permission. Links an album by hand when automatic matching fails, like "Link a Spotify track":

```json
{ "tidalAlbumId": "240189283" }
```

- `null` removes the link.
- Validate the id by fetching it (400 when TIDAL does not know it), then clear that album's cache entry and miss so the next GET looks again.
- Answers 204. **As built:** also 409 when no TIDAL app is set up, 429 or 502 (with `{ "error" }`) when TIDAL is rate limiting or unreachable while the id is checked, and 400 when the id is not digits.
- Keep links in `tidal-links.json` in the data dir, in the `SpotifyIdStore` shape. A link is an id the admin chose, not TIDAL content, so it is kept until removed.

`POST /CascadeServer/AnimatedArt/{albumId}/Refresh`, same permission. Drops that album's TIDAL cache entry and miss. Answers 204.

#### Finding the album on TIDAL

First hit wins:

1. **Manual link** from the route above.
2. **Barcode (UPC/EAN):** `GET https://openapi.tidal.com/v2/albums?countryCode=<cc>&filter[barcodeId]=<barcode>&include=coverArt`. This was tested live and is exact per edition. It matters: the Dolby Atmos edition of RENAISSANCE (`251380836`) has only a still, while the stereo edition (`240189283`) has the video.
   - The plugin does not read barcodes today. Try, in order:
     - the first track's `BARCODE` or `UPC` tag, with the TagLib# reference from section B;
     - the album's MusicBrainz release id (Jellyfin's `MusicBrainzAlbum` provider id) through `https://musicbrainz.org/ws/2/release/<mbid>?fmt=json`, field `barcode`. MusicBrainz needs a descriptive `User-Agent` and at most one request per second.
   - Confirm both work on 10.11 and 12.
3. **ISRC:** `GET /v2/tracks?countryCode=<cc>&filter[isrc]=<isrc>&include=albums`, using the album's first one or two tracks. An ISRC is shared by every release of a recording. A live test of one returned an *instrumental* edition. So accept an album only when its normalised title matches (the same normalising as section B) and its `numberOfItems` matches the local track count.
4. **Nothing else.** TIDAL's search answered `400 INVALID_RESOURCE_ID` for every query made with client credentials, and fuzzy text matching would pick wrong editions anyway. No match means no TIDAL art.

From the album's included `artworks`, take the one with `attributes.mediaType == "VIDEO"`, and from its `files` the one whose `meta.width` matches `TidalArtSize`. None means a miss.

**Token:** `POST https://auth.tidal.com/v1/oauth2/token` with HTTP Basic auth (client id and secret) and `grant_type=client_credentials`. Keep it in memory until a minute before `expires_in`. Send `accept: application/vnd.api+json` on API calls. On a 401, get a new token and retry once. On a 429, honour `Retry-After` and give up on this album for now (answer `pending: false`, `source: null`) rather than block.

**Cache:** in `{DataDir}/animated-art/tidal/`:
- `{albumId}.mp4`, plus `{albumId}.json` with `{ TidalAlbumId, ArtworkId, Width, Href, FetchedUtc }`;
- with `"direct"` delivery, only the `.json`;
- a 25-day TTL as above;
- misses saved to disk (not in memory like SpicyLyrics' misses) for 7 days. With about 92% of albums missing, an in-memory miss list reset by every restart would re-ask TIDAL for the same albums over and over;
- clearing the TIDAL settings deletes the whole TIDAL cache, since the terms want copies gone when access ends (section VI).

**Scheduled task:** add the TIDAL cache to the daily sweep, either as a new "Prune animated art cache" task or folded into `PruneSpicyLyricsCacheTask` (renamed to cover both). Nothing else runs on a schedule.

#### What Cascade will do with it

Context, not plugin work. When `animated-art` is listed, the now-playing view asks the GET for the album and plays the `url` in a muted, looping `<video>`. That takes priority over the GIF/WebP check and the iTunes upgrade, and the still stays as the poster. Grids keep stills, for the same reason `renderer.js` gives for GIF/WebP. Uploading, removing and "Link a TIDAL album" go in the album's context menu, shown when `canEditAnimatedArt` is true.

## Manual test checklist

Run it against a dev Jellyfin 10.11 server with two users, an admin and a normal user, and on 12 if you can.

1. **`/CascadeServer/Info`** lists the four new capabilities, and `canEditExplicit` and `canEditAnimatedArt` are right for each user.
2. **Style:**
   - a normal user's PUT gets 403;
   - an admin's PUT of a preset copied from Cascade's Share a look page round-trips through GET;
   - an invalid preset gets 400;
   - DELETE goes back to `off`.
3. **Explicit:**
   - a file tagged explicit (set `ITUNESADVISORY=1` on a FLAC, and an m4a with `rtng` 1) is found by the task with `source: "tag"`;
   - a well-known explicit single with no tag is found by Deezer or iTunes;
   - a karaoke track with the same title is NOT matched;
   - a manual PUT wins over the tag and survives the task running again;
   - `null` hands the song back;
   - Query with 501 ids gets 400.
4. **Playlists:**
   - the owner (not an admin) can set and remove a picture and set a description;
   - another normal user gets 403;
   - a PNG sent as `image/jpeg` gets 400;
   - the new picture shows in Jellyfin's web client.
5. **Animated art:**
   - an album with a hand-placed `cover.mp4` answers `source: "sidecar"`, and `/File` plays in a browser `<video>` using `?api_key=` and seeks (range requests work);
   - an admin's upload lands in the album folder; with the library mounted read-only it lands in the data dir and still answers `"sidecar"`;
   - a normal user's upload gets 403; a PNG sent as `video/mp4` gets 400; a file over the limit gets 413;
   - with the admin's TIDAL app set, the Test button passes, and an album tagged with barcode `196589246974` (RENAISSANCE, stereo) answers `source: "tidal"`, while `196589525444` (the Atmos edition) answers `null`;
   - with `"direct"` delivery nothing lands in `animated-art/tidal/` except `.json` files, and `url` is a `resources.tidal.com` address;
   - a cache entry with its time set back past 25 days is gone after the daily sweep, and the next GET fetches it again;
   - a manual TIDAL link wins over the barcode, and `null` removes it;
   - clearing the TIDAL settings empties the TIDAL cache;
   - nothing in a library-wide task calls TIDAL (check the server log during "Download lyrics").
6. **Builds:** both targets build, and the plugin page loads and saves the new settings.

## Report back

Report:
- the CascadeServer branch and commit;
- anything in the Contract you changed (and the change made here);
- what you found about TagLib# availability on 12 and about tags surviving a refresh;
- where barcodes came from in practice (tags, MusicBrainz, neither), and whether `[Authorize]` accepts `api_key` on both versions;
- which checklist items you ran.
