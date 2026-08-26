# Cascade code map

**Describes commit `0577b88`. Line numbers rot fast - if a landmark is not where
this says, re-grep and fix the line here rather than trusting it.**

Written so an agent can start work without re-reading the whole tree. It is a
map, not documentation: it says where things are and how they are wired, not
what they should be.

## Shape of the project

| File | Lines | What it is |
|---|---|---|
| `renderer.js` | ~6850 | The whole UI. Plain global scope, **no semicolons**, no modules. |
| `index.html` | ~2210 | All markup AND every CSS rule, in one `<style>` block. |
| `main.js` | 626 | Electron main process. Uses semicolons. |
| `src/preload.ts` | 46 | The only bridge to main. Builds `window.cascade`, typed as `ElectronPlatform`. |
| `src/core/*.ts` | - | Pure logic, bundled by esbuild via `src/index.ts` into global `CascadeCore`. |
| `test/*.test.ts` | - | `node --test`. 197 passing at this commit. |

Verify everything with `npm run build:ts && npm run typecheck && npm test`.

**The coupling that matters most and is invisible to any AST:** `index.html`
defines ids and classes, `renderer.js` reaches them by `getElementById` /
`querySelector` string literals. Renaming an id is a silent break. Grep the id
across both files before touching one.

## renderer.js landmarks

### Session and connection
- `connect(serverUrl, token, userId)` - **458**. Sets the global `jf`.
  - It pings `jfGet('/Users/${userId}')` up to 3x purely to verify the token and
    **throws the response away**. That response is the full user object and
    contains `Policy.IsAdministrator`. Admin detection is free here; do not add
    a second request for it.
  - Then: `startRemoteControl()`, `probeCascadePlugin()` (not awaited),
    `populateLibraryPicker()`, `invalidateLibraryViews()`, `loadHome()`,
    `maybeShowVideoIntro()`.
- `promptReauth(message)` - **3836**. Full-screen reauth path.
- Sign out - around **3805**. Tears down playback, Discord and caches (b95c8b7).
  Any new session-scoped flag must be cleared here or it survives into the next
  account.

### View caches
- `invalidateLibraryViews()` - **574**. Clears `allSongs` and the
  `dataset.loaded` flag on `albums-grid`, `artists-grid`, `songs-rows`,
  `playlists-grid`.
- `invalidateVideoViews()` - **582**. Same for `movies-grid`, `shows-grid`.
  Deliberately separate: changing music libraries must not drop a loaded movie
  grid.
- `showView(name)` - **~890**. Lazy-loads a grid only when `dataset.loaded` is
  absent. This pair of functions plus that flag IS the cache layer. There is no
  other one. Home's shelves (`loadRecentlyPlayed`, `loadRecentlyAdded`,
  `loadRecentlyWatched`) are NOT covered by either and reload on `loadHome()`.

### Playlists
- `loadPlaylists()` - **1418** (index grid).
- `currentPlaylistItems` - **1730**. The in-memory copy the Play/Shuffle buttons
  read. Keeping it in sync with the server is the whole game here.
- `playlistMutated(playlistId)` - **1738**. **The single choke point every
  mutation must go through.** Commit 8085688 exists because the old code patched
  the DOM by hand and left this array holding removed tracks, so Play could play
  something no longer in the playlist. Do not add a mutation path that bypasses
  it.
- Playlist detail render - **1504-1575**, `openPlaylist()` at **2029**.
  Row markup at **1518**, drag rebinding at **1521**.
- Refresh button handler - **1495**.
- Smart playlists (Favorites / Most Played) - **~1610-1660**. Most Played
  already sorts on `UserData.PlayCount` (**1622-1626**), so the count is
  already in memory; showing it needs no new fetch.
- Ownership: **`src/core/ownership.ts` is NOT about this.** It is playback
  ownership (local vs cast vs waterfall). There is no playlist-ownership helper
  in this codebase yet. Jellyfin exposes `GET /Playlists/{id}/Users` and item
  DTOs carry `CanDelete`; neither is currently read. Decide and say which you
  used.

### Songs list
- `loadSongs()` - **1232**. `Limit: 500`.
- Virtualised: `SONG_WIN = 40` at **1329**, `_drawSongRows()` at **1405**.
  Row element references go stale on every redraw - **2567** has the comment
  explaining why nothing caches them.
- Sorting is `sortSongs` / `songSortValue` in `src/core/`. Any new column
  follows that, not a new mechanism.

### Playback and decks
- Two permanent `<video>` decks, `DECKS`, global `audio` pointer, and
  `onDeck(type, fn)` which binds both and filters to the live one - **~44-80**.
  Every listener goes through `onDeck` so a crossfade handoff is a pointer move.
- `playCurrentTrack(opts)` - **~2310**. `opts.alreadyPlaying` means a crossfade
  already has the deck playing.
- Crossfade - **2947-3180**. `startCrossfade` **2995**, `_swapDeck` **3602**,
  `finishCrossfade` **3621**, `cancelCrossfade` **3646**.
- `_waitForPlayable(deck, timeoutMs)` - **3761**. Already waits for
  `canplaythrough` / readyState 4.
- Prefetch into the idle deck - **~3182-3255**.
- **Crossfade stutter (open bug): four causes already ruled out by reading.**
  Ramp resolution is fine (50 points over the fade, interpolated on the audio
  thread). Readiness bar is already the strong one. Colour extraction at handoff
  is 6400 pixels. Queue panel and songs list are both already virtualised. Do
  not re-investigate these four. It needs measurement.

### Web Audio / EQ
- `_ensureEqGraph()` - **4696**. AudioContext -> per-deck source -> per-deck
  GainNode (crossfade envelope) -> preamp -> 5 biquads -> analyser -> out.
- Three failure flags - **4666-4668**, and the distinction is load-bearing:
  - `_eqGraphFailed` - no graph at all. Blocks bars **and** crossfade.
  - `_eqNoSignal` - graph exists, tap reads zeros. Cosmetic, bars only.
  - `_eqEverHadSignal` - one non-zero sample proves the tap works.
  Conflating the first two is what silently killed crossfade for a whole
  session once (bc6af6c). Keep them apart.

### Theme and album art colour
- `setThemeMode(mode)` - **7107**. Sets `data-theme="light"` or `''` on `<html>`.
- `applyGradient(start, end)` - **6587**.
- `applyAlbumArtTheme(imgEl)` - **7261**. **One** extraction, feeding both the
  blobs and the accent. Commit 2edb864 removed a second, disagreeing extraction;
  do not reintroduce one.
- `_blobColors` **4100**, `randomizeDrift()` **4103**, drift loop **~4122**.
- `NEUTRAL_ART_SAT` **6738**. Gradient normalises to L 0.62 / S 0.85 - eyeball
  numbers, tuned against a black background.
- `extractTopColors(img)` - **~6689**. 80x80 canvas, nearest-neighbour on
  purpose (smoothing invents colours that appear nowhere on the cover).

### CascadeSLRC plugin detection
- `probeCascadePlugin()` - **6108**. `GET {jf.url}/CascadeLyrics/Info`. 200
  present, 404 absent, network error changes nothing.
- The gating function that greys controls - **5622**.

### Permissions and the setup wizard
- `_applyAdminGating()` - **596**. `jf.isAdmin` comes free from the `/Users/{id}`
  ping in `connect()`; do not add a second request for it. Gates the library
  scan, both "Refresh metadata" entries, and both "Edit metadata"/"Edit
  images" entries (they open the Jellyfin web UI, which itself refuses those
  edits without admin).
- `jf.canDelete` - set in `connect()` right after `jf.isAdmin`, same free
  `/Users/{id}` response, via `CascadeCore.canDeleteMedia(policy)` in
  `src/core/permissions.ts`. Deletion is its own Jellyfin right
  (`Policy.EnableContentDeletion` / `EnableContentDeletionFromFolders`), not
  implied by admin alone - a non-admin can be granted it. `canDeleteMedia`
  collapses the per-library folder list to one global yes/no (an admin, or
  `EnableContentDeletion`, or at least one folder in the list); a user granted
  deletion on only some libraries sees "Delete media" enabled everywhere and a
  delete outside their granted libraries still gets refused server-side.
  Gates `ctx-delete` in `_applyAdminGating()`, cleared on sign out next to
  `jf.isAdmin`.
- `maybeShowSetupWizard()` - **1001**, `WIZARD_REVISION` - **970**. Runs from
  `connect()` off a stored revision, NOT the app version and NOT a boolean.
  Every step seeds from the current live value, which is the only reason it is
  safe to re-show on update. Never add a step that writes a default on entry.
- `renderLibraryPicker()` - **679**, `renderVideoLibraryGroups()` - **859**.
  Neither hides itself for having one library any more. A sole video library
  defaults on but can be switched off, so `effectiveLibraryIds()` treats a
  missing saved value and an empty one as different answers.

### Decks, detaching, and the debug panel
- `_detachDeck(el)` - **3597**. The ONLY correct way to let go of a deck.
  Assigning an empty string to `.src` makes the element load the page itself as
  media; every detach goes through here.
- `debugPanelText()` - **7387**. Behind a `.cascade-debug` sentinel file, costs
  nothing when absent. Shows PlayMethod and prefetch hit/miss with readyState.

## index.html landmarks

- Titlebar CSS **21-23**, markup **~1010**. `html[data-platform="darwin"]
  .titlebar { padding-left: 80px }` reserves the traffic lights.
  `data-platform` is set in `renderer.js` at **3944** from
  `window.cascade.platform`.
- Setup overlay **255-293** (fade + `prefers-reduced-motion`), video intro card
  **286-292**.
- Popup animation pattern **793+** and **919+**. Everything keeps `display`
  fixed and moves `opacity` + `visibility` + `pointer-events` + a transform,
  140ms, `cubic-bezier(0.2,0.7,0.3,1)`. **Do not go back to toggling
  `display`** - it cannot be transitioned, and `visibility` is what keeps a
  closed popup out of hit-testing.
- Modals: `.modal-overlay` / `.modal-card` / `.modal-list` / `.modal-btn` /
  `.modal-input`. Reuse these verbatim for any new dialog and it inherits the
  animation for free.
- Tooltips: `[data-tip]::after`. Renders **below** its host on purpose, because
  one parent panel clips overflow. Check clipping wherever you attach it. There
  is exactly one tooltip system - do not add a second.
- Settings view `#view-settings` **1514**. Five groups since the consolidation:
  Library **1517**, Playback (Equalizer folded in) **1566**, Lyrics & Metadata
  (the old Fetching + Lyrics) **1669**, Integrations (Discord + Waterfall)
  **1697**, Account **1747**. Reorganising headings is fine, **renaming an
  element id is not**: `renderer.js` looks them up by string literal, and no
  typecheck catches a rename.
- Range inputs already have a shared style (from the EQ sliders), so a new
  slider needs no new CSS.

## main.js landmarks

- `createWindow()` - **166**. `titleBarStyle: 'hiddenInset'` +
  `trafficLightPosition` (**176-177**) are **macOS only**; on Windows and Linux
  they are ignored, which is why those platforms get the OS title bar AND the
  app's own 38px one stacked. `minHeight: 560` at **173** is deliberate, with a
  comment saying why.
- macOS app menu **196+**. Passing `null` on macOS leaves a dead stub and costs
  the Edit menu, which is what makes Cmd+C/V work in a text field.
- Discord RPC ipc handlers, incl. the `discord-rpc-clear` throttle fix.
- Electron **29**, so `titleBarOverlay` is available on Windows and Linux.

## Server facts (verified against the user's live Jellyfin 10.11.11)

- Admin flag: `Policy.IsAdministrator` on the `/Users/{id}` response.
- `POST /Library/Refresh` - **admin only**, async (returns before scanning).
- `POST /Items/{id}/Refresh` - **admin only**.
- `POST /Items/{id}/Images/Primary` - **admin only**.
- `POST /Playlists/{id}` - normal user. Body `UpdatePlaylistDto`:
  `Name`, `Ids` (full ordered contents, replaces everything), `IsPublic`,
  `Users`. Null fields are left alone. **No Overview field exists.**
- `POST /Playlists/{id}/Items/{itemId}/Move/{newIndex}`, `DELETE
  /Playlists/{id}/Items`.
- User rating is thumbs only (`POST /UserItems/{id}/Rating?likes=`), a different
  field from `IsFavorite`. No star ratings exist. Decided not to build on it.

## House style

- `renderer.js`: no semicolons. `main.js`: semicolons. Match the neighbours.
- **No em dashes anywhere**, code comments and commit messages included.
- Comments explain WHY, especially where a previous bug drove the shape.
- Store values are untrusted: a corrupted setting must never reach a filter gain
  or a bitrate as NaN.
- Every animation belongs in the existing `prefers-reduced-motion` block.
