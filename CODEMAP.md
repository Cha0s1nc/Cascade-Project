# Cascade code map

**Describes the optimization pass on `dev` (parent `93bfb97`). Every line number
below was re-derived at that state, not carried over. Line numbers rot fast: if
a landmark is not where this says, re-grep and fix the line here rather than
trusting it.**

Last re-derivation found the drift from `a3f5f52` was NOT a constant offset -
`connect()` had moved +137 lines while `_detachDeck()` had moved -111. A stale
map cannot be corrected by arithmetic; it has to be re-grepped.

Written so an agent can start work without re-reading the whole tree. It is a
map, not documentation: it says where things are, how they are wired, and
**which shapes exist because a specific bug forced them**. That last part is
the point. Most of what follows is a scar.

## Shape of the project

| File | Lines | What it is |
|---|---|---|
| `renderer.js` | ~8996 | The whole UI. Plain global scope, **no semicolons**, no modules. |
| `index.html` | ~2792 | All markup AND every CSS rule in one `<style>` block. |
| `main.js` | ~1028 | Electron main process. Uses semicolons. |
| `src/core/*.ts` | 21 modules | Pure logic, bundled by esbuild via `src/index.ts` into the global `CascadeCore`. |
| `test/*.test.ts` | - | `node --test`. **303 passing** at this commit. |
| `miniplayer.html`, `metadata-editor.html`, `lyrics-editor.html`, `updater.html` | - | Secondary windows, each with its own preload. |

Verify with `npm run build:ts && npm run typecheck && npm test`.

**Run `npx tsc --noEmit` directly, never piped to `tail`.** Errors print above
the last line, so `| tail -1` hides them. A broken assertion shipped that way.

**The coupling no AST can see:** `index.html` defines ids and classes,
`renderer.js` reaches them by `getElementById` / `querySelector` string
literals. Renaming an id is a silent break that typecheck will not catch.

## Rules this codebase learned the hard way

1. **Read the response of anything that writes.** Five separate write paths
   were found reporting success on an HTTP 403 because nothing checked
   `res.ok`, and one removed a track from the queue regardless of what the
   server said, so a refused delete looked exactly like a successful one.
2. **Never trust an endpoint's shape from memory.** "Mark as played" was
   written against `/Users/{id}/PlayedItems/{id}`, which does not exist on
   Jellyfin 10.11. The server's own OpenAPI spec is the source of truth.
3. **A layout class must be set or cleared BEFORE a skeleton is drawn**, not
   after the fetch resolves, or the placeholder is laid out by whatever the
   previous screen left behind.
4. **`ready-to-show` can never fire on Windows.** See `showWhenReady()`.
5. **Windows and Linux draw OS caption buttons OVER the page, top right.**
   Use `--caption-reserve`. This has bitten three separate controls.
6. **A `-webkit-app-region: drag` surface hands its mouse events to the OS.**
   Nothing under it receives hover, click or mousemove.
7. **A pseudo-element cannot escape its host** - not its clipping, not its
   stacking context. No z-index fixes it from the inside.
8. **A canvas painted from a DOM `<img>` is tainted.** Art elements are written
   by `innerHTML` with no `crossorigin`, so `getImageData` throws and colour
   extraction silently returns nothing - a theme toggle that looks simply dead.
   Always go `fetch -> blob -> objectURL -> Image`; see `themeFromArtUrl()`.
   Do NOT "fix" it with `crossorigin="anonymous"` on the tags: that sends an
   Origin header the server may not answer, breaking the image itself.
9. **A guard that names an element id is only as good as the id.** The side
   panel's karaoke fill was gated on `getElementById('view-lyrics')`, which has
   never existed - the optional chain yielded `undefined` and the feature never
   ran once, for as long as it shipped. `?.` on a lookup turns a typo into
   permanent silence. Grep the id before trusting a guard that uses one.

## renderer.js landmarks

### Session, permissions, setup
- `connect(serverUrl, token, userId)` - **614**. Sets the global `jf`. Fires
  `/Users/{id}/Views` in PARALLEL with the token ping rather than after it.
  The ping's response carries `Policy`, which is where `isAdmin` and
  `canDelete` come from, so both are free - do not add a request for them.
- `_applyAdminGating()` - **801**. Gates the library scan, both Refresh
  metadata entries, Edit metadata/images, and playlist delete. **A new
  admin-only control must be added to this function's id list or it is not
  gated at all.** Uses the `.needs-admin` class plus an inline note.
- `maybeShowSetupWizard()` - **1273**, `WIZARD_REVISION` - **1242**. Runs from
  `connect()` off a stored revision, NOT the app version and NOT a boolean.
  Safe to re-show on update only because every step seeds from the current
  live value. **Never add a step that writes a default on entry.**
- `setBrowseMode()` - **1078**. The Music/Video toggle. A browsing filter only:
  it never touches playback or the queue.

### Library, views, caches
- `invalidateLibraryViews()` - **783**, `invalidateVideoViews()` - **792**.
  Plus the `dataset.loaded` flag `showView()` checks. That pair and that flag
  ARE the cache layer; there is no other.
- `renderLibraryPicker()` - **906**, `renderVideoLibraryGroups()` - **1131**.
  Neither hides itself for having only one library. A sole video library
  defaults on but can be switched off, so `effectiveLibraryIds()` treats a
  missing saved value and an empty one as different answers.
- `loadPosterGrid()` - **2874**. Adds `.lib-grouped` to the container when it
  holds groups (index.html **154**). Without it the container is still a
  150px-column grid and each whole library group becomes ONE cell, which
  renders two libraries as two narrow columns.

### Playlists
- `currentPlaylistItems` - **2074**, `playlistMutated()` - **2082**. **The
  single choke point every mutation must go through.** Bypassing it is what
  once left the in-memory list holding removed tracks.
- `openPlaylist()` - **2386**. Clears `has-extra-col` before drawing its
  skeleton, per rule 3 above.
- Smart playlists (Favorites, Most Played) hide the Edit button: they are
  generated, with nothing on the server to rewrite.

### Playback, decks, crossfade
- Two permanent `<video>` decks, `DECKS`, the `audio` pointer, and
  `onDeck(type, fn)` which binds both and filters to the live one.
- `_detachDeck(el)` - **4232**. **The only correct way to let go of a deck.**
  Assigning `''` to `.src` makes the element load the page itself as media.
- `_swapDeck` **4237**, `finishCrossfade` **4256**, `cancelCrossfade` **4281**,
  `_waitForPlayable` **4396**.
- `currentDeviceProfile()` - **437**. The profile minus any codec proven
  undecodable at runtime.
- `_armAudioDecodeCheck()` - **8704**. Detects "video plays, no sound" using
  `webkitAudioDecodedByteCount`, NOT the analyser level: a quiet scene and a
  broken decoder both read as zero level, but only a broken decoder has
  decoded zero BYTES while the clock ran. On failure it withdraws the codec
  claim, persists it, and re-negotiates.
- **Crossfade stutter is still open**, and six candidates are already ruled
  out by reading: ramp resolution, the readiness bar, colour extraction at
  handoff, list virtualisation, EQ parameter ramping, and graph rewiring. It
  needs a `readyState` reading off the debug panel, not another guess.

### Web Audio / EQ
- `_ensureEqGraph()` - **5380**. AudioContext -> per-deck source -> per-deck
  gain (the crossfade envelope) -> preamp -> 5 biquads -> analyser -> out.
  Built once, never rewired.
- Three failure flags at **5343**, and the distinction is load-bearing:
  `_eqGraphFailed` (no graph at all, blocks bars AND crossfade),
  `_eqNoSignal` (cosmetic, bars only), `_eqEverHadSignal`. Conflating the
  first two silently killed crossfade for a whole session once.

### Lyrics
- `lyricsPanelOpen()` - **7604**. The single visibility test both lyrics loops
  use: `_paintWordSpans`/`_wordHighlightFrame` (**7543**) and the `timeupdate`
  line-promotion handler. `.lyrics-panel` is `position: fixed` ABOVE every view
  (index.html **958**), so it is NOT hidden by navigating elsewhere and `.open`
  is the entire condition. Both loops are expensive off-screen: one restyles
  word spans at 60fps, the other forces layout per line change.
- A lyrics MISS is cached, not just a hit (`_cachePut(item.Id, null)` at the
  tail of `fetchLyricsWaterfall`). Both readers gate on `.has()`, so without it
  a track with no lyrics anywhere re-ran all three sources on every advance -
  for the track and the five `_prefetchUpcoming` looks ahead at. A forced
  source still bypasses the cache; `_reloadLyricsFor()` is the escape hatch
  when a source was merely down.

### Theme and album art
- `setThemeMode()` - **8318**, `applyAlbumArtTheme()` - **8496**. **One**
  extraction feeding both blobs and accent; a second, disagreeing one was
  removed.
- `themeFromArtUrl()` - **8482**. The ONLY way to feed colour extraction, per
  rule 8 above. Four call sites route through it; `applyAlbumArtTheme()` is
  called from nowhere else.
- `setOverlayBackgroundImage()` - **5281**. Single choke point for
  `#np-overlay`'s background, holding a skip-if-unchanged cache. That element is
  `position: fixed; inset: 0` and the queue, transport, art and lyrics all paint
  into the same layer, so every assignment re-rasters the viewport - and writing
  an identical value still invalidates paint. The cache lives in the setter and
  not in `startBeatLoop`'s closure precisely because three other paths write
  this property and would leave a closure-local cache stale.
- Light mode is NOT "dark but paler". With multiply blending a dark blob
  stains a near-white base like ink, so the two lightness ranges move in
  opposite directions on purpose. See `BLOB_L_RANGE` in `album-colors.ts`.

### Tooltips, menus, debug
- `_positionTooltip()` - **8623**. One shared `#tooltip` element on `<body>`
  (index.html **513**), delegated from `document`. NOT a `::after`: a
  pseudo-element cannot escape clipping or a stacking context, which is why
  tips vanished behind the player bar and inside Settings.
- Three context menus, all direct children of `<body>`: `#ctx-menu`
  (**2452**), `#track-ctx-menu` (**2506**), `#item-ctx-menu` (**2554**, albums
  / artists / video / series / playlists, driven by `menuItemsForKind()` in
  `src/core/context-menu.ts`). All three clamp position via
  `CascadeCore.clampMenuPosition()`.
  - Known gap, deliberately left: `#ctx-menu`'s own item handlers never call
    `hideCtxMenu()` on click.
- `setItemPlayed()` - **7130**. `POST`/`DELETE /UserPlayedItems/{id}`.
- `debugPanelText()` - **8800**. Behind a `.cascade-debug` sentinel file,
  costs nothing when absent. Shows PlayMethod, every audio track with whether
  this build claims to decode it, live analyser peak, decoded byte count, and
  prefetch hit/miss with readyState. Shift-click copies it.
- `pushMiniplayerState()` - **3628**. Sends lyrics from the CURRENT line
  onward, so the miniplayer renders top-down with the active line at the top
  and does no scrolling of its own.

## index.html landmarks

- Titlebar CSS **21-43**, `--caption-reserve` at **39**. `data-platform` is set
  on `<html>` from `window.cascade.platform`.
- `#tooltip` **513**. `.hshelf` **166** (the horizontal shelf with edge arrows,
  used by Home shelves and grouped library rows). `.lib-grouped` **154**.
- Now-playing overlay: header **536**, video full mode **744**. The header and
  the column divider have no borders on purpose - they cut through the album
  art background, which bleeds across both halves.
- Settings `#view-settings` **1825**, five groups from **1827**: Library,
  Playback (Equalizer folded in), Lyrics & Metadata, Integrations, Account.
  Reorganising headings is fine; **renaming an id is not**.
- First-run wizard `#firstrun-overlay` **2209**.
- Popups keep `display` fixed and transition opacity + visibility + transform.
  **Never go back to toggling `display`**: it cannot be transitioned, and
  `visibility` is what keeps a closed popup out of hit-testing.

## main.js landmarks

- `showWhenReady(w, after)` - **273**. **The only correct way to show a window
  created with `show: false`.** `ready-to-show` fires on first paint, and a
  hidden window on Windows may never produce one, which cost this app both its
  main window and its lyrics editor. Races it against `did-finish-load` with a
  timeout behind both. Media keys and the update check hang off
  `did-finish-load` for the same reason.
- `createWindow()` - **310**. `hiddenInset` + `trafficLightPosition` are macOS
  only; Windows and Linux get `titleBarOverlay`. `minHeight: 560` is
  deliberate.
- `DEBUG_SENTINEL` - **446**. Resolved on first ask, not at module scope: it
  once called `app.getPath()` during `require()`, before the app was ready.
- Secondary windows: metadata editor **613**, miniplayer **672**
  (`MINI_WIDTH` **657**, width locked, height 100-900, persisted).
  **Every new window must be added to `package.json`'s `build.files`** or it
  works in dev and is missing from the packaged app.
- The miniplayer is gated to unpackaged builds; packaged shows "coming soon".

## Server facts (verified against this user's live Jellyfin 10.11.11)

- Admin: `Policy.IsAdministrator` on `/Users/{id}`.
- Deletion is its OWN right: `Policy.EnableContentDeletion` plus
  `EnableContentDeletionFromFolders`. An admin has it implicitly; a non-admin
  can be granted it. See `canDeleteMedia()` in `src/core/permissions.ts`.
- `POST /Library/Refresh`, `POST /Items/{id}/Refresh`, `POST /Items/{id}` and
  `POST /Items/{id}/Images/Primary` are all **RequiresElevation**.
- `POST /Playlists/{id}` takes Name, Ids (the full ordered contents) and
  IsPublic under normal auth. **No Overview field exists.**
- `POST /Playlists/{id}/Items` takes `ids` as a query array, so
  comma-separated works.
- Played state is `POST`/`DELETE /UserPlayedItems/{id}` with `userId` as a
  query parameter. The `/Users/{id}/PlayedItems/{id}` route is gone.
- There are **no star ratings**. `POST /UserItems/{id}/Rating` is a thumbs
  boolean, a different field from `IsFavorite`. Decided not to build on it.
- Jellyfin exposes **no per-playlist add date**. Playlist entries are the plain
  track DTO plus a `PlaylistItemId`.

## House style

- `renderer.js`: no semicolons. `main.js`: semicolons. Match the neighbours.
- **No em dashes anywhere**, code comments and commit messages included.
- Comments explain WHY, especially where a past bug drove the shape.
- Store values are untrusted: a corrupted setting must never reach a filter
  gain or a bitrate as NaN.
- Every animation belongs in the existing `prefers-reduced-motion` block.
- A disabled control must ALSO be guarded in its handler. A disabled-looking
  element can still be clicked programmatically.
