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

Lock screen art is back (2026-09-27). The old trap was Swift 6 isolation: the
MPMediaItemArtwork request handler was written inside a @MainActor method, so
it inherited main-actor isolation and a runtime check, and MediaPlayer calls it
on a background queue. Reproduced in the simulator by calling the handler off
main (SIGTRAP with the old closure, returns fine when built in a nonisolated
function). Rule: any closure handed to MediaPlayer or AVFoundation that they
may call on their own queue must be built outside main-actor isolation. See
"Lock screen art" in PlaybackService.swift. The iOS 26.5 simulator shows no
Now Playing on its lock screen or Control Center, so the art itself still
wants a look on a real phone.

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
Verified by a person on the iPhone 16 (iOS 27, free provisioning, Xcode 27,
2026-09-23): Quick Connect sign-in, lyrics on Now Playing (toggle, sync,
tap-to-seek), the favourite button sticking server-side, and the Playlists
tab. tvOS: builds and reaches the Quick Connect screen; signed-in use not
checked yet.

Browsing screens: first used by a person on the iPhone 16 on 2026-09-23, and
59bcb5e fixed what that found (artist counts, doubled back buttons, paging
Songs and Albums in 200s).

Cross-library copies (`LibraryMerge.swift`, 2026-09-24): the same song,
album or artist in two selected libraries shows once, ported from the
desktop's dedupeById with its tests. `itemsAcrossLibraries` tags each item
with `sourceLibrary` and merges; `loadPaged` re-merges everything loaded so
far, because copies can land on different pages.

tvOS, signed in, first exercised 2026-09-24 in the Apple TV (1080p)
simulator, tvOS 26.5, against a throwaway Jellyfin 10.11.11 with two music
libraries sharing an album: Quick Connect sign-in, every tab, album detail,
playback (confirmed server-side), Now Playing with synced lyrics, Settings.
That run found and fixed: no way to reach Now Playing on tvOS at all (it is
now a tab, and starting playback switches to it; a tab inserted and selected
in one update was never built, so it is always present), "1 tracks", and
merged libraries not in server order. The tab bar is wider than its glass:
Search and Settings sit past the right edge until focus scrolls to them.

Driving tvOS without a person: the CascadetvOSUITests target
(UITests/tvOS/RemoteScript.swift) presses Siri Remote buttons from a
TEST_RUNNER_SCRIPT, screenshots to TEST_RUNNER_OUT_DIR, and can approve
Quick Connect itself. xcodebuild sometimes never exits after the test
passes; wait for "Test Suite 'Selected tests' passed" in its output instead
of its exit.

Out of scope for v1: EQ, crossfade, offline downloads, video.

Driving iOS without a person: the CascadeiOSUITests target
(UITests/iOS/TapScript.swift) taps, long-presses, drags, locks and
screenshots from a TEST_RUNNER_SCRIPT, the phone's counterpart of the tvOS
RemoteScript. Steps are separated by `|`; see the file's header.

Gapless (2026-09-27): PlaybackService plays through an AVQueuePlayer. While a
track plays, the one advanceOnEnd would pick is resolved and enqueued behind
it (syncPreload), and at the end the player moves onto it by itself; the
service only catches up its bookkeeping and reports (handOver). Anything that
changes what plays next must call syncPreload. Measured in the simulator
against a local server, from the end notification to the next item's clock
running: 180 to 445 ms before, -36 to +21 ms after (flac, m4a, mp3 and an
HLS transcode). DEBUG builds log it as HANDOVER.
