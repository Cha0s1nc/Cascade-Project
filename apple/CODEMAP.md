# Cascade Swift: map

Native Jellyfin music client for iOS and tvOS. New project, not a port of the
Electron desktop app, which keeps shipping untouched.

Everything pure and testable lives in `CascadeKit`. The app targets are thin
reflections of it, so the phone runs the same compiled code the Apple TV will.

## Layout

- `CascadeKit/` - the shared Swift package. No SwiftUI, no UIKit.
  - `JSON.swift` - the one rule bridging Jellyfin's PascalCase to Swift naming.
    Use `JSON.decoder` / `JSON.encoder`, never a bare `JSONDecoder()`.
  - `Models.swift` - the Jellyfin shapes this app actually reads.
  - `DeviceProfile.swift` - `DeviceProfile.apple`, what the server negotiates
    against. Read the comments before changing anything in it.
  - `JellyfinClient.swift` - auth and HTTP. Every call checks the status.
  - `Playback.swift` - PlaybackInfo negotiation, resume, transcode seeking.
  - `PlaybackReporting.swift` - start / progress / stopped.
  - `PlaybackService.swift` - the only place AVPlayer is wired up.
- `App/Sources/` - both app targets build these same files. SwiftUI covers most
  of the platform difference; where it does not (tvOS has no `Slider`, and focus
  replaces touch) the views branch on `#if os(tvOS)` rather than forking.
  - `AppState.swift` - the one session and one player, read from the environment.
  - `Keychain.swift` - the access token lives here, not in UserDefaults.
  - `Components.swift` - `ArtworkView`, `TrackRow`, `ItemGrid`, `LoadingOverlay`.
  - `MainView.swift` - tabs, plus the iOS mini player.
  - One file per screen.
- `project.yml` - xcodegen input. `Cascade.xcodeproj` is generated, not
  committed; run `xcodegen generate` after cloning.

## Running on a device

`./run-device.sh` builds, installs and launches on a connected iPhone without
attaching the debugger. About 7 seconds warm. Xcode's own Run attaches LLDB,
which resolves symbols by reading device memory and shows a "taking longer than
expected" dialog; `~/.lldbinit` with `settings set target.preload-symbols false`
takes the edge off that when you do need breakpoints.

## Tests

`cd CascadeKit && swift test` runs offline in under a second.

Point it at a real server to also run the live suite, which is the only thing
that checks the shapes this app sends against the shapes a given Jellyfin
version accepts:

```
CASCADE_SERVER=https://host CASCADE_USER=name CASCADE_PASS=pw swift test
```

## Rules carried over from desktop, each of which cost real time to learn

1. Read the response of anything that writes. Five desktop write paths once
   reported success on an HTTP 403 because nothing checked the status.
2. Never trust an endpoint's shape from memory. The server's own spec is at
   `/api-docs/openapi.json`.
3. A guessed device profile is worse than none. The server trusts it and hands
   back something undecodable, which presents as silence, not an error.
4. Comments explain WHY, especially where a bug forced the shape.
5. No em dashes anywhere, code comments and commit messages included.
6. Anything pure and testable belongs in CascadeKit with a test, not in a view.

## Status

Built: skeleton, device profile, auth, PlaybackInfo, AVPlayer playback with
seek, audio session, now playing and remote commands. The whole build order in
the original brief is done.

Lock screen art is deliberately absent. MPMediaItemArtwork made MediaPlayer
trap inside its own queue plumbing and then crash outright; two fixes moved the
trap without removing it. Everything else on the lock screen works. See the
comment in PlaybackService.swift before trying to add it back.

Verified against the live server: FLAC direct plays (no transcode), the stream
URL serves bytes, AVFoundation decodes it to the duration Jellyfin reports, and
all three reporting endpoints are accepted by 10.11.11.

Verified on real hardware (iPhone 16, iOS 26, free provisioning, 2026-08-27):
sign in, FLAC playback, seeking, lock screen controls, audio surviving a screen
lock, and playback stopping when the app is swiped away.

Background audio DOES work under free provisioning. That was the one unknown
worth answering before building anything on top of it, so it is written down
here rather than re-derived.

Not yet verified: anything needing an Apple TV. Real TV performance, tvOS codec
limits, tvOS storage limits. The iPhone is a strong proxy for the audio path
and no proof at all about video.

Built since: queue with repeat and shuffle, the tvOS target, and every screen.
Home, Albums, Artists, Songs, Album detail, Artist detail, Search, Settings,
Sign in and Now Playing all build for both platforms.

The tvOS player follows the mapping validated against tvOS Apple Music: it
rests with no chrome, the artwork is the focus target, select is play/pause,
left and right are previous and next, and the Play/Pause key works whether or
not anything is on screen.

Not built: playlists, favourites UI, lyrics, offline downloads.

Added on branch `ios-next` (2026-09-23, Xcode 27 / iOS and tvOS 27 SDKs):
- Quick Connect sign-in (`QuickConnect.swift`), verified in the iOS simulator
  against the live server. Debug builds take `-cascade.autoQuickConnect YES`
  (with `-cascade.serverUrl <url>`) to start it on launch, for driving
  simulators without UI automation.
- Lyrics on Now Playing from the server's Cascade plugin (`Lyrics.swift`:
  `parseLRC` ported with the desktop's tests; plugin probe tries
  `CascadeServer/Info`, then the pre-rename `CascadeLyrics/Info`). Line sync
  only, no karaoke word fill yet. Never requests SpicyLyrics (no credit UI).
  iOS toggles artwork/lyrics and a tapped line seeks; tvOS shows lyrics in
  place of the queue.
- Favourite button on iOS Now Playing (not on tvOS yet).
- Playlists tab, read-only: browse, play, shuffle.
None of the new UI has been tapped through by a person yet; the simulator
checks were sign-in and Home only.

Never exercised by a person: every browsing screen. They compile for both
platforms and the queries behind them are covered by live tests, but nobody has
scrolled a thousand songs, run a search, or opened an album on a device yet.
That is the largest untested surface in the project.

Out of scope for v1: EQ, crossfade, offline downloads, video.
