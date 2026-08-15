// ── Waterfall (BETA) — same-server synced listening ──────────────────────────
//
// Everyone in a room hears the same track at the same time. Unlike the shelved
// peer-to-peer attempt, NO AUDIO CROSSES THE WIRE: every member streams the
// track from the same Jellyfin server they are already signed in to. The room
// only carries "track X, position Y, playing/paused".
//
// That constraint is the whole design. It means:
//   - no WebRTC, so no ICE negotiation and no NAT traversal to get wrong
//   - no shared Web Audio node, so local volume/mute cannot leak into the room
//   - no driver handoff: the host simply owns playback and everyone follows
//   - rooms are same-server only, and joining a foreign server is refused
//
// Loaded as a second <script> after renderer.js, sharing its global scope
// (`audio`, `queue`, `queueIndex`, `jf`, `jfGet`, `playCurrentTrack`,
// `updateNowPlaying`, `showToast`, `esc`).

// Default relay. Anyone who would rather not route their room through someone
// else's server can point this at their own in Settings - the Worker source
// lives in wip-waterfall/signaling/ and deploys with `npx wrangler deploy`.
const WF_DEFAULT_RELAY = CascadeCore.WF_DEFAULT_RELAY

// Wire format and sync maths come from src/core/waterfall-protocol.ts, so a
// future TV client can join the same rooms without reimplementing any of it.
// Everything left in this file is DOM: the panel, the modal, the transport
// interception.
const {
  WF_HEARTBEAT_MS, WF_DRIFT_MS,
  buildStateMessage, expectedPositionMs, shouldReseek, isForeignServer, roomSocketUrl,
  buildQueueMessage, buildEnqueueMessage, buildEnqueueRejected,
  buildControlMessage, isControlAction,
  isStaleQueue, missingTrackIds,
} = CascadeCore

// Metadata a queue row needs to render and play.
const WF_ITEM_FIELDS = 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag,UserData'

// Read at session start rather than cached, so changing it in Settings takes
// effect on the next room without a restart.
async function wfRelayBase() {
  const stored = (await window.cascade.store.get('waterfallRelay') || '').trim()
  return (stored || WF_DEFAULT_RELAY).replace(/\/+$/, '')
}

let wfWs        = null
let wfIsHost    = false
let wfCode      = null
let wfMemberId  = null
let wfRoster    = []
let wfServerId  = null
let wfHeartbeat = null
let _wfApplying = false   // guard: we are applying host state, don't echo it back

// ── Shared queue ─────────────────────────────────────────────────────────────
// The host owns the queue; guests mirror it and may only propose additions.

let wfQueueRev        = 0      // host: bumped on every queue mutation
let wfLastQueueRev    = -1     // guest: highest rev applied, drops stale broadcasts
let wfAddedBy         = []     // parallel to `queue` - guest display name, or null for the host
let wfGuestAddsAllowed = true      // host: the setting. guest: last value the host broadcast
let wfGuestControlAllowed = false  // ditto. Off by default - a guest pausing or
                                   // skipping interrupts the whole room, which is
                                   // a bigger imposition than appending a track.

let _wfQueueSig = ''          // host: last published queue shape, for change detection

// Which track the guest actually has loaded. Distinct from queue[queueIndex]:
// a queue broadcast can move the index before the audio element has followed,
// and comparing against the queue would then skip the load entirely.
let wfLoadedTrackId = null

// A state message that arrived before the queue it refers to. Replayed as soon
// as the queue lands - see wfApplyQueue.
let _wfPendingState = null

/** Stand-in for a track this member cannot see, so indices stay aligned. */
function wfPlaceholder(id) {
  return { Id: id, Name: 'Unavailable on your account', Artists: [], RunTimeTicks: 0, __wfUnavailable: true }
}

/** Guests mirror the host's queue and must not edit it locally. */
function wfIsFollower() {
  return wfActive() && !wfIsHost
}

/** Whether this client may offer "add to queue" right now. */
function wfGuestAddsPermitted() {
  return wfGuestAddsAllowed !== false
}

/** Whether a guest's transport buttons should drive the room instead of being inert. */
function wfGuestControlPermitted() {
  return wfGuestControlAllowed === true
}

/**
 * Guest -> host transport request. Returns false when the guest is not allowed,
 * so the caller can fall back to explaining why.
 *
 * The guest deliberately does not touch its own audio element: the host applies
 * the action and its `state` broadcast moves everyone together. A guest that
 * acted locally would fork the room until the next heartbeat dragged it back.
 */
function wfRequestControl(action, positionMs) {
  if (!wfActive() || wfIsHost || !wfGuestControlPermitted()) return false
  wfSend(buildControlMessage(action, positionMs))
  return true
}

function wfActive() { return !!wfWs && wfWs.readyState === WebSocket.OPEN }

// The "should local playback be blocked" decision now lives in the shared
// arbiter (renderer.js blocksLocalPlayback -> src/core/ownership.ts), because
// casting can drive playback too and two independent guards would fight.
// waterfall.js just publishes its state via the globals the arbiter reads:
// wfActive(), wfIsHost, _wfApplying.

// ── Signaling ────────────────────────────────────────────────────────────────

async function wfResolveServerId() {
  if (wfServerId) return wfServerId
  const info = await jfGet('/System/Info/Public')
  wfServerId = info?.Id || null
  return wfServerId
}

function wfSend(payload, to) {
  if (!wfActive()) return
  wfWs.send(JSON.stringify({ type: 'relay', to, payload }))
}

async function wfOpenSocket(code, asHost) {
  await wfResolveServerId()
  const base = await wfRelayBase()
  const name = (await window.cascade.store.get('username')) || 'Listener'
  const url  = roomSocketUrl(base, code, name)

  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url)
    let settled = false

    ws.onmessage = ev => {
      let msg
      try { msg = JSON.parse(ev.data) } catch { return }

      if (msg.type === 'join-denied') {
        settled = true
        ws.close()
        reject(new Error(msg.reason === 'room-full' ? 'That room is full.' : 'No room with that code.'))
        return
      }
      if (msg.type === 'joined') {
        settled = true
        wfWs = ws; wfIsHost = asHost; wfCode = code
        wfMemberId = msg.memberId; wfRoster = msg.roster || []
        resolve(ws)
        // A joining guest asks whoever is hosting for the current state
        if (!asHost) wfSend({ k: 'hello', serverId: wfServerId })
        return
      }
      if (msg.type === 'roster') { wfRoster = msg.members || []; wfRenderPanel(); return }
      if (msg.type === 'relay')  { wfOnRelay(msg.from, msg.payload) }
    }

    ws.onerror = () => { if (!settled) { settled = true; reject(new Error('Could not reach the room server.')) } }
    ws.onclose = () => { if (settled) wfTeardown('The room closed.') }
  })
}

function wfOnRelay(from, p) {
  if (!p || typeof p !== 'object') return

  // Same-server guard. Members on a different Jellyfin server cannot possibly
  // stream the host's tracks, so the room refuses rather than half-working.
  if (isForeignServer(p.serverId, wfServerId)) {
    if (wfIsHost) wfSend({ k: 'wrong-server' }, from)
    else wfTeardown('That room is hosted on a different Jellyfin server.')
    return
  }

  // A joining or resyncing guest needs the queue as well as the position.
  if (p.k === 'hello' && wfIsHost) { wfBroadcastQueue(from); wfBroadcastState(from); return }
  if (p.k === 'wrong-server')      { wfTeardown('That room is hosted on a different Jellyfin server.'); return }
  if (p.k === 'enqueue' && wfIsHost) { wfHandleEnqueue(from, p); return }
  if (p.k === 'control' && wfIsHost) { wfHandleControl(p); return }
  if (p.k === 'enqueue-rejected' && !wfIsHost) { showNotice(p.reason || 'The host refused that addition.', 'Waterfall'); return }
  if (p.k === 'queue' && !wfIsHost) { wfApplyQueue(p); return }
  if (p.k === 'state' && !wfIsHost) wfApplyState(p)
}

// ── Host: announce what is playing ───────────────────────────────────────────

function wfBroadcastState(to) {
  if (!wfActive() || !wfIsHost) return
  const item = queue[queueIndex]
  if (!item) return
  wfSend(buildStateMessage({
    serverId:   wfServerId,
    trackId:    item.Id,
    positionMs: Math.round(audio.currentTime * 1000),
    paused:     audio.paused,
    index:      queueIndex,
  }), to)
}

// ── Host: the shared queue ───────────────────────────────────────────────────

function wfBroadcastQueue(to) {
  if (!wfActive() || !wfIsHost) return
  wfSend(buildQueueMessage({
    serverId:         wfServerId,
    rev:              wfQueueRev,
    trackIds:         queue.map(t => t.Id),
    addedBy:          wfAddedBy,
    index:               queueIndex,
    guestAddsAllowed:    wfGuestAddsAllowed,
    guestControlAllowed: wfGuestControlAllowed,
  }), to)
}

/** Bump the revision and publish. Call after mutating the host's queue. */
function wfOnQueueChanged() {
  if (!wfActive() || !wfIsHost) return
  // Keep attribution aligned - entries the host added carry no name.
  while (wfAddedBy.length < queue.length) wfAddedBy.push(null)
  wfAddedBy.length = queue.length
  wfQueueRev++
  _wfQueueSig = wfQueueSignature()
  wfBroadcastQueue()
}

function wfQueueSignature() {
  return queue.map(t => t?.Id).join(',')
}

// renderer.js mutates `queue` in a dozen places - playItems, the context menu,
// queue-row drag and remove, auto-mix, stop. Rather than teaching every one of
// them about Waterfall (and having the next one forget), the host diffs the
// queue on the heartbeat it already runs. Self-healing, and a new mutation site
// is picked up for free. Worst case a queue edit takes one heartbeat to reach
// guests, which is fine for a track list; guest additions still publish
// immediately from wfHandleEnqueue.
function wfSyncQueueIfChanged() {
  if (!wfActive() || !wfIsHost) return
  if (wfQueueSignature() === _wfQueueSig) return
  wfOnQueueChanged()
}

// A guest asked to drive the transport. Applied through the host's own buttons
// rather than by poking the audio element, so every side effect the real
// controls have - crossfade cancellation, playback reporting, queue advance -
// happens exactly as if the host had clicked. The resulting audio events then
// broadcast the new state to the room on their own.
function wfHandleControl(p) {
  if (!wfGuestControlPermitted()) return
  if (!isControlAction(p.action)) return   // arrives from another client; validate

  switch (p.action) {
    case 'playpause': document.getElementById('btn-play')?.click(); break
    case 'next':      document.getElementById('btn-next')?.click(); break
    case 'prev':      document.getElementById('btn-prev')?.click(); break
    case 'seek': {
      const ms = Number(p.positionMs)
      if (!Number.isFinite(ms) || ms < 0) return
      if (audio.duration && ms / 1000 > audio.duration) return
      audio.currentTime = ms / 1000
      break
    }
  }
  // The audio 'play'/'pause'/'seeked' listeners already rebroadcast state, but
  // a paused-and-unchanged element fires nothing - so publish explicitly.
  wfBroadcastState()
}

// A guest asked to append tracks. The host is the authority: it validates with
// its OWN credentials, because a guest can see tracks the host cannot, and the
// room's whole premise is that everyone streams the same track from the same
// server.
async function wfHandleEnqueue(from, p) {
  if (!wfGuestAddsAllowed) {
    wfSend(buildEnqueueRejected('The host has turned off guest additions.'), from)
    return
  }

  const ids = (p.trackIds || []).filter(Boolean).slice(0, 100)
  if (!ids.length) return

  let items = []
  try {
    const res = await jfGet(`/Users/${jf.userId}/Items`, { Ids: ids.join(','), Fields: WF_ITEM_FIELDS })
    items = res.Items || []
  } catch {}

  if (!items.length) {
    wfSend(buildEnqueueRejected('The host cannot access that track on this server.'), from)
    return
  }

  const name = wfRoster.find(m => m.id === from)?.name || 'A guest'
  const byId = new Map(items.map(i => [i.Id, i]))
  // Preserve the order the guest asked for.
  for (const id of ids) {
    const item = byId.get(id)
    if (!item) continue
    queue.push(item)
    wfAddedBy.push(name)
  }

  if (items.length < ids.length) {
    wfSend(buildEnqueueRejected('Some of those tracks are not available to the host.'), from)
  }

  wfQueueRev++
  wfBroadcastQueue()
  renderQueuePanel()
  showToast(`${name} added ${items.length} track${items.length === 1 ? '' : 's'}`)
}

// Hooking the audio element rather than patching every transport handler keeps
// this file from having to know how playback is triggered - next/prev, a queue
// row, a media key and the mini player all surface here as the same events.
;['play', 'pause', 'seeked', 'loadedmetadata'].forEach(ev =>
  audio.addEventListener(ev, () => { if (wfIsHost) wfBroadcastState() })
)

// ── Guest: follow the host ───────────────────────────────────────────────────

// Host-driven updates run strictly one at a time.
//
// Both handlers are async - they fetch metadata and resolve streams - and a
// single host action fires a burst of broadcasts, because the host rebroadcasts
// on 'play', 'pause', 'seeked' AND 'loadedmetadata'. Re-entrant handlers then
// each set audio.src, and every new assignment aborts the previous play(),
// leaving the guest stuck at 0:00. They also interleave writes to `queue`, which
// one of them is rebuilding while the other reads it.
//
// One chain for both, so neither can overlap the other or itself.
let _wfChain = Promise.resolve()
function wfSerial(fn) {
  _wfChain = _wfChain.catch(() => {}).then(fn)
  return _wfChain
}

const wfApplyQueue = (m) => wfSerial(() => wfApplyQueueNow(m))
const wfApplyState = (s) => wfSerial(() => wfApplyStateNow(s))

// Rebuild the local queue from the host's broadcast.
async function wfApplyQueueNow(m) {
  if (isStaleQueue(m.rev, wfLastQueueRev)) return
  wfLastQueueRev = m.rev
  wfGuestAddsAllowed    = m.guestAddsAllowed !== false
  wfGuestControlAllowed = m.guestControlAllowed === true

  const known = new Map(queue.filter(t => t && !t.__wfUnavailable).map(t => [t.Id, t]))
  const missing = missingTrackIds(m.trackIds || [], known.keys())

  if (missing.length) {
    // One batched lookup rather than one per track.
    try {
      const res = await jfGet(`/Users/${jf.userId}/Items`, { Ids: missing.join(','), Fields: WF_ITEM_FIELDS })
      for (const it of res.Items || []) known.set(it.Id, it)
    } catch { /* leave them as placeholders below */ }
  }

  // Placeholders rather than omissions: per-user library permissions apply
  // independently to every member, and dropping an entry would shift this
  // member's queueIndex out of alignment with the host for good.
  let unavailable = 0
  queue = (m.trackIds || []).map(id => {
    const item = known.get(id)
    if (item) return item
    unavailable++
    return wfPlaceholder(id)
  })
  wfAddedBy = (m.addedBy || []).slice(0, queue.length)
  while (wfAddedBy.length < queue.length) wfAddedBy.push(null)

  if (Number.isInteger(m.index)) queueIndex = Math.max(-1, Math.min(m.index, queue.length - 1))
  if (unavailable) wfWarnOnce('Some tracks in this room are not available to your account')

  renderQueuePanel()

  // A state message that raced ahead of this queue now has something to work
  // with. Without this the guest sits silent until the next heartbeat, which is
  // the whole reason joining mid-song felt stuck.
  if (_wfPendingState) {
    const pending = _wfPendingState
    _wfPendingState = null
    // The inner function, not the serialised wrapper - we are already inside the
    // chain, and re-entering it here would deadlock waiting on ourselves.
    await wfApplyStateNow(pending)
  }
}

// Ask the host to resend state and queue. Rate-limited: the host answers every
// hello, so an unthrottled request on each heartbeat would ping-pong.
let _wfLastResync = 0
function wfRequestResync() {
  const now = Date.now()
  if (now - _wfLastResync < WF_HEARTBEAT_MS) return
  _wfLastResync = now
  wfSend({ k: 'hello', serverId: wfServerId })
}

// Guest -> host. Deliberately does not touch the local queue: the host is the
// authority, and a local append would be wiped by the next broadcast.
function wfRequestEnqueue(items) {
  const trackIds = (items || []).map(i => i?.Id).filter(Boolean)
  if (!trackIds.length || !wfActive()) return false
  wfSend(buildEnqueueMessage({ serverId: wfServerId, trackIds }))
  return true
}

async function wfApplyStateNow(s) {
  if (!s.trackId) return
  const expected = expectedPositionMs(s)
  let justLoaded = false

  // Follow the host's index when it sends one; fall back to locating the track,
  // which is only ambiguous if the same track sits in the queue twice.
  if (Number.isInteger(s.index) && queue[s.index]?.Id === s.trackId) {
    queueIndex = s.index
  } else {
    const found = queue.findIndex(t => t?.Id === s.trackId)
    if (found >= 0) queueIndex = found
  }

  if (wfLoadedTrackId !== s.trackId) {
    const current = queue[queueIndex]

    // The queue broadcast is what puts tracks here. On join, the host sends the
    // queue and then the state, but applying the queue involves a metadata fetch
    // - so the state routinely arrives while that is still in flight and finds
    // an empty queue. Hold the state and replay it the moment the queue lands,
    // instead of waiting out the resync throttle.
    if (current?.Id !== s.trackId) {
      _wfPendingState = s
      wfRequestResync()
      return
    }

    // The host is demonstrably playing this track, so it exists on the server.
    // A placeholder therefore means Jellyfin is hiding it from this account,
    // not that it's missing. Each member streams with their own credentials, so
    // per-user library permissions apply independently to everyone in the room.
    if (current.__wfUnavailable) {
      wfWarnOnce('You do not have access to this track on the server')
      return
    }

    justLoaded = true

    // Seek only once the element has metadata.
    //
    // playCurrentTrack sets audio.src and immediately calls play(). Setting
    // currentTime while the element is still loading ABORTS that pending play(),
    // and because play() flips `paused` to false synchronously, the element then
    // looks like it is running while no audio comes out. Nothing below re-issued
    // play() because `audio.paused` was already false - which is exactly why a
    // manual pause/resume was needed to get sound.
    const startAt = Math.max(0, expected / 1000)
    // Guarded by a local flag, not wfLoadedTrackId: that is only assigned after
    // the await below, so this listener - which fires *during* the load - would
    // always see a stale value and skip the seek entirely.
    let seekCancelled = false
    const seekOnMetadata = () => { if (!seekCancelled) audio.currentTime = startAt }
    audio.addEventListener('loadedmetadata', seekOnMetadata, { once: true })

    // playCurrentTrack can bail without loading anything - it re-checks the
    // queue after its own PlaybackInfo round-trip, and a queue broadcast landing
    // in that window makes it return. Claiming the track as loaded before
    // knowing that would leave wfLoadedTrackId pointing at a track that never
    // started, and every later heartbeat would skip the load: silence until a
    // manual pause/resume. Only record it once audio.src has actually moved.
    const srcBefore = audio.src
    _wfApplying = true
    await playCurrentTrack()
    _wfApplying = false

    if (audio.src === srcBefore) {
      seekCancelled = true
      audio.removeEventListener('loadedmetadata', seekOnMetadata)
      wfLoadedTrackId = null   // let the next heartbeat retry
      return
    }
    wfLoadedTrackId = s.trackId
  }

  // Drift correction, with two guards:
  //
  // - readyState 0 means no metadata yet, and seeking then is simply ignored -
  //   which is how a guest joining mid-song ended up playing from 0:00. The
  //   loadedmetadata handler above owns that first positioning; this stays as
  //   the backstop in case it missed.
  // - a seek already in flight: measured against a remote Jellyfin a mid-file
  //   seek takes 1.3-2.2s to return its first bytes, longer than WF_DRIFT_MS
  //   (1.5s). Without this the next heartbeat sees the pre-seek position, fires
  //   another seek, and the guest stutters through endless re-buffers instead of
  //   settling.
  if (audio.readyState > 0 && !audio.seeking && shouldReseek(audio.currentTime * 1000, expected)) {
    audio.currentTime = expected / 1000
  }

  _wfApplying = true
  if (s.paused && !audio.paused) {
    audio.pause()
  } else if (!s.paused && (justLoaded || audio.paused)) {
    // `justLoaded` rather than trusting audio.paused: see above - a play() that
    // gets aborted still leaves paused === false, so that check alone would let
    // a silent element sit there forever. Calling play() twice is harmless.
    await audio.play().catch(() => {})
  }
  _wfApplying = false
}

// A follower's transport buttons do nothing, which is baffling with no feedback.
// But this fires on every click, so a modal each time would be worse than the
// silence. Explain it once per session, then stay quiet.
let _wfToldAboutHost = false
function wfNotifyHostControls() {
  if (_wfToldAboutHost) return
  _wfToldAboutHost = true
  showNotice('The host controls playback in this room. Your play, skip and queue controls stay inactive until you leave.', 'Waterfall')
}

// The host re-announces every few seconds, so without the dedupe a follower who
// can't reach a track would get this modal reopened at them every 4 seconds.
// Keyed by track so the next song can still report its own problem.
let _wfLastWarn = null
function wfWarnOnce(msg) {
  const key = `${msg}:${queue[queueIndex]?.Id || ''}`
  if (key === _wfLastWarn) return
  _wfLastWarn = key
  showNotice(msg, 'Waterfall')
}

// A follower can pass the metadata lookup and still be refused the stream, if
// Jellyfin shows them the item but not the file. Nothing in the app listens for
// audio errors, so that failed silently: track showing, no sound, no reason.
audio.addEventListener('error', () => {
  if (!wfActive() || wfIsHost || !audio.src) return
  wfWarnOnce('Could not play this track - your account may not have access to it')
})

// A guest's transport buttons never drive its own element - that would fork the
// room. Capture phase so this runs before renderer.js's handler on the same
// element, then either forward the intent to the host or explain the silence.
const WF_TRANSPORT_ACTIONS = {
  'btn-play': 'playpause', 'ov-play': 'playpause',
  'btn-prev': 'prev',      'ov-prev': 'prev',
  'btn-next': 'next',      'ov-next': 'next',
}

Object.entries(WF_TRANSPORT_ACTIONS).forEach(([id, action]) => {
  document.getElementById(id)?.addEventListener('click', e => {
    if (!wfActive() || wfIsHost) return
    e.stopImmediatePropagation()
    e.preventDefault()
    if (!wfRequestControl(action)) wfNotifyHostControls()
  }, true)
})

// Seek bars need the click position, so they are intercepted separately.
// Without this a guest could scrub its own element and silently drift until the
// next heartbeat yanked it back.
//
// Both events are captured: the statusbar bar seeks on `click`, but the overlay
// bar seeks on `mousedown` (it supports dragging), which fires first. Acting on
// mousedown and swallowing the click covers both without seeking twice.
;['prog-bar', 'ov-prog-bar'].forEach(id => {
  const el = document.getElementById(id)
  if (!el) return

  el.addEventListener('mousedown', e => {
    if (!wfActive() || wfIsHost) return
    e.stopImmediatePropagation()
    e.preventDefault()
    if (!wfGuestControlPermitted() || !audio.duration) { wfNotifyHostControls(); return }
    const rect = el.getBoundingClientRect()
    const ratio = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width))
    wfRequestControl('seek', ratio * audio.duration * 1000)
  }, true)

  el.addEventListener('click', e => {
    if (!wfActive() || wfIsHost) return
    e.stopImmediatePropagation()
    e.preventDefault()
  }, true)
})

// ── Session lifecycle ────────────────────────────────────────────────────────

async function wfCreate() {
  // Re-read in case Settings changed since load.
  await wfLoadPermissions()

  const res = await fetch(`${await wfRelayBase()}/create`, { method: 'POST' })
  if (!res.ok) throw new Error('Could not create a room.')
  const { code } = await res.json()
  await wfOpenSocket(code, true)
  wfHeartbeat = setInterval(() => { wfSyncQueueIfChanged(); wfBroadcastState() }, WF_HEARTBEAT_MS)
  wfOnQueueChanged()
  wfBroadcastState()
  return code
}

async function wfJoin(code) {
  await wfOpenSocket(code.trim().toUpperCase(), false)
}

// unexpected: the room ended without the user asking, so say so in a modal they
// have to dismiss. Leaving on purpose needs no announcement.
function wfTeardown(reason, unexpected = true) {
  if (wfHeartbeat) { clearInterval(wfHeartbeat); wfHeartbeat = null }
  if (wfWs) { try { wfWs.onclose = null; wfWs.close() } catch {} }
  wfWs = null; wfIsHost = false; wfCode = null; wfMemberId = null; wfRoster = []
  _wfLastWarn = null
  // Shared-queue state is per room; a stale rev would make the next room's
  // first broadcast look older than what we already applied and be dropped.
  wfQueueRev = 0; wfLastQueueRev = -1; wfAddedBy = []; _wfQueueSig = ''
  wfLoadedTrackId = null; _wfLastResync = 0; _wfPendingState = null
  // A guest's mirrored permissions reset; the host's own are reloaded from
  // Settings when it next creates a room.
  wfGuestAddsAllowed = true
  wfGuestControlAllowed = false
  wfRenderPanel()
  if (!reason) return
  if (unexpected) showNotice(reason, 'Waterfall')
  else showToast(reason)
}

// ── Panel ────────────────────────────────────────────────────────────────────

function wfRenderPanel() {
  const idle = document.getElementById('wf-idle')
  const live = document.getElementById('wf-live')
  if (!idle || !live) return

  const on = wfActive()
  idle.style.display = on ? 'none' : ''
  live.style.display = on ? '' : 'none'
  document.getElementById('btn-waterfall-open')?.classList.toggle('active', on)
  if (!on) return

  document.getElementById('wf-code').textContent = wfCode || ''
  document.getElementById('wf-role').textContent = wfIsHost
    ? 'You are hosting. Everyone follows your playback.'
    : 'Following the host.'

  document.getElementById('wf-members').innerHTML = wfRoster.map(m =>
    `<div class="wf-member">${esc(m.name)}${m.id === wfMemberId ? ' <span style="color:var(--text3)">(you)</span>' : ''}</div>`
  ).join('')
}

document.getElementById('btn-waterfall-open')?.addEventListener('click', () => {
  if (!jf?.url) { showNotice('Connect to your Jellyfin server before starting or joining a room.', 'Waterfall'); return }
  wfRenderPanel()
  document.getElementById('wf-modal').classList.remove('hidden')
})
document.getElementById('wf-close')?.addEventListener('click', () =>
  document.getElementById('wf-modal').classList.add('hidden'))

document.getElementById('wf-create')?.addEventListener('click', async e => {
  e.target.disabled = true
  try { await wfCreate(); wfRenderPanel() }
  catch (err) { showNotice(err.message, 'Could not start room') }
  finally { e.target.disabled = false }
})

document.getElementById('wf-join')?.addEventListener('click', async e => {
  const code = document.getElementById('wf-code-input').value
  if (code.trim().length !== 6) { showNotice('Room codes are 6 characters long.', 'Waterfall'); return }
  e.target.disabled = true
  try { await wfJoin(code); wfRenderPanel() }
  catch (err) { showNotice(err.message, 'Could not join room') }
  finally { e.target.disabled = false }
})

document.getElementById('wf-leave')?.addEventListener('click', () => wfTeardown('Left the room', false))

// Host permissions live in Settings, not the room panel - they are a standing
// preference, not something you set per room. Republished immediately so guests
// gain or lose the ability mid-room rather than at the next room.
async function wfLoadPermissions() {
  wfGuestAddsAllowed    = (await window.cascade.store.get('waterfallAllowGuestQueue')) !== false
  wfGuestControlAllowed = (await window.cascade.store.get('waterfallAllowGuestControl')) === true

  const adds = document.getElementById('s-wf-guest-adds')
  const ctrl = document.getElementById('s-wf-guest-control')
  if (adds) adds.checked = wfGuestAddsAllowed
  if (ctrl) ctrl.checked = wfGuestControlAllowed
}

document.getElementById('s-wf-guest-adds')?.addEventListener('change', async (e) => {
  wfGuestAddsAllowed = e.target.checked
  await window.cascade.store.set('waterfallAllowGuestQueue', wfGuestAddsAllowed)
  wfOnQueueChanged()
})

document.getElementById('s-wf-guest-control')?.addEventListener('change', async (e) => {
  wfGuestControlAllowed = e.target.checked
  await window.cascade.store.set('waterfallAllowGuestControl', wfGuestControlAllowed)
  wfOnQueueChanged()
})

wfLoadPermissions()

document.getElementById('wf-copy')?.addEventListener('click', () => {
  if (wfCode) { window.cascade.clipboard.write(wfCode); showToast('Room code copied') }
})

window.addEventListener('beforeunload', () => { if (wfWs) try { wfWs.close() } catch {} })
