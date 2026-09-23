# Cascade code map

**Describes `dev` at `526f6ba` (the CSS split). Every line number below was
re-derived at that state, not carried over. Line numbers rot fast: if
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
| `renderer.js` | ~9491 | The whole UI. Plain global scope, **no semicolons**, no modules. |
| `index.html` | ~1479 | All markup. No CSS: it links `styles/*.css`. |
| `styles/*.css` | 12 files | Every CSS rule, split by area and linked from `index.html` **in cascade order** (base, layout, library, settings, player-bar, controls, np-overlay, menus, lyrics, modals, theme, components). Reordering the `<link>`s changes the cascade. A new stylesheet must be under `styles/`, which `package.json` `build.files` ships. |
| `main.js` | ~1328 | Electron main process. **No semicolons**, same as renderer.js. |
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
- `connect(serverUrl, token, userId)` - **628**. Sets the global `jf`. Fires
  `/Users/{id}/Views` in PARALLEL with the token ping rather than after it.
  The ping's response carries `Policy`, which is where `isAdmin` and
  `canDelete` come from, so both are free - do not add a request for them.
- `_applyAdminGating()` - **815**. Gates the library scan, both Refresh
  metadata entries, Edit metadata/images, and playlist delete. **A new
  admin-only control must be added to this function's id list or it is not
  gated at all.** Uses the `.needs-admin` class plus an inline note.
- `maybeShowSetupWizard()` - **1295**, `WIZARD_REVISION` - **1259**, and
  `FIRSTRUN_STEP_REVISION` - **1266**, the revision each step arrived in. An
  update shows only steps newer than the revision last finished. Runs from
  `connect()` off a stored revision, NOT the app version and NOT a boolean.
  Safe to re-show on update only because every step seeds from the current
  live value. **Never add a step that writes a default on entry.**
- `setBrowseMode()` - **1092**. The Music/Video toggle. A browsing filter only:
  it never touches playback or the queue.

### Library, views, caches
- `invalidateLibraryViews()` - **797**, `invalidateVideoViews()` - **806**.
  Plus the `dataset.loaded` flag `showView()` checks. That pair and that flag
  ARE the cache layer; there is no other.
- `renderLibraryPicker()` - **920**, `renderVideoLibraryGroups()` - **1145**.
  Neither hides itself for having only one library. A sole video library
  defaults on but can be switched off, so `effectiveLibraryIds()` treats a
  missing saved value and an empty one as different answers.
- `loadPosterGrid()` - **2904**. Adds `.lib-grouped` to the container when it
  holds groups (`styles/layout.css` **113**). Without it the container is still a
  150px-column grid and each whole library group becomes ONE cell, which
  renders two libraries as two narrow columns.

### Playlists
- `currentPlaylistItems` - **2104**, `playlistMutated()` - **2112**. **The
  single choke point every mutation must go through.** Bypassing it is what
  once left the in-memory list holding removed tracks.
- `openPlaylist()` - **2416**. Clears `has-extra-col` before drawing its
  skeleton, per rule 3 above.
- Smart playlists (Favorites, Most Played) hide the Edit button: they are
  generated, with nothing on the server to rewrite.

### Playback, decks, crossfade
- Two permanent `<video>` decks, `DECKS`, the `audio` pointer, and
  `onDeck(type, fn)` which binds both and filters to the live one.
- `_detachDeck(el)` - **4262**. **The only correct way to let go of a deck.**
  Assigning `''` to `.src` makes the element load the page itself as media.
- `_swapDeck` **4267**, `finishCrossfade` **4286**, `cancelCrossfade` **4311**,
  `_waitForPlayable` **4426**.
- `currentDeviceProfile()` - **451**. The profile minus any codec proven
  undecodable at runtime.
- `_armAudioDecodeCheck()` - **9176**. Detects "video plays, no sound" using
  `webkitAudioDecodedByteCount`, NOT the analyser level: a quiet scene and a
  broken decoder both read as zero level, but only a broken decoder has
  decoded zero BYTES while the clock ran. On failure it withdraws the codec
  claim, persists it, and re-negotiates.
- **Crossfade stutter is still open**, and six candidates are already ruled
  out by reading: ramp resolution, the readiness bar, colour extraction at
  handoff, list virtualisation, EQ parameter ramping, and graph rewiring. It
  needs a `readyState` reading off the debug panel, not another guess.

### Web Audio / EQ
- `_ensureEqGraph()` - **5436**. AudioContext -> per-deck source -> per-deck
  gain (the crossfade envelope) -> preamp -> 5 biquads -> analyser -> out.
  Built once, never rewired.
- Three failure flags at **5399**, and the distinction is load-bearing:
  `_eqGraphFailed` (no graph at all, blocks bars AND crossfade),
  `_eqNoSignal` (cosmetic, bars only), `_eqEverHadSignal`. Conflating the
  first two silently killed crossfade for a whole session once.
- `stopEqLoop()` resets `_eqSilentSinceTs`. Without it, a pause during a
  silent intro left the silence timer counting, and resuming more than
  `EQ_SILENCE_MS` later latched `_eqNoSignal` on the first frame and froze
  the bars for the session. Reproduced before fixing.

### Lyrics
- `lyricsPanelOpen()` - **7696**. The single visibility test both lyrics loops
  use: `_paintWordSpans`/`_wordHighlightFrame` (**7635**/**7645**) and the `timeupdate`
  line-promotion handler. `.lyrics-panel` is `position: fixed` ABOVE every view
  (`styles/lyrics.css` **2**), so it is NOT hidden by navigating elsewhere and `.open`
  is the entire condition. The guard matters for correctness (the karaoke fill
  never ran before it); as a CPU saving it measured below noise, see
  "Measured, not worth building" below.
- **Translation** is Mozilla's Firefox Translations models on the bergamot
  WASM runtime, into English only, for `ja`, `ko`, `zh-Hans`, `zh-Hant`, `es`.
  Adding a language: its files in `translation-models.json` (copied from
  Remote Settings with hashes), uploaded to the models release as
  `<key>-en.<file>`, and the key in `src/core/translation-models.ts`.
  - `translation-models.json` pins every model file by size and sha256.
    Updating a model is a manifest edit plus a new GitHub release, never a
    runtime lookup of Mozilla's Remote Settings (Firefox internals).
  - main.js `downloadTranslationModel()` - **963**. Tries Cascade's GitHub
    release, then Mozilla's CDN, per file. **The hash check is not optional:**
    `downloadFile()` resolves on a truncated stream. Files land in
    `<key>.partial/` and the directory is renamed only once all verify, so an
    installed model is exactly a directory that exists. Keys from IPC are
    checked against the manifest before touching a path.
  - The models' GitHub release must live in a **separate repo**, never
    `Cascade-Project`: the updater reads that repo's latest (or first
    non-draft) release as an app update.
  - `cascade-model://` (`registerModelProtocol`, main.js **60**) serves
    `/runtime/` (the wasm) and `/models/` (installed models) behind
    `serveWithin()`'s escape guard, plus a registry per model
    (`translationRegistryResponse`, **1032**): translator.js keys registries
    by from+to, so the two Chinese models can never share one.
  - `scripts/build-bergamot.js` vendors the runtime. It bundles translator.js
    to the `Bergamot` global with `import.meta.url` defined as
    `self.__bergamotBase` (set in index.html), and points the worker's wasm
    fetch at `cascade-model://`, since fetch from file:// is blocked. Each patch
    asserts it matched, so a runtime upgrade that moves the code fails the build.
  - Renderer: `translateLines()` - **6513**, one `BatchTranslator` per model,
    retired after `TRANSLATE_IDLE_MS` (**6455**); one line per call; an
    in-memory LRU of translated lines for the session.
    `ensureLyricsTranslation()` - **8370** downloads a missing model before
    translating. `CascadeCore.translationModelFor()` decides which model (or
    none, so no Translate button) a sheet gets, telling the Chinese scripts
    apart by characters written differently in each.
  - Two switches, on purpose: `lyricsTranslationEnabled` (Settings/wizard,
    default on) is whether the feature exists; `lyricsTranslateOn` (the
    Translate button, default off) is whether translations are showing.
    `setLyricsTranslationEnabled()` - **8205** is the one path for both
    Settings and the wizard.
  - **Apple Translation (macOS 26+, default on there).** `native/apple-translate`
    is a Swift helper (`TranslationSession(installedSource:target:)`, the
    windowless macOS 26 API) built by `scripts/build-apple-translate.js`: a
    no-op off macOS, fails in CI without the 26 SDK, warns and skips locally.
    CI's mac job is pinned to `macos-26` for that SDK. It is `asarUnpack`ed,
    since nothing inside app.asar can be executed. main.js keeps one
    long-lived helper, spoken to with one JSON line each way over stdin, and
    ends it after five idle minutes and on quit.
    - `CascadeCore.pickTranslationEngine()` decides per sheet: Apple if the
      language is installed in macOS; Mozilla if Apple is off, has no model
      for it ("unsupported"), or the user chose Cascade's model for that
      language; otherwise `needs-install`. The chosen-Mozilla list only
      applies while a language is missing from macOS.
    - `needs-install` shows the install prompt **only for an actual Translate
      press** (`ensureLyricsTranslation(userAsked)`), never on a song change;
      then the button reads "Install X…" and pressing it opens the prompt.
    - Translated lines are cached per engine (`apple|ja|...`), so switching
      engines never serves the other's output.
    - Translation Languages has no System Settings link of its own; the
      prompt opens Language & Region
      (`com.apple.Localization-Settings.extension`) and says where to click.
  - Settings model rows (`renderTranslationModelRows`, **8234**) update in
    place, never rebuild: progress events arrive several times a second and a
    rebuild would swap the button under the pointer.
- A lyrics MISS is cached, not just a hit (`_cachePut(item.Id, null)` at the
  tail of `fetchLyricsWaterfall`). Both readers gate on `.has()`, so without it
  a track with no lyrics anywhere re-ran all three sources on every advance -
  for the track and the five `_prefetchUpcoming` looks ahead at. A forced
  source still bypasses the cache; `_reloadLyricsFor()` is the escape hatch
  when a source was merely down.

### Theme and album art
- `setThemeMode()` - **8790**, `applyAlbumArtTheme()` - **8968**. **One**
  extraction feeding both blobs and accent; a second, disagreeing one was
  removed.
- `themeFromArtUrl()` - **8954**. The ONLY way to feed colour extraction, per
  rule 8 above. Four call sites route through it; `applyAlbumArtTheme()` is
  called from nowhere else.
- `setOverlayBackgroundImage()` - **5337**. Single choke point for
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
- `_positionTooltip()` - **9095**. One shared `#tooltip` element on `<body>`
  (index.html **1477**, CSS `styles/controls.css` **19**), delegated from `document`. NOT a `::after`: a
  pseudo-element cannot escape clipping or a stacking context, which is why
  tips vanished behind the player bar and inside Settings.
- Three context menus, all direct children of `<body>`: `#ctx-menu`
  (index.html **1132**), `#track-ctx-menu` (**1186**), `#item-ctx-menu` (**1234**, albums
  / artists / video / series / playlists, driven by `menuItemsForKind()` in
  `src/core/context-menu.ts`). All three clamp position via
  `CascadeCore.clampMenuPosition()`.
  - Known gap, deliberately left: `#ctx-menu`'s own item handlers never call
    `hideCtxMenu()` on click.
- `setItemPlayed()` - **7222**. `POST`/`DELETE /UserPlayedItems/{id}`.
- `debugPanelText()` - **9291**. Behind a `.cascade-debug` sentinel file,
  costs nothing when absent. Shows PlayMethod, every audio track with whether
  this build claims to decode it, live analyser peak, decoded byte count, and
  prefetch hit/miss with readyState. Shift-click copies it. Its resources
  section (`refreshDebugMetrics()`, fed by main.js `app-metrics` over
  `app.getAppMetrics()`) lists per-process memory, CPU and idle wake-ups.
  **Measure with this before building any performance change.**
- `pushMiniplayerState()` - **3658**. Sends lyrics from the CURRENT line
  onward, so the miniplayer renders top-down with the active line at the top
  and does no scrolling of its own.

### Landmarks for the 2.2.0 work
- Volume: `setVolumeRatio()` **119** is the single choke point (both bars via
  `wireVolumeBar()` **4613** / `wireBar()` **4529**, `nudgeVolume()` **6104**,
  remote control).
- Track lists: `trackRowHtml()` **1804** (shared row markup), `wireTrackRow()`
  **2537**. Songs view: `renderSongRows()` **1965** / `_drawSongRows()` **2035**,
  virtualised, **wires its own handlers inline instead of `wireTrackRow`**, so a
  row behaviour change goes in both. `SONG_ROW_H` **1958** and `QUEUE_ROW_H`
  **20** must match the CSS row heights. Queue: `_drawQueueRows()` **6246**.
  Others: `openAlbum()` **1655**, `openArtist()` **1742**,
  `renderPlaylistDetailItems()` **2323**, search `runSearch()` **8633**.
- Settings wiring: `loadSettingsFields()` **4746**. Theme save: `saveTheme()` **8828**.
- Track change: `playCurrentTrack()` **3349**, `updateNowPlaying()` **3521**
  (mediaSession metadata).
- Menus: `hideCtxMenu()` **6781**; `menuItemsForKind()` `src/core/context-menu.ts` **50**.
- Discord: renderer `initDiscordRpc()` **8558**; main `connectDiscordRpc()`
  main.js **95**, `destroyRpc()` **129**.
- Lyrics sources: `fetchLyricsWaterfall()` **7725**; plugin probe
  `_cascadePluginAbsent` **7307**.
- Updater: main.js `parseVersion()` **530**, `checkForUpdates()` **820**,
  `installSilentlyWindows()` **1221**.

## Measured, not worth building

Taken with the debug panel's resources section on Apple Silicon, playing real
audio on the live deck. Recorded so these are not rebuilt on a hunch.

- **Parking animation loops while minimized.** rAF does keep running at 61fps
  behind a minimized window (`backgroundThrottling: false`), but with the EQ
  bars, overlay blob drift and karaoke loop all live, renderer CPU was 3.4%
  whether the loops ran or not. Chromium already skips raster for an unseen
  window, and the loops' own JS is below noise. Built, measured, reverted.
- **Detecting minimize from the page.** `visibilitychange` never fires and
  `document.visibilityState` stays `visible` while minimized, because Electron
  ties the Page Visibility API to `backgroundThrottling`. Anything that needs
  it must come from main's window events.
- **Overlay blob background.** Animating versus holding one frame, window
  maximized at 1920x1169: GPU 5.0% versus 4.6%. Noise.
- Where the cost actually is: audio playback itself (~1% renderer CPU over
  paused), a constant ~4-5% GPU process baseline that does not move with any
  of the above, and translation memory while a model is loaded (translators
  are retired when idle).
  Low-end hardware was not measured and could differ.

## index.html landmarks

- CSS lives in `styles/`; the line numbers here are within those files.
- Titlebar CSS `styles/base.css` **16-37**, `--caption-reserve` at **32**.
  `data-platform` is set on `<html>` from `window.cascade.platform`.
- `.hshelf` `styles/layout.css` **131** (the horizontal shelf with edge arrows,
  used by Home shelves and grouped library rows). `.lib-grouped` **113**.
- Now-playing overlay: markup index.html **956**; CSS `styles/np-overlay.css`,
  header at **4**, video full mode at **200**. The header and
  the column divider have no borders on purpose - they cut through the album
  art background, which bleeds across both halves.
- Settings `#view-settings` index.html **463**, five groups from **465**: Library,
  Playback (Equalizer folded in), Lyrics & Metadata, Integrations, Account.
  Reorganising headings is fine; **renaming an id is not**.
- First-run wizard `#firstrun-overlay` **874**. Theme picker popover `#theme-picker` **43**.
- Popups keep `display` fixed and transition opacity + visibility + transform.
  **Never go back to toggling `display`**: it cannot be transitioned, and
  `visibility` is what keeps a closed popup out of hit-testing.

## main.js landmarks

- `showWhenReady(w, after)` - **283**. **The only correct way to show a window
  created with `show: false`.** `ready-to-show` fires on first paint, and a
  hidden window on Windows may never produce one, which cost this app both its
  main window and its lyrics editor. Races it against `did-finish-load` with a
  timeout behind both. Media keys and the update check hang off
  `did-finish-load` for the same reason.
- `createWindow()` - **320**. `hiddenInset` + `trafficLightPosition` are macOS
  only; Windows and Linux get `titleBarOverlay`. `minHeight: 560` is
  deliberate.
- `DEBUG_SENTINEL` - **456**. Resolved on first ask, not at module scope: it
  once called `app.getPath()` during `require()`, before the app was ready.
- Secondary windows: metadata editor **640**, miniplayer **699**
  (`MINI_WIDTH` **684**, width locked, height 100-900, persisted).
  **Every new window must be added to `package.json`'s `build.files`** or it
  works in dev and is missing from the packaged app.
- The miniplayer is gated to unpackaged builds; packaged shows "coming soon".
- **Updates.** Windows runs the NSIS installer silently (`installSilentlyWindows`).
  macOS installs in place through `mac-update.js`, **shared byte-identical with
  Cha0s Stream's `electron/mac-update.js`**: change one, copy it to the other.
  Mount the DMG, stage the new
  `Cascade.app` beside the installed one, verify its signature, bundle id and
  version, then a detached shell script waits for Cascade to quit, swaps the
  bundles (restoring the old one if the swap fails) and relaunches. Running
  from the DMG, an App Translocation copy, or an unwritable folder, or any
  failed check, falls back to opening the DMG. Squirrel.Mac is not an option:
  it requires a Developer ID signature and Cascade is ad-hoc signed. None of
  this protects against a malicious release uploaded to the repo; GitHub's
  asset digest only catches corruption. The swap script logs to
  `$TMPDIR/cascade-update.log` (named from the bundle, so Stream's is
  `cha0s-stream-update.log`). `isNewer` sorts `-bN` betas below their release;
  Stream's is the same function.

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

- No semicolons in `renderer.js` or `main.js`. Match the neighbours.
- **No em dashes anywhere**, code comments and commit messages included.
- Comments explain WHY, especially where a past bug drove the shape.
- Store values are untrusted: a corrupted setting must never reach a filter
  gain or a bitrate as NaN.
- Every animation belongs in the existing `prefers-reduced-motion` block.
- A disabled control must ALSO be guarded in its handler. A disabled-looking
  element can still be clicked programmatically.
