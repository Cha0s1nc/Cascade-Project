// ── Waterfall: synced listening ────────────────────────────────────────────
// Star topology: only the current track's owner ("driver") streams from
// their own Jellyfin server (exactly like solo playback) and sends the
// decoded audio to everyone else over WebRTC. Listeners never touch
// streamUrl()/jf for a track they don't own.
//
// Loaded as a second <script> tag after renderer.js (no bundler in this
// project), so it shares renderer.js's top-level scope directly — audio,
// queue, queueIndex, jf, streamUrl, playCurrentTrack, updateNowPlaying,
// reportPlaybackStart/Stopped, showToast, esc, _audioCtx, _mediaSrc are
// all already in scope here.
//
// Naming note: this deliberately avoids the bare identifier `waterfall` —
// renderer.js already uses that word for the unrelated lyrics-provider
// fallback chain (fetchLyricsWaterfall). Session state here is `wfSession`.

const WATERFALL_SIGNAL_URL = 'https://cascade-waterfall-signaling.cha0s-netw0rks.workers.dev'
const WATERFALL_STUN = [{ urls: 'stun:stun.l.google.com:19302' }]

let wfSession = null
// {
//   ws, code, myId, roster: [{id,name}],
//   queue: [], index: -1,
//   pcs: Map<memberId, RTCPeerConnection>,  // while driving: one per listener
//   listenerPc: RTCPeerConnection|null,     // while listening: one, to current driver
// }

let _wfStreamDest = null

function wfIsActive() { return !!wfSession }

function wfIsDriver() {
  if (!wfSession || wfSession.index < 0) return false
  return wfSession.queue[wfSession.index]?.owner === wfSession.myId
}

function wfCurrentDriverId() {
  return wfSession?.queue[wfSession.index]?.owner ?? null
}

async function wfDisplayName() {
  return (await window.cascade.store.get('username')) || 'Listener'
}

// ── Outgoing audio tap ───────────────────────────────────────────────────────
// Branches a second output off the SAME MediaElementAudioSourceNode used for
// beat detection — createMediaElementSource() may only be called once per
// <audio> element ever, so this reuses _mediaSrc rather than creating a new one.
function wfOutgoingStream() {
  initBeatDetection() // no-op if already set up; guarantees _audioCtx/_mediaSrc exist
  if (!_wfStreamDest) {
    _wfStreamDest = _audioCtx.createMediaStreamDestination()
    _mediaSrc.connect(_wfStreamDest)
  }
  return _wfStreamDest.stream
}

// ── Session lifecycle ───────────────────────────────────────────────────────

async function wfCreate() {
  try {
    const res = await fetch(`${WATERFALL_SIGNAL_URL}/create`, { method: 'POST' })
    const { code, error } = await res.json()
    if (error) { showToast('Could not create a Waterfall room'); return }
    await wfJoin(code)
  } catch { showToast('Could not reach the Waterfall relay') }
}

async function wfJoin(code) {
  const name = await wfDisplayName()
  const base = WATERFALL_SIGNAL_URL.replace(/^http/, 'ws')
  const ws = new WebSocket(`${base}/room/${code}?name=${encodeURIComponent(name)}`)

  ws.onopen = () => {
    wfSession = { ws, code, myId: null, roster: [], queue: [], index: -1, pcs: new Map(), listenerPc: null }
  }
  ws.onmessage = (e) => wfHandleMessage(JSON.parse(e.data))
  ws.onclose = () => wfTeardown()
}

function wfLeave() {
  if (!wfSession) return
  wfSession.ws.close()
  wfTeardown()
}

function wfTeardown() {
  if (!wfSession) return
  for (const pc of wfSession.pcs.values()) pc.close()
  wfSession.listenerPc?.close()
  wfSession = null
  wfRenderPanel()
}

function wfHandleMessage(msg) {
  switch (msg.type) {
    case 'joined':
      wfSession.myId = msg.memberId
      wfSession.roster = msg.roster
      wfRenderPanel()
      if (msg.roster.length > 1) {
        wfSend(null, { kind: 'request-sync' })
      } else if (queue[queueIndex]) {
        // I'm the first one here — whatever's already playing solo becomes the shared track
        wfQueueAdd(queue[queueIndex])
      }
      break

    case 'join-denied':
      showToast(msg.reason === 'room-full' ? 'That room is full (10/10)' : 'Room not found')
      wfTeardown()
      break

    case 'roster': {
      if (!wfSession) break
      const oldIds = new Set(wfSession.roster.map(m => m.id))
      const newIds = new Set(msg.members.map(m => m.id))
      const joined = msg.members.filter(m => m.id !== wfSession.myId && !oldIds.has(m.id))
      const left = [...wfSession.pcs.keys()].filter(id => !newIds.has(id))

      wfSession.roster = msg.members
      for (const id of left) { wfSession.pcs.get(id)?.close(); wfSession.pcs.delete(id) }

      // A driver's offers only reach whoever was already in the room at the
      // time playback started — anyone joining afterward needs their own offer.
      if (wfIsDriver() && joined.length) {
        const stream = wfOutgoingStream()
        for (const m of joined) wfOfferTo(m.id, stream)
      }
      wfRenderPanel()
      break
    }

    case 'relay':
      wfHandlePayload(msg.from, msg.payload)
      break
  }
}

function wfSend(to, payload) {
  if (!wfSession) return
  wfSession.ws.send(JSON.stringify({ type: 'relay', to, payload }))
}

// ── Control-plane payloads ───────────────────────────────────────────────────

function wfHandlePayload(from, payload) {
  switch (payload.kind) {
    case 'request-sync':
      if (wfSession.queue.length) wfSend(from, { kind: 'queue-sync', queue: wfSession.queue, index: wfSession.index })
      break

    case 'queue-sync':
      wfSession.queue = payload.queue
      wfSession.index = payload.index
      wfRenderPanel()
      if (wfSession.index >= 0) wfEnterIndex(wfSession.index)
      break

    case 'queue-add':
      wfSession.queue.push({ ...payload.item, owner: payload.owner })
      wfRenderPanel()
      if (wfSession.index === -1) wfEnterIndex(0)
      break

    case 'track-change':
      wfEnterIndex(payload.index)
      break

    case 'play':
      audio.play()
      break

    case 'pause':
      audio.pause()
      break

    case 'seek':
      // No-op for listeners: a live srcObject stream ignores currentTime writes.
      // The driver's own seek already reaches listeners for free, since the
      // WebRTC stream is tapped straight off the driver's real playback.
      if (isFinite(audio.duration)) audio.currentTime = payload.position
      break

    case 'webrtc-offer':
      wfHandleOffer(from, payload.sdp)
      break

    case 'webrtc-answer': {
      const pc = wfSession.pcs.get(from)
      if (pc) wfSetRemoteAndFlush(pc, { type: 'answer', sdp: payload.sdp })
      break
    }

    case 'webrtc-ice': {
      const pc = wfSession.pcs.get(from) || (from === wfCurrentDriverId() ? wfSession.listenerPc : null)
      if (pc) wfAddIceCandidate(pc, payload.candidate)
      break
    }
  }
}

// ── ICE candidate buffering ──────────────────────────────────────────────────
// Candidates routinely arrive before setRemoteDescription() has resolved —
// that's normal over a real network, not just a same-machine test. Queue them
// and flush once the remote description actually lands, instead of dropping
// whatever arrives too early.

function wfAddIceCandidate(pc, candidate) {
  if (pc._wfRemoteSet) {
    pc.addIceCandidate(candidate).catch((e) => console.warn('[waterfall] addIceCandidate failed', e))
  } else {
    (pc._wfPendingIce ||= []).push(candidate)
  }
}

async function wfSetRemoteAndFlush(pc, desc) {
  await pc.setRemoteDescription(desc)
  pc._wfRemoteSet = true
  const pending = pc._wfPendingIce || []
  pc._wfPendingIce = []
  for (const c of pending) {
    try { await pc.addIceCandidate(c) } catch (e) { console.warn('[waterfall] queued addIceCandidate failed', e) }
  }
}

// ── Driver / listener handoff ────────────────────────────────────────────────

function wfEnterIndex(index) {
  wfSession.index = index
  const item = wfSession.queue[index]
  if (!item) return

  for (const pc of wfSession.pcs.values()) pc.close()
  wfSession.pcs.clear()
  wfSession.listenerPc?.close()
  wfSession.listenerPc = null

  updateNowPlaying(item) // safe even cross-server: art <img onerror> already falls back to the note glyph

  if (item.owner === wfSession.myId) {
    wfBecomeDriver(item)
  } else {
    audio.srcObject = null // wait for the new driver's webrtc-offer, handled separately
  }
}

function wfBecomeDriver(item) {
  audio.srcObject = null
  audio.src = streamUrl(item.Id)
  audio.play()
  reportPlaybackStart(item.Id)

  const stream = wfOutgoingStream()
  for (const member of wfSession.roster) {
    if (member.id === wfSession.myId) continue
    wfOfferTo(member.id, stream)
  }
}

function wfOfferTo(memberId, stream) {
  const pc = new RTCPeerConnection({ iceServers: WATERFALL_STUN })
  for (const track of stream.getTracks()) pc.addTrack(track, stream)
  pc.onicecandidate = (e) => { if (e.candidate) wfSend(memberId, { kind: 'webrtc-ice', candidate: e.candidate }) }
  pc.oniceconnectionstatechange = () => wfRenderPanelDebounced()
  wfSession.pcs.set(memberId, pc)

  pc.createOffer()
    .then((offer) => pc.setLocalDescription(offer))
    .then(() => wfSend(memberId, { kind: 'webrtc-offer', sdp: pc.localDescription.sdp }))
}

function wfHandleOffer(from, sdp) {
  const pc = new RTCPeerConnection({ iceServers: WATERFALL_STUN })
  pc.onicecandidate = (e) => { if (e.candidate) wfSend(from, { kind: 'webrtc-ice', candidate: e.candidate }) }
  pc.oniceconnectionstatechange = () => wfRenderPanelDebounced()
  pc.ontrack = (e) => { audio.src = ''; audio.srcObject = e.streams[0]; audio.play() }
  wfSession.listenerPc = pc

  wfSetRemoteAndFlush(pc, { type: 'offer', sdp })
    .then(() => pc.createAnswer())
    .then((answer) => pc.setLocalDescription(answer))
    .then(() => wfSend(from, { kind: 'webrtc-answer', sdp: pc.localDescription.sdp }))
}

// ── Hooks called from renderer.js ────────────────────────────────────────────

function wfQueueAdd(item) {
  if (!wfSession) return false
  wfSend(null, { kind: 'queue-add', item, owner: wfSession.myId })
  wfSession.queue.push({ ...item, owner: wfSession.myId })
  wfRenderPanel()
  if (wfSession.index === -1) wfEnterIndex(0)
  return true
}

function wfBroadcastPlay()  { if (wfSession) wfSend(null, { kind: 'play' }) }
function wfBroadcastPause() { if (wfSession) wfSend(null, { kind: 'pause' }) }

// Called from the prev/next buttons; returns true if it handled the move
// (session mode — always true while in a session, even a no-op skip target),
// false to fall through to solo-queue prev/next.
function wfSkip(delta) {
  if (!wfSession) return false
  const next = wfSession.index + delta
  if (next >= 0 && next < wfSession.queue.length) {
    wfSend(null, { kind: 'track-change', index: next })
    wfEnterIndex(next)
  }
  return true
}

// Called from the existing `ended` listener; returns true if it handled the
// advance (session mode), false to fall through to solo-queue behavior.
function wfHandleEnded() {
  if (!wfIsDriver()) return false
  const item = wfSession.queue[wfSession.index]
  if (item) reportPlaybackStopped(item.Id, Math.round((audio.duration || 0) * 10000000))
  const next = wfSession.index + 1
  if (next >= wfSession.queue.length) return true // end of shared queue — no repeat modes in v1
  wfSend(null, { kind: 'track-change', index: next })
  wfEnterIndex(next)
  return true
}

// ── UI: room panel (#waterfall-panel, added in index.html) ──────────────────

// ICE connection state can fire several transitions in quick succession while
// a peer connection is establishing — coalesce those into a single re-render
// instead of rebuilding the whole panel's innerHTML on every transition.
let _wfRenderDebounceTimer = null
function wfRenderPanelDebounced() {
  clearTimeout(_wfRenderDebounceTimer)
  _wfRenderDebounceTimer = setTimeout(wfRenderPanel, 150)
}

function wfRenderPanel() {
  const panel = document.getElementById('waterfall-panel')
  if (!panel) return

  if (!wfSession) {
    panel.innerHTML = `
      <button id="wf-create-btn" class="modal-btn modal-btn-accent">Start a Waterfall</button>
      <div class="wf-join-row">
        <input id="wf-join-code" class="modal-input" placeholder="Room code" maxlength="6">
        <button id="wf-join-btn" class="modal-btn">Join</button>
      </div>
    `
    document.getElementById('wf-create-btn').onclick = () => wfCreate()
    document.getElementById('wf-join-btn').onclick = () => {
      const code = document.getElementById('wf-join-code').value.trim().toUpperCase()
      if (code) wfJoin(code)
    }
    return
  }

  const link = `cascade://join/${wfSession.code}`
  const members = wfSession.roster.map(m => {
    const isMe = m.id === wfSession.myId
    const pc = wfSession.pcs.get(m.id) || (wfCurrentDriverId() === m.id ? wfSession.listenerPc : null)
    const state = isMe ? 'connected' : (pc?.iceConnectionState || 'connecting')
    const cls = (state === 'connected' || state === 'completed') ? 'connected' : ''
    return `<div class="wf-member"><span class="ws-dot ${cls}"></span>${esc(m.name)}${isMe ? ' (you)' : ''}</div>`
  }).join('')

  panel.innerHTML = `
    <div class="wf-room-code">Room <b>${esc(wfSession.code)}</b>
      <button id="wf-copy-code" class="modal-btn">Copy Code</button>
      <button id="wf-copy-link" class="modal-btn">Copy Link</button>
    </div>
    <div class="wf-members">${members}</div>
    <button id="wf-leave-btn" class="modal-btn">Leave Waterfall</button>
  `
  document.getElementById('wf-copy-code').onclick = () => window.cascade.clipboard.write(wfSession.code).then(() => showToast('Room code copied'))
  document.getElementById('wf-copy-link').onclick = () => window.cascade.clipboard.write(link).then(() => showToast('Invite link copied'))
  document.getElementById('wf-leave-btn').onclick = () => wfLeave()
}

// ── Modal open/close ─────────────────────────────────────────────────────────

document.getElementById('btn-waterfall-open').addEventListener('click', () => {
  wfRenderPanel()
  document.getElementById('wf-modal').classList.remove('hidden')
})
document.getElementById('wf-modal-close').addEventListener('click', () => {
  document.getElementById('wf-modal').classList.add('hidden')
})

wfRenderPanel() // draw the initial "not in a session" state

// Deep-link join (cascade://join/CODE), forwarded from main.js via preload.js
window.cascade.onWaterfallJoin((code) => {
  wfJoin(code)
  document.getElementById('wf-modal').classList.remove('hidden')
})
