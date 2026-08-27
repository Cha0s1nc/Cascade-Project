# Cascade code map

**Describes commit `69b7c4f` on `dev`, as last corrected during the
feat/miniplayer-metadata-editor work. Line numbers rot fast - if a landmark is
not where this says, re-grep and fix the line here rather than trusting it.**
(The previous version of this file described `0577b88` and had drifted
significantly - renderer.js alone had grown by over 1100 lines. Several
landmarks below were re-grepped and corrected as part of that work; the ones
that were not are still worth a grep-first before trusting.)

Written so an agent can start work without re-reading the whole tree. It is a
map, not documentation: it says where things are and how they are wired, not
what they should be.

**Note on `main.js`'s "uses semicolons":** it does not, in practice - the file
has zero trailing semicolons as of this commit. Match the surrounding lines,
not this table, whichever file you're in.

## Shape of the project

| File | Lines | What it is |
|---|---|---|
| `renderer.js` | ~7981+ | The whole UI. Plain global scope, **no semicolons**, no modules. |
| `index.html` | ~2400+ | All markup AND every CSS rule, in one `<style>` block. |
| `main.js` | ~850+ | Electron main process. No semicolons in practice, despite the name. |
| `src/preload.ts` | - | The only bridge to main. Builds `window.cascade`, typed as `ElectronPlatform`. |
| `src/platform/index.ts` | - | Defines `ElectronPlatform`/`DesktopCapabilities` - the actual contract `src/preload.ts` and `types/cascade.d.ts` both derive from. |
| `src/core/*.ts` | - | Pure logic, bundled by esbuild via `src/index.ts` into global `CascadeCore`. |
| `test/*.test.ts` | - | `node --test` (native TS support, Node 22+). 238 passing at this commit. |

Verify everything with `npm run build:ts && npm run typecheck && npm test`.
As of this commit `typecheck` has one pre-existing failure unrelated to any of
this - `test/album-colors.test.ts(184)`, `driftedBlobs()`'s `Blob` has no `.r`
field (it's `w`/`h`). Not touched here; the assertion silently passes at
runtime either way (`undefined === undefined`), so `npm test`'s count is
unaffected.

**Adding a `window.cascade.*` bridge method:** edit `src/platform/index.ts`
(both `DesktopCapabilities` and, if renderer.js should call it without
optional chaining, the `ElectronPlatform` required-fields block) and
`src/preload.ts`. `types/cascade.d.ts` needs no edit - it just declares the
global from `ElectronPlatform` and cannot drift on its own.

**The coupling that matters most and is invisible to any AST:** `index.html`
defines ids and classes, `renderer.js` reaches them by `getElementById` /
`querySelector` string literals. Renaming an id is a silent break. Grep the id
across both files before touching one.

## renderer.js landmarks

### Session and connection
- `connect(serverUrl, token, userId)` - **476**. Sets the global `jf`.
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
- `invalidateLibraryViews()` - **610**. Clears `allSongs` and the
  `dataset.loaded` flag on `albums-grid`, `artists-grid`, `songs-rows`,
  `playlists-grid`.
- `invalidateVideoViews()` - **618**. Same for `movies-grid`, `shows-grid`.
  Deliberately separate: changing music libraries must not drop a loaded movie
  grid.
- `showView(name)` - **1248**. Lazy-loads a grid only when `dataset.loaded` is
  absent. This pair of functions plus that flag IS the cache layer. There is no
  other one. Home's shelves (`loadRecentlyPlayed`, `loadRecentlyAdded`,
  `loadRecentlyWatched`) are NOT covered by either and reload on `loadHome()`.
- These two invalidate functions plus `showView(_currentView)` + `loadHome()`
  are also the established "refresh whatever is on screen right now" idiom -
  see the `s-refresh-local` settings button, and the metadata editor's
  `metadata-editor-saved` handler below, which both use exactly this rather
  than a parallel refresh mechanism.

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
  `onDeck(type, fn)` which binds both and filters to the live one - **67-89**.
  Every listener goes through `onDeck` so a crossfade handoff is a pointer move.
  These two decks and the Web Audio graph they feed (see `_ensureEqGraph`
  below) are the reason the miniplayer (below) is a remote control view rather
  than a second player - moving playback into a second `BrowserWindow` would
  mean a new media element and every track restarting.
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
- `_ensureEqGraph()` - **5000**. AudioContext -> per-deck source -> per-deck
  GainNode (crossfade envelope) -> preamp -> 5 biquads -> analyser -> out.
- Three failure flags - **4666-4668**, and the distinction is load-bearing:
  - `_eqGraphFailed` - no graph at all. Blocks bars **and** crossfade.
  - `_eqNoSignal` - graph exists, tap reads zeros. Cosmetic, bars only.
  - `_eqEverHadSignal` - one non-zero sample proves the tap works.
  Conflating the first two is what silently killed crossfade for a whole
  session once (bc6af6c). Keep them apart.

### Theme and album art colour
- `setThemeMode(mode)` - **7491**. Sets `data-theme="light"` or `''` on `<html>`.
- `applyGradient(start, end)` - **~6587** (not re-verified this pass).
- `applyAlbumArtTheme(imgEl)` - **7645**. **One** extraction, feeding both the
  blobs and the accent. Commit 2edb864 removed a second, disagreeing extraction;
  do not reintroduce one.
- `_blobColors` **4100**, `randomizeDrift()` **4103**, drift loop **~4122**.
- `NEUTRAL_ART_SAT` **6738**. Gradient normalises to L 0.62 / S 0.85 - eyeball
  numbers, tuned against a black background.
- `extractTopColors(img)` - **~6689**. 80x80 canvas, nearest-neighbour on
  purpose (smoothing invents colours that appear nowhere on the cover).

### CascadeSLRC plugin detection
- `probeCascadePlugin()` - **6450**. `GET {jf.url}/CascadeLyrics/Info`. 200
  present, 404 absent, network error changes nothing.
- The gating function that greys controls - **~5622** (not re-verified this pass).

### Permissions and the setup wizard
- `_applyAdminGating()` - **627**. `jf.isAdmin` comes free from the `/Users/{id}`
  ping in `connect()`; do not add a second request for it. Gates the library
  scan, both "Refresh metadata" entries, "Edit images", and (as of this PR)
  "Edit metadata" - the last of these now opens the in-app metadata editor
  (below) rather than the Jellyfin web UI; only "Edit images" still bounces
  to a browser.
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
- `_detachDeck(el)` - **3878**. The ONLY correct way to let go of a deck.
  Assigning an empty string to `.src` makes the element load the page itself as
  media; every detach goes through here.
- `debugPanelText()` - **7891**. Behind a `.cascade-debug` sentinel file, costs
  nothing when absent. Shows PlayMethod and prefetch hit/miss with readyState.

### Miniplayer (remote control view, not a second player)
- `pushMiniplayerState()` - **3300**. Builds a snapshot via
  `CascadeCore.buildMiniplayerState()` (`src/core/miniplayer.ts`, guards NaN/
  out-of-range same as the EQ/volume clamps elsewhere) and sends it over IPC.
  Called from `updateNowPlaying()`, `syncProgressUI()` (timeupdate) and both
  `onDeck('play'/'pause', ...)` handlers - fire-and-forget; main.js drops it on
  the floor when no miniplayer window is open, so nothing here tracks that.
- `window.cascade.miniPlayer.onControl(...)` - wired next to the existing
  `onMediaKey` handler. Maps `'playpause'|'next'|'prev'` to
  `document.getElementById('btn-play'/'btn-next'/'btn-prev').click()` - the
  same buttons `onMediaKey` and `mediaSession` already drive, not a new
  playback path.
- `btn-miniplayer-open` (statusbar) calls `window.cascade.miniPlayer.open()`,
  which main.js turns into minimizing the main window and creating/focusing
  `miniplayer.html`. Clicking anywhere in that window (or a control button
  first stopping propagation) sends `miniplayer-restore`, which main.js turns
  into `win.restore()` + `win.focus()` + closing the miniplayer window.

### Video full mode
- `setVideoFullMode(on)` - **5533**, persisted to `videoFullMode` store key,
  applied in `applyVideoMode()` (**2978**) so a saved preference from the last
  video takes effect on the next one. Independent of real OS fullscreen
  (`toggleVideoFullscreen()` - **5517**) by design - see `.np-overlay.video.full`
  in index.html.
- Reuses `pokeOverlayControls()` / `.np-overlay.idle` (the existing idle-fade
  timer) rather than a second one - full mode only changes what the CSS does
  while idle, not how idle is detected.
- `ov-full-exit` (click -> `closeOverlay()`) restores the exit that hiding
  `.np-overlay-header` costs; Escape still works unconditionally regardless.

### Metadata editor
- `openMetadataEditorFor(item)` - **~6679** (search `function
  openMetadataEditorFor`; line drifts with every edit to this section).
  Gated on `jf.isAdmin` before ever opening the window - `POST /Items/{id}` is
  `RequiresElevation` on the live server (verified, see Server facts below).
  Wired to `ctx-edit-meta` / `tctx-edit-meta`, which used to call
  `openInJellyfinWeb()`; only `ctx-edit-images` still does.
- Its own window (`metadata-editor.html` + `metadata-editor-preload.js`),
  same shape as the lyrics editor. Fetches the full item itself
  (`GET /Items/{id}`) rather than trusting whatever DTO the row/queue held -
  the save handler always POSTs that full object back with only the eight
  form fields overwritten, never a partial body.
- `metadata-editor-saved` handler (renderer.js, next to
  `openMetadataEditorFor`) - reuses `invalidateLibraryViews()` +
  `invalidateVideoViews()` + `showView(_currentView)` + `loadHome()` (the same
  local-refresh idiom as the `s-refresh-local` settings button), plus a direct
  re-fetch-and-patch of `queue[queueIndex]` when the edited item is the one
  currently playing, since its status-bar/overlay text comes from that
  in-memory object, not from either cache.

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
- Full-screen now-playing overlay CSS **~510+**. `.np-overlay.video.idle` (the
  idle fade, reused rather than duplicated - see `pokeOverlayControls()` in
  renderer.js) collapses title/padding but deliberately leaves the progress
  row up. `.np-overlay.video.full` (**~705+**, added for video full mode) is a
  separate, stronger state on top of that: header hidden outright, info and
  transport floated over the picture with a scrim, and its own `.full.idle`
  rule that - unlike the plain idle fade - hides the progress row too, since
  there is no docked chrome left for it to sit in. `.np-overlay:fullscreen`
  (real OS fullscreen) is a third, orthogonal axis - neither state checks the
  other, by design; either can be on without the other, the same way VLC lets
  you keep on-screen controls in fullscreen.

### Secondary windows
Four now, and they all follow one pattern: an html file, a matching preload, an
`open-*` ipc handler in main.js, and `showWhenReady()` to display them.
- Updater: `updater.html` / `updater-preload.js`
- Lyrics editor: `lyrics-editor.html` / `lyrics-editor-preload.js`
- Metadata editor: `metadata-editor.html` / `metadata-editor-preload.js`. Admin
  only, `POST /Items/{id}` is RequiresElevation.
- Miniplayer: `miniplayer.html` / `miniplayer-preload.js`, plus
  `src/core/miniplayer.ts`. A REMOTE CONTROL VIEW, not a second player: audio
  keeps running on the main window's decks and only a state snapshot crosses
  IPC. A second media element would mean a fresh stream negotiation and every
  track restarting.

**Every new window must be added to `package.json`'s `build.files`** or it is
missing from the packaged app while working perfectly in dev.

**`showWhenReady(w, after)` is the only correct way to show one.** `ready-to-show`
fires on first paint, and a hidden window on Windows may never produce one, so
that event alone cost this app both its main window and its lyrics editor. The
helper races it against `did-finish-load` with a timeout behind both.

## main.js landmarks

- `createWindow()` - **246**. `titleBarStyle: 'hiddenInset'` +
  `trafficLightPosition` are **macOS only**, guarded via `isDarwin ? ... :
  overlayOptions()` - unguarded, this is how Windows/Linux once got the OS
  title bar AND the app's own 38px one stacked (fixed here; see `overlayOptions()`
  and `showWhenReady()`, both above `createWindow()`). `minHeight: 560` is
  deliberate, with a comment saying why.
- `showWhenReady(w, after)` - **209**. `ready-to-show` can simply never fire on
  Windows for a window created with `show:false` - confirmed in practice, and
  once cost the app its main window AND the lyrics editor. Falls back to
  `did-finish-load`, with a 10s timeout as a last resort. Every secondary
  window (updater, lyrics editor, metadata editor, miniplayer) goes through
  this rather than its own `ready-to-show` listener.
- macOS app menu **~280+**. Passing `null` on macOS leaves a dead stub and
  costs the Edit menu, which is what makes Cmd+C/V work in a text field.
- Discord RPC ipc handlers, incl. the `discord-rpc-clear` throttle fix.
- Electron **29**, so `titleBarOverlay` is available on Windows and Linux.
- Secondary windows, each its own `<name>.html` + `<name>-preload.js` +
  `open-<name>`/`<name>-saved or -state`/`<name>-close` IPC trio:
  - `openUpdaterWindow()` - **~448**.
  - `open-lyrics-editor` - **~481**.
  - `open-metadata-editor` - **~529**. Same shape as the lyrics editor, but
    deliberately keeps the OS's own title bar rather than a custom
    `hiddenInset` one - a hand-rolled titlebar strip needs its own per-platform
    caption-button guarding (see `createWindow()` above) that a plain framed
    window sidesteps entirely.
  - `open-miniplayer` - **~578**. Frameless (`frame:false`, cross-platform,
    not macOS-only like `titleBarStyle`), always-on-top, `skipTaskbar:true`.
    Minimizes the main window on open (`win.minimize()`, not `hide()` - this
    app has no tray icon, so `hide()` would leave no way back to it) and
    restores it (`win.restore()` + `win.focus()`) on `miniplayer-restore`.
  - Every one of these must be added to `package.json`'s `build.files` - it is
    an allowlist for the packaged app, not just a manifest; a file left off it
    is invisible in a built installer despite working fine from source.

## Server facts (verified against the user's live Jellyfin 10.11.11)

- Admin flag: `Policy.IsAdministrator` on the `/Users/{id}` response.
- `POST /Library/Refresh` - **admin only**, async (returns before scanning).
- `POST /Items/{id}/Refresh` - **admin only**.
- `POST /Items/{id}/Images/Primary` - **admin only**.
- `POST /Items/{id}` (update an item's metadata) - **admin only**
  (`RequiresElevation`). `GET /Items/{id}` is normal auth. See the metadata
  editor above - it fetches the full item via the GET and POSTs the whole
  thing back modified, never a partial body.
- `POST /Playlists/{id}` - normal user. Body `UpdatePlaylistDto`:
  `Name`, `Ids` (full ordered contents, replaces everything), `IsPublic`,
  `Users`. Null fields are left alone. **No Overview field exists.**
- `POST /Playlists/{id}/Items/{itemId}/Move/{newIndex}`, `DELETE
  /Playlists/{id}/Items`.
- User rating is thumbs only (`POST /UserItems/{id}/Rating?likes=`), a different
  field from `IsFavorite`. No star ratings exist. Decided not to build on it.

## House style

- `renderer.js`: no semicolons. `main.js`: no semicolons in practice either,
  despite its name suggesting otherwise (see the note near the top of this
  file) - match the neighbours in whichever file you're editing.
- **No em dashes anywhere**, code comments and commit messages included.
- Comments explain WHY, especially where a previous bug drove the shape.
- Store values are untrusted: a corrupted setting must never reach a filter gain
  or a bitrate as NaN.
- Every animation belongs in the existing `prefers-reduced-motion` block.
