# Waterfall (shelved WIP) — synced listening feature

Status: **pulled from the shipping app.** Kept here in case it's worth picking
back up later. Not wired into Cascade right now — the app runs exactly as it
did before this existed.

## What it was

A Spotify-Jam-style "listen together" feature: a host and up to 9 guests hear
the same track together in real time. Only one participant is ever an audio
source at a time (whoever's track is currently playing — the "driver"),
streaming from their own Jellyfin server exactly like solo playback and
sending the decoded audio to everyone else over WebRTC. Everyone else just
listens. When the shared queue advances to a different participant's track,
that participant becomes the new driver and the old one tears down.

Signaling (room creation/join, roster, WebRTC offer/answer/ICE relay) went
through a small Cloudflare Worker + Durable Object, since it only ever
carries small JSON messages, never audio.

## Why it got pulled

Not because the architecture was wrong — because hand-rolled WebRTC is
inherently finicky, and every real test surfaced a new class of bug: ICE
candidates arriving before `setRemoteDescription` resolved, the driver's
local volume/mute leaking into the broadcast stream because both paths
tapped the same audio node, two different queue data sources showing
different things during a session, a route/deep-link protocol handler
touching the app's launch behavior. Each one was fixable, and got fixed, but
the pattern was "another one surfaces every session," which is a real
ongoing maintenance cost for a solo passion project, not a sign the approach
was broken.

## Files here

- `sync.js` — the entire client implementation. Session lifecycle, control
  protocol, WebRTC star topology, queue panel integration, room UI.
- `signaling/` — the Cloudflare Worker + Durable Object relay (`wrangler`
  project, deploy with `npm install && npx wrangler deploy` from inside this
  folder).

**Heads up:** the Worker was left deployed and live at
`https://cascade-waterfall-signaling.cha0s-netw0rks.workers.dev` as of when
this was shelved. It's a Durable Object on Cloudflare's free tier — costs
nothing sitting idle — but it's still a public endpoint on your account. Run
`npx wrangler delete` from `signaling/` if you'd rather it not exist at all.

`sync.js` is not runnable standalone — it's a second `<script>` tag meant to
load after `renderer.js` in a page that already has `audio`, `queue`,
`queueIndex`, `jf`, `streamUrl`, `playCurrentTrack`, `updateNowPlaying`,
`reportPlaybackStart`/`Stopped`, `showToast`, `esc`, `_audioCtx`, `_mediaSrc`
in scope (no bundler in this project — everything's shared global scope).

## Hooks that existed in the main app (reference for re-integrating)

If picking this back up, these are exactly the touch points that need to be
re-applied — everything else in the app is back to its pre-Waterfall state:

- **`index.html`**: a `<script src="sync.js">` tag after `renderer.js`; a
  transport-bar button (`#btn-waterfall-open`, a droplet icon) next to the
  lyrics button; a modal (`#wf-modal` → `#waterfall-panel`) reusing the
  existing `.modal-overlay`/`.modal-card` pattern; a few small CSS rules
  (`.wf-join-row`, `.wf-room-code`, `.wf-members`, `.wf-member`).
- **`renderer.js`**, all small, isolated touches:
  - `initBeatDetection()`: promote the local `src` (from
    `createMediaElementSource`) to a module-level `_mediaSrc` so `sync.js`
    can branch a second output off the same node — `createMediaElementSource`
    can only be called once per `<audio>` element, ever.
  - Local volume/mute needs its own `GainNode` (`_localGain`), separate from
    `audio.volume`/`.muted`, because once an element is routed through Web
    Audio, `.volume`/`.muted` get baked into what `_mediaSrc` captures —
    which is also what gets broadcast. Route every volume/mute control
    through one `applyVolume()` function rather than writing
    `audio.volume`/`.muted` directly from multiple places, and centralize
    state in plain `volume`/`muted` variables. (An event-based
    detect-and-undo approach was tried first and was actively broken —
    `volumechange` fires asynchronously, so it can't reliably tell "my own
    reset" apart from a real change. Don't repeat that.)
  - `playCurrentTrack()` and `playItems()`: both need an early return/redirect
    into the Waterfall queue while a session is active — otherwise solo
    playback actions silently hijack (or silently no-op against) the shared
    audio element.
  - `audio`'s `ended` listener: needs a one-line delegate to the session's
    own end-of-track handling before the solo-queue auto-advance logic runs.
  - Play/pause, prev/next buttons: need to broadcast to the room and route
    through the session queue instead of the solo one while active.
  - The right-click "Add to Queue" action, and the queue panel in the Now
    Playing overlay (`renderQueuePanel`/`_drawQueueRows`): both need to read
    from whichever queue is authoritative (session vs. solo) — this was a
    real bug last time (toast said "no more tracks" while the panel showed 8,
    because the panel was never made session-aware and just kept rendering
    stale solo-queue data).
  - `fmtTime()`: needs an `isFinite` guard, not just `isNaN` — a live
    WebRTC-streamed `<audio>` reports `duration = Infinity`, which produced a
    literal "Infinity:NaN" in the UI.
- **`main.js`**: `cascade://join/<code>` deep link handling —
  `app.setAsDefaultProtocolClient`, `app.requestSingleInstanceLock()` +
  `second-instance` (Windows/Linux) and `open-url` (macOS) events, forwarding
  the code to the renderer via a `waterfall-join` IPC event. This was the
  only reason `main.js` needed any changes at all.
- **`preload.js`**: one bridged event, `onWaterfallJoin`.
- **`package.json`**: `sync.js` in the packaged build's `files` list, and a
  `protocols` entry (`schemes: ["cascade"]`) so installers register the URL
  scheme.

## What was actually working when this got shelved

Confirmed via real cross-machine testing (not just same-process): room
create/join, roster sync, WebRTC offer/answer/ICE (after the buffering fix),
driver handoff on track change, local volume/mute isolation from the
broadcast stream, queue panel correctness. The last round of testing didn't
turn up a new bug — it turned up a decision that the bug-fixing cadence
itself wasn't worth it right now, which is a different kind of signal than
"it doesn't work."
