# Missing features plan

A handoff for an agent working on Cascade (desktop, Electron) and, where noted, the Apple app in `apple/`. Written 2026-09-30 from a recon of the repo and of what users of competing Jellyfin clients (Feishin, Swiftfin) upvote most. Read `CODEMAP.md` (desktop) and `apple/CODEMAP.md` first. **Every line number in CODEMAP.md can be stale: re-grep, do not trust.**

## How to work

- Branch from `dev`, never `stable`. Open one PR per numbered item so they can land or be dropped independently.
- Desktop verify command: `npm run build:ts && npm run typecheck && npm test`. Run `npx tsc --noEmit` directly, never piped to `tail`.
- `renderer.js` and `main.js` have **no semicolons**. No em dashes anywhere, including code comments and commit messages. American English.
- Pure logic goes in `src/core/*.ts` with a `node --test` test in `test/`, not inline in `renderer.js`. Add a new export to `src/index.ts` so it reaches the `CascadeCore` global.
- Read the response of anything that writes (`res.ok`). Check endpoint shapes against the server's own spec at `/api-docs/openapi.json`, never from memory.
- A new id in `index.html` is reached by string literal in `renderer.js`. Grep the id before trusting a guard that uses it.
- Do not hard-wrap Markdown. Write each paragraph on one line.
- Commit messages: end with the Co-Authored-By trailer only. No Claude session link.
- Do not edit `CHANGELOG.md` unless you are cutting a release. If you do, follow the format in its header; `npm test` checks it.
- **Cloud agents cannot build or run the Apple targets** (no Xcode, no simulator). Items marked Apple below: put every pure, testable piece in `apple/CascadeKit` with a Swift test, keep the UI thin, and say plainly in the PR that the UI is unverified on a device. Do the desktop items first.

## Priority order

1. Desktop: Clear queue that keeps the playing song
2. Desktop: ungate the miniplayer
3. Desktop and Apple: Skip Intro and Outro
4. Desktop and Apple: custom HTTP headers and client certificates for reverse proxies
5. Desktop: offline downloads
6. Apple: lyrics translation on device
7. Apple: video chapters and playback speed

Items 1 and 2 are small. Item 5 is the largest and the most requested (Swiftfin's top issue, 145 votes, is local downloads; Feishin's is offline sync, 88).

## 1. Desktop: Clear queue that keeps the playing song

The context menu has "Clear queue" (`ctx-clear-queue` in `index.html`, handler in `renderer.js`). It sets `queue = []` and `queueIndex = -1`, which drops the track that is playing while its audio keeps going, so the queue panel and the player disagree. The owner also reports the option is not reachable in the current UI.

- Make it keep the current track: `queue = [queue[queueIndex]]`, `queueIndex = 0`, and keep clearing the prefetch via `_clearStreamPrefetch()`. If nothing is playing, empty it.
- Put a "Clear" action on the Up Next header of the now-playing queue panel (the queue is split into History, Now Playing and Up Next) and keep the context menu entry. Clearing Up Next must not touch History.
- Confirm the Waterfall host path and the persisted last queue (restored on launch) see the change. Grep for every writer of `queue`; the playlist choke point rule applies in spirit: do not leave a second copy holding removed tracks.
- Test: extract the "trim to current" step as a pure function in `src/core` and test it with empty, one-item and mid-queue cases.

## 2. Desktop: ungate the miniplayer

`renderer.js` has an `_miniplayerEnabled` flag set from `isPackaged`, so release builds show "Miniplayer - coming soon". The comment says why: no volume, no shuffle or repeat, no queue pane, and window chrome that only works on macOS. The owner released without lifting it and wants it available.

- Add volume, shuffle and repeat to `miniplayer.html` and its preload, wired through the existing `miniplayer-control` IPC in `main.js`. A queue pane is optional; skip it.
- Make the window chrome work on Windows and Linux, or hide the controls that do not. There is a standing rule: Windows and Linux draw OS caption buttons over the page, top right, so use `--caption-reserve`. A `-webkit-app-region: drag` surface swallows its own mouse events.
- Remove the `isPackaged` gate and the `needs-admin` dimming on `btn-miniplayer-open` only once the above works. Do not remove the gate if it does not; say so in the PR.
- Cannot be verified headlessly. Say which parts were checked.

## 3. Desktop and Apple: Skip Intro and Outro

Jellyfin 10.10 and later exposes Media Segments: `GET /MediaSegments/{itemId}` returns typed ranges (Intro, Outro, Recap, Preview, Commercial) in ticks. The server only has data if a provider made it (the Intro Skipper plugin, or chapter-based detection). Verify the exact path, query and field names against the server's openapi before writing code; if the server is older or returns 404 or an empty list, show nothing and do not error.

- Pure logic in `src/core`: parse the response, and given a position return the active segment or null. Test boundaries (exact start, exact end, overlapping, empty, unknown type).
- Desktop video player: fetch segments when a video loads, next to `loadChapters()`. On entering an Intro or Outro show a "Skip Intro" or "Skip Credits" button, hide it on leaving, and seek to the segment end on click. Add a setting for auto-skip (off by default) and a keyboard shortcut, and list it in the `?` shortcuts overlay. Skipping an Outro that runs to the end of an episode should go to the next episode if Cascade already does that for episode ends.
- Apple: port the parser to `apple/CascadeKit` with a test. In `VideoSession` (`App/Sources/VideoPlayer.swift`) add the button as a contextual action on the player. On tvOS it needs focus, and the skip button must not steal the remote's select. Unverified without a device.

## 4. Desktop and Apple: custom HTTP headers and client certificates

Who needs it: people whose Jellyfin sits behind Cloudflare Access (service tokens), Authelia, or a proxy that requires a client certificate. The proxy rejects any request without the header or certificate, so the app cannot even reach the Jellyfin sign-in. Competing apps' trackers show real demand (Swiftfin #812 with 31 votes, Feishin #1995 and #1720).

Desktop (Electron):
- Setting: a short list of header name and value pairs, entered at sign-in and editable in Settings, stored with the other connection settings (never the password, as today). Validate names (token characters only) and refuse to override `Authorization`, `Host` and `Content-Length`.
- Inject them in the main process with `session.defaultSession.webRequest.onBeforeSendHeaders`, filtered to the Jellyfin server's origin. This is the only approach that also covers `<img>`, `<audio>` and `<video>` requests, which a `fetch` wrapper cannot reach. Do not send the headers to any other host (lyrics providers, GitHub, Mozilla, the Waterfall relay).
- Client certificate: handle `app.on('select-client-certificate')` and let the user choose a `.p12` or `.pfx` file plus passphrase. Keep this as a second step if it is large; headers alone unblock most people.
- Test the pure part (name validation, origin matching) in `src/core`.

Apple:
- Headers: `URLSessionConfiguration.httpAdditionalHeaders` for the API client and the background download session, and `AVURLAssetHTTPHeaderFieldsKey` in the options for every `AVURLAsset` (music, video, preload). Missing the asset path would make sign-in work and playback fail, which is the worst outcome, so grep every place a stream URL is opened.
- Client certificate: a `URLSessionDelegate` handling `NSURLAuthenticationMethodClientCertificate`. AVPlayer does its own networking, so a certificate may not apply to playback at all. Test that on a device; if it fails, say so in the PR rather than shipping it as supported.

## 5. Desktop: offline downloads

The Apple app has a full offline library (`apple/CascadeKit/Sources/CascadeKit/OfflineIndex.swift`, `OfflineLibrary.swift`) and its design carries over: read the "Offline downloads" section of `apple/CODEMAP.md`. Desktop today only has a per-item "Download" that saves a single file to disk (`/Items/{id}/Download`), with no library, no index and no offline playback.

- Store under `app.getPath('userData')/offline` with one index file of relative paths, validated when read. A track shared by two downloads is stored once; removing one download deletes only files nobody else holds. Reconcile the index with the files on disk at launch.
- Download from an album's or playlist's menu and a button on its page, with a Downloads view showing progress, size and remove. Use `/Items/{id}/Download`, not `/File` (only the former honors the admin's download switch). Keep a file only on a 2xx with the full length; a truncated stream must not become a finished download. Write to a `.partial` name and rename on verify, the way translation models are handled in `main.js`.
- Playback: resolve a downloaded track to a file URL before asking the server. Serve it through a custom protocol with the escape guard `serveWithin()` already uses; do not load `file://` directly, and never accept a path from the renderer without checking it resolves inside the offline directory.
- Offline mode: when the server is unreachable, Downloads and playback must still work with no network. Playback reports for offline plays are queued and replayed (Jellyfin counts a play on the START report, so replay as a played-at update, see the Apple notes).
- Out of scope: transcoded downloads, offline lyrics, an offline mode for the library tabs.
- Pure index logic goes in `src/core` with tests mirroring `OfflineIndex`'s.

## 6. Apple: lyrics translation on device

Desktop translates lyrics (Apple's on-device Translation on macOS 26 and later, Mozilla models otherwise). The Apple app has none. Use the Translation framework (`TranslationSession`, which on iOS is obtained from a SwiftUI `.translationTask` modifier, so the request must be driven from a view). On-device only: no lyric text may leave the phone, same promise as the desktop README.

- Language detection: the desktop uses `franc`. Use `NaturalLanguage`'s `NLLanguageRecognizer` on the phone.
- Translate line by line starting from the current line, show the translation under each line, and cache results on device for 25 days like the desktop.
- If the language pack is not installed, offer to download it through the framework's own prompt.
- Unverified without a device. Put detection glue and the cache in CascadeKit with tests.

## 7. Apple: video chapters and playback speed

Desktop's video player has chapters and a speed control; Apple's `VideoSession` uses `AVPlayerViewController` and exposes neither. Chapters come from the item's `Chapters` field and can be supplied as `AVNavigationMarkersGroup` through `externalMetadata` or `navigationMarkerGroups`. `AVPlayerViewController` already has a speed menu on iOS, so only confirm it is reachable and add chapters. Lowest priority.

## Deliberately not in this plan

- **Scrobbling to Last.fm or ListenBrainz.** Cascade already sends Jellyfin playback reports, and the server-side Last.fm and ListenBrainz plugins scrobble from those. A client-side scrobbler would double-count for anyone who has the plugin. Revisit only if users without server access ask.
- **Chromecast.** The Apple app has AirPlay. Not worth a sender.
- **CarPlay.** Blocked on a paid Apple developer account.
- **Widgets, Siri, Handoff, Spotlight.** Real gaps but nobody upvoted them; no demand evidence.
- **SyncPlay and SharePlay.** Waterfall is the listen-together answer for music. Video together is a separate, large project.
- **Roku.** Handled separately in `~/VScode/cascade-roku`.
