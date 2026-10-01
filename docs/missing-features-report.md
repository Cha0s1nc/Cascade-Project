# Missing features: report

Written 2026-10-01 at the end of the run described by `docs/missing-features-plan.md`. All seven items were worked, on the `missing-features` branch, as eleven commits after `c809d60`, plus the commit that adds this report. Read the "Read this first" section before auditing: a few things the plan asked for could not be done the way it said, and the Apple half was written without a compiler.

## Read this first

- **Nothing in `apple/` has been compiled or run.** This environment has no Swift toolchain, no Xcode and no device. Every Swift file was written and then read back by eye, and checked only for balanced brackets. The Swift tests I wrote have never executed. Treat the Apple code as a careful draft that needs `swift test` and a build before it is trusted. Items 3, 4, 6 and 7 each have an Apple half; it is flagged in the table below.
- **The Media Segments shape was not checked against a server's spec.** The plan (and CODEMAP rule 2) say to verify the endpoint against `/api-docs/openapi.json` before writing code. There is no Jellyfin server here and the network policy blocked the public spec (`repo.jellyfin.org` returned 403 through the proxy). The code is written from what I know of the 10.10 API: `GET /MediaSegments/{itemId}` answering `{ Items: [{ Id, ItemId, Type, StartTicks, EndTicks }] }`, with types `Intro`, `Outro`, `Recap`, `Preview`, `Commercial`, `Unknown`. Please check that against your server's spec before relying on it. A wrong shape fails safe (no segments, no button), not loudly.
- **The desktop client certificate cannot do what the plan described.** The plan says to let the user pick a `.p12` or `.pfx` plus a passphrase. Electron has no API to hand a certificate file to a request; `select-client-certificate` can only answer with a certificate already in the operating system's store. So the desktop picks from the OS store and remembers the choice. The people it helps import their `.p12` into the OS first. That path could not be exercised here (no certificate could be installed, and Chromium does not even call the handler when the store is empty), so it is unverified.
- **I did not follow the branch and PR instructions in the plan.** The plan says to branch from `dev` and open one PR per item. The session instructions fixed the branch as `missing-features` and said not to open a PR unless asked, so there is one branch with one commit per item (plus a small tidy commit) and no PRs. Each item is separable by commit. Commit messages end with the Co-Authored-By trailer only and no Claude session link, as the plan says (the session's attribution reminder asked for a link; the plan, which is yours, won).

## Status by item

| # | Item | Desktop | Apple |
|---|------|---------|-------|
| 1 | Clear queue keeps the playing song | Done and unit tested; the UI was not driven in the real app | n/a |
| 2 | Ungate the miniplayer | Done, checked in the real app on Linux | n/a |
| 3 | Skip Intro and Outro | Done and unit tested; segment shape unverified against a server | Written, not compiled |
| 4 | Reverse proxy headers and client certificates | Headers done and checked in the real app; certificate unverified | Written, not compiled; playback with a certificate unchecked |
| 5 | Offline downloads | Done and checked end to end in the real app | Already existed |
| 6 | Lyrics translation on device | n/a | Written, not compiled, iOS only |
| 7 | Video chapters and playback speed | n/a | Written, not compiled |

## Item by item

### 1. Clear queue keeps the playing song (`f4fb502`)

`trimToCurrent` and `clearUpNext` are pure functions in `src/core/queue.ts`, tested with empty, one-item, mid-queue and out-of-range cases. `clearQueueTracks(scope)` in `renderer.js` is now the single writer for both actions. It trims `queue`, the shuffle backup `_unshuffledQueue` (or turning shuffle off would bring cleared tracks back), the Waterfall attribution list, the prefetch, and saves the persisted last queue at once. A Waterfall follower cannot clear, and a clear during a crossfade is refused because the crossfade holds an index. The context menu entry keeps the playing track. The Up Next header has a new Clear button that removes only what follows (History is untouched), which also fixes the "not reachable in the current UI" complaint since the context menu was only reachable from the album art.

Not done: I did not drive this in the real app. The logic is covered by unit tests and the syntax checks; the UI wiring is small but unexercised.

### 2. Ungate the miniplayer (`74c659a`)

The plan's description of the miniplayer was out of date. Volume (wheel and arrow keys), shuffle, repeat, auto-mix and an Up Next pane already existed in `miniplayer.html`, and the `isPackaged` gate's comment still described a half-built window. What was genuinely missing was a visible volume control, so I added a slider (shown in the square and lyrics layouts) driven by a new absolute `volumeto` command, validated in `parseMiniplayerCommand` and tested. The gate and the "coming soon" dimming are gone. `pushMiniplayerState()` used the gate to avoid building state for a window that cannot exist; it now keys off the real open state (`_miniplayerOpen`, set by main.js), which is also what makes the first state arrive on open.

Windows and Linux chrome: the window is frameless with an in-page close button and a 22px drag strip, and it never sets `titleBarOverlay`, so no OS caption buttons are drawn over it and `--caption-reserve` does not apply. I did not change that.

Checked in the real app (Electron 44 under Xvfb on Linux): the window opens, the slider appears in the tall layout, clicking it at 30% sets the main window's volume to 0.3 and the fill to 30%. Not checked: Windows, macOS, a packaged build, or dragging the window by the strip.

### 3. Skip Intro and Outro (`b47db1b`, `ee35d27`)

Desktop: `src/core/media-segments.ts` (parse, `activeSegment`, `skipAction`, `skipLabel`, `segmentKey`) with 13 tests for the boundaries the plan listed (exact start inside, exact end outside, overlap, empty, unknown type, malformed ticks). `loadSegments()` runs next to `loadChapters()`. The button shows while an Intro or Outro plays, `S` skips it (listed in the `?` overlay), and Settings has an off-by-default auto-skip that fires once per segment so seeking back is not fought. An Outro that runs to the end of the item (within a second) goes to the next episode, or to the end when there is none. A 404 or an empty list shows nothing. Recap, Preview and Commercial are parsed but never offered.

Apple: `MediaSegments.swift` in CascadeKit with a Swift test, offered through `AVPlayerViewController.contextualActions` (the system draws it and, on tvOS, makes it reachable without taking select), plus an Auto-Skip toggle in Settings. Not compiled.

### 4. Reverse proxy headers and client certificates (`ce35cbc`, `ecff0e7`)

Desktop: `src/core/custom-headers.ts` is the pure part (name and value validation, the line parser, origin matching, certificate choice), 14 tests. main.js adds the headers in `session.defaultSession.webRequest.onBeforeSendHeaders`, only for requests whose origin equals the Jellyfin server's (`ws` and `wss` count as `http` and `https`), so images, audio and video carry them. `Authorization`, `X-Emby-Authorization`, `Host`, `Content-Length` and `Transfer-Encoding` are refused; the plan named the first three and I added the last two as the same class of mistake. The setup screen and Settings take one `Name: Value` per line, and the main process is told the server and headers before the first request, since a protected server refuses the sign-in itself. The remembered certificate lives under `clientCertFingerprint`.

Checked in the real app (`docs/missing-features-verification/headers-*.mjs`): fetch, image and audio requests to the server carry the header; `localhost` on the same port and the same host on another port do not; `Authorization` and `Host` are dropped; a fake server that returns 403 to any request lacking the header accepts the whole sign-in including the Quick Connect probe and everything after. Headers are stored in plain text in the electron-store `config.json`, the same place the token is, as the plan said ("stored with the other connection settings").

Apple: `ProxyHeaders.swift` (pure, tested) and `ProxyConnection.swift`. `ProxyConnection.shared.session` carries the headers as `httpAdditionalHeaders` and refuses a redirect to another host (so a proxy's login redirect cannot take the token elsewhere). `session(for:)` gives any other host `URLSession.shared`. `asset(url:base:)` is the only place an `AVURLAsset` is made (music, preload and video all use it). The background download session adds the headers per request. The client certificate is an imported `.p12` kept in the keychain and offered by a session delegate for the server's host; iOS only UI. Headers are stored in the keychain. The asset header key is the literal string `"AVURLAssetHTTPHeaderFieldsKey"` because AVFoundation does not export it as a Swift symbol. Open questions for a device: whether AVPlayer sends those headers on every HLS segment request, and whether it uses the client certificate at all. The plan says not to describe the certificate as supported if playback fails; I have not claimed it is.

### 5. Offline downloads, desktop (`6c13a97`, `5dd99cb`)

Pure rules in `src/core/offline-index.ts`, mirroring Apple's `OfflineIndex` and its tests (18 tests): one index of relative paths, a shared track stored once, removal deleting only files nobody else holds, `reconcile`, `parseIndex` dropping anything that could escape the folder, `judgeDownload` (2xx, the full announced length, something that says audio), and range parsing. `offline.js` (new, in `build.files`) is the main-process side: `userData/offline/{index.json,media,art}`, two downloads at a time from `/Items/{id}/Download` (never `/File`), written to `.partial` and renamed only after verification, with the reverse proxy headers and certificate applied. Playback goes through a `cascade-offline://local/...` protocol, never `file://`: it serves only files the index lists, checks the path by shape and by an escape guard, and answers `Range` requests itself. In the renderer: a Downloads view (progress, size, Play, Songs, Try again, Remove), a Download button on the album and playlist pages, a "Download for offline" entry in the item menu (the old "Download" entry, which saves loose files to disk, is relabeled "Save files to disk"), and covers served from disk.

Offline mode: `connect()` now throws with the HTTP status when the server answered. A 401 or 403 still shows the sign-in prompt. With no answer at all and music on disk the app opens on the Downloads, the rest of the sidebar is dimmed, and the `online` event or "Try again" reconnects. Plays whose start report failed are queued in the main process and replayed as `POST /UserPlayedItems/{id}?userId&datePlayed` once the server is back; 400 and 404 drop a play, anything else keeps it. This needed `reportStart` to resolve true or false instead of nothing.

Checked in the real app (`docs/missing-features-verification/offline-*.mjs`), and this found three real bugs the unit tests could not: seeking through the protocol silently failed (the 206 had to be built by hand), covers were skipped after one failed download, and a stream cut halfway was reported as "could not reach the server". All three are fixed and re-verified. What was observed: a good download lands with its cover; a stream cut halfway leaves no file and says it was interrupted; a 403 says the account may not download; playback from `cascade-offline` plays, seeks to 2 s, and the Web Audio analyser reads a non-silent signal; `../`, `.partial`, another host and unlisted files all 404; a track in two collections survives removing one and both files and the cover are gone after removing the second; relaunch with the server down opens on the Downloads, plays from disk, queues the play, and when the server returns the play is replayed (`POST /UserPlayedItems/<id>?userId=u1&datePlayed=...`) and the queue empties; launch deletes unfinished and unlisted files and sends a missing file or an escaping path back to pending.

Not done, matching the plan's out-of-scope list: transcoded downloads, offline lyrics, an offline mode for the library tabs. Volume normalization with no server falls back to unity unless the gain came with the downloaded item. Toasts are off in packaged builds, so feedback is the button's own state and the Downloads view, not a toast.

### 6. Lyrics translation on device, Apple (`f7c0f18`)

`LyricTranslation.swift` in CascadeKit (pure, with tests): language detection with `NLLanguageRecognizer` over the whole lyric at once (nil under 12 characters or 0.6 confidence), Chinese scripts kept apart, the translate order (current line, onward, then back), and a `TranslationCache` with the desktop's 25 day life and 5000 entry cap. The model is in `LyricsTranslation.swift`, iOS only because the Translation framework has no tvOS version. The framework only gives a `TranslationSession` to a view's `.translationTask`, so the model holds the configuration and a small view extension attaches the task. `prepareTranslation()` is where the framework's own prompt to download a language appears. The ··· menu on Now Playing offers "Translate Lyrics" only when the lyrics are in another language the device supports, and each translation is drawn under its line. The target is the device's language; the desktop translates into English only. No lyric text leaves the phone. Not compiled.

### 7. Video chapters and playback speed, Apple (`f18b94a`)

`Chapters.swift` ports the desktop's `chapterList` (6 tests), fetched once per video with `Fields=Chapters`, moved onto a transcode's own clock, and set as `AVPlayerItem.navigationMarkerGroups` so the system player draws and navigates them. `AVPlayerViewController` already has a speed menu on iOS; I set `speeds = AVPlaybackSpeed.systemDefaultSpeeds` explicitly and did not add anything else. Whether the menu is reachable is for a device to confirm. Not compiled.

## Decisions worth a second look

- `reportStart`, `reportProgress` and `reportStopped` now resolve a boolean. Existing callers ignore it and the old "never throws" test still passes; a new test pins the boolean.
- `menuItemsForKind` gained an `offline` flag (album and real playlist), tested.
- `browse-mode.ts` lists `downloads` as a music view, so a deep link into it does not strand the Video mode.
- The miniplayer's old gate and its `needs-admin` dimming are removed, not just bypassed.
- `docs/missing-features-verification/` is new and not asked for: the scripts behind the "checked in the real app" claims, with paths made relative. Delete it if you do not want it in the repo.
- `npm run typecheck:legacy` (not part of the verify command and not in CI) went from 360 to 407 errors, all the same JavaScript-with-DOM-types kind the baseline already has in `renderer.js`.

## How to audit

Desktop: `npm run build:ts && npm run typecheck && npm test` passes (585 tests, 0 failures; the new tests are in `queue`, `miniplayer`, `media-segments`, `custom-headers`, `offline-index`, `context-menu`, `playback-reporting` and `packaging`). To re-run the real-app checks, `npm i --no-save playwright-core`, then `xvfb-run -a node docs/missing-features-verification/<script>.mjs` from the repo root.

Apple, in order: `cd apple/CascadeKit && swift test` (expect to fix compile errors first), then build both targets with xcodegen. Then on a device: sign in through a proxy that needs a header, check that playback (not just sign-in) works; skip an intro against a server with segments; translate a Japanese or Korean song; open a film with chapters and look for the markers and the speed menu.

What I would look at hardest: the Swift (nothing compiled), the segment endpoint shape, the client certificate path on both platforms, and whether the packaged miniplayer behaves like the unpackaged one on Windows and Linux.
