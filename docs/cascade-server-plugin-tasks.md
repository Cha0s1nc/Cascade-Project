# Cascade Server plugin tasks

A brief for an agent working in the **CascadeServer** repository (`Cha0s1nc/CascadeServer`, the Jellyfin plugin), not in this one. It covers the three features that need server work:

- **A. Server style:** a theme and lyrics look an admin sets for everyone, offered as the default or enforced.
- **B. Explicit marking:** Jellyfin has no explicit flag, so the plugin works one out and serves it.
- **C. Playlist picture and description for owners:** Jellyfin only lets admins set them.

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
- `enforce` says which parts are locked when `mode` is `"enforced"`; both are ignored for `"default"`.
- `updatedUtc` is an ISO 8601 UTC time or `null`. Cascade uses it to notice a change.

`PUT /CascadeServer/Style`, admins only (403 otherwise). The body has the same shape without `updatedUtc`. Answers 204, or 400 when the preset is invalid.

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
   - **Deezer:** `https://api.deezer.com/track/isrc:<ISRC>` when the item has an ISRC, otherwise `https://api.deezer.com/search?q=artist:"<artist>" track:"<title>"`. The fields are `explicit_lyrics` (bool) and `explicit_content_lyrics` (0 not explicit, 1 explicit, 2 unknown, 3 edited, 4 clean, 5 explicit, 6 no advice; confirm against a live response before relying on it).
   - **iTunes Search:** `https://itunes.apple.com/search?entity=song&term=<artist title>`, field `trackExplicitness` (`explicit`, `cleaned`, `notExplicit`).
   - **Matching rule.** Accept a result only when the artist and title match after normalising (lowercase, accents removed, bracketed edition words like "(Remastered)" dropped) **and** the duration is within 3 seconds. Port the normalising from `src/core/itunes-art.ts` in Cascade-Project, which was written because taking the first search result picked karaoke and tribute versions.
   - **No confident match means unknown, never clean.**
   - `notExplicit` or Deezer `0` are stored as "not explicit". They answer as unknown in the Query route, since only `clean` means an edited version.

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

## Manual test checklist

Run it against a dev Jellyfin 10.11 server with two users, an admin and a normal user, and on 12 if you can.

1. **`/CascadeServer/Info`** lists the three new capabilities, and `canEditExplicit` is right for each user.
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
5. **Builds:** both targets build, and the plugin page loads and saves the new settings.

## Report back

Report:
- the CascadeServer branch and commit;
- anything in the Contract you changed (and the change made here);
- what you found about TagLib# availability on 12 and about tags surviving a refresh;
- which checklist items you ran.
