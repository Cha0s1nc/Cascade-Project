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
const WF_DEFAULT_RELAY = 'https://cascade-waterfall-signaling.cha0s-netw0rks.workers.dev'
const WF_HEARTBEAT_MS  = 4000   // host re-announces position this often
const WF_DRIFT_MS      = 1500   // guest re-seeks once it is this far out

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

function wfActive() { return !!wfWs && wfWs.readyState === WebSocket.OPEN }

// renderer.js asks this before starting local playback. A guest's transport is
// the host's to drive; without this, a double-clicked row silently hijacks the
// shared session until the next heartbeat drags it back.
function wfBlocksLocalPlayback() {
  return wfActive() && !wfIsHost && !_wfApplying
}

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
  const url  = `${base.replace(/^http/, 'ws')}/room/${code}?name=${encodeURIComponent(name)}`

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
  if (p.serverId && wfServerId && p.serverId !== wfServerId) {
    if (wfIsHost) wfSend({ k: 'wrong-server' }, from)
    else wfTeardown('That room is hosted on a different Jellyfin server.')
    return
  }

  if (p.k === 'hello' && wfIsHost) { wfBroadcastState(from); return }
  if (p.k === 'wrong-server')      { wfTeardown('That room is hosted on a different Jellyfin server.'); return }
  if (p.k === 'state' && !wfIsHost) wfApplyState(p)
}

// ── Host: announce what is playing ───────────────────────────────────────────

function wfBroadcastState(to) {
  if (!wfActive() || !wfIsHost) return
  const item = queue[queueIndex]
  if (!item) return
  wfSend({
    k: 'state',
    serverId:   wfServerId,
    trackId:    item.Id,
    positionMs: Math.round(audio.currentTime * 1000),
    paused:     audio.paused,
    sentAt:     Date.now(),
  }, to)
}

// Hooking the audio element rather than patching every transport handler keeps
// this file from having to know how playback is triggered - next/prev, a queue
// row, a media key and the mini player all surface here as the same events.
;['play', 'pause', 'seeked', 'loadedmetadata'].forEach(ev =>
  audio.addEventListener(ev, () => { if (wfIsHost) wfBroadcastState() })
)

// ── Guest: follow the host ───────────────────────────────────────────────────

async function wfApplyState(s) {
  if (!s.trackId) return
  const latency  = Math.max(0, Date.now() - (s.sentAt || Date.now()))
  const expected = (s.positionMs || 0) + (s.paused ? 0 : latency)

  if (queue[queueIndex]?.Id !== s.trackId) {
    let item
    try {
      const res = await jfGet(`/Users/${jf.userId}/Items`, {
        Ids: s.trackId,
        Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag',
      })
      item = res.Items?.[0]
    } catch {}
    if (!item) { showToast('That track is not on your server'); return }

    _wfApplying = true
    queue = [item]; queueIndex = 0
    await playCurrentTrack()
    _wfApplying = false
  }

  // ponytail: one-way latency is approximated as the full round trip and never
  // re-estimated. Good to a few hundred ms, which is fine for people in
  // different rooms. Swap in a proper clock-offset handshake if it ever matters.
  if (Math.abs(audio.currentTime * 1000 - expected) > WF_DRIFT_MS) {
    audio.currentTime = expected / 1000
  }
  _wfApplying = true
  if (s.paused && !audio.paused) audio.pause()
  if (!s.paused && audio.paused) await audio.play().catch(() => {})
  _wfApplying = false
}

// Guests' own transport buttons are inert while following. Capture phase so
// this runs before renderer.js's own click handler on the same element.
;['btn-play', 'btn-prev', 'btn-next', 'ov-play', 'ov-prev', 'ov-next'].forEach(id => {
  document.getElementById(id)?.addEventListener('click', e => {
    if (!wfActive() || wfIsHost) return
    e.stopImmediatePropagation()
    e.preventDefault()
    showToast('The host controls playback in this room')
  }, true)
})

// ── Session lifecycle ────────────────────────────────────────────────────────

async function wfCreate() {
  const res = await fetch(`${await wfRelayBase()}/create`, { method: 'POST' })
  if (!res.ok) throw new Error('Could not create a room.')
  const { code } = await res.json()
  await wfOpenSocket(code, true)
  wfHeartbeat = setInterval(() => wfBroadcastState(), WF_HEARTBEAT_MS)
  wfBroadcastState()
  return code
}

async function wfJoin(code) {
  await wfOpenSocket(code.trim().toUpperCase(), false)
}

function wfTeardown(reason) {
  if (wfHeartbeat) { clearInterval(wfHeartbeat); wfHeartbeat = null }
  if (wfWs) { try { wfWs.onclose = null; wfWs.close() } catch {} }
  wfWs = null; wfIsHost = false; wfCode = null; wfMemberId = null; wfRoster = []
  wfRenderPanel()
  if (reason) showToast(reason)
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
  if (!jf?.url) { showToast('Connect to your server first'); return }
  wfRenderPanel()
  document.getElementById('wf-modal').classList.remove('hidden')
})
document.getElementById('wf-close')?.addEventListener('click', () =>
  document.getElementById('wf-modal').classList.add('hidden'))

document.getElementById('wf-create')?.addEventListener('click', async e => {
  e.target.disabled = true
  try { await wfCreate(); wfRenderPanel() }
  catch (err) { showToast(err.message) }
  finally { e.target.disabled = false }
})

document.getElementById('wf-join')?.addEventListener('click', async e => {
  const code = document.getElementById('wf-code-input').value
  if (code.trim().length !== 6) { showToast('Room codes are 6 characters'); return }
  e.target.disabled = true
  try { await wfJoin(code); wfRenderPanel() }
  catch (err) { showToast(err.message) }
  finally { e.target.disabled = false }
})

document.getElementById('wf-leave')?.addEventListener('click', () => wfTeardown('Left the room'))

document.getElementById('wf-copy')?.addEventListener('click', () => {
  if (wfCode) { window.cascade.clipboard.write(wfCode); showToast('Room code copied') }
})

window.addEventListener('beforeunload', () => { if (wfWs) try { wfWs.close() } catch {} })
