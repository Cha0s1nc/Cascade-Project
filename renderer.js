// ── Cascade renderer ──────────────────────────────────────────────────────────

// State
let jf = { url: '', token: '', userId: '' }

// Unique per install, persisted on first run. Used to be the constant
// "cascade-app", which made every Cascade look like one device to Jellyfin -
// so remote control could not target a specific client and two instances
// collided in the session list. Loaded in init() before anything authenticates.
let deviceId = 'cascade-app'
let appVersion = '1.0.0'
let queue = []
let queueIndex = -1
let shuffle = false
let repeatMode = 'none' // 'none' | 'all' | 'one'
let _unshuffledQueue = []   // original order saved when shuffle is enabled

// Queue panel virtualisation
const QUEUE_WIN      = 20   // rows kept in DOM at once
const QUEUE_ROW_H    = 53   // px per row - .queue-row pins this exact height in CSS
const QUEUE_BEFORE   = 5    // rows to show before current track when re-centering
let _queueWinStart   = 0    // index of first rendered row
let _queueScrollBound = false
let volume = 1.0
let crossfadeEnabled = false
let crossfadeSeconds = 6
let maxStreamingBitrate = 140000000   // overridden from settings in loadSettingsFields
// The server only transcodes to specific bitrates, not a continuum - the
// streaming quality slider is stepped through this exact list rather than
// letting the user drag to an arbitrary number.
const MAX_BITRATE_STEPS = [
  { value: 140000000, label: 'Original' },
  { value: 320000, label: '320 kbps' },
  { value: 192000, label: '192 kbps' },
  { value: 128000, label: '128 kbps' },
  { value: 96000, label: '96 kbps' },
]

// The one code path each of these settings goes through - Settings and the
// first-run wizard both call these rather than each persisting the value
// themselves, so there is nowhere for the two to drift apart.
async function setCrossfadeEnabled(enabled) {
  crossfadeEnabled = enabled
  await window.cascade.store.set('crossfadeEnabled', crossfadeEnabled)
}
async function setCrossfadeSeconds(seconds) {
  crossfadeSeconds = seconds
  await window.cascade.store.set('crossfadeSeconds', crossfadeSeconds)
}
async function setMaxStreamingBitrate(bitrateValue) {
  maxStreamingBitrate = bitrateValue
  await window.cascade.store.set('maxStreamingBitrate', maxStreamingBitrate)
}

let eqEnabled = false
let eqActiveMode = 'music'   // which saved profile is wired into the live graph right now
let eqMusicProfile = { preamp: null, bands: [0, 0, 0, 0, 0] }
let eqVideoProfile = { preamp: null, bands: [0, 0, 0, 0, 0] }   // all overridden from the store in init()
let _eqEditTarget = 'music'   // which saved profile the settings panel is editing right now

// Two permanent "deck" media elements (A/B), so a crossfade is two real
// elements overlapping instead of one element having its src handed back and
// forth. Both are the <video id="media">/<video id="media-b"> in index.html,
// not `new Audio()`, because movies and episodes need somewhere to draw.
// HTMLVideoElement *is* an HTMLMediaElement, so every .play()/.pause()/.src/
// .currentTime/.duration/.volume call below works exactly as it did.
const DECKS = [
  /** @type {HTMLVideoElement} */ (document.getElementById('media')),
  /** @type {HTMLVideoElement} */ (document.getElementById('media-b')),
]
DECKS.forEach(d => { d.crossOrigin = 'anonymous'; d.volume = volume })

// `audio` points at whichever deck is current. It is a `let` reassigned at
// the end of a crossfade (see finishCrossfade), and it is still called
// `audio` on purpose: renaming it would churn 100-odd lines for no behaviour
// change, since every existing `audio.foo` reference just follows the
// reassignment. It plays music the overwhelming majority of the time.
let audio = DECKS[0]

// The 20-odd `audio.addEventListener(...)` calls sprinkled through this file
// were written when `audio` was a single, permanent element - they captured
// whichever deck `audio` pointed to at parse time and would go deaf the first
// time a crossfade reassigned it. onDeck() binds to both decks permanently
// and filters to whichever one is current *at event time*, so every one of
// those call sites keeps working across a crossfade without needing to know
// decks exist.
function onDeck(type, fn, opts) {
  DECKS.forEach(d => d.addEventListener(type, e => { if (e.target === audio) fn(e) }, opts))
}

// Element .volume/.muted must track the user's setting on BOTH decks at all
// times - the crossfade envelope lives entirely in Web Audio gain nodes (see
// _ensureEqGraph), never on the element, so whichever deck becomes current
// next already has the right volume with nothing left to sync.
function setDeckVolume(v) { DECKS.forEach(d => d.volume = v) }
function setDeckMuted(m) { DECKS.forEach(d => d.muted = m) }

/**
 * Sets playback volume to `ratio` (0..1) and keeps everything that depends on it
 * in step: both decks, both volume bars' fill and aria-valuenow (they mirror each
 * other), and the persisted setting. Every volume-changing input - drag, keyboard,
 * the remote-control API, and the saved-value restore on launch - goes through
 * this so none of them can drift from the others.
 */
function setVolumeRatio(ratio) {
  ratio = Math.max(0, Math.min(1, ratio))
  volume = ratio
  setDeckVolume(ratio)
  const pct = `${ratio * 100}%`
  document.getElementById('vol-fill').style.width = pct
  document.getElementById('ov-vol-fill').style.width = pct
  const now = String(Math.round(ratio * 100))
  document.getElementById('vol-bar').setAttribute('aria-valuenow', now)
  document.getElementById('ov-vol-bar').setAttribute('aria-valuenow', now)
  window.cascade.store.set('volume', ratio)
}

// ── Media kind ────────────────────────────────────────────────────────────────

// Jellyfin returns one item shape for everything, so Type is what separates a
// movie from a song. Anything that is not video is treated as audio: an unknown
// Type falling back to the music path is the safe direction.
function isVideoItem(item) {
  return item?.Type === 'Movie' || item?.Type === 'Episode' || item?.MediaType === 'Video'
}

/** True when the thing currently loaded into the media element is video. */
function playingVideo() {
  return isVideoItem(queue[queueIndex])
}

// ── Portable core ─────────────────────────────────────────────────────────────
// src/core/*.ts, bundled to build/core.js and loaded by index.html before this
// file. Everything here is DOM-free and Electron-free on purpose: it is the part
// that can be reused by a future webOS/Tizen/React Native client.

// Careful when converting more functions to `const` bindings like these: a
// top-level `const` lives in the global *lexical* environment (still visible to
// waterfall.js, which loads after this file) but is NOT a property of
// globalThis. Inline HTML handlers - index.html uses onclick="showView(...)" -
// resolve only against globalThis, so anything referenced from markup must stay
// a `function` declaration.
const {
  parseLRC, parseKrc,
  sortSongs, songSortValue, shuffleInPlace, shuffled, nextQueueIndex,
  resolveStream, universalStreamUrl, withStartTicks, stopActiveEncoding,
  buildElectronProfile, DEFAULT_MAX_BITRATE,
  resumeTicks, neededAudioStreamIndex,
  entryIdOf, removeSelected, moveSelectedToTop, moveSelectedToBottom,
  groupRecentlyWatched,
} = CascadeCore

// Passed as a getter, not as `jf` itself: connect() replaces the whole object,
// and a captured reference would keep serving stale credentials.
const jfClient = new CascadeCore.JellyfinClient(() => jf)

// ── Helpers ───────────────────────────────────────────────────────────────────

function fmtTime(sec) {
  if (!sec || isNaN(sec)) return '0:00'
  const m = Math.floor(sec / 60)
  const s = Math.floor(sec % 60)
  return `${m}:${s.toString().padStart(2, '0')}`
}

function greeting() {
  const h = new Date().getHours()
  if (h < 12) return 'Good morning'
  if (h < 18) return 'Good afternoon'
  return 'Good evening'
}

const artUrl       = (itemId, tag) => jfClient.artUrl(itemId, tag)
const artistArtUrl = (itemId)      => jfClient.artistArtUrl(itemId)

// ── Skeleton loaders ──────────────────────────────────────────────────────────
// Placeholder cards/rows shown while a view's data is being fetched.
const SKELETON_TEMPLATES = {
  album: `<div class="album-card skel-card">
    <div class="album-art skel"></div>
    <div class="album-body">
      <div class="skel skel-text" style="width:80%"></div>
      <div class="skel skel-text" style="width:50%;height:9px;margin-top:6px"></div>
    </div>
  </div>`,
  artist: `<div class="artist-card skel-card">
    <div class="artist-avatar skel"></div>
    <div class="skel skel-text" style="width:70%;margin:0 auto"></div>
  </div>`,
  poster: `<div class="poster-card skel-card">
    <div class="poster-art skel"></div>
    <div class="skel skel-text" style="width:80%;margin-top:7px"></div>
  </div>`,
  playlist: `<div class="playlist-card skel-card">
    <div class="playlist-art skel"></div>
    <div class="playlist-body">
      <div class="skel skel-text" style="width:75%"></div>
      <div class="skel skel-text" style="width:40%;height:9px;margin-top:6px"></div>
    </div>
  </div>`,
  rp: `<div class="rp-item skel-card">
    <div class="rp-art skel"></div>
    <div style="min-width:0;flex:1">
      <div class="skel skel-text" style="width:85%"></div>
      <div class="skel skel-text" style="width:55%;height:9px;margin-top:5px"></div>
    </div>
  </div>`,
  track: `<div class="track-row skel-card">
    <div class="skel skel-text" style="width:14px;height:11px;margin:0 auto"></div>
    <div class="track-thumb skel"></div>
    <div style="min-width:0">
      <div class="skel skel-text" style="width:60%"></div>
      <div class="skel skel-text" style="width:35%;height:9px;margin-top:5px"></div>
    </div>
    <div class="skel skel-text" style="width:70%"></div>
    <div class="skel skel-text" style="width:34px;height:9px;margin-left:auto"></div>
  </div>`,
  line: `<div class="skel skel-text" style="width:100%;height:16px;margin:4px 0"></div>`,
  lyrics: `<div style="display:flex;flex-direction:column;align-items:center;gap:14px;padding:40px 0">
    <div class="skel skel-text" style="width:55%;height:16px"></div>
    <div class="skel skel-text" style="width:70%;height:16px"></div>
    <div class="skel skel-text" style="width:40%;height:16px"></div>
    <div class="skel skel-text" style="width:60%;height:16px"></div>
  </div>`
}

function skeletonHTML(type, count) {
  return SKELETON_TEMPLATES[type].repeat(count)
}

// ── iTunes album art (high-res, no API key needed) ────────────────────────────
const _ITUNES_ART_CACHE_MAX = 1000
const _itunesArtCache = new Map()

async function fetchItunesArt(artist, album) {
  const key = `${artist}|||${album}`.toLowerCase()
  if (_itunesArtCache.has(key)) {
    // Re-insert to mark as most-recently-used (Map preserves insertion order)
    const v = _itunesArtCache.get(key)
    _itunesArtCache.delete(key)
    _itunesArtCache.set(key, v)
    return v
  }
  if (_itunesArtCache.size >= _ITUNES_ART_CACHE_MAX) {
    _itunesArtCache.delete(_itunesArtCache.keys().next().value) // evict least-recently-used
  }
  // The entry is the in-flight promise, not a null placeholder. Two callers ask
  // for the same album on a single track change (the now-playing art upgrade and
  // the Discord presence), and a placeholder handed the second one `null` as
  // though the album had no cover, so whichever lost the race got nothing.
  const inFlight = (async () => {
    try {
      const term = encodeURIComponent(`${artist} ${album}`.trim())
      const r = await fetch(
        `https://itunes.apple.com/search?term=${term}&entity=album&limit=5&media=music`,
        { signal: AbortSignal.timeout(7000) }
      )
      // Unauthenticated iTunes search allows roughly 20 requests a minute, which
      // a shuffle through an unfamiliar library will trip. A 403 is not an
      // answer about the album, so it must not be remembered as one: drop the
      // entry and let the next play ask again. Same for a timeout or a blip.
      if (!r.ok) { _itunesArtCache.delete(key); return null }
      const d = await r.json()
      const result = d.results?.[0]
      // Scale from 100px thumbnail to 600px - just replace the size token in the URL
      const url = result?.artworkUrl100
        ? result.artworkUrl100.replace(/\d+x\d+bb/, '600x600bb')
        : null
      // A real answer, including a real "iTunes has never heard of this", which
      // is worth remembering so a bootleg is not looked up once per play.
      _itunesArtCache.set(key, url)
      return url
    } catch {
      _itunesArtCache.delete(key)
      return null
    }
  })()
  _itunesArtCache.set(key, inFlight)
  return inFlight
}

// Tracks the best available art URL for the current track (iTunes > Jellyfin)
let _currentHighResArtUrl = null

// Ask the server how to play a track, given what Chromium can decode. Async
// because it POSTs /Items/{id}/PlaybackInfo - the server picks direct play or
// transcode. Falls back to the old /universal URL if that call fails, so this
// never rejects. See src/core/playback.ts.
// `kind` picks the endpoint family: /Audio/{id} vs /Videos/{id}. Passed from
// the item rather than inferred inside core, because core has no opinion about
// Jellyfin's Type strings.
// What this build can actually decode, asked once rather than assumed.
//
// canPlayType is the right test because playback is a plain `src` on the media
// element, not MSE. 'probably' only: a 'maybe' means the browser recognises the
// container but will not commit to the codec, and treating that as yes is how
// you get a direct-play URL and a black screen - the exact failure
// PLATFORM-NOTES.md warns about.
//
// The big one is HEVC. Chromium decodes it wherever the OS does (VideoToolbox
// on macOS), and those are precisely the files a server would otherwise burn
// minutes transcoding.
const DEVICE_PROFILE = buildElectronProfile(t => {
  try { return audio.canPlayType(t) === 'probably' } catch { return false }
})

// Audio codecs this profile claims for a video container - what neededAudioStreamIndex()
// checks a movie's default track against. See its doc comment in playback.ts: direct play
// hands over every embedded audio stream, and Chromium decodes whichever one the file
// itself flags as default, not whatever the server decided was "the" compatible one.
// Codecs this build CLAIMED it could decode and then demonstrably could not:
// the picture played, the clock advanced, and the audio decoder produced zero
// bytes. Filled in at runtime by _checkAudioActuallyDecoded() and persisted,
// because the claim is wrong for the machine, not for the file.
let _undecodableAudioCodecs = new Set()

/** The device profile with any proven-undecodable codec withdrawn. */
function currentDeviceProfile() {
  return _undecodableAudioCodecs.size
    ? CascadeCore.withoutAudioCodecs(DEVICE_PROFILE, [..._undecodableAudioCodecs])
    : DEVICE_PROFILE
}

// Audio codecs the profile currently claims for a video container - what
// neededAudioStreamIndex() checks a movie's default track against.
function decodableVideoAudioCodecs() {
  return (currentDeviceProfile().DirectPlayProfiles.find(p => p.Type === 'Video')?.AudioCodec || '')
    .split(',').filter(Boolean)
}

/** @type {(itemId: string, kind?: 'Audio' | 'Video', opts?: any) => Promise<any>} */
const resolveTrackStream = (itemId, kind = 'Audio', opts = {}) =>
  resolveStream(jfClient, jf, itemId, currentDeviceProfile(), maxStreamingBitrate, kind, opts)

// Self-contained URL for "Copy stream URL". Deliberately the /universal form
// rather than a PlaySessionId-bound one, so the copied link keeps working after
// this session ends.
/** @type {(itemId: string, kind?: 'Audio' | 'Video') => string} */
const streamUrl = (itemId, kind = 'Audio') => universalStreamUrl(jf, itemId, maxStreamingBitrate, kind)

// Server-side playback session, from the most recent PlaybackInfo. Reported
// back so Jellyfin ties progress to the right session instead of guessing.
let _playSessionId = null

// ── Playback ownership ───────────────────────────────────────────────────────
// Local user, a Jellyfin cast controller, and a Waterfall host can all issue
// playback commands. One arbiter decides, rather than each mechanism guessing.
// Rules live in src/core/ownership.ts; the state lives in waterfall.js.

const NO_WATERFALL = { waterfallActive: false, waterfallIsHost: false, waterfallApplying: false }

/**
 * What happens when the local user adds a track to the queue.
 * 'local' = mutate directly, 'propose' = ask the host, 'blocked' = not allowed.
 */
function queueAdditionMode() {
  return CascadeCore.queueAdditionMode(ownershipState())
}

/** True when this client mirrors someone else's queue and must not edit it. */
function isWaterfallFollower() {
  return typeof wfIsFollower === 'function' && wfIsFollower()
}

/**
 * Who added queue entry `i`, or null.
 *
 * Gated on wfIsFollower rather than on wfAddedBy itself: that is a `let` in
 * waterfall.js, and `typeof` on a let in its temporal dead zone throws instead
 * of returning 'undefined'. wfIsFollower is a function declaration, so testing
 * it is safe even before that script runs - and if it exists, waterfall.js has
 * finished executing and its bindings are initialised.
 */
function queueAddedBy(i) {
  if (typeof wfIsFollower !== 'function') return null
  return wfAddedBy?.[i] ?? null
}

/**
 * Add tracks to the queue, routed through the arbiter.
 *
 * A guest must not mutate locally - the next host broadcast would wipe it,
 * which is exactly how "Add to queue" used to look like it worked and then
 * silently do nothing.
 */
function enqueueTracks(items, label) {
  const mode = queueAdditionMode()

  if (mode === 'blocked') {
    showToast('The host has turned off guest additions')
    return
  }
  if (mode === 'propose') {
    if (wfRequestEnqueue(items)) showToast(`Asked the host to add ${label}`)
    return
  }

  queue.push(...items)
  showToast(`Added ${label} to queue`)
}

function ownershipState() {
  // waterfall.js is a separate <script> that loads after this one, so during
  // init none of its bindings exist yet.
  //
  // Gate on wfActive specifically: it is a `function` declaration, so `typeof`
  // is safe even before the script runs. wfIsHost and _wfApplying are `let`s,
  // and `typeof` on a let in its temporal dead zone THROWS rather than
  // returning 'undefined' - reading them is only safe once wfActive exists,
  // which means waterfall.js has finished executing.
  if (typeof wfActive !== 'function' || !wfActive()) return NO_WATERFALL

  return {
    waterfallActive:    true,
    waterfallIsHost:    !!wfIsHost,
    waterfallApplying:  !!_wfApplying,
    guestAddsAllowed:   wfGuestAddsAllowed !== false,
  }
}

/** True when local transport controls should do nothing. */
function blocksLocalPlayback() {
  return CascadeCore.blocksLocalPlayback(ownershipState())
}

/** True when an incoming cast command should be acted on. */
function playbackIsLocallyOwned() {
  return CascadeCore.acceptsRemoteCommand(ownershipState())
}

// ── Toast ─────────────────────────────────────────────────────────────────────
// Toasts are dev-only noise in production builds - only show when running
// unpackaged (i.e. launched from the command line via `npm start`/`electron .`).
let _toastsEnabled = false
window.cascade?.isPackaged?.().then(packaged => { _toastsEnabled = !packaged })

// Toasts are suppressed in packaged builds (_toastsEnabled above), so anything
// the user genuinely needs to read has to be a modal they dismiss. Resolves once
// OK is clicked; returns immediately if a notice is already on screen.
function showNotice(message, title = 'Heads up') {
  const modal = document.getElementById('notice-modal')
  if (!modal || !modal.classList.contains('hidden')) return Promise.resolve()
  document.getElementById('notice-title').textContent = title
  document.getElementById('notice-body').textContent  = message
  modal.classList.remove('hidden')
  return new Promise(resolve => {
    document.getElementById('notice-ok').addEventListener('click', () => {
      modal.classList.add('hidden')
      resolve()
    }, { once: true })
  })
}

function showToast(msg, duration = 2200) {
  if (!_toastsEnabled) return
  const t = document.getElementById('toast')
  t.textContent = msg
  t.style.opacity = '1'
  clearTimeout(t._to)
  t._to = setTimeout(() => { t.style.opacity = '0' }, duration)
}

// ── Jellyfin API ──────────────────────────────────────────────────────────────

// Typed loosely on purpose: callers here hit list endpoints, single-item
// endpoints and /System/Info alike, so the client's JfItemsResponse default is
// wrong for most of them. src/ code calls jfClient.get directly and does get
// the strict types.
/** @type {(path: string, params?: Record<string, any>) => Promise<any>} */
const jfGet  = (path, params = {}) => jfClient.get(path, params)
const jfAuth = (serverUrl, username, password) =>
  CascadeCore.authenticate(serverUrl, username, password, appVersion, deviceId)

// ── Connection ────────────────────────────────────────────────────────────────

async function connect(serverUrl, token, userId) {
  jf = { url: serverUrl.replace(/\/$/, ''), token, userId, deviceId }

  const loadingEl  = document.getElementById('setup-loading')
  const loadingTxt = document.getElementById('setup-loading-text')
  const errorEl    = document.getElementById('setup-error')
  const connectBtn = document.getElementById('setup-connect')

  const showLoading = (msg) => {
    if (loadingEl)  loadingEl.classList.add('visible')
    if (loadingTxt) loadingTxt.textContent = msg
    if (errorEl)    errorEl.textContent = ''
    if (connectBtn) connectBtn.style.display = 'none'
  }
  const hideLoading = () => {
    if (loadingEl)  loadingEl.classList.remove('visible')
    if (connectBtn) connectBtn.style.display = ''
  }

  // Fired alongside the token ping below rather than waiting for it. The two
  // are independent requests to the same server, and /Views cannot succeed on a
  // bad token either, so running them in turn just put an extra round trip in
  // front of everything the user actually sees. The ping is still needed for
  // its own sake: it carries Policy, which is where isAdmin and canDelete come
  // from.
  //
  // .catch is attached here, not later, so a rejection can never surface as an
  // unhandled rejection while nothing is awaiting it yet. A null result means
  // populateLibraryPicker just fetches normally, so the slow path is exactly
  // what it was before.
  const viewsPromise = jfGet(`/Users/${userId}/Views`).catch(() => null)

  // Verify the token is still valid with a lightweight ping, retry up to 3x
  let verified = false
  let userInfo = null
  for (let attempt = 1; attempt <= 3; attempt++) {
    showLoading(attempt === 1 ? 'Connecting…' : `Retrying… (${attempt}/3)`)
    try {
      userInfo = await jfGet(`/Users/${userId}`)
      verified = true
      break
    } catch (e) {
      if (attempt < 3) await new Promise(r => setTimeout(r, 1500 * attempt))
    }
  }

  hideLoading()

  if (!verified) {
    if (errorEl) errorEl.textContent = 'Connection failed. Check your server URL and try again.'
    throw new Error('Could not reach Jellyfin server')
  }

  // Free: userInfo is the same /Users/{id} response the token-verify ping just
  // fetched, no second request needed. Gates server-only admin actions (see
  // _applyAdminGating) - always overwritten here so a previous account's
  // admin status can never survive into this session.
  jf.isAdmin = !!userInfo?.Policy?.IsAdministrator
  // Same free response as isAdmin above - deletion is its own Jellyfin right,
  // not implied by admin status alone, but an admin always has it too (see
  // canDeleteMedia). Gates the "Delete media" entry, kept apart from
  // _applyAdminGating's admin-only entries below.
  jf.canDelete = CascadeCore.canDeleteMedia(userInfo?.Policy)
  _applyAdminGating()

  startRemoteControl()
  probeCascadePlugin()  // not awaited - cheap, and nothing here depends on the result yet
  await populateLibraryPicker(viewsPromise)
  invalidateLibraryViews()
  await loadHome()
  // Both sit over a populated app rather than a blank one, hence after loadHome.
  // The wizard runs itself off its stored revision, so an ordinary launch on the
  // current revision shows nothing - and when it does run it has already marked
  // the video intro seen, since its library step covers the same ground.
  if (!await maybeShowSetupWizard()) await maybeShowVideoIntro()
}

// ── Remote control (cast target) ─────────────────────────────────────────────
// Registers this client with Jellyfin so the web UI, a phone, or a future TV
// client can drive it. Protocol lives in src/core/remote-control.ts; only the
// "actually do it" callbacks are here, because only they touch the DOM.

let _remote = null

function startRemoteControl() {
  if (_remote) _remote.stop()

  _remote = new CascadeCore.RemoteControl(jfClient, () => jf, {
    async play(itemIds, startIndex) {
      if (!itemIds.length) return
      const res = await jfGet(`/Users/${jf.userId}/Items`, {
        Ids: itemIds.join(','),
        // MediaStreams/MediaSources are what applySubtitles() needs. Without
        // them a movie pushed from Jellyfin's "Play On" would play with no
        // subtitles even when the file has them.
        Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag,UserData,MediaStreams,MediaSources',
      }).catch(() => null)
      const items = res?.Items || []
      if (!items.length) return
      // Jellyfin returns items in its own order, so re-sort to what was sent.
      const byId = new Map(items.map(i => [i.Id, i]))
      const ordered = itemIds.map(id => byId.get(id)).filter(Boolean)
      playItems(ordered.length ? ordered : items, startIndex)
    },
    playPause()     { if (audio.paused) audio.play().catch(() => {}); else audio.pause() },
    pause()         { audio.pause() },
    unpause()       { audio.play().catch(() => {}) },
    stop()          { stopPlayback() },
    nextTrack()     { document.getElementById('btn-next').click() },
    previousTrack() { document.getElementById('btn-prev').click() },
    seek(ticks)     { seekTo(ticks / 10_000_000) },
    setVolume(pct)  { applyRemoteVolume(pct / 100) },
    volumeUp()      { applyRemoteVolume(volume + 0.1) },
    volumeDown()    { applyRemoteVolume(volume - 0.1) },
    toggleMute()    { setDeckMuted(!audio.muted) },
    setMute(muted)  { setDeckMuted(muted) },
  }, playbackIsLocallyOwned)

  // Not fatal - playback works fine without it - but it must be visible.
  // Silently swallowing this hid a malformed capabilities payload that left
  // Cascade invisible as a cast target with no symptom to chase.
  _remote.start().catch(err => {
    console.warn('[cascade] remote control unavailable:', err?.message || err)
  })
}

// Mirrors what the volume slider does, so a remote change looks identical.
function applyRemoteVolume(next) {
  setVolumeRatio(next)
}

// The library selection may have changed - force every lazy view to refetch.
// allSongs must be cleared too: shuffleAllSongs() short-circuits when it is
// non-empty and would keep queueing tracks from deselected libraries.
function invalidateLibraryViews() {
  allSongs = []
  for (const id of ['albums-grid', 'artists-grid', 'songs-rows', 'playlists-grid'])
    delete document.getElementById(id).dataset.loaded
}

/** Same, for the video grids. Separate because the two selections are separate:
 *  changing music libraries must not throw away a loaded movie grid. */
function invalidateVideoViews() {
  for (const id of ['movies-grid', 'shows-grid'])
    delete document.getElementById(id).dataset.loaded
}

/** Greys out the server library scan button when the account is not an admin,
 *  using the same disabled+data-tip pattern as the CascadeSLRC gating below.
 *  Safe to call anytime, including before connect() has run (jf.isAdmin is
 *  then undefined, which reads as "not admin" - the safe default). */
function _applyAdminGating() {
  const btn = document.getElementById('s-refresh-server')
  if (btn) btn.disabled = !jf.isAdmin
  const host = document.getElementById('s-refresh-server-tip')
  if (host) {
    if (!jf.isAdmin) host.setAttribute('data-tip', 'Needs a Jellyfin admin account')
    else host.removeAttribute('data-tip')
  }
  // Both "Refresh metadata" entries hit POST /Items/{id}/Refresh, the same
  // RequiresElevation endpoint as the library scan. "Edit metadata" and "Edit
  // images" open the item in the Jellyfin web UI, which itself refuses those
  // edits without admin - so a non-admin gets a browser tab that cannot do
  // anything. All admin-only. A floating context menu is a bad place for the
  // [data-tip] tooltip (it renders below its host, and the menu is already
  // positioned against the viewport edge), so these say why inline instead.
  for (const id of ['ctx-refresh-meta', 'tctx-refresh-meta', 'ctx-edit-meta', 'ctx-edit-images', 'tctx-edit-meta']) {
    const item = document.getElementById(id)
    if (item) item.classList.toggle('needs-admin', !jf.isAdmin)
    const note = document.getElementById(id + '-note')
    if (note) note.hidden = !!jf.isAdmin
  }
  // Delete media is gated on the actual deletion right (see canDeleteMedia),
  // not admin - an admin always has it, but a non-admin can be granted it too,
  // and gating on isAdmin would hide the feature from someone who has it.
  {
    const item = document.getElementById('ctx-delete')
    if (item) item.classList.toggle('needs-admin', !jf.canDelete)
    const note = document.getElementById('ctx-delete-note')
    if (note) note.hidden = !!jf.canDelete
  }
}

document.getElementById('s-refresh-server').addEventListener('click', async () => {
  // The button is disabled for a non-admin, but a disabled button can still
  // be clicked programmatically - don't trust the DOM state alone against a
  // server call that would just 403 anyway.
  if (!jf.isAdmin) return
  try {
    const res = await fetch(`${jf.url}/Library/Refresh`, { method: 'POST', headers: { 'X-Emby-Token': jf.token } })
    if (!res.ok) throw new Error(String(res.status))
    // Async on the server - it scans in the background and this response says
    // nothing about when it finishes, so there is nothing to await here.
    showToast('Library scan started on the server - new items appear once it finishes')
  } catch {
    showNotice('Could not start a library scan on the server.', 'Scan failed')
  }
})

document.getElementById('s-refresh-local').addEventListener('click', async () => {
  // Local cache invalidation only - works for any account, and unlike the
  // server scan above this is immediately useful because it just re-reads
  // whatever the server already has.
  invalidateLibraryViews()
  invalidateVideoViews()
  showView(_currentView)   // reloads whichever grid is currently on screen, if any
  await loadHome()         // Home's shelves aren't covered by either invalidate above
  showToast('Refreshed from what the server has now')
})

let _musicLibs        = []     // the server's music libraries, cached so a mode flip needn't refetch
let _movieLibs        = []     // movies libraries, same caching reason
let _showLibs         = []     // tvshows libraries, kept apart from _movieLibs so a movie query
                                // never fans out across TV libraries or vice versa
let singleLibraryMode = false  // one library at a time (dropdown) instead of merging several

/** `prefetched` is the in-flight /Views request connect() started in parallel
 *  with the token ping. It resolves to null if that request failed, in which
 *  case this fetches it the old way - a retry is worth more here than saving a
 *  round trip, because empty _musicLibs is indistinguishable from a music-only
 *  server and takes Movies and TV down with it. */
async function populateLibraryPicker(prefetched = null) {
  try {
    const data = (prefetched && await prefetched) || await jfGet(`/Users/${jf.userId}/Views`)
    _musicLibs = (data.Items || []).filter(i =>
      i.CollectionType === 'music' || i.CollectionType === 'musicvideos'
    )
    _movieLibs = (data.Items || []).filter(i => i.CollectionType === 'movies')
    _showLibs  = (data.Items || []).filter(i => i.CollectionType === 'tvshows')
    await migrateVideoLibraryIds()
    await loadVideoLibrarySelection()
    await loadCollapsedLibs()
    const savedRaw = await window.cascade.store.get('libraryIds')
    let savedIds = []
    try { savedIds = savedRaw ? JSON.parse(savedRaw) : [] } catch {}
    singleLibraryMode = (await window.cascade.store.get('singleLibraryMode')) === true

    // First connect selects everything; single mode only ever holds one
    if (!savedIds.length && _musicLibs.length) savedIds = _musicLibs.map(l => l.Id)
    savedIds = savedIds.filter(id => _musicLibs.some(l => l.Id === id))  // drop libraries that vanished
    if (singleLibraryMode) savedIds = savedIds.slice(0, 1)
    if (!savedIds.length && _musicLibs.length) savedIds = [_musicLibs[0].Id]

    jf.libraryIds = savedIds
    await window.cascade.store.set('libraryIds', JSON.stringify(savedIds))
    renderLibraryPicker()
  } catch (e) {
    // Swallowing this used to take Movies and TV down with it: _movieLibs and
    // _showLibs stay empty, both nav rows stay hidden, the intro card silently
    // never shows, and there is nothing anywhere to explain why. Playback still
    // works without a picker, so this stays non-fatal - but it no longer disappears.
    console.error('[cascade] could not load libraries from /Views:', e)
  }
}

function renderLibraryPicker() {
  const container = document.getElementById('s-library-list')
  const singleRow = document.getElementById('s-single-lib-row')
  const libRow    = document.getElementById('s-library-row')
  const desc      = document.getElementById('s-library-desc')
  const toggle    = document.getElementById('s-single-lib-toggle')
  const ids       = jf.libraryIds || []

  if (!_musicLibs.length) {
    singleRow.style.display = 'none'
    libRow.style.display = ''
    container.innerHTML = '<span style="font-size:12px;color:var(--text3);">No music libraries found</span>'
    return
  }

  // Merging is meaningless with one library, so that toggle really is noise.
  // The list itself is not: it is the only place to see which library you are
  // on, it is where a library added on the server later shows up, and hiding it
  // left an account with access to a single library unable to see or change
  // anything here at all. The last enabled entry is locked on regardless (see
  // lockLast below), so a one-entry list cannot be turned into an empty one.
  const hasChoice = _musicLibs.length > 1
  singleRow.style.display = hasChoice ? '' : 'none'
  libRow.style.display    = ''

  toggle.checked = singleLibraryMode

  if (singleLibraryMode) {
    desc.textContent = 'Changes apply immediately.'
    container.innerHTML = `<select class="setting-input" id="s-library-select" style="width:100%;">${
      _musicLibs.map(lib =>
        `<option value="${lib.Id}"${ids[0] === lib.Id ? ' selected' : ''}>${esc(lib.Name)}</option>`
      ).join('')
    }</select>`
    document.getElementById('s-library-select').onchange = e => applyLibrarySelection([e.target.value])
    return
  }

  desc.textContent = 'Merged into one view. Changes apply immediately.'
  // The last one on is locked: an empty selection has no coherent meaning here
  const lockLast = ids.length === 1
  container.innerHTML = _musicLibs.map(lib => {
    const on = ids.includes(lib.Id)
    return `<div class="lib-check-row${on && lockLast ? ' locked' : ''}">
      <span class="lib-check-label" title="${esc(lib.Name)}">${esc(lib.Name)}</span>
      <label class="toggle">
        <input type="checkbox" value="${lib.Id}"${on ? ' checked' : ''} />
        <span class="toggle-track"></span>
      </label>
    </div>`
  }).join('')
  container.querySelectorAll('input[type=checkbox]').forEach(cb => {
    cb.onchange = () => {
      const next = [...container.querySelectorAll('input[type=checkbox]:checked')].map(c => c.value)
      applyLibrarySelection(next)
    }
  })
}

// Persist the selection and rebuild every view against it. No re-auth involved:
// which libraries you browse has nothing to do with your credentials.
async function applyLibrarySelection(ids) {
  // Shouldn't be reachable while the last toggle is locked, but if it is, snap the
  // UI back to what's actually active rather than leaving it showing nothing on
  if (!ids.length) { renderLibraryPicker(); return }
  jf.libraryIds = ids
  await window.cascade.store.set('libraryIds', JSON.stringify(ids))
  renderLibraryPicker()
  invalidateLibraryViews()
  showToast(ids.length === 1
    ? `Now playing from ${_musicLibs.find(l => l.Id === ids[0])?.Name || 'library'}`
    : `Merging ${ids.length} libraries`)
  await loadHome()
}

// ── Video libraries ───────────────────────────────────────────────────────────
//
// Deliberately a second, independent selection rather than widening the music
// one. jf.libraryIds narrows *every* getMerged call, so folding movie libraries
// into it would make every album and artist query fan out across them.
//
// Movies and TV are themselves kept apart (movieLibraryIds / showLibraryIds)
// so a movie query never fans out across TV libraries and vice versa. Each
// category auto-selects its one library when that's all the server has - see
// CascadeCore.effectiveLibraryIds - so there's nothing to toggle in that case.

// Earlier Cascade builds saved one flat list of movie/TV ids under the single
// videoLibraryIds key. Split it into the new per-category keys the first time
// this runs, using each id's CollectionType, then delete the old key so this
// is a one-shot: once it's gone, a selection made under the new keys is never
// overwritten by a stale flat list on a later launch.
async function migrateVideoLibraryIds() {
  const raw = await window.cascade.store.get('videoLibraryIds')
  if (!raw) return
  let oldIds = []
  try { oldIds = JSON.parse(raw) } catch {}
  const { movieIds, showIds } = CascadeCore.splitVideoLibraryIds([..._movieLibs, ..._showLibs], oldIds)
  if (movieIds.length) await window.cascade.store.set('movieLibraryIds', JSON.stringify(movieIds))
  if (showIds.length)  await window.cascade.store.set('showLibraryIds', JSON.stringify(showIds))
  await window.cascade.store.delete('videoLibraryIds')
}

async function loadVideoLibrarySelection() {
  const movieRaw = await window.cascade.store.get('movieLibraryIds')
  const showRaw  = await window.cascade.store.get('showLibraryIds')
  // null, not [], when the key is absent: never-chosen and chosen-none are
  // different answers, and only the first should default a sole library on.
  let movieSaved = null, showSaved = null
  try { movieSaved = movieRaw ? JSON.parse(movieRaw) : null } catch {}
  try { showSaved  = showRaw  ? JSON.parse(showRaw)  : null } catch {}

  // Sole library in a category defaults on, but can be turned off and stay off.
  // Otherwise whatever was saved, minus anything that has since vanished.
  jf.movieLibraryIds = CascadeCore.effectiveLibraryIds(_movieLibs, movieSaved)
  jf.showLibraryIds  = CascadeCore.effectiveLibraryIds(_showLibs, showSaved)

  renderVideoLibraryPicker()
  applyVideoNavVisibility()
}

// ── Poster grid grouping (Movies/TV with more than one library) ──────────────

/** Library ids collapsed in a grouped poster grid, persisted across restarts. */
let _collapsedLibs = new Set()

async function loadCollapsedLibs() {
  const raw = await window.cascade.store.get('collapsedLibs')
  let ids = []
  // The stored value is untrusted - anything but a plain array of strings
  // is treated as "nothing collapsed" rather than thrown or wedging the view.
  try { ids = JSON.parse(raw) } catch {}
  _collapsedLibs = new Set(Array.isArray(ids) ? ids.filter(id => typeof id === 'string') : [])
}

function saveCollapsedLibs() {
  window.cascade.store.set('collapsedLibs', JSON.stringify([..._collapsedLibs]))
}

/** Movies and TV Shows each only exist in the sidebar once that category is in
 *  play - either a library was selected, or there was only one to begin with.
 *  A music-only user should never see either nav row lead nowhere. */
function applyVideoNavVisibility() {
  const hasMovies = (jf.movieLibraryIds || []).length > 0
  const hasShows  = (jf.showLibraryIds  || []).length > 0
  // One class per category on <body>, CSS owns the rest - beats walking the
  // nav rows and setting inline styles on each.
  document.body.classList.toggle('has-movies', hasMovies)
  document.body.classList.toggle('has-shows', hasShows)
  // Leaving the user parked on a view whose nav row just disappeared would
  // strand them with no way back except another nav click.
  if (!hasMovies && _currentView === 'movies') showView('home')
  if (!hasShows  && _currentView === 'shows')  showView('home')
  // Same trigger drives the Music/Video mode toggle's own visibility and
  // forces Music mode once no video library is left - one mechanism, not two.
  refreshBrowseMode()
}

// ── Music / Video mode toggle ─────────────────────────────────────────────
//
// A persistent browsing filter, not a "what would you like to do this
// session" launch prompt - that option was put to the user and rejected in
// favor of this toggle, so it restores silently on launch instead of asking.
// Purely a sidebar/Home filter: never touches playback, the queue, or the
// player bar (see setBrowseMode - it only flips classes and attributes).

let _browseMode = 'music'

/** Applies `mode` to the DOM and, unless `skipSave`, persists it. skipSave is
 *  for refreshBrowseMode() re-deriving the mode from what's already saved -
 *  writing it back there would overwrite a saved "video" choice with "music"
 *  the instant the last video library is removed, losing the choice for good
 *  even if a video library is added back later. */
function setBrowseMode(mode, opts = {}) {
  _browseMode = mode
  document.body.classList.toggle('mode-video', mode === 'video')
  document.body.classList.toggle('mode-music', mode === 'music')
  const musicBtn = document.getElementById('mode-music-btn')
  const videoBtn = document.getElementById('mode-video-btn')
  musicBtn?.classList.toggle('active', mode === 'music')
  videoBtn?.classList.toggle('active', mode === 'video')
  musicBtn?.setAttribute('aria-pressed', String(mode === 'music'))
  videoBtn?.setAttribute('aria-pressed', String(mode === 'video'))
  if (!opts.skipSave) window.cascade.store.set('browseMode', mode)
}

/** Re-derives the effective mode from what's saved and whether a video
 *  library actually exists right now, and shows/hides the toggle itself to
 *  match. Called from applyVideoNavVisibility() so both stay in lockstep
 *  instead of drifting apart as two separate mechanisms. */
async function refreshBrowseMode() {
  const hasVideo = document.body.classList.contains('has-movies') || document.body.classList.contains('has-shows')
  document.getElementById('mode-toggle')?.classList.toggle('hidden', !hasVideo)
  const saved = await window.cascade.store.get('browseMode')
  setBrowseMode(CascadeCore.resolveBrowseMode(saved, hasVideo), { skipSave: true })
}

document.getElementById('mode-music-btn').addEventListener('click', () => setBrowseMode('music'))
document.getElementById('mode-video-btn').addEventListener('click', () => setBrowseMode('video'))

/** Renders one category's toggles into `list`, given its libraries, its
 *  currently selected ids, and what to call with the new list on change.
 *  Takes a container plus explicit data rather than reaching for a fixed id
 *  or a single global list, because two places show these (the Settings row
 *  and the one-time intro card) for two independent categories. */
function renderVideoLibraryRows(list, libs, ids, onChange) {
  if (!list) return
  list.innerHTML = libs.map(lib => `
    <div class="lib-check-row">
      <span class="lib-check-label" title="${esc(lib.Name)}">${esc(lib.Name)}</span>
      <label class="toggle">
        <input type="checkbox" value="${lib.Id}"${ids.includes(lib.Id) ? ' checked' : ''} />
        <span class="toggle-track"></span>
      </label>
    </div>`).join('')

  list.querySelectorAll('input[type=checkbox]').forEach(cb => {
    cb.onchange = () => onChange(
      [...list.querySelectorAll('input[type=checkbox]:checked')].map(c => c.value))
  })
}

/** Builds the Movies / TV Shows headings and toggle groups inside `container`.
 *  Every category holding at least one library is rendered, a sole one
 *  included: it defaults on, but turning video off has to be possible and this
 *  is the only place to do it. Shared by the Settings row and the intro card. */
function renderVideoLibraryGroups(container) {
  const section = (title, libs, cls) =>
    libs.length ? `<div class="lib-group-title">${title}</div><div class="${cls}"></div>` : ''
  container.innerHTML = [
    section('Movies', _movieLibs, 'vlib-movies'),
    section('TV Shows', _showLibs, 'vlib-shows'),
  ].join('')

  // Every category with a library gets real toggles, including a sole one:
  // turning video off entirely is a legitimate thing to want, and this is the
  // only place to do it.
  const fill = (cls, libs, ids, apply) => {
    const host = container.querySelector('.' + cls)
    if (host) renderVideoLibraryRows(host, libs, ids, apply)
  }
  fill('vlib-movies', _movieLibs, jf.movieLibraryIds || [],
    ids => applyVideoLibrarySelection('movie', ids))
  fill('vlib-shows', _showLibs, jf.showLibraryIds || [],
    ids => applyVideoLibrarySelection('show', ids))
}

function renderVideoLibraryPicker() {
  const row = document.getElementById('s-video-library-row')
  if (!row) return

  // Shown whenever the server has any video library at all, not only when a
  // category has a choice to make. Hiding it meant an account with one movie
  // library and one TV library had nowhere to see what was on, which read as
  // the section having vanished.
  const anyVideo = _movieLibs.length > 0 || _showLibs.length > 0
  row.style.display = anyVideo ? '' : 'none'
  if (!anyVideo) return

  renderVideoLibraryGroups(document.getElementById('s-video-library-list'))
}

// ── One-time video intro ──────────────────────────────────────────────────────
//
// Movies and TV are hidden until a library is picked, so without this the whole
// feature is invisible to anyone upgrading from a build that did not have it.
//
// Keyed on a feature flag, not a version comparison: the version is still moving
// during beta, and a `>= 1.3` check would simply never fire on 1.2.0. Same shape
// as `deviceIdMigrated`. To see it again, delete `videoIntroSeen` from the store.
async function maybeShowVideoIntro() {
  if (await window.cascade.store.get('videoIntroSeen')) return

  // A music-only Jellyfin has nothing to introduce. Logged because empty
  // _movieLibs/_showLibs is also what a failed /Views call looks like from
  // here, and the two are indistinguishable to anyone wondering where Movies went.
  if (!_movieLibs.length && !_showLibs.length) {
    console.info('[cascade] no movie or TV libraries on this server - skipping the video intro')
    return
  }

  // A category only needs the intro when it has a real choice (more than one
  // library) that has not been made yet. A sole library defaults on, so there
  // is no choice to put in front of anyone here (it can still be turned off
  // later in Settings); an already-made choice means they have found the
  // feature already. If neither category needs it, burn the flag quietly
  // rather than explaining something there's nothing left to configure for.
  const movieNeedsChoice = _movieLibs.length > 1 && !(jf.movieLibraryIds || []).length
  const showNeedsChoice  = _showLibs.length  > 1 && !(jf.showLibraryIds  || []).length
  if (!movieNeedsChoice && !showNeedsChoice) {
    await window.cascade.store.set('videoIntroSeen', true)
    return
  }

  renderVideoLibraryGroups(document.getElementById('vi-library-list'))
  document.getElementById('video-intro-overlay').classList.remove('hidden')
}

async function dismissVideoIntro() {
  await window.cascade.store.set('videoIntroSeen', true)
  document.getElementById('video-intro-overlay').classList.add('hidden')
}

document.getElementById('vi-done').addEventListener('click', dismissVideoIntro)
document.getElementById('vi-skip').addEventListener('click', dismissVideoIntro)

// ── Setup wizard ─────────────────────────────────────────────────────────────
//
// Runs on a genuine first run, and again after an update that added settings
// worth pointing at. Gated on a REVISION, not a boolean and not a version
// comparison: the app version keeps moving during beta, so a `>= 1.3` check
// would simply never fire on 1.2.0 - the same reasoning videoIntroSeen above
// is keyed on a feature flag for.
//
// Bump WIZARD_REVISION when the wizard starts covering something existing
// users have not been shown. Everyone whose stored revision is behind sees it
// once more, then never again until the next bump.
//
// Re-showing it to an existing user is only safe because every step seeds from
// the CURRENT live value rather than a default (see _renderSetupStep), so
// clicking straight through changes nothing. Do not add a step that writes a
// default on entry, or an update would quietly reset people's settings.
//
// This is why it can now be called from connect() rather than only from the
// interactive sign-in handlers: the revision does the "don't nag" work that
// the interactive-only rule used to do, and an ordinary launch on the current
// revision shows nothing.
//
// Every control writes through the exact function Settings itself calls
// (applyLibrarySelection, applyVideoLibrarySelection via renderVideoLibraryGroups,
// setCrossfadeEnabled, setCrossfadeSeconds, setMaxStreamingBitrate, setThemeMode,
// setAlbumArtAccent) - there is nothing here that persists a setting on its own.

// 1: the original first-run-only wizard (b6).
// 2: re-shown to everyone upgrading, for video libraries, crossfade, the
//    streaming cap and album art accent - none of which an existing user had
//    ever been walked through.
const WIZARD_REVISION = 2

const FIRSTRUN_STEPS = ['libraries', 'crossfade', 'quality', 'theme']
let _firstRunSteps = []
let _firstRunIdx = 0

/** The library step is only worth a screen when there is an actual choice -
 *  same rule maybeShowVideoIntro() uses for the categories it covers. */
function _firstRunNeedsLibraryStep() {
  return _musicLibs.length > 1 || _movieLibs.length > 1 || _showLibs.length > 1
}

/** Call before connect() from an interactive sign-in handler, never from a
 *  silent stored-token reconnect. Returns whether the wizard should run once
 *  connect() finishes, and pre-empts the older video intro when it does -
 *  the wizard's own library step already covers the same ground, so showing
 *  both back to back would just be two library pickers in a row. */
/** Which revision this install has already been shown. Absent means either a
 *  fresh install (0) or one from before revisions existed, which is revision 1
 *  if it had already completed the wizard. */
async function _wizardSeenRevision() {
  const raw = await window.cascade.store.get('wizardSeenRevision')
  const n = Number(raw)
  if (Number.isFinite(n) && n > 0) return n
  return (await window.cascade.store.get('firstRunWizardSeen')) ? 1 : 0
}

/** True on a genuine first run, as opposed to an update. Only changes the
 *  wording - an update must not be told "welcome". */
let _wizardIsFirstRun = true

async function maybeShowSetupWizard() {
  const seen = await _wizardSeenRevision()
  if (seen >= WIZARD_REVISION) return false
  _wizardIsFirstRun = seen === 0

  // The wizard's library step covers the same ground as the older video intro
  // card, so showing both back to back would be two library pickers in a row.
  await window.cascade.store.set('videoIntroSeen', true)

  _firstRunSteps = FIRSTRUN_STEPS.filter(s => s !== 'libraries' || _firstRunNeedsLibraryStep())
  _firstRunIdx = 0
  _renderSetupStep()
  document.getElementById('firstrun-overlay').classList.remove('hidden')
  return true
}

/** applyLibrarySelection(ids) refuses an empty selection by re-rendering
 *  Settings' own picker (#s-library-list) to snap back to what is actually
 *  selected - that does nothing for the wizard's own checkboxes, which live
 *  in a different container. Re-rendering this list after every change keeps
 *  it reflecting jf.libraryIds either way, including that snap-back. */
function _frRenderMusicList() {
  renderVideoLibraryRows(document.getElementById('fr-music-list'), _musicLibs, jf.libraryIds || [], async ids => {
    await applyLibrarySelection(ids)
    _frRenderMusicList()
  })
}

function _renderSetupStep() {
  const step = _firstRunSteps[_firstRunIdx]
  document.getElementById('fr-heading').textContent =
    _wizardIsFirstRun ? 'Set up Cascade' : 'New since your last update'
  document.getElementById('fr-subheading').textContent =
    'Your current settings are already filled in, so skipping changes nothing. All of it lives in Settings afterwards.'
  FIRSTRUN_STEPS.forEach(s => { document.getElementById(`fr-step-${s}`).style.display = s === step ? '' : 'none' })
  document.getElementById('fr-progress').textContent = `Step ${_firstRunIdx + 1} of ${_firstRunSteps.length}`
  document.getElementById('fr-next').textContent = _firstRunIdx === _firstRunSteps.length - 1 ? 'Done' : 'Next'

  if (step === 'libraries') {
    if (_musicLibs.length > 1) _frRenderMusicList()
    else document.getElementById('fr-music-list').innerHTML = ''
    renderVideoLibraryGroups(document.getElementById('fr-video-list'))
  } else if (step === 'crossfade') {
    document.getElementById('fr-crossfade-toggle').checked = crossfadeEnabled
    document.getElementById('fr-crossfade-duration-row').style.display = crossfadeEnabled ? '' : 'none'
    document.getElementById('fr-crossfade-duration').value = String(crossfadeSeconds)
    document.getElementById('fr-crossfade-duration-value').textContent = `${crossfadeSeconds}s`
  } else if (step === 'quality') {
    const i = Math.max(0, MAX_BITRATE_STEPS.findIndex(s => s.value === maxStreamingBitrate))
    document.getElementById('fr-max-bitrate').value = String(i)
    document.getElementById('fr-max-bitrate-value').textContent = MAX_BITRATE_STEPS[i].label
  } else if (step === 'theme') {
    const light = document.documentElement.getAttribute('data-theme') === 'light'
    document.getElementById('fr-seg-dark').classList.toggle('active', !light)
    document.getElementById('fr-seg-light').classList.toggle('active', light)
    document.getElementById('fr-toggle-album-art').checked = themeAlbumArt
  }
}

async function _finishSetupWizard() {
  await window.cascade.store.set('wizardSeenRevision', WIZARD_REVISION)
  // Kept in step so a downgrade to a build that only knows the boolean does not
  // greet an existing user with the wizard again.
  await window.cascade.store.set('firstRunWizardSeen', true)
  document.getElementById('firstrun-overlay').classList.add('hidden')
}

document.getElementById('fr-next').addEventListener('click', () => {
  if (_firstRunIdx < _firstRunSteps.length - 1) { _firstRunIdx++; _renderSetupStep() }
  else _finishSetupWizard()
})
// Skippable at any point, not just from the last step - whatever was already
// changed on an earlier step already went through its real setter above and
// stays changed; whatever step was never reached just keeps today's default.
document.getElementById('fr-skip').addEventListener('click', _finishSetupWizard)

document.getElementById('fr-crossfade-toggle').addEventListener('change', async e => {
  document.getElementById('fr-crossfade-duration-row').style.display = e.target.checked ? '' : 'none'
  await setCrossfadeEnabled(e.target.checked)
})
document.getElementById('fr-crossfade-duration').addEventListener('input', e => {
  document.getElementById('fr-crossfade-duration-value').textContent = `${e.target.value}s`
})
document.getElementById('fr-crossfade-duration').addEventListener('change', async e => {
  await setCrossfadeSeconds(parseInt(e.target.value, 10))
})

document.getElementById('fr-max-bitrate').addEventListener('input', e => {
  document.getElementById('fr-max-bitrate-value').textContent = MAX_BITRATE_STEPS[Number(e.target.value)].label
})
document.getElementById('fr-max-bitrate').addEventListener('change', async e => {
  await setMaxStreamingBitrate(MAX_BITRATE_STEPS[Number(e.target.value)].value)
})

document.getElementById('fr-seg-dark').addEventListener('click', () => {
  setThemeMode('dark'); saveTheme()
  document.getElementById('fr-seg-dark').classList.add('active')
  document.getElementById('fr-seg-light').classList.remove('active')
})
document.getElementById('fr-seg-light').addEventListener('click', () => {
  setThemeMode('light'); saveTheme()
  document.getElementById('fr-seg-light').classList.add('active')
  document.getElementById('fr-seg-dark').classList.remove('active')
})
document.getElementById('fr-toggle-album-art').addEventListener('change', e => setAlbumArtAccent(e.target.checked))

/** `category` is 'movie' or 'show' - the two hardcoded video categories. */
async function applyVideoLibrarySelection(category, ids) {
  const key = category === 'movie' ? 'movieLibraryIds' : 'showLibraryIds'
  jf[key] = ids
  await window.cascade.store.set(key, JSON.stringify(ids))
  invalidateVideoViews()
  applyVideoNavVisibility()
  renderVideoLibraryPicker()
  loadContinueWatching()
  loadRecentlyWatched()
}

document.getElementById('s-single-lib-toggle').addEventListener('change', async e => {
  singleLibraryMode = e.target.checked
  await window.cascade.store.set('singleLibraryMode', singleLibraryMode)
  // Collapsing to one keeps the first that was already on; expanding keeps it as the seed
  const ids = jf.libraryIds || []
  await applyLibrarySelection(singleLibraryMode ? ids.slice(0, 1) : ids)
})

// ── Sidebar expand/collapse ───────────────────────────────────────────────────

const sidenav = document.getElementById('sidenav')
const backdrop = document.getElementById('backdrop')

sidenav.addEventListener('mouseenter', () => {
  sidenav.classList.add('expanded')
  backdrop.classList.add('dim')
})
sidenav.addEventListener('mouseleave', () => {
  sidenav.classList.remove('expanded')
  backdrop.classList.remove('dim')
})
backdrop.addEventListener('click', () => {
  sidenav.classList.remove('expanded')
  backdrop.classList.remove('dim')
})

// ── View routing ──────────────────────────────────────────────────────────────

// Tracked so applyVideoNavVisibility() can tell whether the user is currently
// standing on a view it is about to hide.
let _currentView = 'home'

function showView(name) {
  // Deep links (search results, now-playing "view album", a resumed video
  // from Home) must never land on a view the current mode is hiding - switch
  // mode instead of leaving them on a view with no way to see it. Every
  // navigation in the app funnels through showView, so this one check covers
  // all of them.
  const targetMode = CascadeCore.sectionMode(name)
  if (targetMode && targetMode !== _browseMode) setBrowseMode(targetMode)

  document.querySelectorAll('.view').forEach(v => v.classList.remove('active'))
  document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'))
  document.getElementById(`view-${name}`).classList.add('active')
  document.querySelector(`[data-view="${name}"]`)?.classList.add('active')
  sidenav.classList.remove('expanded')
  backdrop.classList.remove('dim')
  _currentView = name

  if (name === 'albums' && !document.getElementById('albums-grid').dataset.loaded) loadAlbums()
  if (name === 'artists' && !document.getElementById('artists-grid').dataset.loaded) loadArtists()
  if (name === 'songs' && !document.getElementById('songs-rows').dataset.loaded) loadSongs()
  if (name === 'playlists' && !document.getElementById('playlists-grid').dataset.loaded) loadPlaylists()
  if (name === 'movies' && !document.getElementById('movies-grid').dataset.loaded) loadMovies()
  if (name === 'shows' && !document.getElementById('shows-grid').dataset.loaded) loadShows()
  if (name === 'settings') loadSettingsFields()
}

// Categories with an index/detail split - clicking the sidebar item again while
// already on that category clicks its own back button, which returns to the
// index. The back buttons are already idempotent (they just re-set the same
// display styles), so this is a no-op if you're already on the index.
const CATEGORY_BACK_BTN = {
  albums: 'album-back-btn',
  artists: 'artist-back-btn',
  playlists: 'pl-back-btn',
  movies: 'movie-back-btn',
  shows: 'show-back-btn'
}

document.querySelectorAll('.nav-item[data-view]').forEach(el => {
  el.addEventListener('click', () => {
    const name = el.dataset.view
    const wasActive = name === _currentView
    showView(name)
    if (wasActive && CATEGORY_BACK_BTN[name]) document.getElementById(CATEGORY_BACK_BTN[name]).click()
  })
})

// ── Home ──────────────────────────────────────────────────────────────────────

async function loadHome() {
  document.getElementById('greeting').textContent = `${greeting()}, ${await window.cascade.store.get('username') || 'there'}`

  loadRecentlyPlayed()
  loadRecentlyAdded()
  loadContinueWatching()
  loadRecentlyWatched()
}

async function loadRecentlyPlayed() {
  const grid = document.getElementById('rp-grid')
  try {
    const data = await jfGetMerged(`/Users/${jf.userId}/Items`, {
      SortBy: 'DatePlayed',
      SortOrder: 'Descending',
      IncludeItemTypes: 'Audio',
      Filters: 'IsPlayed',
      Limit: 24,
      Recursive: true,
      Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag,UserData'
    })
    // jfGetMerged concatenates per-library results, so the server's DatePlayed
    // ordering only holds within a library - re-sort across the merge.
    const items = (data.Items || [])
      .sort((a, b) => new Date(b.UserData?.LastPlayedDate || 0) - new Date(a.UserData?.LastPlayedDate || 0))
      .slice(0, 24)
    // Fetched wider than any row could show and clipped by CSS (.rp-grid), so
    // the row is always full at any window width instead of ragged.
    if (!items.length) { grid.innerHTML = '<div class="empty-state" style="grid-column:1/-1">No play history yet</div>'; return }
    grid.innerHTML = items.map(item => rpCard(item)).join('')
    grid.querySelectorAll('.rp-item').forEach((el, i) => {
      el.addEventListener('click', () => playItems(items, i))
    })
  } catch (e) {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">Could not load history</div>`
  }
}

function rpCard(item) {
  const art = artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
  const img = art ? `<img src="${art}" alt="" loading="lazy" onerror="this.style.display='none'">` : '♪'
  return `<div class="rp-item" data-id="${item.Id}">
    <div class="rp-art">${img}</div>
    <div style="min-width:0">
      <div class="rp-name">${esc(item.Name)}</div>
      <div class="rp-sub">${esc(item.AlbumArtist || item.Artists?.[0] || '')}</div>
    </div>
  </div>`
}

async function loadRecentlyAdded() {
  const grid = document.getElementById('home-recent-albums')
  try {
    const data = await jfGetMerged(`/Users/${jf.userId}/Items`, {
      SortBy: 'DateCreated',
      SortOrder: 'Descending',
      IncludeItemTypes: 'MusicAlbum',
      Limit: 24,
      Recursive: true,
      Fields: 'PrimaryImageAspectRatio'
    })
    // Fetched wider than any row could show and clipped by CSS (.album-grid on
    // #home-recent-albums), so the row is always full at any window width.
    if (!data.Items?.length) { grid.innerHTML = '<div class="empty-state" style="grid-column:1/-1">No albums yet</div>'; return }
    grid.innerHTML = data.Items.map(item => albumCard(item)).join('')
    grid.querySelectorAll('.album-card').forEach((el, i) => {
      el.addEventListener('click', () => { showView('albums'); openAlbum(data.Items[i].Id) })
    })
  } catch (e) {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">Could not load albums</div>`
  }
}

// ── Albums ────────────────────────────────────────────────────────────────────

// Fetch items across all selected libraries and merge, deduplicating by Id.
// `getAllPaged` is the same thing but keeps paging past params.Limit.
const jfGetMerged   = (path, params = {}) => jfClient.getMerged(path, params)
const jfGetAllPaged = (path, params = {}) => jfClient.getAllPaged(path, params)

async function loadAlbums() {
  const grid = document.getElementById('albums-grid')
  grid.dataset.loaded = '1'
  try {
    const params = { SortBy: 'SortName', SortOrder: 'Ascending', IncludeItemTypes: 'MusicAlbum', Recursive: true, Fields: 'PrimaryImageAspectRatio', Limit: 200 }
    const data = await jfGetMerged(`/Users/${jf.userId}/Items`, params)
    grid.innerHTML = data.Items.map(item => albumCard(item)).join('')
    grid.querySelectorAll('.album-card').forEach((el, i) => {
      el.addEventListener('click', () => { showView('albums'); openAlbum(data.Items[i].Id) })
    })
  } catch (e) {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">Could not load albums</div>`
  }
}

function albumCard(item, opts = {}) {
  const art = artUrl(item.Id, item.ImageTags?.Primary)
  const img = art ? `<img src="${art}" alt="" loading="lazy" onerror="this.style.display='none'">` : '♪'
  const idAttr = opts.idAttr || 'data-id'
  return `<div class="album-card" ${idAttr}="${item.Id}">
    <div class="album-art">${img}</div>
    <div class="album-body">
      <div class="album-name">${esc(item.Name)}</div>
      <div class="album-artist">${esc(item.AlbumArtist || '')}</div>
    </div>
  </div>`
}

// idAttr lets search results use data-search-artist instead of data-id.
function artistCardHtml(item, opts = {}) {
  const art = artistArtUrl(item.Id)
  const idAttr = opts.idAttr || 'data-id'
  return `<div class="artist-card" ${idAttr}="${item.Id}" data-name="${esc(item.Name)}">
    <div class="artist-avatar"><img src="${art}" alt="" loading="lazy" onerror="this.style.display='none'"></div>
    <div class="artist-name">${esc(item.Name)}</div>
  </div>`
}

let currentAlbumTracks = []

async function openAlbum(albumId) {
  document.getElementById('albums-index').style.display = 'none'
  const detail = document.getElementById('album-detail')
  detail.style.display = ''
  document.getElementById('album-detail-name').textContent = ''
  document.getElementById('album-detail-meta').innerHTML = '<span class="skel skel-text" style="display:inline-block;width:120px"></span>'
  document.getElementById('album-detail-rows').innerHTML = skeletonHTML('track', 6)
  document.getElementById('album-detail-art').innerHTML = '♪'

  try {
    const [album, tracksData] = await Promise.all([
      jfGet(`/Users/${jf.userId}/Items/${albumId}`),
      jfGet(`/Users/${jf.userId}/Items`, {
        ParentId: albumId,
        SortBy: 'ParentIndexNumber,IndexNumber,SortName',
        IncludeItemTypes: 'Audio',
        Recursive: true,
        Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag'
      })
    ])
    const tracks = tracksData.Items || []
    currentAlbumTracks = tracks

    document.getElementById('album-detail-name').textContent = album.Name || ''
    const artistHtml = album.AlbumArtist
      ? `<span class="row-link" data-artist-link="${esc(album.AlbumArtist)}" tabindex="0">${esc(album.AlbumArtist)}</span>`
      : ''
    const meta = [artistHtml, album.ProductionYear, `${tracks.length} song${tracks.length !== 1 ? 's' : ''}`].filter(Boolean)
    document.getElementById('album-detail-meta').innerHTML = meta.join(' · ')

    const art = artUrl(album.Id, album.ImageTags?.Primary)
    document.getElementById('album-detail-art').innerHTML = art ? `<img src="${art}" alt="" onerror="this.innerHTML='♪'">` : '♪'

    document.getElementById('album-detail-rows').innerHTML = tracks.map((item, i) => trackRowHtml(item, i)).join('')
    highlightPlayingRow()

    document.getElementById('album-detail-rows').querySelectorAll('.track-row').forEach(el => {
      const idx = parseInt(el.dataset.idx)
      wireTrackRow(el, tracks[idx], tracks, idx)
    })
  } catch (e) {
    document.getElementById('album-detail-meta').textContent = 'Could not load album'
  }
}

document.getElementById('album-back-btn').addEventListener('click', () => {
  document.getElementById('album-detail').style.display = 'none'
  document.getElementById('albums-index').style.display = ''
})

// Album detail's artist name - opens the artist page via the same path as the
// track context menu's "View artist" (openArtistFromTrack matches by name).
document.getElementById('album-detail-meta').addEventListener('click', e => {
  const link = e.target.closest('[data-artist-link]')
  if (!link) return
  openArtistFromTrack({ AlbumArtist: link.dataset.artistLink })
})
document.getElementById('album-detail-meta').addEventListener('keydown', e => {
  if (e.key !== 'Enter' && e.key !== ' ') return
  if (!e.target.closest('[data-artist-link]')) return
  e.preventDefault()
  e.target.click()
})

document.getElementById('btn-play-album').addEventListener('click', () => {
  if (currentAlbumTracks.length) playItems(currentAlbumTracks, 0)
})

// ── Artists ───────────────────────────────────────────────────────────────────

async function loadArtists() {
  const grid = document.getElementById('artists-grid')
  grid.dataset.loaded = '1'
  try {
    const params = { UserId: jf.userId, SortBy: 'SortName', SortOrder: 'Ascending', Limit: 200 }
    const data = await jfGetMerged(`/Artists`, params)
    grid.innerHTML = data.Items.map(item => artistCardHtml(item)).join('')
    grid.querySelectorAll('.artist-card').forEach(el => {
      el.addEventListener('click', () => openArtist(el.dataset.id, el.dataset.name))
    })
  } catch (e) {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">Could not load artists</div>`
  }
}

async function openArtist(artistId, name) {
  document.getElementById('artist-index').style.display = 'none'
  const detail = document.getElementById('artist-detail')
  detail.style.display = ''
  document.getElementById('artist-detail-name').textContent = name
  document.getElementById('artist-detail-meta').innerHTML = '<span class="skel skel-text" style="display:inline-block;width:120px"></span>'
  document.getElementById('artist-albums-grid').innerHTML = skeletonHTML('album', 6)
  document.getElementById('artist-songs-rows').innerHTML = skeletonHTML('track', 6)

  const art = artistArtUrl(artistId)
  document.getElementById('artist-detail-art').innerHTML = `<img src="${art}" alt="" onerror="this.innerHTML='♪'" style="width:100%;height:100%;object-fit:cover;border-radius:50%">`

  try {
    const [albumsData, songsData] = await Promise.all([
      jfGet(`/Users/${jf.userId}/Items`, {
        ArtistIds: artistId, IncludeItemTypes: 'MusicAlbum', Recursive: true,
        SortBy: 'ProductionYear,SortName', SortOrder: 'Descending',
        Fields: 'PrimaryImageAspectRatio'
      }),
      jfGet(`/Users/${jf.userId}/Items`, {
        ArtistIds: artistId, IncludeItemTypes: 'Audio', Recursive: true,
        SortBy: 'Album,ParentIndexNumber,IndexNumber',
        Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag'
      })
    ])

    const songs  = songsData.Items  || []
    const albums = albumsData.Items || []

    document.getElementById('artist-detail-meta').textContent =
      `${albums.length} album${albums.length !== 1 ? 's' : ''} · ${songs.length} song${songs.length !== 1 ? 's' : ''}`

    // Albums grid
    document.getElementById('artist-albums-grid').innerHTML = albums.map(item => albumCard(item)).join('')
    document.getElementById('artist-albums-grid').querySelectorAll('.album-card').forEach((el, i) => {
      el.addEventListener('click', () => { showView('albums'); openAlbum(albums[i].Id) })
    })

    // Play all button
    document.getElementById('btn-play-artist-discography').onclick = () => {
      if (songs.length) playItems(songs, 0)
    }

    // Songs list
    document.getElementById('artist-songs-rows').innerHTML = songs.map((item, i) => trackRowHtml(item, i)).join('')
    highlightPlayingRow()

    document.getElementById('artist-songs-rows').querySelectorAll('.track-row').forEach(el => {
      const idx = parseInt(el.dataset.idx)
      wireTrackRow(el, songs[idx], songs, idx)
    })
  } catch (e) {
    document.getElementById('artist-detail-meta').textContent = 'Could not load artist'
  }
}

document.getElementById('artist-back-btn').addEventListener('click', () => {
  document.getElementById('artist-detail').style.display = 'none'
  document.getElementById('artist-index').style.display = ''
})

// ── Track row helpers ─────────────────────────────────────────────────────────

// Shared thumb HTML - includes the EQ bars for the now-playing animation
function trackThumbHtml(art) {
  const img = art ? `<img src="${art}" alt="" loading="lazy" onerror="this.style.display='none'">` : ''
  return `<div class="track-thumb">${img}<span class="track-eq"><i></i><i></i><i></i></span></div>`
}

// Shared track-row markup. opts: idxAttr (default 'data-idx'), extraClass, entryId, style.
function trackRowHtml(item, i, opts = {}) {
  const art = artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
  const idxAttr   = opts.idxAttr || 'data-idx'
  const cls       = 'track-row' + (opts.extraClass || '')
  const entryAttr = opts.entryId != null ? ` data-entry-id="${opts.entryId}"` : ''
  const styleAttr = opts.style ? ` style="${opts.style}"` : ''
  const dragAttr  = opts.draggable ? ' draggable="true"' : ''
  // Artist/album cells are only clickable when there's something to open -
  // a track with a name but no linked artist/album must not look clickable.
  const artistName  = item.AlbumArtist || item.Artists?.[0] || ''
  const artistCls    = artistName ? ' row-link' : ''
  const artistAttrs  = artistName ? ' data-artist-link tabindex="0"' : ''
  const albumCls     = item.AlbumId ? ' row-link' : ''
  const albumAttrs   = item.AlbumId ? ' data-album-link tabindex="0"' : ''
  // Both are playlist-detail-only (opts.checkbox / opts.extraVal never set
  // elsewhere), so Songs/Albums/Artists rows are byte-for-byte unchanged.
  // draggable="false" on the checkbox cell stops a checkbox click/drag from
  // being swallowed as a row-reorder drag when the row itself is draggable.
  const checkHtml = opts.checkbox
    ? `<div class="tl-check" draggable="false"><input type="checkbox"${opts.checked ? ' checked' : ''}></div>` : ''
  const extraHtml = opts.extraVal != null
    ? `<div class="tl-extra">${esc(opts.extraVal)}</div>` : ''
  return `<div class="${cls}" ${idxAttr}="${i}" data-id="${item.Id}"${entryAttr}${styleAttr}${dragAttr}>
    ${checkHtml}
    <div class="track-num">${i + 1}</div>
    ${trackThumbHtml(art)}
    <div style="min-width:0">
      <div class="track-title">${esc(item.Name)}</div>
      <div class="track-artist${artistCls}"${artistAttrs}>${esc(artistName)}</div>
    </div>
    <div class="track-album-name${albumCls}"${albumAttrs}>${esc(item.Album || '')}</div>
    ${extraHtml}
    <div class="track-dur">${fmtTime((item.RunTimeTicks || 0) / 10000000)}</div>
  </div>`
}

// ── Songs ─────────────────────────────────────────────────────────────────────

let allSongs = []

async function loadSongs() {
  const rows = document.getElementById('songs-rows')
  rows.dataset.loaded = '1'
  await loadSongsSortPrefs()
  updateSongsSortUI()
  try {
    // jfGetAllPaged instead of jfGetMerged so libraries over 500 tracks aren't
    // silently truncated (same fix as shuffleAllSongs).
    const params = { SortBy: 'SortName', SortOrder: 'Ascending', IncludeItemTypes: 'Audio', Recursive: true, Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag,UserData,DateCreated', Limit: 500 }
    const data = await jfGetAllPaged(`/Users/${jf.userId}/Items`, params)
    allSongs = data.Items || []
    sortAllSongs()
    renderSongRows()
  } catch (e) {
    rows.innerHTML = `<div class="empty-state">Could not load songs</div>`
  }
}

// ── Songs sort ────────────────────────────────────────────────────────────────

let songsSortField = 'name'   // 'name' | 'artist' | 'album' | 'added' | 'played'
let songsSortDir   = 'asc'    // 'asc' | 'desc'

const SONG_SORT_LABELS = {
  name: 'Title', artist: 'Artist', album: 'Album', added: 'Date added', played: 'Date last played'
}

async function loadSongsSortPrefs() {
  songsSortField = (await window.cascade.store.get('songsSortField')) || 'name'
  songsSortDir   = (await window.cascade.store.get('songsSortDir'))   || 'asc'
}

// sortSongs / songSortValue now come from CascadeCore (src/core/queue.ts).
// Core takes the field and direction explicitly rather than reading globals, so
// call sites pass songsSortField/songsSortDir. It still sorts in place, which
// matters: other code holds a reference to `allSongs`.
const sortAllSongs = () => sortSongs(allSongs, songsSortField, songsSortDir)

function updateSongsSortUI() {
  document.getElementById('songs-sort-label').textContent = SONG_SORT_LABELS[songsSortField]
  document.querySelectorAll('#songs-sort-dropdown [data-sort-field]').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.sortField === songsSortField)
  })
  document.getElementById('songs-sort-dir-label').textContent = songsSortDir === 'desc' ? 'Descending' : 'Ascending'
  document.getElementById('songs-sort-dir-icon').style.transform = songsSortDir === 'desc' ? 'rotate(180deg)' : ''
}

function resortSongsAndRerender() {
  sortAllSongs()
  updateSongsSortUI()
  if (document.getElementById('songs-rows').dataset.loaded) renderSongRows()
}

const songsSortDropdown = document.getElementById('songs-sort-dropdown')

document.getElementById('btn-sort-songs').addEventListener('click', (e) => {
  e.stopPropagation()
  const isOpen = songsSortDropdown.classList.contains('open')
  songsSortDropdown.classList.toggle('open', !isOpen)
  if (!isOpen) {
    const btn = e.currentTarget.getBoundingClientRect()
    songsSortDropdown.style.left = `${btn.left}px`
    songsSortDropdown.style.top  = `${btn.bottom + 6}px`
    const r = songsSortDropdown.getBoundingClientRect()
    if (r.right > window.innerWidth - 8) songsSortDropdown.style.left = `${window.innerWidth - songsSortDropdown.offsetWidth - 8}px`
    if (r.bottom > window.innerHeight - 8) songsSortDropdown.style.top = `${btn.top - songsSortDropdown.offsetHeight - 6}px`
  }
})

songsSortDropdown.querySelectorAll('[data-sort-field]').forEach(btn => {
  btn.addEventListener('click', (e) => {
    e.stopPropagation()
    songsSortField = btn.dataset.sortField
    window.cascade.store.set('songsSortField', songsSortField)
    resortSongsAndRerender()
  })
})

document.getElementById('songs-sort-dir-toggle').addEventListener('click', (e) => {
  e.stopPropagation()
  songsSortDir = songsSortDir === 'desc' ? 'asc' : 'desc'
  window.cascade.store.set('songsSortDir', songsSortDir)
  resortSongsAndRerender()
})

document.addEventListener('mousedown', (e) => {
  if (!songsSortDropdown.contains(e.target) && !e.target.closest('#btn-sort-songs')) {
    songsSortDropdown.classList.remove('open')
  }
})

// Songs list virtualisation - with large libraries (1000+ tracks) rendering
// every row up front means thousands of DOM nodes, event listeners and
// simultaneous art requests. Only a scrolled window of rows is kept mounted,
// same approach as the queue panel (_drawQueueRows), except the scrollable
// element here is the ancestor `.view`, not #songs-rows itself.
const SONG_ROW_H  = 45   // must match .track-row's CSS height
const SONG_WIN    = 40   // rows kept in DOM at once
const SONG_BEFORE = 8    // rows to keep rendered above the visible top
let _songsWinStart    = 0
let _songsScrollBound = false
let _songsRowsOffset  = 0   // distance from top of view's scrollable content to #songs-rows

function renderSongRows() {
  const rows = document.getElementById('songs-rows')
  const view = document.getElementById('view-songs')

  if (!allSongs.length) { rows.style.height = ''; rows.innerHTML = '<div class="empty-state">No songs found</div>'; return }

  rows.style.height = `${allSongs.length * SONG_ROW_H}px`
  // getBoundingClientRect (unlike offsetTop) accounts for the ancestor's current
  // scroll, so adding view.scrollTop back converts to scroll-independent content space.
  _songsRowsOffset = rows.getBoundingClientRect().top - view.getBoundingClientRect().top + view.scrollTop

  if (!_songsScrollBound) {
    _songsScrollBound = true
    view.addEventListener('scroll', () => {
      if (!allSongs.length) return
      const relTop   = view.scrollTop - _songsRowsOffset
      const visStart = Math.floor(Math.max(0, relTop) / SONG_ROW_H)
      const visEnd   = visStart + Math.ceil(view.clientHeight / SONG_ROW_H)
      const nearTop  = visStart < _songsWinStart + 3
      const nearBot  = visEnd   > _songsWinStart + SONG_WIN - 3
      if (nearTop || nearBot) {
        _songsWinStart = Math.max(0, Math.min(visStart - SONG_BEFORE, allSongs.length - SONG_WIN))
        _drawSongRows(rows)
      }
    }, { passive: true })

    // Delegated row interactions - bound once on the container instead of
    // re-attaching 4 listeners per row on every virtualization redraw (which
    // fires repeatedly while scrolling a large library).
    rows.addEventListener('click', (e) => {
      const el = e.target.closest('.track-row')
      if (!el) return
      const idx = parseInt(el.dataset.idx)
      if (e.target.closest('.track-thumb')) {
        e.stopPropagation()
        playItems(allSongs, idx)
        return
      }
      if (e.target.closest('[data-album-link]')) { e.stopPropagation(); openAlbumFromTrack(allSongs[idx]); return }
      if (e.target.closest('[data-artist-link]')) { e.stopPropagation(); openArtistFromTrack(allSongs[idx]); return }
      document.querySelectorAll('.track-row.selected').forEach(r => r.classList.remove('selected'))
      el.classList.add('selected')
    })
    rows.addEventListener('dblclick', (e) => {
      if (e.target.closest('.row-link')) return
      const el = e.target.closest('.track-row')
      if (!el) return
      playItems(allSongs, parseInt(el.dataset.idx))
    })
    rows.addEventListener('contextmenu', (e) => {
      const el = e.target.closest('.track-row')
      if (!el) return
      e.preventDefault()
      const idx = parseInt(el.dataset.idx)
      showTrackCtxMenu(allSongs[idx], el, e.clientX, e.clientY, false)
    })
    // Keyboard access for the album/artist links (Enter/Space triggers the same click path above)
    rows.addEventListener('keydown', (e) => {
      if (e.key !== 'Enter' && e.key !== ' ') return
      const link = e.target.closest('.row-link')
      if (!link) return
      e.preventDefault()
      link.click()
    })
  }

  _songsWinStart = 0
  _drawSongRows(rows)
}

function _drawSongRows(rows) {
  const winEnd    = Math.min(allSongs.length, _songsWinStart + SONG_WIN)
  const currentId = queue[queueIndex]?.Id

  rows.innerHTML = allSongs.slice(_songsWinStart, winEnd).map((item, offset) => {
    const i = _songsWinStart + offset
    const extraClass = currentId && item.Id === currentId ? ' playing' : ''
    return trackRowHtml(item, i, { extraClass, style: `top:${i * SONG_ROW_H}px` })
  }).join('')
}

// ── Playlists ─────────────────────────────────────────────────────────────────

async function loadPlaylists() {
  const grid = document.getElementById('playlists-grid')
  grid.dataset.loaded = '1'
  const smartHtml = smartPlaylistCardHtml('favorites') + smartPlaylistCardHtml('most-played')
  try {
    const data = await jfGet(`/Users/${jf.userId}/Items`, {
      SortBy: 'SortName',
      SortOrder: 'Ascending',
      IncludeItemTypes: 'Playlist',
      Recursive: true,
      Fields: 'PrimaryImageAspectRatio,ChildCount'
    })
    grid.innerHTML = smartHtml + (data.Items || []).map(item => {
      const art = artUrl(item.Id, item.ImageTags?.Primary)
      const img = art ? `<img src="${art}" alt="" loading="lazy" onerror="this.style.display='none'">` : '♪'
      const count = item.ChildCount != null ? `${item.ChildCount} songs` : ''
      return `<div class="playlist-card" data-id="${item.Id}" data-name="${esc(item.Name)}">
        <div class="playlist-art">${img}</div>
        <div class="playlist-body">
          <div class="playlist-name">${esc(item.Name)}</div>
          <div class="playlist-count">${count}</div>
        </div>
      </div>`
    }).join('')
    grid.querySelectorAll('[data-id]').forEach(el => {
      el.addEventListener('click', () => openPlaylist(el.dataset.id, el.dataset.name))
    })
    grid.querySelectorAll('[data-smart]').forEach(el => {
      el.addEventListener('click', () => openSmartPlaylist(el.dataset.smart))
    })
  } catch (e) {
    grid.innerHTML = smartHtml + `<div class="empty-state" style="grid-column:1/-1">Could not load playlists</div>`
    grid.querySelectorAll('[data-smart]').forEach(el => {
      el.addEventListener('click', () => openSmartPlaylist(el.dataset.smart))
    })
  }
}

let currentPlaylistId = null
let currentPlaylistItems = []
let currentSmartKind = null // set while a SMART_PLAYLISTS entry is open, so refresh knows how to re-fetch it

// Single choke point every playlist-mutating action (add/remove a track) routes
// through, so the common case updates without the user pressing anything.
// Lazily invalidates the index grid's cache (it re-fetches next time the Playlists
// tab is shown, same pattern as invalidateLibraryViews) and, if the mutated playlist
// is the one currently open in detail, refreshes that detail in place.
function playlistMutated(playlistId) {
  delete document.getElementById('playlists-grid').dataset.loaded
  if (playlistId && playlistId === currentPlaylistId) return refreshPlaylistDetail()
}

// Re-fetches whatever is open in the playlist detail view and re-renders it in place.
// Shared by playlistMutated() above and the manual refresh button below, so add/remove
// and the manual escape hatch (server changed underneath us) go through one fetch+render
// path and both rebind wirePlaylistRowDrag the same way renderPlaylistDetailItems always does.
async function refreshPlaylistDetail() {
  if (!currentPlaylistId && !currentSmartKind) return
  const scrollEl = document.getElementById('view-playlists')
  const scrollTop = scrollEl.scrollTop
  try {
    if (currentSmartKind) {
      renderPlaylistDetailItems(await SMART_PLAYLISTS[currentSmartKind].fetch(), false)
    } else {
      const data = await jfGet(`/Playlists/${currentPlaylistId}/Items`, {
        UserId: jf.userId,
        Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag,DateCreated'
      })
      renderPlaylistDetailItems(data.Items || [], true)
    }
  } catch (e) {
    showNotice('Could not refresh this playlist.', 'Playlist')
  }
  scrollEl.scrollTop = scrollTop
}

let _plDetailRefreshing = false
document.getElementById('pl-detail-refresh').addEventListener('click', async () => {
  if (_plDetailRefreshing) return
  _plDetailRefreshing = true
  await refreshPlaylistDetail()
  _plDetailRefreshing = false
})

// ── Edit Playlist mode ──────────────────────────────────────────────────────
// Rename, public/private, bulk remove, bulk move-to-top/bottom. Drag-to-reorder
// (wirePlaylistRowDrag above) stays live the whole time it's already the fine-
// grained reorder tool; edit mode only adds the bulk one. Every write here goes
// through the same playlistMutated() choke point as everything else, so
// currentPlaylistItems never drifts from what the server has.
let plEditMode = false
let plEditSelected = new Set() // entry ids (entryIdOf) of checked rows
let plCurrentIsPublic = false  // last-known IsPublic, read when edit mode opens

function updatePlEditToolbar() {
  const n = plEditSelected.size
  const total = currentPlaylistItems.length
  document.getElementById('pl-edit-count').textContent = `${n} selected`
  document.getElementById('pl-edit-top').disabled = !n
  document.getElementById('pl-edit-bottom').disabled = !n
  document.getElementById('pl-edit-remove').disabled = !n
  const selectAll = document.getElementById('pl-select-all')
  selectAll.checked = n > 0 && n === total
  selectAll.indeterminate = n > 0 && n < total
}

function enterPlEditMode() {
  plEditMode = true
  plEditSelected.clear()
  document.getElementById('playlist-detail').classList.add('edit-mode')
  document.getElementById('pl-edit-toolbar').classList.add('visible')
  document.getElementById('btn-edit-playlist').textContent = 'Done'
  renderPlaylistDetailItems(currentPlaylistItems, true)
  updatePlEditToolbar()
}

// silent: skip the re-render (used from showPlaylistDetailShell, where the
// old items are about to be thrown away by a fresh fetch anyway).
function exitPlEditMode(silent) {
  const wasActive = plEditMode
  plEditMode = false
  plEditSelected.clear()
  document.getElementById('playlist-detail').classList.remove('edit-mode')
  document.getElementById('pl-edit-toolbar').classList.remove('visible')
  document.getElementById('btn-edit-playlist').textContent = 'Edit'
  if (!silent && wasActive) renderPlaylistDetailItems(currentPlaylistItems, !!currentPlaylistId)
}

document.getElementById('btn-edit-playlist').addEventListener('click', async () => {
  if (plEditMode) { exitPlEditMode(); return }
  if (!currentPlaylistId) return // smart playlists hide this button; nothing to edit
  // Ownership: Jellyfin has no dedicated "do you own this playlist" field, but
  // item DTOs carry CanDelete - the same permission Jellyfin itself uses to
  // gate deleting/managing an item, computed server-side for the current user.
  // An explicit false is trusted and blocks entry. Anything else (true, or
  // missing on an older server) offers Edit mode anyway; a write it isn't
  // allowed to make then fails loudly via the catch blocks below, same as
  // remove-from-playlist and drag-reorder already do for every playlist today.
  try {
    const it = await jfGet(`/Users/${jf.userId}/Items/${currentPlaylistId}`)
    if (it.CanDelete === false) {
      showNotice('You do not have permission to edit this playlist.', 'Playlist')
      return
    }
    plCurrentIsPublic = !!it.IsPublic
  } catch (e) {
    plCurrentIsPublic = false
  }
  enterPlEditMode()
})

document.getElementById('pl-select-all').addEventListener('change', (e) => {
  if (e.target.checked) currentPlaylistItems.forEach(i => plEditSelected.add(entryIdOf(i)))
  else plEditSelected.clear()
  renderPlaylistDetailItems(currentPlaylistItems, true)
  updatePlEditToolbar()
})

// Rewrites Ids wholesale (one atomic request) rather than firing per-row
// Move/DELETE calls. Built from currentPlaylistItems after applying the change
// locally, then playlistMutated() re-reads from the server so the view and
// currentPlaylistItems never disagree with what actually saved.
async function savePlaylistIds(newItems, successMsg) {
  try {
    const res = await fetch(`${jf.url}/Playlists/${currentPlaylistId}`, {
      method: 'POST',
      headers: { 'X-Emby-Token': jf.token, 'Content-Type': 'application/json' },
      body: JSON.stringify({ Ids: newItems.map(i => i.Id) })
    })
    if (!res.ok) throw new Error(await CascadeCore.readErrorMessage(res))
    showToast(successMsg)
    plEditSelected.clear()
    updatePlEditToolbar()
    await playlistMutated(currentPlaylistId)
  } catch (e) {
    showNotice(`Could not update the playlist.\n\n${e.message}`, 'Playlist')
  }
}

document.getElementById('pl-edit-remove').addEventListener('click', () => {
  if (!plEditSelected.size) return
  const n = plEditSelected.size
  savePlaylistIds(removeSelected(currentPlaylistItems, plEditSelected), `Removed ${n} track${n === 1 ? '' : 's'}`)
})
document.getElementById('pl-edit-top').addEventListener('click', () => {
  if (!plEditSelected.size) return
  savePlaylistIds(moveSelectedToTop(currentPlaylistItems, plEditSelected), 'Moved to top')
})
document.getElementById('pl-edit-bottom').addEventListener('click', () => {
  if (!plEditSelected.size) return
  savePlaylistIds(moveSelectedToBottom(currentPlaylistItems, plEditSelected), 'Moved to bottom')
})

// Rename + public/private. One small modal for both since they're the same
// UpdatePlaylistDto request - reuses .modal-overlay/.modal-card/.modal-input/
// .modal-btn verbatim (no new modal CSS) and the existing .toggle switch used
// throughout Settings.
document.getElementById('pl-edit-props').addEventListener('click', () => {
  document.getElementById('pl-edit-name').value = document.getElementById('pl-detail-name').textContent
  document.getElementById('pl-edit-public').checked = plCurrentIsPublic
  document.getElementById('pl-edit-modal').classList.remove('hidden')
})
document.getElementById('pl-edit-cancel').addEventListener('click', () => {
  document.getElementById('pl-edit-modal').classList.add('hidden')
})
document.getElementById('pl-edit-save').addEventListener('click', async () => {
  const name = document.getElementById('pl-edit-name').value.trim()
  if (!name) { showNotice('Playlist name cannot be empty.', 'Playlist'); return }
  const isPublic = document.getElementById('pl-edit-public').checked
  try {
    const res = await fetch(`${jf.url}/Playlists/${currentPlaylistId}`, {
      method: 'POST',
      headers: { 'X-Emby-Token': jf.token, 'Content-Type': 'application/json' },
      body: JSON.stringify({ Name: name, IsPublic: isPublic })
    })
    if (!res.ok) throw new Error(await CascadeCore.readErrorMessage(res))
    plCurrentIsPublic = isPublic
    document.getElementById('pl-detail-name').textContent = name
    document.getElementById('pl-edit-modal').classList.add('hidden')
    showToast('Playlist updated')
    await playlistMutated(currentPlaylistId)
  } catch (e) {
    showNotice(`Could not update the playlist.\n\n${e.message}`, 'Playlist')
  }
})

function showPlaylistDetailShell(name) {
  document.getElementById('playlist-index').style.display = 'none'
  const detail = document.getElementById('playlist-detail')
  detail.classList.add('active')
  exitPlEditMode(true) // reset edit-mode UI left over from whatever was open before
  document.getElementById('pl-detail-name').textContent = name
  document.getElementById('pl-detail-meta').innerHTML = '<span class="skel skel-text" style="display:inline-block;width:70px"></span>'
  // has-extra-col decides the row's grid columns and is only set once the items
  // resolve, so leaving the previous playlist's value on would lay the skeleton
  // out for a column this one may not have.
  detail.classList.remove('has-extra-col')
  document.getElementById('pl-detail-rows').innerHTML = skeletonHTML('track', 6)
}

// Shared by real playlists and smart playlists - populates the track list once
// items are resolved. entryIds controls whether rows get a real playlist entry ID
// (needed for "Remove from playlist") - smart playlists aren't real Jellyfin
// playlists, so there's nothing to remove an entry from.
//
// Also decides the one extra column playlists can show: Most Played gets a
// Plays count (already in UserData.PlayCount, nothing new to fetch); real
// playlists get a "date added" column - except Jellyfin's playlist-items
// endpoint carries no per-entry added-to-playlist date (checked: BaseItemDto
// there is the plain track DTO plus PlaylistItemId, nothing else). Rather than
// fake that or quietly pass off DateCreated as the answer, it's shown labelled
// as what it actually is: when the track was added to the server library.
function renderPlaylistDetailItems(items, entryIds) {
  currentPlaylistItems = items
  document.getElementById('pl-detail-meta').textContent = `${items.length} song${items.length !== 1 ? 's' : ''}`
  const extraKind = entryIds ? 'added' : (currentSmartKind === 'most-played' ? 'plays' : null)
  document.getElementById('playlist-detail').classList.toggle('has-extra-col', !!extraKind)
  const headExtra = document.getElementById('pl-head-extra')
  // "Added (server)", not "Added": the distinction is the whole point of the
  // column, since Jellyfin has no per-playlist add date and this one is the
  // library date. The full explanation stays in the title below.
  headExtra.textContent = extraKind === 'plays' ? 'Plays' : extraKind === 'added' ? 'Added (server)' : ''
  headExtra.title = extraKind === 'added'
    ? 'When this track was added to the Jellyfin server library, not when it was added to this playlist - Jellyfin does not expose a per-playlist add date.'
    : ''
  const showCheck = entryIds && plEditMode
  document.getElementById('pl-detail-rows').innerHTML = items.map((item, i) => {
    const extraVal = extraKind === 'plays' ? String(item.UserData?.PlayCount || 0)
      : extraKind === 'added' ? (item.DateCreated ? new Date(item.DateCreated).toLocaleDateString() : '—')
      : null
    if (!entryIds) return trackRowHtml(item, i, { extraVal })
    const entryId = entryIdOf(item)
    return trackRowHtml(item, i, {
      entryId, draggable: true, extraVal,
      checkbox: showCheck, checked: plEditSelected.has(entryId)
    })
  }).join('')
  const rowsEl = document.getElementById('pl-detail-rows')
  rowsEl.querySelectorAll('.track-row').forEach(el => {
    const idx = parseInt(el.dataset.idx)
    wireTrackRow(el, items[idx], items, idx, { inPlaylist: entryIds })
  })
  if (showCheck) {
    rowsEl.querySelectorAll('.tl-check input[type=checkbox]').forEach(cb => {
      cb.addEventListener('click', e => e.stopPropagation())
      cb.addEventListener('change', e => {
        const entryId = e.target.closest('.track-row').dataset.entryId
        if (e.target.checked) plEditSelected.add(entryId)
        else plEditSelected.delete(entryId)
        updatePlEditToolbar()
      })
    })
  }
  // Smart playlists aren't real Jellyfin playlists - nothing to reorder on the server.
  // Left on in edit mode too: bulk move (top/bottom) covers big jumps, this still
  // covers fine single-row reordering, and building a second reorder path for edit
  // mode alone isn't worth it when this one already works.
  if (entryIds) wirePlaylistRowDrag(rowsEl, items)
  highlightPlayingRow()
}

// Drag-to-reorder for real playlists, mirroring the queue panel's drag pattern.
// Reorders locally first for snappy feedback, then persists via Jellyfin's
// playlist-item Move endpoint - a failed save just leaves the client order
// stale until the playlist is reopened, not destructive either way.
function wirePlaylistRowDrag(rowsEl, items) {
  let dragSrc = null
  rowsEl.querySelectorAll('.track-row').forEach(el => {
    el.addEventListener('dragstart', (e) => {
      dragSrc = el
      el.classList.add('dragging')
      e.dataTransfer.effectAllowed = 'move'
      e.dataTransfer.setData('text/plain', el.dataset.idx)
    })
    el.addEventListener('dragend', () => {
      el.classList.remove('dragging')
      rowsEl.querySelectorAll('.track-row').forEach(r => r.classList.remove('drag-over'))
    })
    el.addEventListener('dragover', (e) => {
      e.preventDefault()
      e.dataTransfer.dropEffect = 'move'
      rowsEl.querySelectorAll('.track-row').forEach(r => r.classList.remove('drag-over'))
      if (el !== dragSrc) el.classList.add('drag-over')
    })
    el.addEventListener('drop', async (e) => {
      e.preventDefault()
      if (!dragSrc || dragSrc === el) return
      const from = parseInt(dragSrc.dataset.idx)
      const to   = parseInt(el.dataset.idx)
      const [moved] = items.splice(from, 1)
      items.splice(to, 0, moved)
      renderPlaylistDetailItems(items, true)
      try {
        const entryId = moved.PlaylistItemId || moved.Id
        const res = await fetch(`${jf.url}/Playlists/${currentPlaylistId}/Items/${entryId}/Move/${to}`, {
          method: 'POST', headers: { 'X-Emby-Token': jf.token }
        })
        if (!res.ok) throw new Error(res.status)
      } catch (err) {
        showNotice('Could not save the new playlist order. It may still be reordered on this device only.', 'Playlist')
      }
    })
  })
}

async function openPlaylist(playlistId, name) {
  currentPlaylistId = playlistId
  currentSmartKind = null
  showPlaylistDetailShell(name)
  document.getElementById('btn-edit-playlist').style.display = ''
  const artEl = document.getElementById('pl-detail-art')
  artEl.style.background = ''
  const plArtUrl = `${jf.url}/Items/${playlistId}/Images/Primary?fillHeight=160&fillWidth=160&quality=80&api_key=${jf.token}`
  artEl.innerHTML = `<img src="${plArtUrl}" alt="" onerror="this.innerHTML='♪'">`

  try {
    const data = await jfGet(`/Playlists/${playlistId}/Items`, {
      UserId: jf.userId,
      Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag,DateCreated'
    })
    renderPlaylistDetailItems(data.Items || [], true)
  } catch (e) {
    document.getElementById('pl-detail-rows').innerHTML = `<div class="empty-state">Could not load playlist</div>`
  }
}

// ── Smart playlists ─────────────────────────────────────────────────────────────
// Auto-updating, synthesized from Jellyfin queries rather than real playlist entities.

const SMART_PLAYLISTS = {
  favorites: {
    name: 'Favorites',
    icon: '<svg width="32" height="32" viewBox="0 0 24 24" fill="currentColor" stroke="none"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/></svg>',
    gradient: 'linear-gradient(135deg,#f472b6,#dc2626)',
    async fetch() {
      const data = await jfGetMerged(`/Users/${jf.userId}/Items`, {
        IncludeItemTypes: 'Audio', Recursive: true, Filters: 'IsFavorite',
        SortBy: 'SortName', SortOrder: 'Ascending',
        Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag'
      })
      return data.Items || []
    }
  },
  'most-played': {
    name: 'Most Played',
    icon: '<svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="23 6 13.5 15.5 8.5 10.5 1 18"/><polyline points="17 6 23 6 23 12"/></svg>',
    gradient: 'linear-gradient(135deg,#60a5fa,#059669)',
    async fetch() {
      // Ask each library for its own top 200 by play count (server-side sorted),
      // then merge and re-sort/slice client-side - a per-library cap could otherwise
      // leave the true top 100 overall incomplete once multiple libraries are merged.
      const data = await jfGetMerged(`/Users/${jf.userId}/Items`, {
        IncludeItemTypes: 'Audio', Recursive: true,
        SortBy: 'PlayCount', SortOrder: 'Descending', Limit: 200,
        Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag'
      })
      const items = (data.Items || []).filter(i => (i.UserData?.PlayCount || 0) > 0)
      items.sort((a, b) => (b.UserData?.PlayCount || 0) - (a.UserData?.PlayCount || 0))
      return items.slice(0, 100)
    }
  }
}

function smartPlaylistCardHtml(kind) {
  const sp = SMART_PLAYLISTS[kind]
  return `<div class="playlist-card" data-smart="${kind}">
    <div class="playlist-art" style="background:${sp.gradient};color:#fff;">${sp.icon}</div>
    <div class="playlist-body">
      <div class="playlist-name">${sp.name}</div>
      <div class="playlist-count">Auto-updating</div>
    </div>
  </div>`
}

async function openSmartPlaylist(kind) {
  const sp = SMART_PLAYLISTS[kind]
  if (!sp) return
  currentPlaylistId = null
  currentSmartKind = kind
  showPlaylistDetailShell(sp.name)
  // Not a real Jellyfin playlist - nothing for Edit mode to write to.
  document.getElementById('btn-edit-playlist').style.display = 'none'
  document.getElementById('pl-detail-art').style.background = sp.gradient
  document.getElementById('pl-detail-art').innerHTML = sp.icon

  try {
    renderPlaylistDetailItems(await sp.fetch(), false)
  } catch (e) {
    document.getElementById('pl-detail-rows').innerHTML = `<div class="empty-state">Could not load</div>`
  }
}

document.getElementById('pl-back-btn').addEventListener('click', () => {
  document.getElementById('playlist-detail').classList.remove('active')
  document.getElementById('playlist-index').style.display = ''
})

document.getElementById('btn-play-playlist').addEventListener('click', () => {
  if (currentPlaylistItems.length) playItems(currentPlaylistItems, 0)
})

document.getElementById('btn-shuffle-playlist').addEventListener('click', () => shuffleAndPlay(currentPlaylistItems))

// ── Universal track context menu ───────────────────────────────────────────────

const trackCtxMenu = document.getElementById('track-ctx-menu')
let _ctxItem = null   // Jellyfin item object for the right-clicked row
let _ctxEl   = null   // DOM element of the right-clicked row
let _ctxInPl = false  // whether we're inside a playlist (shows Remove option)

function showTrackCtxMenu(item, el, x, y, inPlaylist = false) {
  _ctxItem = item; _ctxEl = el; _ctxInPl = inPlaylist
  // Show/hide playlist-only items
  trackCtxMenu.querySelectorAll('.tctx-pl-only').forEach(n => n.classList.toggle('hidden', !inPlaylist))
  trackCtxMenu.style.left = `${x}px`
  trackCtxMenu.style.top  = `${y}px`
  trackCtxMenu.classList.add('open')
  const r = trackCtxMenu.getBoundingClientRect()
  if (r.right  > window.innerWidth)  trackCtxMenu.style.left = `${x - r.width}px`
  if (r.bottom > window.innerHeight) trackCtxMenu.style.top  = `${y - r.height}px`
}

function closeTrackCtxMenu() { trackCtxMenu.classList.remove('open') }

document.addEventListener('mousedown', e => {
  if (!trackCtxMenu.contains(e.target)) closeTrackCtxMenu()
})

// Helper: attach click+dblclick+contextmenu to a track row
function wireTrackRow(el, item, items, idx, opts = {}) {
  // Click on the thumb (play button overlay) - play immediately
  const thumb = el.querySelector('.track-thumb')
  if (thumb) {
    thumb.addEventListener('click', e => {
      e.stopPropagation()
      playItems(items, idx)
    })
  }
  // Single click on rest of row - select (or play immediately in transient
  // contexts like the search dropdown, where "select" has nothing to select for)
  el.addEventListener('click', e => {
    if (e.target.closest('.track-thumb')) return  // handled above
    if (e.target.closest('[data-album-link]')) { e.stopPropagation(); openAlbumFromTrack(item); return }
    if (e.target.closest('[data-artist-link]')) { e.stopPropagation(); openArtistFromTrack(item); return }
    if (opts.clickToPlay) { playItems(items, idx); return }
    document.querySelectorAll('.track-row.selected').forEach(r => r.classList.remove('selected'))
    el.classList.add('selected')
  })
  // Double click anywhere - play, except on the album/artist links themselves
  el.addEventListener('dblclick', e => {
    if (e.target.closest('.row-link')) return
    playItems(items, idx)
  })
  // Right click - context menu
  el.addEventListener('contextmenu', e => {
    e.preventDefault()
    showTrackCtxMenu(item, el, e.clientX, e.clientY, opts.inPlaylist || false)
  })
  // Keyboard access for the album/artist links (Enter/Space triggers the same click path above)
  el.addEventListener('keydown', e => {
    if (e.key !== 'Enter' && e.key !== ' ') return
    const link = e.target.closest('.row-link')
    if (!link) return
    e.preventDefault()
    link.click()
  })
}

// ── Context menu actions ────────────────────────────────────────────────────────

document.getElementById('tctx-play').addEventListener('click', () => {
  if (!_ctxEl) return
  closeTrackCtxMenu()
  _ctxEl.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }))
})

document.getElementById('tctx-play-next').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  // Guests append only - letting them jump the line would let the last clicker
  // always win the next slot.
  if (isWaterfallFollower()) { showToast('Only the host can choose what plays next'); return }
  const insertAt = queueIndex + 1
  queue.splice(insertAt, 0, _ctxItem)
  showToast(`"${_ctxItem.Name}" plays next`)
})

document.getElementById('tctx-add-queue').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  enqueueTracks([_ctxItem], `"${_ctxItem.Name}"`)
})

document.getElementById('tctx-instant-mix').addEventListener('click', async () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  // Reuse the existing instant mix logic via the ctx-instant-mix path
  try {
    const data = await jfGet(`/Items/${_ctxItem.Id}/InstantMix`, { UserId: jf.userId, Limit: 50, Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag' })
    if (!data.Items?.length) { showNotice('Jellyfin did not return an instant mix for this track.', 'Instant mix'); return }
    playItems(data.Items, 0)
    showToast(`Instant mix from "${_ctxItem.Name}"`)
  } catch (e) { showNotice('Could not build an instant mix from this track.', 'Instant mix') }
})

document.getElementById('tctx-add-playlist').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  // Reuse existing add-to-playlist modal - store item for it
  _atpTargetItem = _ctxItem
  openAtpModal()
})

document.getElementById('tctx-download').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  const url = `${jf.url}/Items/${_ctxItem.Id}/Download?api_key=${jf.token}`
  const a = document.createElement('a'); a.href = url; a.download = _ctxItem.Name || 'track'; a.click()
})

document.getElementById('tctx-copy-url').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  const url = `${jf.url}/Audio/${_ctxItem.Id}/universal?UserId=${jf.userId}&api_key=${jf.token}&Container=mp3,aac,ogg,flac`
  navigator.clipboard.writeText(url).then(() => showToast('Stream URL copied'))
})

// Shared by every "view album" entry point (track context menus, now-playing title click,
// the now-playing 3-dot menu). Minimizes the overlay first if it's open, since navigating
// to a different tab behind an open overlay would otherwise be invisible until closed.
function openAlbumFromTrack(item) {
  if (!item?.AlbumId) return
  if (overlayOpen) closeOverlay()
  showView('albums')
  openAlbum(item.AlbumId)
}

document.getElementById('tctx-view-album').addEventListener('click', () => {
  if (!_ctxItem?.AlbumId) return
  closeTrackCtxMenu()
  openAlbumFromTrack(_ctxItem)
})

// Shared by every "view artist" entry point (track context menus, now-playing artist click,
// the now-playing 3-dot menu). Minimizes the overlay first if it's open, same reasoning as
// openAlbumFromTrack above.
async function openArtistFromTrack(item) {
  const artistName = item?.AlbumArtist || item?.Artists?.[0]
  if (!artistName) return
  if (overlayOpen) closeOverlay()
  showView('artists')
  // showView() kicks off loadArtists() but doesn't wait for it - on a first-ever visit
  // to the Artists tab this session, the grid isn't populated yet, so the card below
  // wouldn't exist. Load-and-wait ourselves whenever it isn't already there.
  let artistCard = document.querySelector(`.artist-card[data-name="${CSS.escape(artistName)}"]`)
  if (!artistCard) {
    await loadArtists()
    artistCard = document.querySelector(`.artist-card[data-name="${CSS.escape(artistName)}"]`)
  }
  if (artistCard) artistCard.click()
}

document.getElementById('tctx-view-artist').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  openArtistFromTrack(_ctxItem)
})

document.getElementById('tctx-refresh-meta').addEventListener('click', async () => {
  if (!_ctxItem || !jf.isAdmin) return
  closeTrackCtxMenu()
  try {
    const res = await fetch(`${jf.url}/Items/${_ctxItem.Id}/Refresh?MetadataRefreshMode=FullRefresh&ImageRefreshMode=FullRefresh&ReplaceAllMetadata=false&ReplaceAllImages=false`, {
      method: 'POST', headers: { 'X-Emby-Token': jf.token }
    })
    // The response was never read, so a 403 from a non-admin account reported
    // "queued" for a refresh the server had refused outright.
    if (!res.ok) throw new Error(String(res.status))
    showToast('Metadata refresh queued')
  } catch { showNotice('Could not queue a metadata refresh on the server.', 'Refresh failed') }
})

document.getElementById('tctx-edit-meta').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  openMetadataEditorFor(_ctxItem)
})

document.getElementById('tctx-pl-remove').addEventListener('click', async () => {
  if (!_ctxEl || !currentPlaylistId) return
  closeTrackCtxMenu()
  const entryId = _ctxEl.dataset.entryId
  if (!entryId) { showNotice('This row is missing its playlist entry ID, so it cannot be removed.', 'Playlist'); return }
  try {
    const res = await fetch(`${jf.url}/Playlists/${currentPlaylistId}/Items?EntryIds=${encodeURIComponent(entryId)}`, {
      method: 'DELETE', headers: { 'X-Emby-Token': jf.token }
    })
    if (!res.ok) throw new Error(res.status)
    showToast('Removed from playlist')
    // Re-fetch rather than patch the DOM in place - a manual patch left currentPlaylistItems
    // (what Play/Shuffle use) still holding the removed track.
    await playlistMutated(currentPlaylistId)
  } catch (e) { showNotice(`Could not remove this track from the playlist.\n\n${e.message}`, 'Playlist') }
})

// ── Movies & TV ───────────────────────────────────────────────────────────────
//
// Browsing only. Playback is the same code path music uses: these views build a
// queue and hand it to playItems(), which is what makes next-episode autoplay
// fall out for free rather than needing a second player.

/** Like jfGetMerged, but against the movie libraries only, so browsing movies
 *  never fans out across TV libraries. */
const jfGetMovies = (path, params = {}) =>
  jfClient.getMerged(path, params, jf.movieLibraryIds || [])

/** Same, against the TV libraries only. */
const jfGetShows = (path, params = {}) =>
  jfClient.getMerged(path, params, jf.showLibraryIds || [])

/** Runtime as "1h 47m" / "47m". Distinct from fmtTime, which is for a scrubber. */
function fmtRuntime(ticks) {
  if (!ticks) return ''
  const mins = Math.round(ticks / 600_000_000)
  const h = Math.floor(mins / 60)
  return h ? `${h}h ${mins % 60}m` : `${mins}m`
}

// `opts` lets a caller show a different item's art/name than the one the card
// is `data-id`'d and clicked on - used to fold a recently-watched episode into
// its series' poster and name (see groupRecentlyWatched) without changing
// which item wirePosterCards resolves the click to.
function posterCard(item, sub, opts = {}) {
  const art = artUrl(opts.artId || item.Id, 'artTag' in opts ? opts.artTag : item.ImageTags?.Primary)
  const img = art
    ? `<img src="${art}" alt="" loading="lazy" onerror="this.style.display='none'">`
    : '🎞'
  const name = opts.title || item.Name
  // How far in the user got, if anywhere. Same signal the Resume button uses.
  const pos = resumeTicks(item)
  const pct = pos && item.RunTimeTicks ? Math.min(100, (pos / item.RunTimeTicks) * 100) : 0
  const bar = pct ? `<div class="poster-progress"><span style="width:${pct}%"></span></div>` : ''
  return `<div class="poster-card" data-id="${item.Id}">
    <div class="poster-art">${img}${bar}</div>
    <div class="poster-name" title="${esc(name)}">${esc(name)}</div>
    <div class="poster-sub">${esc(sub || '')}</div>
  </div>`
}

// ── Horizontal shelf: a sideways-scrolling row with edge arrows ──
//
// One reusable wrapper for any row that should scroll sideways instead of
// wrapping - Home's "Continue watching" and a grouped library's poster row
// both call this. `trackHTML` is the row's own markup (cards already
// rendered); `trackClass` sets what the scrolling element is, so it can also
// carry `.poster-grid` and pick up that class's card styling. Call
// wireHShelf() on the rendered container afterwards to make the arrows work -
// this only builds the markup.
const HSHELF_CHEVRON_LEFT  = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 18 9 12 15 6"/></svg>'
const HSHELF_CHEVRON_RIGHT = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="9 18 15 12 9 6"/></svg>'
function hshelfHTML(trackHTML, trackClass = 'poster-grid hshelf-track') {
  return `<div class="hshelf">
    <button class="hshelf-arrow hshelf-arrow-left" aria-label="Scroll left" tabindex="-1">${HSHELF_CHEVRON_LEFT}</button>
    <div class="${trackClass}">${trackHTML}</div>
    <button class="hshelf-arrow hshelf-arrow-right" aria-label="Scroll right" tabindex="-1">${HSHELF_CHEVRON_RIGHT}</button>
  </div>`
}

/** Makes every .hshelf inside `root` scroll by its arrows and keeps them
 *  showing only on the side with real overflow, hiding once scrolled to that
 *  edge. The track itself is a plain overflow-x:auto row, so a trackpad's
 *  native horizontal swipe and the page's vertical scroll are untouched -
 *  this only adds what a horizontal-wheel-less mouse cannot reach otherwise.
 *  Stores its update function on the track (`_hshelfUpdate`) so a caller that
 *  changes the track's size for a reason a ResizeObserver cannot see coming
 *  (e.g. un-collapsing a library group from display:none) can force a
 *  recompute immediately instead of waiting on it. */
function wireHShelf(root) {
  root.querySelectorAll('.hshelf').forEach(shelf => {
    const track = shelf.querySelector('.hshelf-track')
    const left  = shelf.querySelector('.hshelf-arrow-left')
    const right = shelf.querySelector('.hshelf-arrow-right')
    if (!track || !left || !right) return
    const EPS = 2 // absorbs subpixel rounding at the scroll edges
    const update = () => {
      const overflowing = track.scrollWidth > track.clientWidth + EPS
      const showLeft  = overflowing && track.scrollLeft > EPS
      const showRight = overflowing && track.scrollLeft < track.scrollWidth - track.clientWidth - EPS
      left.classList.toggle('show', showLeft)
      left.tabIndex = showLeft ? 0 : -1
      right.classList.toggle('show', showRight)
      right.tabIndex = showRight ? 0 : -1
    }
    track._hshelfUpdate = update
    // No explicit behavior here on purpose - 'smooth' would force it even
    // under prefers-reduced-motion, overriding the track's own CSS
    // scroll-behavior (smooth normally, auto in the reduced-motion block
    // above). Omitting it lets that CSS property decide.
    left.addEventListener('click', () => track.scrollBy({ left: -track.clientWidth * 0.85 }))
    right.addEventListener('click', () => track.scrollBy({ left: track.clientWidth * 0.85 }))
    track.addEventListener('scroll', update, { passive: true })
    // Window resizes, and a library group's track going from display:none (0
    // width) to visible when expanded - both are a track resize either way.
    new ResizeObserver(update).observe(track)
  })
}

/** Wires poster-card clicks by matching each card's data-id back to `items`,
 *  rather than an index into one flat list - needed once a grid can hold more
 *  than one group of cards, each with its own item list. */
function wirePosterCards(container, items, onPick) {
  const byId = new Map(items.map(i => [i.Id, i]))
  container.querySelectorAll('.poster-card').forEach(el => {
    const item = byId.get(el.dataset.id)
    if (item) el.addEventListener('click', () => onPick(item))
  })
}

/** One library's section of a grouped poster grid: a collapsible header
 *  (name + count) plus its cards. Cards are always rendered, even collapsed -
 *  the header just hides them via CSS, so expanding never needs a refetch. */
function posterGroupHTML(libId, name, items, sub) {
  const collapsed = _collapsedLibs.has(libId)
  const cards = items.map(i => posterCard(i, sub(i))).join('')
  // A horizontal shelf rather than a wrapping grid: two libraries stacked as
  // grids used to mean the second one's cards ran off the right edge with no
  // way for a plain mouse to reach them (reverted in 32db4e3). The row now
  // scrolls with wireHShelf()'s arrows instead, so overflow is reachable
  // either way.
  return `<div class="lib-group${collapsed ? ' collapsed' : ''}" data-lib-id="${libId}">
    <div class="sect-header lib-group-header" tabindex="0" role="button" aria-expanded="${!collapsed}">
      <span class="sect-title"><span class="lib-group-chevron">▾</span>${esc(name)}</span>
      <span class="lib-group-count">${items.length}</span>
    </div>
    ${hshelfHTML(cards)}
  </div>`
}

/** Click/keyboard wiring for every group header in a just-rendered grouped
 *  grid. Toggling just flips a CSS class and persists the id set - the cards
 *  are already in the DOM either way. */
function wireLibGroupHeaders(grid) {
  grid.querySelectorAll('.lib-group-header').forEach(header => {
    const toggle = () => {
      const group = header.closest('.lib-group')
      const collapsed = group.classList.toggle('collapsed')
      header.setAttribute('aria-expanded', String(!collapsed))
      const libId = group.dataset.libId
      if (collapsed) _collapsedLibs.add(libId)
      else _collapsedLibs.delete(libId)
      saveCollapsedLibs()
      // Expanding: the track was display:none a moment ago (0 width), so its
      // arrows need a forced recompute rather than waiting on the
      // ResizeObserver's own timing.
      if (!collapsed) group.querySelector('.hshelf-track')?._hshelfUpdate?.()
    }
    header.addEventListener('click', toggle)
    header.addEventListener('keydown', e => {
      if (e.key !== 'Enter' && e.key !== ' ') return
      e.preventDefault()
      toggle()
    })
  })
}

// Both grids are the same shape, so they share one loader. `sub` picks what goes
// under each title; `getVideo` is jfGetMovies or jfGetShows, so each grid only
// ever fans out across its own category's libraries. `libs`/`ids` are that
// category's known libraries and its currently selected ids (in fetch order) -
// with more than one selected, the grid renders one collapsible group per
// library instead of a single merged pile.
async function loadPosterGrid(gridId, itemType, sub, onPick, getVideo, libs, ids) {
  const grid = document.getElementById(gridId)
  grid.dataset.loaded = '1'
  // Cleared before the skeleton, not after the fetch: left over from a previous
  // grouped load it makes the container display:block, and eight poster
  // skeletons stack into a full-width column instead of a grid.
  grid.classList.remove('lib-grouped')
  grid.innerHTML = skeletonHTML('poster', 8)
  const path = `/Users/${jf.userId}/Items`
  const params = {
    SortBy: 'SortName', SortOrder: 'Ascending',
    IncludeItemTypes: itemType, Recursive: true,
    Fields: 'PrimaryImageAspectRatio,UserData,ProductionYear',
    Limit: 500,
  }
  try {
    if ((ids || []).length > 1) {
      const groups = await jfClient.getGrouped(path, params, ids)
      if (!groups.some(g => g.items.length)) {
        grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">Nothing here yet</div>`
        return
      }
      // The container is itself a .poster-grid, so without this its groups
      // become grid cells rather than stacked sections. See .lib-grouped.
      grid.classList.add('lib-grouped')
      grid.innerHTML = groups.map(g => {
        const lib = libs.find(l => l.Id === g.libraryId)
        return posterGroupHTML(g.libraryId, lib ? lib.Name : g.libraryId, g.items, sub)
      }).join('')
      grid.querySelectorAll('.lib-group').forEach((section, i) => {
        wirePosterCards(section, groups[i].items, onPick)
      })
      wireLibGroupHeaders(grid)
      wireHShelf(grid)
    } else {
      // Single library: the container goes back to being a real poster grid.
      grid.classList.remove('lib-grouped')
      const data = await getVideo(path, params)
      const items = data.Items || []
      if (!items.length) {
        grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">Nothing here yet</div>`
        return
      }
      grid.innerHTML = items.map(i => posterCard(i, sub(i))).join('')
      wirePosterCards(grid, items, onPick)
    }
  } catch {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">Could not load this library</div>`
  }
}

const loadMovies = () => loadPosterGrid(
  'movies-grid', 'Movie',
  m => m.ProductionYear || '',
  m => openMovie(m.Id), jfGetMovies, _movieLibs, jf.movieLibraryIds || [])

const loadShows = () => loadPosterGrid(
  'shows-grid', 'Series',
  s => s.ProductionYear || '',
  s => openSeries(s.Id), jfGetShows, _showLibs, jf.showLibraryIds || [])

// ── Continue watching (Home) ──
//
// Distinct from Recently watched below it: this is specifically what's
// partway through (Filters: IsResumable), not play history - a movie or
// episode watched to the end never appears here even though it does there.
// Horizontal, matching Jellyfin's own webui, via the shared hshelf component;
// same hide-when-empty rule as every other video shelf.
async function loadContinueWatching() {
  const section = document.getElementById('home-resume-section')
  const videoLibIds = [...(jf.movieLibraryIds || []), ...(jf.showLibraryIds || [])]
  if (!videoLibIds.length) { section.style.display = 'none'; return }
  try {
    const data = await jfClient.getMerged(`/Users/${jf.userId}/Items`, {
      SortBy: 'DatePlayed',
      SortOrder: 'Descending',
      IncludeItemTypes: 'Movie,Episode',
      Filters: 'IsResumable',
      Recursive: true,
      Fields: 'PrimaryImageAspectRatio,UserData,ProductionYear',
      Limit: 24
    }, videoLibIds)
    // Same reasoning as Recently watched below: getMerged concatenates
    // per-library results, so the server's DatePlayed order only holds within
    // one library - re-sort across the merge.
    const items = (data.Items || [])
      .sort((a, b) => new Date(b.UserData?.LastPlayedDate || 0) - new Date(a.UserData?.LastPlayedDate || 0))
    if (!items.length) { section.style.display = 'none'; return }
    section.style.display = ''
    const grid = document.getElementById('home-resume-grid')
    // posterCard's own resumeTicks-driven .poster-progress bar is exactly the
    // "how far in" signal this shelf is about - nothing extra to build here.
    grid.innerHTML = hshelfHTML(items.map(item => posterCard(item, recentVideoSub(item))).join(''))
    wireHShelf(grid)
    wirePosterCards(grid, items, item => {
      if (item.Type === 'Movie') { showView('movies'); openMovie(item.Id) }
      else { showView('shows'); openSeries(item.SeriesId) }
    })
  } catch {
    section.style.display = 'none'
  }
}

// ── Recently watched (Home) ──
//
// Movies and episodes played across both video categories, merged and
// re-sorted by when they were last watched. Only shown when there's actually
// a video library configured and some play history - a music-only user (or
// one who hasn't watched anything yet) never sees the section at all.

function recentVideoSub(item) {
  if (item.Type === 'Movie') return item.ProductionYear || ''
  const ep = (item.ParentIndexNumber != null && item.IndexNumber != null)
    ? ` · S${item.ParentIndexNumber}E${item.IndexNumber}` : ''
  return (item.SeriesName || '') + ep
}

/** Just the "S1E4" part, for a card that already shows the series as its
 *  title - repeating the series name in the subtitle too would be noise. */
function episodeCode(item) {
  const s = item.ParentIndexNumber, e = item.IndexNumber
  return (s != null && e != null) ? `S${s}E${e}` : (item.Name || '')
}

async function loadRecentlyWatched() {
  const section = document.getElementById('home-continue-section')
  const videoLibIds = [...(jf.movieLibraryIds || []), ...(jf.showLibraryIds || [])]
  if (!videoLibIds.length) { section.style.display = 'none'; return }
  try {
    const data = await jfClient.getMerged(`/Users/${jf.userId}/Items`, {
      SortBy: 'DatePlayed',
      SortOrder: 'Descending',
      IncludeItemTypes: 'Movie,Episode',
      Filters: 'IsPlayed',
      Recursive: true,
      Fields: 'PrimaryImageAspectRatio,UserData,ProductionYear,SeriesPrimaryImageTag',
      Limit: 24
    }, videoLibIds)
    // getMerged concatenates per-library results, so the server's DatePlayed
    // ordering only holds within a library - re-sort across the merge. Fold
    // binged episodes down to one card per series AFTER that re-sort, so the
    // kept episode is the actually-most-recent one, not an arbitrary one from
    // whichever library happened to be fetched first.
    const items = groupRecentlyWatched(
      (data.Items || [])
        .sort((a, b) => new Date(b.UserData?.LastPlayedDate || 0) - new Date(a.UserData?.LastPlayedDate || 0))
    )
    if (!items.length) { section.style.display = 'none'; return }
    section.style.display = ''
    const grid = document.getElementById('home-continue-grid')
    grid.innerHTML = items.map(item =>
      // A grouped episode shows the series' own poster and name, with the
      // episode itself demoted to the subtitle. An episode with no SeriesId
      // (never grouped - see groupRecentlyWatched) has no series art to show,
      // so it keeps the plain episode card it always had.
      item.Type === 'Episode' && item.SeriesId
        ? posterCard(item, episodeCode(item), { artId: item.SeriesId, artTag: item.SeriesPrimaryImageTag, title: item.SeriesName || item.Name })
        : posterCard(item, recentVideoSub(item))
    ).join('')
    wirePosterCards(grid, items, item => {
      // Same detail views Movies/TV browsing already opens - no separate
      // playback path for a Home entry.
      if (item.Type === 'Movie') { showView('movies'); openMovie(item.Id) }
      else { showView('shows'); openSeries(item.SeriesId) }
    })
  } catch {
    section.style.display = 'none'
  }
}

// ── Movie detail ──

async function openMovie(movieId) {
  document.getElementById('movies-index').style.display = 'none'
  const detail = document.getElementById('movie-detail')
  detail.style.display = ''
  const body = document.getElementById('movie-detail-body')
  body.innerHTML = skeletonHTML('track', 3)

  try {
    // MediaStreams is what applySubtitles() reads, and MediaSources is needed to
    // build a subtitle URL - neither comes back on the grid query, so the detail
    // fetch is where the item becomes playable.
    const movie = await jfGet(`/Users/${jf.userId}/Items/${movieId}`,
      { Fields: 'Overview,MediaStreams,MediaSources,Genres' })

    const art = artUrl(movie.Id, movie.ImageTags?.Primary)
    const meta = [movie.ProductionYear, fmtRuntime(movie.RunTimeTicks), (movie.Genres || []).slice(0, 3).join(', ')]
      .filter(Boolean).join('  ·  ')
    const resume = resumeTicks(movie)

    body.innerHTML = `
      <div class="vd-header">
        <div class="vd-poster">${art ? `<img src="${art}" alt="">` : '🎞'}</div>
        <div class="vd-info">
          <div class="vd-title">${esc(movie.Name)}</div>
          <div class="vd-meta">${esc(meta)}</div>
          <div class="vd-overview">${esc(movie.Overview || '')}</div>
          <div class="vd-actions">
            ${resume ? `<button class="shuffle-all-btn" id="movie-resume">Resume from ${fmtTime(resume / 10_000_000)}</button>` : ''}
            <button class="shuffle-all-btn" id="movie-play">${resume ? 'Play from start' : 'Play'}</button>
          </div>
        </div>
      </div>`

    // startTicks 0 on "Play from start" is what stops playCurrentTrack falling
    // back to the stored resume position.
    document.getElementById('movie-play').onclick = () => playVideo([movie], 0, 0)
    document.getElementById('movie-resume')?.addEventListener('click',
      () => playVideo([movie], 0, resume))
  } catch {
    body.innerHTML = `<div class="empty-state">Could not load this movie</div>`
  }
}

// ── Series detail ──

let _currentSeries = null

async function openSeries(seriesId) {
  document.getElementById('shows-index').style.display = 'none'
  const detail = document.getElementById('show-detail')
  detail.style.display = ''
  const body = document.getElementById('show-detail-body')
  body.innerHTML = skeletonHTML('track', 4)

  try {
    const [series, seasonsData] = await Promise.all([
      jfGet(`/Users/${jf.userId}/Items/${seriesId}`, { Fields: 'Overview,Genres' }),
      jfGet(`/Shows/${seriesId}/Seasons`, { UserId: jf.userId, Fields: 'UserData' }),
    ])
    _currentSeries = series
    const seasons = seasonsData.Items || []

    const art = artUrl(series.Id, series.ImageTags?.Primary)
    const meta = [series.ProductionYear, `${seasons.length} season${seasons.length !== 1 ? 's' : ''}`,
      (series.Genres || []).slice(0, 3).join(', ')].filter(Boolean).join('  ·  ')

    body.innerHTML = `
      <div class="vd-header">
        <div class="vd-poster">${art ? `<img src="${art}" alt="">` : '📺'}</div>
        <div class="vd-info">
          <div class="vd-title">${esc(series.Name)}</div>
          <div class="vd-meta">${esc(meta)}</div>
          <div class="vd-overview">${esc(series.Overview || '')}</div>
        </div>
      </div>
      <div class="season-tabs" id="season-tabs">${
        seasons.map((s, i) =>
          `<button class="season-tab${i === 0 ? ' active' : ''}">${esc(s.Name)}</button>`
        ).join('')
      }</div>
      <div id="episode-list"></div>`

    // Closes over `seasons` by index rather than reading an id back out of a
    // data attribute - the array is right here.
    document.querySelectorAll('#season-tabs .season-tab').forEach((tab, i) => {
      tab.addEventListener('click', () => {
        document.querySelectorAll('#season-tabs .season-tab').forEach(t => t.classList.remove('active'))
        tab.classList.add('active')
        loadEpisodes(seriesId, seasons[i].Id)
      })
    })

    if (seasons.length) loadEpisodes(seriesId, seasons[0].Id)
    else document.getElementById('episode-list').innerHTML =
      `<div class="empty-state">No seasons found</div>`
  } catch {
    body.innerHTML = `<div class="empty-state">Could not load this show</div>`
  }
}

async function loadEpisodes(seriesId, seasonId) {
  const list = document.getElementById('episode-list')
  list.innerHTML = skeletonHTML('track', 5)
  try {
    const data = await jfGet(`/Shows/${seriesId}/Episodes`, {
      SeasonId: seasonId, UserId: jf.userId,
      Fields: 'Overview,MediaStreams,MediaSources,UserData',
    })
    const eps = data.Items || []
    if (!eps.length) { list.innerHTML = `<div class="empty-state">No episodes</div>`; return }

    list.innerHTML = eps.map(ep => {
      const thumb = artUrl(ep.Id, ep.ImageTags?.Primary)
      const pos = resumeTicks(ep)
      const pct = pos && ep.RunTimeTicks ? Math.min(100, (pos / ep.RunTimeTicks) * 100) : 0
      const num = ep.IndexNumber != null ? `${ep.IndexNumber}. ` : ''
      return `<div class="ep-row" data-id="${ep.Id}">
        <div class="ep-thumb">
          ${thumb ? `<img src="${thumb}" alt="" loading="lazy" onerror="this.style.display='none'">` : '▶'}
          ${pct ? `<div class="poster-progress"><span style="width:${pct}%"></span></div>` : ''}
        </div>
        <div>
          <div class="ep-title">${esc(num + (ep.Name || ''))}</div>
          <div class="ep-overview">${esc(ep.Overview || '')}</div>
        </div>
        <div class="ep-time">${ep.UserData?.Played ? '<span class="ep-watched">✓</span> ' : ''}${fmtRuntime(ep.RunTimeTicks)}</div>
      </div>`
    }).join('')

    // The whole season becomes the queue, so finishing one episode rolls into
    // the next through the existing `ended` handler. No second queue.
    list.querySelectorAll('.ep-row').forEach((el, i) => {
      el.addEventListener('click', () => playVideo(eps, i, resumeTicks(eps[i])))
    })
  } catch {
    list.innerHTML = `<div class="empty-state">Could not load episodes</div>`
  }
}

/**
 * Start video playback. Thin wrapper over the music path: the only thing it adds
 * is honouring a resume position, which playItems() has no concept of.
 */
function playVideo(items, startIndex, startTicks) {
  if (blocksLocalPlayback()) {
    if (typeof wfNotifyHostControls === 'function') wfNotifyHostControls()
    return
  }
  // Shuffling a season is never what a click on episode 3 means.
  _unshuffledQueue = []
  queue = [...items]
  queueIndex = startIndex
  playCurrentTrack({ startTicks: startTicks || 0 })
}

document.getElementById('movie-back-btn').addEventListener('click', () => {
  document.getElementById('movie-detail').style.display = 'none'
  document.getElementById('movies-index').style.display = ''
})

document.getElementById('show-back-btn').addEventListener('click', () => {
  document.getElementById('show-detail').style.display = 'none'
  document.getElementById('shows-index').style.display = ''
})

// ── Playback ──────────────────────────────────────────────────────────────────

function playItems(items, startIndex) {
  // In a Waterfall room a guest follows the host - starting something locally
  // would silently fight the session until the next sync pulled it back.
  if (blocksLocalPlayback()) {
    if (typeof wfNotifyHostControls === 'function') wfNotifyHostControls()
    return
  }
  if (shuffle) {
    // New queue loaded while shuffle is on - shuffle the new queue immediately
    _unshuffledQueue = [...items]
    queue = [...items]
    const startItem = queue[startIndex]
    shuffleInPlace(queue)
    // Move the selected track to front
    const nowIdx = queue.findIndex(t => t.Id === startItem?.Id)
    if (nowIdx > 0) { const [t] = queue.splice(nowIdx, 1); queue.unshift(t) }
    queueIndex = 0
  } else {
    _unshuffledQueue = []
    queue = [...items]
    queueIndex = startIndex
  }
  playCurrentTrack()
}

// ── Video mode ────────────────────────────────────────────────────────────────

// Flip the overlay between the music layout (art + lyrics/queue columns) and the
// single-column video layout. Purely a class toggle: the CSS in index.html owns
// what actually shows, so there is one place to change if the layout moves.
function applyVideoMode(on) {
  // Music and video keep separate saved EQ curves - this is the one place
  // playback knows which is active, so it is also where the live graph
  // switches which profile it is wired to.
  eqActiveMode = on ? 'video' : 'music'
  _applyEqToGraph()
  const ov = document.getElementById('np-overlay')
  ov.classList.toggle('video', !!on)
  // Only the current deck may show a picture - the other is mid-crossfade or idle.
  DECKS.forEach(d => d.classList.toggle('deck-hidden', d !== audio))
  // A film opened on its own is a queue of one, so prev and next have nowhere
  // to go. A season is not - that queue is the whole point of next-episode.
  ov.classList.toggle('single', !!on && queue.length <= 1)
  // Full mode only ever means anything over a picture - applied here so a
  // saved preference from the last video takes effect on this one too,
  // without also being live (and misleading) while music is playing.
  ov.classList.toggle('full', !!on && videoFullMode)
  document.getElementById('ov-full-mode')?.classList.toggle('active', !!on && videoFullMode)
  // A movie playing behind the library grid with no picture is confusing, so
  // opening the overlay is part of starting video, not a separate step.
  if (on) openOverlay()
  // Covers the other direction too: going back to music must stop the sampler.
  else refreshAmbient()
}

// Attach text subtitles as native <track> elements.
//
// Only text subtitles appear here. Bitmap ones (PGS, VOBSUB) cannot be drawn by
// a <track>, so ELECTRON_PROFILE deliberately omits them and the server burns
// them into the video instead - which means they arrive as picture and need
// nothing from this function.
function applySubtitles(item, resolved) {
  audio.querySelectorAll('track').forEach(t => t.remove())
  if (!isVideoItem(item)) return

  const sourceId = resolved?.mediaSourceId
  if (!sourceId) return

  const subs = (item.MediaStreams || []).filter(s =>
    s.Type === 'Subtitle' && s.IsTextSubtitleStream)

  for (const s of subs) {
    const track = document.createElement('track')
    track.kind = 'subtitles'
    track.label = s.DisplayTitle || s.Language || `Track ${s.Index}`
    if (s.Language) track.srclang = s.Language
    track.src = `${jf.url}/Videos/${item.Id}/${sourceId}/Subtitles/${s.Index}/Stream.vtt?api_key=${jf.token}`
    audio.appendChild(track)
    // Mode is set after appending, and explicitly rather than via `default`,
    // because `default` only decides the *initial* pick - the picker needs a
    // handle it can keep changing afterwards.
    track.track.mode = (s.IsDefault || s.IsForced) ? 'showing' : 'disabled'
  }
}

/** Show one subtitle track by index, or none when `index` is null. */
function selectSubtitleTrack(index) {
  const tracks = [...audio.querySelectorAll('track')]
  tracks.forEach((t, i) => { t.track.mode = i === index ? 'showing' : 'disabled' })
}

// opts.alreadyPlaying: true when a crossfade handoff already has `audio` playing
// the new track in place - skip the src reset that would otherwise restart it.
// opts.startTicks: resume position, overriding the item's stored one.
async function playCurrentTrack(opts = {}) {
  if (blocksLocalPlayback()) return
  if (queueIndex < 0 || queueIndex >= queue.length) return
  const item = queue[queueIndex]

  // Every track change funnels through here, so this is the one place that
  // needs to know to abandon an in-progress crossfade - covers next/prev,
  // queue-row jumps, double-click play, instant mix, everything.
  cancelCrossfade()
  // Whatever the server was encoding for the outgoing item is now waste. Runs
  // before _playSessionId is replaced by the new stream's.
  abandonCurrentEncoding()

  const video = isVideoItem(item)

  // A track already buffered on the idle deck (see _prefetchNext) can be
  // swapped straight in instead of resolving and loading cold - the same
  // handoff finishCrossfade does, just with no fade and its own play() since
  // a prefetched deck is never actually started. Falls through to the normal
  // path whenever the prefetch is missing, stale, or for the wrong item.
  let prefetched = null
  const prefetchEligible = !opts.alreadyPlaying && !opts.startTicks && !video
  if (prefetchEligible && _streamPrefetch?.itemId === item.Id) {
    prefetched = _streamPrefetch
    _streamPrefetch = null
    _swapDeck(prefetched.deck, audio)
  } else {
    // Whatever was prefetched is for a different track now, or this is a
    // crossfade handoff that already consumed it - either way it is stale.
    _clearStreamPrefetch()
  }
  if (prefetchEligible) _lastPrefetchOutcome = { at: Date.now(), from: 'advance', hit: !!prefetched }

  applyVideoMode(video)

  if (prefetched) {
    adoptResolvedStream(prefetched.resolved)
    audio.play().catch(() => {})
  } else if (!opts.alreadyPlaying) {
    // Resolving the stream is now a round-trip, so the user can skip again
    // before it lands. Re-read the queue afterwards and bail if they did,
    // otherwise a stale response would start the wrong track.
    // Resume where the server says the user stopped. opts.startTicks lets the
    // Resume button override the stored position, and a 0 from it means "from
    // the start" rather than "unset" - hence ?? and not ||.
    const startTicks = opts.startTicks ?? (video ? resumeTicks(item) : 0)

    // The offset goes to the server, not to the element: a transcode has to be
    // encoded from that point, and asking for it after the fact would mean
    // throwing away everything already sent. Direct play ignores it here and
    // seeks locally below instead.
    // A track choice belongs to the film you made it on, not to the player -
    // EXCEPT when the file's own default audio track is not something this
    // build can decode (a movie with TrueHD/DTS as track 0 and a compatible
    // track further down, which direct play would still hand over as-is - see
    // neededAudioStreamIndex()). Then forcing the index is the only way the
    // server transcodes to a track we can actually hear.
    _audioStreamIndex = video ? neededAudioStreamIndex(item.MediaStreams, decodableVideoAudioCodecs()) : null

    const resolved = await resolveTrackStream(item.Id, video ? 'Video' : 'Audio',
      { startTicks, audioStreamIndex: _audioStreamIndex })
    if (queue[queueIndex]?.Id !== item.Id) return

    adoptResolvedStream(resolved)
    audio.src = resolved.url

    // Direct play got the whole file, so the seek happens on the element. Has
    // to wait for metadata: setting currentTime before the element knows the
    // duration is a no-op.
    if (startTicks > 0 && resolved.startTicks === 0) {
      audio.addEventListener('loadedmetadata',
        () => { audio.currentTime = startTicks / 10_000_000 },
        { once: true })
    }

    applySubtitles(item, resolved)

    // .catch here because play() is no longer in the same task as the click
    // that triggered it - an autoplay rejection would otherwise surface as an
    // unhandled promise rejection. Matches finishCrossfade's handling.
    audio.play().catch(() => {})
  } else if (opts.resolved) {
    // Crossfade already resolved the stream; adopt it rather than re-resolving.
    adoptResolvedStream(opts.resolved)
  }

  updateNowPlaying(item)
  highlightPlayingRow()
  reportPlaybackStart(item.Id)
}

let _prefetchSession = 0

async function _prefetchUpcoming() {
  const session = ++_prefetchSession
  const start = queueIndex + 1
  const end = Math.min(start + 5, queue.length)
  for (let i = start; i < end; i++) {
    if (session !== _prefetchSession) break        // user skipped, abandon
    const item = queue[i]
    if (!item?.Id || _lyricsCache.has(item.Id)) continue
    await fetchLyricsWaterfall(item).catch(() => {})
    if (session !== _prefetchSession) break
    await new Promise(r => setTimeout(r, 400))    // brief gap between API calls
  }
}

// Marquee: measure a clipping container and scroll its .np-scroll-inner if the text
// overflows. Used by the statusbar and both fullscreen overlay lines.
function applyMarquee(el) {
  const inner = el?.querySelector('.np-scroll-inner')
  if (!inner) return
  inner.style.animation = 'none'
  el.classList.remove('marquee-on')
  const overflow = inner.scrollWidth - el.clientWidth
  if (overflow > 4) { // dead-zone absorbs subpixel rounding
    inner.style.setProperty('--marquee-dist', `-${overflow + 8}px`)
    inner.style.animation = `np-marquee ${Math.max(5, overflow / 25)}s ease-in-out infinite` // ~25px/s
    el.classList.add('marquee-on')
  }
}

const MARQUEE_IDS = ['np-info', 'ov-track', 'ov-artist']

// A plain resize listener rather than ResizeObserver: the overlay's font sizes are
// clamp(..., vh, ...), so a height-only resize changes the text width without changing
// any element's box - an observer would never fire. The rAF also coalesces the burst.
function refreshMarquees() {
  requestAnimationFrame(() => MARQUEE_IDS.forEach(id => applyMarquee(document.getElementById(id))))
}
window.addEventListener('resize', refreshMarquees)

// The line under the title. Artist for music; for video the thing that actually
// locates it - which series and episode, or which year.
function secondaryLine(item) {
  if (item?.Type === 'Episode') {
    const s = item.ParentIndexNumber, e = item.IndexNumber
    const code = s != null && e != null ? `S${s}:E${e}` : (item.SeasonName || '')
    return [item.SeriesName, code].filter(Boolean).join(' · ')
  }
  if (item?.Type === 'Movie') return item.ProductionYear ? String(item.ProductionYear) : ''
  return item?.AlbumArtist || item?.Artists?.[0] || ''
}

function updateNowPlaying(item) {
  const video = isVideoItem(item)

  // Warm the cache for the current song and the next 5 in queue. Movies have no
  // lyrics, and asking LRCLIB and Kugou about one wastes two round-trips per
  // title and pollutes the cache with misses.
  if (item?.Id && !video) {
    fetchLyricsWaterfall(item).catch(() => {})
    _prefetchUpcoming()
  }

  _currentHighResArtUrl = null // reset for new track

  const art = artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
  _currentHighResArtUrl = art  // Jellyfin 600px as immediate baseline
  const artEl = document.getElementById('np-art')
  if (art) {
    artEl.innerHTML = `<img src="${art}" alt="" onerror="this.innerHTML='♪'">`
  } else {
    artEl.innerHTML = '♪'
  }
  document.getElementById('np-info').innerHTML = `
    <span class="np-scroll-inner">
      <span class="np-title">${esc(item.Name)}</span>
      <span class="np-sep">-</span>
      <span class="np-artist">${esc(secondaryLine(item))}</span>
    </span>
  `
  refreshMarquees()
  // Sync like state from Jellyfin user data
  const liked = item.UserData?.IsFavorite || false
  document.getElementById('btn-like').classList.toggle('liked', liked)

  // Update Touch Bar track label
  window.cascade.touchbarUpdate({ title: `${item.Name}  -  ${item.AlbumArtist || item.Artists?.[0] || ''}` })

  // Notify Cha0s Stream of the new track
  window.cascade.nowPlayingUpdate({ title: item.Name || '', artist: item.AlbumArtist || item.Artists?.[0] || '', isPlaying: true })

  // Push track info to OS (lock screen, taskbar, Now Playing widget)
  if ('mediaSession' in navigator) {
    const artwork = art ? [{ src: art, sizes: '200x200', type: 'image/jpeg' }] : []
    navigator.mediaSession.metadata = new MediaMetadata({
      title:  item.Name || '',
      artist: secondaryLine(item),
      album:  item.Album || item.SeriesName || '',
      artwork,
    })
  }

  // Discord RPC
  rpcTrackStart = Date.now()
  updateDiscordPresence(item)

  // Album art accent: fetch for canvas color extraction (api_key is in URL, no extra header needed)
  // Skipped for video - the overlay shows the film, not a recoloured backdrop.
  if (themeAlbumArt && art && !video) {
    _currentBgArtUrl = art
    fetch(art)
      .then(r => r.blob())
      .then(blob => {
        const objectUrl = URL.createObjectURL(blob)
        const img = new Image()
        img.onload = () => { applyAlbumArtTheme(img); URL.revokeObjectURL(objectUrl) }
        img.onerror = () => URL.revokeObjectURL(objectUrl)
        img.src = objectUrl
      })
      .catch(() => {})
  }

  // Upgrade to iTunes high-res art in normal mode (async - replaces Jellyfin art when resolved)
  // The iTunes search is an album/artist lookup, so for a movie it either finds
  // nothing or finds a soundtrack cover and swaps the poster for it. Skip it.
  if (!serverOnlyMode && !video) {
    const artist = item.AlbumArtist || item.Artists?.[0] || ''
    const album  = item.Album || ''
    const itemId = item.Id
    fetchItunesArt(artist, album).then(itunesUrl => {
      if (!itunesUrl || queue[queueIndex]?.Id !== itemId) return  // track changed or not found
      _currentHighResArtUrl = itunesUrl
      _currentBgArtUrl = itunesUrl
      // Update status bar art
      document.getElementById('np-art').innerHTML = `<img src="${itunesUrl}" alt="" onerror="this.innerHTML='♪'">`
      // Update overlay art if open
      document.getElementById('ov-art').innerHTML = `<img src="${itunesUrl}" alt="" onerror="this.innerHTML='♪'">`
      // Update OS Now Playing widget
      if ('mediaSession' in navigator && navigator.mediaSession.metadata) {
        navigator.mediaSession.metadata.artwork = [{ src: itunesUrl, sizes: '600x600', type: 'image/jpeg' }]
      }
      // Re-run color extraction with the higher-quality source
      if (themeAlbumArt) {
        fetch(itunesUrl)
          .then(r => r.blob())
          .then(blob => {
            const objectUrl = URL.createObjectURL(blob)
            const img = new Image()
            img.onload = () => { applyAlbumArtTheme(img); URL.revokeObjectURL(objectUrl) }
            img.onerror = () => URL.revokeObjectURL(objectUrl)
            img.src = objectUrl
          })
          .catch(() => {})
      }
    })
  }

  pushMiniplayerState()
}

// ── Miniplayer state mirror ───────────────────────────────────────────────────
// The miniplayer is a remote control view (see CODEMAP.md) - it never touches
// playback itself, so the only thing that has to cross IPC is this snapshot.
// Pushed on track change, play/pause and every timeupdate; main.js drops it on
// the floor when no miniplayer window is open, so there is no need to track
// that state here too.
function pushMiniplayerState() {
  const item = queue[queueIndex]
  if (!item) { window.cascade.miniPlayer.updateState(null); return }
  const art = _currentHighResArtUrl || artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
  const track = { itemId: item.Id, title: item.Name || '', subtitle: secondaryLine(item), artUrl: art }
  window.cascade.miniPlayer.updateState(CascadeCore.buildMiniplayerState(track, !audio.paused, mediaPosition(), mediaDuration()))
}

// Derived from the DOM, never cached: _drawSongRows() replaces rows.innerHTML on every
// virtualisation redraw, so held element references go stale and their .playing class
// can never be cleared - which left two rows highlighted at once. Scanning is cheap:
// .track-row.playing matches off the class index, and the songs list only ever keeps
// SONG_WIN rows in the DOM.
function highlightPlayingRow() {
  const currentId = queue[queueIndex]?.Id
  document.querySelectorAll('.track-row.playing, .ep-row.playing').forEach(r => r.classList.remove('playing'))
  if (currentId)
    document.querySelectorAll(`.track-row[data-id="${currentId}"], .ep-row[data-id="${currentId}"]`)
      .forEach(r => r.classList.add('playing'))
}

// Report playback to Jellyfin so history updates and remote controllers can
// render a live transport. Payloads live in src/core/playback-reporting.ts.
//
// Progress has to be sent on a timer AND on every state change: without it the
// server's view freezes at track start, so a controller's scrubber never moves,
// pause never registers, and its volume slider has nothing to bind to.

let _mediaSourceId = null   // from the last PlaybackInfo; identifies the stream
/** @type {'DirectPlay' | 'DirectStream' | 'Transcode'} */
let _playMethod = 'DirectPlay'
let _progressTimer = null

// Everything a report needs about how the current track is being streamed.
// Kept together so the crossfade path can hand its already-resolved stream over
// intact instead of the pieces drifting apart.
function adoptResolvedStream(resolved) {
  _playSessionId = resolved.playSessionId
  _mediaSourceId = resolved.mediaSourceId
  _playMethod = resolved.direct ? 'DirectPlay' : 'Transcode'
  _streamOffsetSec = (resolved.startTicks || 0) / 10_000_000
  // Only a transcoded video can be re-pointed by swapping the offset. Direct
  // play seeks on the element, and music never gets here at all.
  _transcodeUrl = (!resolved.direct && isVideoItem(queue[queueIndex])) ? resolved.url : null
}

// ── Position and duration ─────────────────────────────────────────────────────
//
// A transcoded video is a stream that begins partway into the item, so the
// element's currentTime is measured from the start of the *stream*, not the
// start of the film. Everything user-facing - both scrubbers, both time labels,
// lyrics, and the position we report to Jellyfin - has to go through these two
// rather than touching audio.currentTime/duration directly.

/** How far into the current stream the element's clock starts, in seconds. */
let _streamOffsetSec = 0

/** Position within the item, in seconds. */
function mediaPosition() {
  return _streamOffsetSec + audio.currentTime
}

/**
 * Length of the item, in seconds.
 *
 * audio.duration is the truth for anything direct-played, but for a progressive
 * transcode it only counts what the server has encoded so far - it grows as you
 * watch, which is what made the scrubber useless. Jellyfin already told us the
 * real runtime, so prefer that whenever we are running off an offset stream.
 */
function mediaDuration() {
  const item = queue[queueIndex]
  if (isVideoItem(item) && item?.RunTimeTicks) return item.RunTimeTicks / 10_000_000
  return audio.duration || 0
}

/**
 * Seek to a position in the item, in seconds.
 *
 * Direct play can move the element's own clock. A transcode cannot: the bytes
 * past the encoded point do not exist yet, so the only way there is to ask the
 * server for a fresh stream starting at that offset.
 */
async function seekTo(sec) {
  const item = queue[queueIndex]
  const dur = mediaDuration()
  const target = Math.max(0, Math.min(dur || sec, sec))

  if (_playMethod === 'Transcode' && isVideoItem(item)) {
    await restartStreamAt(target)
    return
  }
  audio.currentTime = target
}

/** Which audio track the user picked, as a MediaStreams index. null = server's
 *  choice, which is what everything but an explicit switch uses. */
let _audioStreamIndex = null

/** Guards against an older restart's response overwriting a newer one. */
let _restartSession = 0

/**
 * Throw away the current stream and ask for a new one starting at `sec`.
 *
 * Both things that cannot be done to a running transcode go through here:
 * seeking past what has been encoded, and switching audio track. They are the
 * same operation - a fresh stream at a position - so they share the guard, the
 * play-state restore and the session counter rather than each growing their own.
 */
/**
 * Release the server-side encoder for whatever is playing now.
 *
 * Called before anything that repoints the element, while the current
 * PlaySessionId is still the one the server knows about. Never awaited: it is
 * cleanup, and blocking on it would add back exactly the latency the cached-URL
 * seek exists to remove.
 */
function abandonCurrentEncoding() {
  if (_playMethod !== 'Transcode' || !_playSessionId) return
  stopActiveEncoding(jfClient, jf, _playSessionId)
}

/**
 * The transcoding URL currently in use, or null when direct-playing.
 *
 * Kept so a seek can re-point the element without asking the server what to
 * play again - the answer has not changed, only the offset has.
 */
let _transcodeUrl = null

async function restartStreamAt(sec, opts = {}) {
  const item = queue[queueIndex]
  if (!item) return

  const wasPlaying = !audio.paused
  const ticks = Math.round(sec * 10_000_000)

  // Fast path, and the one that matters: a seek reuses the URL we already have.
  //
  // Re-negotiating meant a PlaybackInfo POST before the video request even
  // started, so every scrub paid a full round trip - and opened a new play
  // session server-side each time. Only an audio track change genuinely needs
  // the server to decide again, which is what `renegotiate` is for.
  if (_transcodeUrl && !opts.renegotiate) {
    // The encoder feeding the stream we are about to drop keeps running
    // otherwise. Not awaited - the new stream should start now, and this is
    // housekeeping the server can do in its own time.
    abandonCurrentEncoding()
    _streamOffsetSec = sec
    audio.src = withStartTicks(_transcodeUrl, ticks)
    if (wasPlaying) audio.play().catch(() => {})
    syncProgressUI()
    return
  }

  abandonCurrentEncoding()

  const session = ++_restartSession

  // A round trip, so the user can seek or skip again before it lands. Same
  // guard playCurrentTrack uses: re-read the queue afterwards and bail if the
  // item moved, otherwise a stale response starts the wrong thing.
  const resolved = await resolveTrackStream(item.Id, 'Video', {
    startTicks: ticks,
    audioStreamIndex: _audioStreamIndex,
  })
  if (session !== _restartSession || queue[queueIndex]?.Id !== item.Id) return

  adoptResolvedStream(resolved)
  audio.src = resolved.url

  // Direct play ignores startTicks, so the seek still has to happen on the
  // element - and only once metadata has landed.
  if (resolved.startTicks === 0 && sec > 0) {
    audio.addEventListener('loadedmetadata', () => { audio.currentTime = sec }, { once: true })
  }

  applySubtitles(item, resolved)
  if (wasPlaying) audio.play().catch(() => {})
  syncProgressUI()
}

// Snapshot of local playback in Jellyfin's units (ticks, 0-100 volume).
function playbackSnapshot(itemId, positionTicks) {
  const item = queue[queueIndex]
  return {
    itemId: itemId ?? item?.Id ?? '',
    positionTicks: positionTicks ?? Math.round(mediaPosition() * 10_000_000),
    isPaused: audio.paused,
    isMuted: audio.muted,
    volumeLevel: Math.round(volume * 100),
    playSessionId: _playSessionId,
    mediaSourceId: _mediaSourceId,
    playMethod: _playMethod,
    // Jellyfin renders a video session differently from an audio one, and a
    // controller uses QueueableMediaTypes to decide what it may push at us.
    mediaType: /** @type {'Audio' | 'Video'} */ (isVideoItem(item) ? 'Video' : 'Audio'),
  }
}

// Guards the window after a stop report. audio.pause() and currentTime = 0 both
// queue events that fire *after* reportPlaybackStopped() has already run - and
// their progress reports would re-register the track server-side, leaving a
// controller showing a stopped song stuck at 0:00.
let _reportingActive = false

function reportPlaybackStart(itemId) {
  _reportingActive = true
  CascadeCore.reportStart(jfClient, playbackSnapshot(itemId))
  startProgressReporting()
}

function reportPlaybackStopped(itemId, positionTicks) {
  _reportingActive = false
  stopProgressReporting()
  CascadeCore.reportStopped(jfClient, playbackSnapshot(itemId, positionTicks))
}

// Fires on the interval and on every play/pause/seek/volume change, so a
// controller sees state changes immediately rather than up to 10s later.
function reportPlaybackProgress() {
  if (!_reportingActive || !jf.url || queueIndex < 0) return
  const item = queue[queueIndex]
  if (!item) return
  CascadeCore.reportProgress(jfClient, playbackSnapshot(item.Id))
}

// Stop: clear the queue and return to the "Nothing playing" state. Distinct
// from pause, which keeps the track loaded.
//
// Reports stopped to Jellyfin as well as clearing locally - otherwise the
// session keeps its NowPlayingItem and a remote controller shows a track that
// this app is no longer holding.
function stopPlayback() {
  const item = queue[queueIndex]
  // Read the position before clearing src, which resets currentTime to 0.
  const positionTicks = Math.round(mediaPosition() * 10_000_000)
  abandonCurrentEncoding()
  _clearStreamPrefetch()

  audio.pause()
  _detachDeck(audio)
  audio.querySelectorAll('track').forEach(t => t.remove())
  queue = []; queueIndex = -1
  // Drop video mode after clearing the queue, so the class toggle sees an empty
  // queue and does not try to re-open the overlay.
  applyVideoMode(false)

  if (item) reportPlaybackStopped(item.Id, positionTicks)

  _clearRpcPauseTimer()  // nothing left to restore the presence for
  window.cascade.discord.clear()
  document.getElementById('np-art').innerHTML = '♪'
  document.getElementById('np-info').innerHTML = '<span class="np-empty">Nothing playing</span>'
  document.getElementById('prog-fill').style.width = '0%'
  document.getElementById('prog-cur').textContent = '0:00'
  document.getElementById('prog-dur').textContent = '0:00'
  setBarAriaNow(document.getElementById('prog-bar'), 0, 0, '0:00')
}

function startProgressReporting() {
  stopProgressReporting()
  _progressTimer = setInterval(reportPlaybackProgress, CascadeCore.PROGRESS_INTERVAL_MS)
}

function stopProgressReporting() {
  if (_progressTimer) { clearInterval(_progressTimer); _progressTimer = null }
}

// State changes a controller needs to see straight away. `volumechange` covers
// both the local slider and an incoming remote SetVolume.
;['play', 'pause', 'seeked', 'volumechange'].forEach(ev =>
  onDeck(ev, reportPlaybackProgress)
)

// ── Audio events ──────────────────────────────────────────────────────────────

// Both scrubbers show the same numbers, so they are filled from one place -
// they used to be two near-identical handlers reading audio.currentTime, and
// only one of them got fixed the first time the offset mattered.
function syncProgressUI() {
  const cur = mediaPosition()
  const dur = mediaDuration()
  const pct = dur ? `${Math.min(100, (cur / dur) * 100)}%` : '0%'

  document.getElementById('prog-cur').textContent = fmtTime(cur)
  document.getElementById('prog-dur').textContent = fmtTime(dur)
  document.getElementById('prog-fill').style.width = pct
  setBarAriaNow(document.getElementById('prog-bar'), cur, dur, fmtTime(cur))

  pushMiniplayerState()

  if (!overlayOpen) return
  document.getElementById('ov-cur').textContent = fmtTime(cur)
  document.getElementById('ov-dur').textContent = fmtTime(dur)
  document.getElementById('ov-prog-fill').style.width = pct
  setBarAriaNow(document.getElementById('ov-prog-bar'), cur, dur, fmtTime(cur))
}

onDeck('timeupdate', syncProgressUI)

onDeck('play', () => {
  document.getElementById('icon-play').style.display = 'none'
  document.getElementById('icon-pause').style.display = ''
  if (_rpcPauseTimer) { clearTimeout(_rpcPauseTimer); _rpcPauseTimer = null }
  if (_rpcClearedByPause) {
    _rpcClearedByPause = false
    // The presence was cleared while paused - recompute the start timestamp
    // from where playback actually is, otherwise Discord's elapsed time
    // counts straight through the time spent paused.
    rpcTrackStart = Date.now() - Math.round(mediaPosition() * 1000)
  }
  updateDiscordPresence(queue[queueIndex])
})

onDeck('pause', () => {
  document.getElementById('icon-play').style.display = ''
  document.getElementById('icon-pause').style.display = 'none'
  // A manual pause mid-crossfade abandons it rather than trying to keep the
  // two decks' pause state in sync - simplest behavior, least surprising.
  cancelCrossfade()

  // Give the pause a minute before giving up on the presence, rather than
  // blanking it the instant playback stops. Guarded on a loaded track so the
  // 'pause' event stopPlayback() itself triggers (via audio.pause(), queued
  // async - it fires after stopPlayback's own cleanup already ran) cannot
  // re-arm a timer for a queue that no longer exists.
  if (_rpcPauseTimer) clearTimeout(_rpcPauseTimer)
  _rpcPauseTimer = (discordEnabled && queue[queueIndex]) ? setTimeout(() => {
    _rpcPauseTimer = null
    _rpcClearedByPause = true
    window.cascade.discord.clear()
  }, RPC_PAUSE_CLEAR_MS) : null
})

onDeck('ended', () => {
  // Crossfade already handles this transition on its own timeline (driven by
  // wall-clock time, not this event) - let it finish rather than double-advance.
  if (_cfActive) return

  const item = queue[queueIndex]
  if (item) reportPlaybackStopped(item.Id, Math.round(audio.duration * 10000000))

  if (sleepAtTrackEnd) {
    sleepAtTrackEnd = false
    document.getElementById('ov-sleep-timer').classList.remove('active')
    showToast('Sleep timer: playback paused')
    return
  }

  if (repeatMode === 'one') {
    audio.currentTime = 0
    audio.play()
    return
  }

  let next = queueIndex + 1
  if (next >= queue.length) {
    if (repeatMode === 'all') { queueIndex = 0; playCurrentTrack(); return }
    // Instant mix is a music feature. Asking Jellyfin for one "similar to" the
    // last episode of a season would either fail or queue up something random.
    if (autoMixEnabled && item && !isVideoItem(item)) continueWithAutoMix(item)
    return
  }
  queueIndex = next
  playCurrentTrack()
})

// Fetches similar tracks to the one that just ended and appends them to the queue,
// continuing playback - only reached when the queue runs out and auto-mix is on.
async function continueWithAutoMix(lastItem) {
  try {
    const data = await jfGet(`/Items/${lastItem.Id}/InstantMix`, {
      UserId: jf.userId, Limit: 25,
      Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag'
    })
    const items = (data.Items || []).filter(i => i.Id !== lastItem.Id)
    if (!items.length) return
    const startIndex = queue.length
    queue.push(...items)
    queueIndex = startIndex
    playCurrentTrack()
    renderQueuePanel()
    showToast('Auto-mix added similar tracks to the queue')
  } catch (e) {
    console.error('Auto-mix failed', e)
  }
}

// ── Crossfade ────────────────────────────────────────────────────────────────
// Fades the ending track out on the current deck while the other, permanent
// deck loads and fades the next track in, then hands off by pointing `audio`
// at that deck - no src copying, no seek. Every existing listener (progress
// bar, lyrics sync, Discord RPC, media session, the now-playing equalizer) is
// bound through onDeck(), so it keeps reading whichever deck is current
// without needing to know a crossfade happened.
//
// The envelope itself lives entirely in the two decks' GainNodes (see
// _ensureEqGraph/_deckGain), ramped on the audio thread with an equal-power
// curve - element .volume never moves during a fade, so a user volume change
// mid-crossfade just works, and there is no rAF loop to stutter on a dropped
// frame.

let _cfArmed = true        // guards against re-triggering mid-fade; re-set per track
let _cfSession = 0         // bumped on cancel, so an in-flight stream resolve knows to stop
let _cfActive = false      // true from the start of a fade until the handoff completes
let _cfOtherDeck = null    // the deck fading in, while a crossfade is in progress
let _cfNextResolved = null   // resolved stream of the incoming track, adopted on finish

// Mirrors the `ended` handler's "what plays next" logic, but only for the case
// where the next track is already known - skips the auto-mix case, since that
// track doesn't exist until the current one actually finishes.
function _resolveCrossfadeTarget() {
  const next = nextQueueIndex(queue.length, queueIndex, repeatMode)
  return next === null ? -1 : next
}

onDeck('timeupdate', () => {
  if (!crossfadeEnabled || !_cfArmed || _cfActive) return
  // No Web Audio graph means no GainNode to ramp on. There is deliberately no
  // second, element-.volume-based fallback ramp. Note this is the hard failure
  // only: an analyser that reads nothing (_eqNoSignal) stands the bars down but
  // leaves the gains working, and must not take crossfade with it.
  if (_eqGraphFailed) return
  // Overlapping the end of one episode with the start of the next is not a
  // thing anyone wants, and crossfading video would drop the picture anyway.
  if (playingVideo()) return
  if (!audio.duration || !isFinite(audio.duration)) return
  if (sleepAtTrackEnd) return
  const remaining = audio.duration - audio.currentTime
  if (remaining > crossfadeSeconds || remaining <= 0) return
  const nextIndex = _resolveCrossfadeTarget()
  if (nextIndex < 0) return
  _cfArmed = false
  startCrossfade(nextIndex)
})

async function startCrossfade(nextIndex) {
  const nextItem = queue[nextIndex]
  if (!nextItem) return

  // Bumped up front so cancelCrossfade() landing anywhere below - during a
  // resolve, or during the buffer wait - is caught before the deck is touched.
  const session = ++_cfSession

  const outgoing = audio
  let incoming, resolved

  if (_streamPrefetch && _streamPrefetch.itemId === nextItem.Id && _streamPrefetch.deck !== outgoing) {
    // Already buffered on the idle deck - skip the round trip and cold load.
    incoming = _streamPrefetch.deck
    resolved = _streamPrefetch.resolved
    _streamPrefetch = null
    // A hit only means the right track is on the idle deck, not that it
    // buffered: preload='auto' is a hint Chromium is free to ignore, and it
    // often does with two media elements alive. Record how ready it actually
    // was, because a hit that still has to cold-fill behaves like a miss and
    // the two are otherwise indistinguishable after the fact.
    _lastPrefetchOutcome = { at: Date.now(), from: 'crossfade', hit: true, readyState: incoming.readyState }
  } else {
    // No usable prefetch (not ready, wrong item, or none). Clear whatever is
    // there first - a stale or still-in-flight prefetch would otherwise race
    // the load below for the same idle deck.
    _clearStreamPrefetch()
    _lastPrefetchOutcome = { at: Date.now(), from: 'crossfade', hit: false }
    resolved = await resolveTrackStream(nextItem.Id)
    if (session !== _cfSession) {
      if (!resolved.direct) stopActiveEncoding(jfClient, jf, resolved.playSessionId)
      return
    }
    incoming = DECKS.find(d => d !== outgoing)
    incoming.src = resolved.url
  }

  incoming.volume = volume   // element volume stays at user volume on both decks always

  // Idempotent - already built from the first track's `play` event in the
  // overwhelming majority of cases. Guards against the (never actually
  // reachable, since timeupdate implies a prior play) edge of arming before
  // the graph exists. Built (and the incoming deck silenced) *before* play()
  // now: with the buffer wait below sitting between play() and the ramp, an
  // incoming deck would otherwise play out loud at whatever gain it was last
  // left at for however long buffering takes, instead of staying silent
  // until the ramp actually starts.
  _ensureEqGraph()
  const outGain = _deckGain(outgoing)
  const inGain = _deckGain(incoming)
  if (inGain && _audioCtx) {
    inGain.gain.cancelScheduledValues(_audioCtx.currentTime)
    inGain.gain.setValueAtTime(0, _audioCtx.currentTime)
  }

  incoming.play().catch(() => {})

  // Tracked from here, not after the buffer wait below - a cancelCrossfade()
  // landing during that wait (pause, skip, track change) has to be able to
  // find and clean up this deck.
  _cfOtherDeck = incoming
  _cfNextResolved = resolved

  // Hold the gain ramp off until the incoming deck can actually play through -
  // starting it the instant play() is called fades into silence on a slow
  // start. Bounded so a stream that never becomes ready cannot hang the
  // crossfade forever; on timeout, just let the track change happen normally
  // when this one ends.
  const ready = await _waitForPlayable(incoming)
  if (session !== _cfSession) return   // cancelCrossfade() already cleaned this up
  if (!ready) {
    // Abandoned - whether this came from the prefetch or a fresh resolve, the
    // server should stop encoding for it rather than run an orphaned stream.
    if (!resolved.direct) stopActiveEncoding(jfClient, jf, resolved.playSessionId)
    incoming.pause()
    _detachDeck(incoming)
    _cfOtherDeck = null
    _cfNextResolved = null
    return
  }

  // The wait above costs real time when nothing was prefetched, and the fade
  // was scheduled against how much track was left before it. Fading for longer
  // than remains means the outgoing track hits `ended` partway through, which
  // hands over abruptly - the exact thing the fade exists to avoid. Fade for
  // whatever is actually left when the ramp finally starts.
  const remaining = audio.duration - audio.currentTime
  const fadeSecs = CascadeCore.fadeDurationSecs(crossfadeSeconds, remaining)
  if (fadeSecs === null) {
    // Not enough of the outgoing track left to fade across. The old code
    // clamped to a 0.1s floor here, which is a hard cut with a smear on it,
    // landing mid-phrase because the outgoing track is being ended early to
    // make room for a fade that is not happening. Hand over cleanly instead.
    const g = _deckGain(incoming)
    if (g && _audioCtx) { g.gain.cancelScheduledValues(_audioCtx.currentTime); g.gain.setValueAtTime(1, _audioCtx.currentTime) }
    _cfActive = true
    finishCrossfade(nextIndex, incoming)
    return
  }

  if (outGain && inGain && _audioCtx) {
    const { outCurve, inCurve } = CascadeCore.equalPowerCrossfadeCurves()
    const now = _audioCtx.currentTime
    outGain.gain.cancelScheduledValues(now)
    inGain.gain.cancelScheduledValues(now)
    outGain.gain.setValueCurveAtTime(outCurve, now, fadeSecs)
    inGain.gain.setValueCurveAtTime(inCurve, now, fadeSecs)
  }
  _cfActive = true

  // The audio thread owns the actual ramp above; this timer only triggers the
  // JS-side handoff bookkeeping once it has finished, so a little timer
  // jitter here does not affect what the fade sounded like.
  setTimeout(() => {
    if (_cfOtherDeck !== incoming) return   // cancelled mid-fade
    finishCrossfade(nextIndex, incoming)
  }, fadeSecs * 1000)
}

// Point `audio` at `incoming`, park `outgoing`. Shared by finishCrossfade and
// playCurrentTrack's prefetched-advance path, so both leave the same things
// correct: the current-deck pointer, the EQ tap, and which deck goes idle.
//
// Swaps the pointer before touching the outgoing element on purpose:
// onDeck() filters every listener by `e.target === audio`, so doing this
// first means the outgoing deck's own pause/emptied events (right below)
// read as "the idle deck went quiet", not as this track pausing - a manual
// pause fires cancelCrossfade(), which must not happen here.
// Detach a deck from whatever it was playing.
//
// NOT by assigning an empty string to .src, which is what this used to be
// everywhere. An empty src attribute gets resolved against the document base
// URL by the resource selection algorithm, so it does not mean "no resource",
// it means "load the page itself as media". Chromium duly goes and fetches
// index.html, tries to demux it, fails, and fires an error, all for nothing.
// In _swapDeck that landed on every single crossfade handoff, and there is no
// error listener on either deck to notice it happening.
//
// removeAttribute + load() runs the same algorithm to its genuine empty case:
// no fetch, no decode attempt, element back to HAVE_NOTHING.
function _detachDeck(el) {
  el.removeAttribute('src')
  el.load()
}

function _swapDeck(incoming, outgoing) {
  audio = incoming
  // Guarded: finishCrossfade only reaches here when the graph already exists
  // (crossfade will not start without it), but the prefetched-advance path in
  // playCurrentTrack is not gated on that, and _deckSource() needs _audioCtx.
  if (_audioCtx) {
    _mediaSrc = _deckSource(incoming)
    // A deck's gain can be left at 0 by an abandoned or cancelled crossfade
    // (see cancelCrossfade/startCrossfade's buffer-wait timeout) and that
    // same idle deck is exactly what a later prefetch picks up. Force it back
    // to full now that this deck is the only one playing - after a completed
    // crossfade ramp it is already ~1, so this is a no-op snap to exact.
    const inGain = _deckGain(incoming)
    if (inGain) { inGain.gain.cancelScheduledValues(_audioCtx.currentTime); inGain.gain.setValueAtTime(1, _audioCtx.currentTime) }
  }
  outgoing.pause()
  _detachDeck(outgoing)
}

function finishCrossfade(nextIndex, incoming) {
  const outgoing = audio
  const outgoingItem = queue[queueIndex]
  if (outgoingItem) reportPlaybackStopped(outgoingItem.Id, Math.round(outgoing.currentTime * 10000000))

  _swapDeck(incoming, outgoing)
  _cfActive = false
  _cfOtherDeck = null

  queueIndex = nextIndex
  // The incoming deck has been playing throughout the fade, so no fresh
  // `play` event fires here to restart the EQ loop or the lyrics word loop
  // for the new track - nudge both explicitly. Both guard themselves, so
  // this is a no-op if they are already running.
  startEqLoop()
  _startWordLoop()
  playCurrentTrack({ alreadyPlaying: true, resolved: _cfNextResolved })
  _cfNextResolved = null
  // Same "no fresh play event" reasoning applies to prefetch scheduling - and
  // it has to come after playCurrentTrack(), which clears any stale prefetch
  // left over from before the handoff.
  _schedulePrefetch()
  renderQueuePanel()
}

function cancelCrossfade() {
  // Bump first: this is what tells an in-flight startCrossfade() resolve that
  // it no longer owns the crossfade.
  _cfSession++
  if (_cfOtherDeck) {
    const otherDeck = _cfOtherDeck
    if (_audioCtx) {
      const now = _audioCtx.currentTime
      const outGain = _deckGain(audio)
      const inGain = _deckGain(otherDeck)
      // Playback stays on `audio` (the fade never finished), so its gain goes
      // back to full; the abandoned deck's gain is reset defensively, though
      // its src is cleared below either way.
      if (outGain) { outGain.gain.cancelScheduledValues(now); outGain.gain.setValueAtTime(1, now) }
      if (inGain) { inGain.gain.cancelScheduledValues(now); inGain.gain.setValueAtTime(0, now) }
    }
    otherDeck.pause()
    _detachDeck(otherDeck)
    // The incoming stream was negotiated and, if transcoded, is being encoded
    // right now for a track we are walking away from. Every other abandon path
    // tells the server to stop; this one used to just drop it.
    if (_cfNextResolved && !_cfNextResolved.direct) {
      stopActiveEncoding(jfClient, jf, _cfNextResolved.playSessionId)
    }
  }
  _cfActive = false
  _cfOtherDeck = null
  _cfNextResolved = null
  _cfArmed = true
}

// ── Stream prefetch ──────────────────────────────────────────────────────────
// Loads the NEXT track into the idle deck once the current one is genuinely
// playing, so a normal advance (playCurrentTrack) or a crossfade
// (startCrossfade) can play what is already buffered instead of paying a
// PlaybackInfo round trip and a cold start. Exactly one track prefetched at a
// time - what "next" means under repeat/shuffle is nextQueueIndex() (see
// _resolveCrossfadeTarget), same as crossfade scheduling.

let _streamPrefetch = null   // { itemId, resolved, deck } for the buffered next track, or null
let _prefetchToken = 0       // bumped to disown an in-flight resolve when invalidated
let _prefetchTimer = null    // the "give the current track's own buffering room" delay

// Last time a track advance looked for a prefetched deck, hit or miss. Only
// consulted by the debug panel - existence of an intermittent crossfade
// stutter suggests this misses more than it should, and there was no way to
// see that without instrumenting a debug session by hand.
let _lastPrefetchOutcome = null   // { at, from, hit, readyState? }

const PREFETCH_DELAY_MS = 3000

/** Drop whatever is prefetched (or in flight), telling the server to stop encoding it. */
function _clearStreamPrefetch() {
  _prefetchToken++
  if (_prefetchTimer) { clearTimeout(_prefetchTimer); _prefetchTimer = null }
  if (_streamPrefetch) {
    const { deck, resolved } = _streamPrefetch
    if (!resolved.direct) stopActiveEncoding(jfClient, jf, resolved.playSessionId)
    deck.pause()
    _detachDeck(deck)
    _streamPrefetch = null
  }
}

/** Wait a bit after the current track starts playing, then prefetch the next one. */
function _schedulePrefetch() {
  if (_prefetchTimer) clearTimeout(_prefetchTimer)
  const token = _prefetchToken
  _prefetchTimer = setTimeout(() => {
    _prefetchTimer = null
    if (token === _prefetchToken) _prefetchNext()
  }, PREFETCH_DELAY_MS)
}

/** Resolve and buffer the next track into the idle deck, if there is one worth prefetching. */
async function _prefetchNext() {
  // Movies/episodes are large, and crossfade already skips video for the same reason.
  if (playingVideo()) return
  const nextIndex = _resolveCrossfadeTarget()
  const nextItem = nextIndex >= 0 ? queue[nextIndex] : null
  if (!nextItem || isVideoItem(nextItem)) return
  if (_streamPrefetch?.itemId === nextItem.Id) return   // already have it

  _clearStreamPrefetch()
  const token = _prefetchToken
  const deck = DECKS.find(d => d !== audio)
  const resolved = await resolveTrackStream(nextItem.Id)
  // Invalidated (track changed, queue mutated) while the round trip was in
  // flight - the deck we would have loaded may not even be idle any more.
  if (token !== _prefetchToken || playingVideo()) {
    if (!resolved.direct) stopActiveEncoding(jfClient, jf, resolved.playSessionId)
    return
  }
  deck.preload = 'auto'
  deck.src = resolved.url
  deck.load()
  _streamPrefetch = { itemId: nextItem.Id, resolved, deck }
}

onDeck('playing', _schedulePrefetch)

// For a queue mutation that does not itself change the playing track (shuffle,
// repeat mode, a reorder, a removal elsewhere in the queue) - the current
// track is already settled, so re-prefetch immediately rather than waiting
// for another 'playing' event that will not come.
function _reprefetch() {
  _clearStreamPrefetch()
  _prefetchNext()
}

/**
 * Wait until `deck` can play through, or `timeoutMs` elapses - whichever comes
 * first. Used to hold the crossfade gain ramp off a deck that has not actually
 * buffered yet, so a slow start fades up instead of fading into silence.
 */
function _waitForPlayable(deck, timeoutMs = 4000) {
  return new Promise(resolve => {
    if (deck.readyState >= 4) { resolve(true); return }   // HAVE_ENOUGH_DATA already
    let done = false
    const onReady = () => finish(true)
    const timer = setTimeout(() => finish(false), timeoutMs)
    function finish(ok) {
      if (done) return
      done = true
      deck.removeEventListener('canplaythrough', onReady)
      clearTimeout(timer)
      resolve(ok)
    }
    deck.addEventListener('canplaythrough', onReady, { once: true })
  })
}

// ── Player controls ───────────────────────────────────────────────────────────

document.getElementById('btn-play').addEventListener('click', () => {
  if (audio.paused) audio.play()
  else audio.pause()
})

document.getElementById('btn-prev').addEventListener('click', () => {
  if (mediaPosition() > 3) { seekTo(0); return }
  queueIndex = Math.max(0, queueIndex - 1)
  playCurrentTrack()
})

document.getElementById('btn-next').addEventListener('click', () => {
  queueIndex = Math.min(queue.length - 1, queueIndex + 1)
  playCurrentTrack()
})

document.getElementById('btn-shuffle').addEventListener('click', () => {
  shuffle = !shuffle
  document.getElementById('btn-shuffle').classList.toggle('active', shuffle)

  const currentId = queue[queueIndex]?.Id

  if (shuffle) {
    // Save original order, then shuffle the live queue in place
    _unshuffledQueue = [...queue]
    shuffleInPlace(queue)
    // Move the currently playing track to position 0 so it finishes before moving on
    const nowIdx = queue.findIndex(t => t.Id === currentId)
    if (nowIdx > 0) { const [t] = queue.splice(nowIdx, 1); queue.unshift(t) }
    queueIndex = 0
  } else {
    // Restore original order, keeping the same track playing
    queue = _unshuffledQueue
    _unshuffledQueue = []
    queueIndex = Math.max(0, queue.findIndex(t => t.Id === currentId))
  }

  _reprefetch()   // shuffling changes what "next" means
  if (overlayOpen) renderQueuePanel()
})

const REPEAT_ICON_ALL = `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="17 1 21 5 17 9"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><polyline points="7 23 3 19 7 15"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/></svg>`
const REPEAT_ICON_ONE = `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="17 1 21 5 17 9"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><polyline points="7 23 3 19 7 15"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/><path d="M11 10h1v4"/></svg>`
const REPEAT_ICON_ALL_LG = `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="17 1 21 5 17 9"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><polyline points="7 23 3 19 7 15"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/></svg>`
const REPEAT_ICON_ONE_LG = `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="17 1 21 5 17 9"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><polyline points="7 23 3 19 7 15"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/><path d="M11 10h1v4"/></svg>`

function updateRepeatButtons() {
  const isOne = repeatMode === 'one'
  const active = repeatMode !== 'none'
  const btnR = document.getElementById('btn-repeat')
  const ovR  = document.getElementById('ov-repeat')
  btnR.innerHTML = isOne ? REPEAT_ICON_ONE    : REPEAT_ICON_ALL
  ovR.innerHTML  = isOne ? REPEAT_ICON_ONE_LG : REPEAT_ICON_ALL_LG
  btnR.classList.toggle('active', active)
  ovR.classList.toggle('active', active)
  btnR.title = isOne ? 'Repeat one' : active ? 'Repeat all' : 'Repeat'
  ovR.title  = btnR.title
}

document.getElementById('btn-repeat').addEventListener('click', () => {
  const modes = ['none', 'all', 'one']
  repeatMode = modes[(modes.indexOf(repeatMode) + 1) % modes.length]
  updateRepeatButtons()
  _reprefetch()   // repeat mode changes what "next" means
})

// ── Scrubber bars ────────────────────────────────────────────────────────────
//
// All four bars (statusbar/overlay x progress/volume) go through wireBar() for
// their drag and keyboard mechanics - only what a ratio *means* differs between
// them, which is what wireProgressBar()/wireVolumeBar() below supply.

/**
 * Wires one bar for click-and-drag, plus focus and arrow-key control as a real
 * role="slider".
 *
 * getRatio() reports where the bar should currently show, 0..1. onChange(ratio)
 * paints that live, on every drag move and every key step. onCommit(ratio), if
 * given, fires once the interaction settles - a drag's mouseup, or a short pause
 * after a run of key presses - for bars where acting on every intermediate step
 * would be wasteful (a transcoded seek restarts the stream) or wrong (a plain
 * click mid-drag should not seek per pixel). Volume has no such settle point, so
 * its onChange does the whole job and it passes no onCommit.
 */
function wireBar(bar, { getRatio, onChange, onCommit, step, bigStep }) {
  const ratioAt = (e) => {
    const rect = bar.getBoundingClientRect()
    return Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width))
  }

  let dragging = false
  function onMove(e) { if (dragging) onChange(ratioAt(e)) }
  function onUp(e) {
    if (!dragging) return
    dragging = false
    bar.classList.remove('dragging')
    document.removeEventListener('mousemove', onMove)
    document.removeEventListener('mouseup', onUp)
    if (onCommit) onCommit(ratioAt(e))
  }
  bar.addEventListener('mousedown', (e) => {
    // The pointer leaves the bar constantly while dragging, so hover alone
    // would flicker the handle away mid-drag - .dragging keeps it up for the
    // whole thing.
    dragging = true; bar.classList.add('dragging'); onChange(ratioAt(e)); e.preventDefault()
    document.addEventListener('mousemove', onMove)
    document.addEventListener('mouseup', onUp)
  })

  // A held or repeated key can fire many keydowns a second - committing on
  // every one would do to a keyboard seek what per-pixel dragging would do to
  // a mouse one, so the commit is debounced the same way a drag's is by
  // waiting for mouseup.
  let commitTimer = null
  bar.addEventListener('keydown', (e) => {
    const cur = getRatio()
    let next
    if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') next = Math.max(0, cur - step())
    else if (e.key === 'ArrowRight' || e.key === 'ArrowUp') next = Math.min(1, cur + step())
    else if (e.key === 'PageDown') next = Math.max(0, cur - bigStep())
    else if (e.key === 'PageUp') next = Math.min(1, cur + bigStep())
    else if (e.key === 'Home') next = 0
    else if (e.key === 'End') next = 1
    else return
    // Stopped here, not left to bubble, so the video overlay's own arrow-key
    // handler (only live when a video overlay is open) never also acts on the
    // same press.
    e.preventDefault()
    e.stopPropagation()
    onChange(next)
    if (onCommit) {
      clearTimeout(commitTimer)
      commitTimer = setTimeout(() => onCommit(next), 150)
    }
  })
}

/** Keeps a slider's aria-valuenow (and, for a time-based one, valuemax/valuetext)
 *  in step with what it currently shows. */
function setBarAriaNow(bar, now, max, text) {
  if (max !== undefined) bar.setAttribute('aria-valuemax', String(Math.round(max)))
  bar.setAttribute('aria-valuenow', String(Math.round(now)))
  if (text !== undefined) bar.setAttribute('aria-valuetext', text)
}

/** Wires a progress bar (statusbar or overlay) - drag, click and keyboard all
 *  land here. Seeking is committed on release/settle, not per move: scrubbing a
 *  transcode re-requests the stream, so seeking per pixel or per keypress would
 *  fire a request storm at the server, while the fill and time label still track
 *  live so the interaction feels immediate. */
function wireProgressBar(barId, fillId, curId) {
  const bar = document.getElementById(barId)
  wireBar(bar, {
    getRatio: () => { const dur = mediaDuration(); return dur ? mediaPosition() / dur : 0 },
    step:     () => { const dur = mediaDuration(); return dur ? 5 / dur : 0.05 },
    bigStep:  () => { const dur = mediaDuration(); return dur ? 30 / dur : 0.1 },
    onChange: (ratio) => {
      const dur = mediaDuration()
      document.getElementById(fillId).style.width = `${ratio * 100}%`
      if (dur) document.getElementById(curId).textContent = fmtTime(ratio * dur)
      setBarAriaNow(bar, ratio * dur, dur, fmtTime(ratio * dur))
    },
    onCommit: (ratio) => { const dur = mediaDuration(); if (dur) seekTo(ratio * dur) },
  })
}

/** Wires a volume bar (statusbar or overlay) through the shared setVolumeRatio(),
 *  which is what keeps the two mirrored. */
function wireVolumeBar(barId) {
  wireBar(document.getElementById(barId), {
    getRatio: () => audio.volume,
    step:     () => 0.05,
    bigStep:  () => 0.2,
    onChange: (ratio) => setVolumeRatio(ratio),
  })
}

wireProgressBar('prog-bar', 'prog-fill', 'prog-cur')
wireVolumeBar('vol-bar')

document.getElementById('btn-mute').addEventListener('click', () => {
  setDeckMuted(!audio.muted)
})

// Lyrics open button
document.getElementById('btn-lyrics-open').addEventListener('click', () => showLyrics())

// Miniplayer open button - main.js minimizes this window and creates (or
// focuses) the small always-on-top remote control window.
document.getElementById('btn-miniplayer-open').addEventListener('click', () => {
  pushMiniplayerState()
  window.cascade.miniPlayer.open()
})

// Like / favourite
const likeBtn = document.getElementById('btn-like')

async function toggleLike() {
  const item = queue[queueIndex]
  if (!item) return
  const isLiked = likeBtn.classList.contains('liked')
  try {
    await fetch(`${jf.url}/Users/${jf.userId}/FavoriteItems/${item.Id}`, {
      method: isLiked ? 'DELETE' : 'POST',
      headers: { 'X-Emby-Token': jf.token }
    })
    likeBtn.classList.toggle('liked', !isLiked)
    document.getElementById('ov-like').classList.toggle('liked', !isLiked)
  } catch (e) { console.error('Like failed', e) }
}

likeBtn.addEventListener('click', toggleLike)

// ── Shuffle All ───────────────────────────────────────────────────────────────

// Shuffle a copy of items, then play it. Shared by every "Shuffle" button.
function shuffleAndPlay(items) {
  if (!items.length) return
  const order = shuffled(items)

  // Store originals so toggling shuffle off restores order
  _unshuffledQueue = items
  shuffle = true
  document.getElementById('btn-shuffle').classList.add('active')
  document.getElementById('ov-shuffle').classList.add('active')

  playItems(order, 0)
}

async function shuffleAllSongs() {
  // Load songs if not yet fetched
  if (!allSongs.length) {
    // No SortBy here - the result is shuffled immediately below, so making the
    // server sort the whole library first would be wasted work. Paginate with
    // jfGetAllPaged instead of jfGetMerged so libraries over 500 tracks aren't
    // silently truncated.
    const params = { IncludeItemTypes: 'Audio', Recursive: true, Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag,UserData', Limit: 500 }
    const data = await jfGetAllPaged(`/Users/${jf.userId}/Items`, params)
    allSongs = data.Items || []
    // If songs view is open, render the rows too
    if (document.getElementById('songs-rows').dataset.loaded) renderSongRows()
  }
  shuffleAndPlay(allSongs)
}

document.getElementById('btn-shuffle-songs').addEventListener('click', shuffleAllSongs)
document.getElementById('btn-shuffle-albums').addEventListener('click', shuffleAllSongs)
document.getElementById('btn-shuffle-artists').addEventListener('click', shuffleAllSongs)

// ── Native media session (OS media keys + lock screen / taskbar integration) ──

if ('mediaSession' in navigator) {
  navigator.mediaSession.setActionHandler('play',          () => { if (audio.paused) audio.play() })
  navigator.mediaSession.setActionHandler('pause',         () => { if (!audio.paused) audio.pause() })
  navigator.mediaSession.setActionHandler('stop',          () => stopPlayback())
  navigator.mediaSession.setActionHandler('nexttrack',     () => document.getElementById('btn-next').click())
  navigator.mediaSession.setActionHandler('previoustrack', () => document.getElementById('btn-prev').click())
  navigator.mediaSession.setActionHandler('seekto', (details) => {
    if (mediaDuration() && details.seekTime != null) seekTo(details.seekTime)
  })
}

// IPC fallback for Windows globalShortcut (covers cases where mediaSession alone isn't enough)
window.cascade.onMediaKey((key) => {
  if (key === 'playpause') document.getElementById('btn-play').click()
  else if (key === 'next')  document.getElementById('btn-next').click()
  else if (key === 'prev')  document.getElementById('btn-prev').click()
})

// Keep OS media session state in sync with playback
onDeck('play',  () => {
  if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing'
  window.cascade.touchbarUpdate({ playing: true })
  window.cascade.nowPlayingUpdate({ isPlaying: true })
  pushMiniplayerState()
})
onDeck('pause', () => {
  if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused'
  window.cascade.touchbarUpdate({ playing: false })
  window.cascade.nowPlayingUpdate({ isPlaying: false })
  pushMiniplayerState()
})

// Miniplayer control -> the exact same buttons onMediaKey above already
// drives, not a second playback path.
window.cascade.miniPlayer.onControl((action) => {
  if (action === 'playpause') document.getElementById('btn-play').click()
  else if (action === 'next')  document.getElementById('btn-next').click()
  else if (action === 'prev')  document.getElementById('btn-prev').click()
})

// ── Settings ──────────────────────────────────────────────────────────────────

async function loadSettingsFields() {
  document.getElementById('s-url').value  = await window.cascade.store.get('serverUrl') || ''
  document.getElementById('s-user').value = await window.cascade.store.get('username') || ''
  document.getElementById('s-pass').value = ''

  // Beta updates toggle - defaults on for a beta build itself, same rule main.js
  // uses for the actual update check, unless the user has explicitly chosen otherwise.
  const betaUpdatesToggle = document.getElementById('beta-updates-toggle')
  const savedBetaPref = await window.cascade.store.get('betaUpdates')
  const isBetaBuild = /-b\d*$/.test(appVersion)
  betaUpdatesToggle.checked = savedBetaPref === undefined ? isBetaBuild : savedBetaPref === true
  betaUpdatesToggle.onchange = async () => {
    await window.cascade.store.set('betaUpdates', betaUpdatesToggle.checked)
  }

  // Crossfade settings
  const crossfadeToggle = document.getElementById('crossfade-toggle')
  const crossfadeDurationRow = document.getElementById('crossfade-duration-row')
  const crossfadeDurationSlider = document.getElementById('crossfade-duration')
  const crossfadeDurationValue = document.getElementById('crossfade-duration-value')
  crossfadeToggle.checked = crossfadeEnabled
  crossfadeDurationRow.style.display = crossfadeEnabled ? '' : 'none'
  crossfadeDurationSlider.value = String(crossfadeSeconds)
  crossfadeDurationValue.textContent = `${crossfadeDurationSlider.value}s`
  crossfadeToggle.onchange = async () => {
    crossfadeDurationRow.style.display = crossfadeToggle.checked ? '' : 'none'
    await setCrossfadeEnabled(crossfadeToggle.checked)
  }
  crossfadeDurationSlider.oninput = () => {
    crossfadeDurationValue.textContent = `${crossfadeDurationSlider.value}s`
  }
  crossfadeDurationSlider.onchange = async () => {
    await setCrossfadeSeconds(parseInt(crossfadeDurationSlider.value, 10))
  }

  // Streaming quality. Takes effect on the next track - the current stream URL
  // was already negotiated at the old bitrate. Stepped, not continuous - the
  // server only transcodes to the exact bitrates in MAX_BITRATE_STEPS.
  const maxBitrateSlider = document.getElementById('max-bitrate')
  const maxBitrateValue = document.getElementById('max-bitrate-value')
  const maxBitrateStepIndex = () => {
    const i = MAX_BITRATE_STEPS.findIndex(s => s.value === maxStreamingBitrate)
    return i === -1 ? 0 : i
  }
  maxBitrateSlider.value = String(maxBitrateStepIndex())
  maxBitrateValue.textContent = MAX_BITRATE_STEPS[maxBitrateStepIndex()].label
  maxBitrateSlider.oninput = () => {
    maxBitrateValue.textContent = MAX_BITRATE_STEPS[Number(maxBitrateSlider.value)].label
  }
  maxBitrateSlider.onchange = async () => {
    await setMaxStreamingBitrate(MAX_BITRATE_STEPS[Number(maxBitrateSlider.value)].value)
  }

  // Waterfall relay. Blank means the default, so clearing the box is the reset.
  const wfRelayInput = document.getElementById('s-wf-relay')
  wfRelayInput.value = (await window.cascade.store.get('waterfallRelay')) || ''
  wfRelayInput.placeholder = typeof WF_DEFAULT_RELAY === 'string' ? WF_DEFAULT_RELAY : 'Default'
  wfRelayInput.onchange = async () => {
    const raw = wfRelayInput.value.trim().replace(/\/+$/, '')
    if (raw && !/^https?:\/\/[^\s/]+/i.test(raw)) {
      showNotice('The relay address must start with http:// or https://', 'Waterfall relay')
      wfRelayInput.value = (await window.cascade.store.get('waterfallRelay')) || ''
      return
    }
    await window.cascade.store.set('waterfallRelay', raw)
    wfRelayInput.value = raw
    showToast(raw ? 'Waterfall relay updated' : 'Using the default Waterfall relay')
  }

  // Discord RPC settings
  const discordToggle = document.getElementById('discord-rpc-toggle')
  const discordInput  = document.getElementById('discord-client-id')
  discordToggle.checked = (await window.cascade.store.get('discordRpcEnabled')) === 'true'
  discordInput.value    = await window.cascade.store.get('discordClientId') || DEFAULT_DISCORD_CLIENT_ID

  discordToggle.onchange = async () => {
    await window.cascade.store.set('discordRpcEnabled', String(discordToggle.checked))
    const clientId = discordInput.value.trim()
    discordEnabled = discordToggle.checked && !!clientId
    if (discordEnabled) {
      window.cascade.discord.connect(clientId)
    } else {
      window.cascade.discord.connect(null) // disconnects
      _clearRpcPauseTimer()
      window.cascade.discord.clear()
    }
  }

  discordInput.onchange = async () => {
    const clientId = discordInput.value.trim()
    await window.cascade.store.set('discordClientId', clientId)
    if (discordToggle.checked && clientId) {
      discordEnabled = true
      window.cascade.discord.connect(clientId)
    }
  }

  // Status is updated by the listener in initDiscordRpc(); sync label to current state here
  const rpcLabel = document.getElementById('discord-rpc-status-label')
  if (rpcLabel) rpcLabel.textContent = _rpcConnected ? 'Connected' : 'Not connected'

  document.getElementById('discord-dev-link').onclick = (e) => {
    e.preventDefault()
    window.cascade.shell.openExternal('https://discord.com/developers/applications')
  }

  // Server-only lyrics toggle
  const serverOnlyToggle = document.getElementById('server-only-lyrics-toggle')
  serverOnlyToggle.checked = serverOnlyMode
  serverOnlyToggle.onchange = async () => {
    if (serverOnlyToggle.checked) {
      const proceed = await _ensureCascadePluginNotice()
      if (!proceed) { serverOnlyToggle.checked = false; return }
    }
    serverOnlyMode = serverOnlyToggle.checked
    await window.cascade.store.set('serverOnlyMode', serverOnlyMode)
    _applyServerOnlyMode(serverOnlyMode)
    // Reset forced source if it's incompatible with the new mode
    const isServerSource = ['cascade-karaoke', 'cascade-synced'].includes(lyricsForcedSource)
    if (serverOnlyMode && !isServerSource && lyricsForcedSource !== 'auto') {
      lyricsForcedSource = 'auto'
      await window.cascade.store.set('lyricsForcedSource', 'auto')
    } else if (!serverOnlyMode && isServerSource) {
      lyricsForcedSource = 'auto'
      await window.cascade.store.set('lyricsForcedSource', 'auto')
    }
    const sel = document.getElementById('s-lyrics-source')
    if (sel) sel.value = lyricsForcedSource
    updateSourcePills()
    _reloadLyricsFor()
  }
  _applyCascadePluginAvailability()  // re-apply in case the probe resolved before this view existed

  // Lyrics source preference
  const lyricsSourceSel = document.getElementById('s-lyrics-source')
  lyricsSourceSel.value = VALID_LYRICS_SOURCES.has(lyricsForcedSource) ? lyricsForcedSource : 'auto'
  _applyServerOnlyMode(serverOnlyMode)  // apply visibility after options exist in DOM
  lyricsSourceSel.onchange = async () => {
    lyricsForcedSource = lyricsSourceSel.value
    await window.cascade.store.set('lyricsForcedSource', lyricsForcedSource)
    updateSourcePills()
    _reloadLyricsFor()
  }

  // Equalizer
  const eqEnableToggle = document.getElementById('eq-enable-toggle')
  eqEnableToggle.checked = eqEnabled
  eqEnableToggle.onchange = async () => {
    eqEnabled = eqEnableToggle.checked
    await window.cascade.store.set('eqEnabled', eqEnabled)
    _applyEqToGraph()
  }

  document.getElementById('eq-edit-music').onclick = () => { _eqEditTarget = 'music'; _refreshEqUI() }
  document.getElementById('eq-edit-video').onclick = () => { _eqEditTarget = 'video'; _refreshEqUI() }

  const eqPresetSel = document.getElementById('eq-preset')
  eqPresetSel.innerHTML = '<option value="">Custom</option>' +
    Object.keys(CascadeCore.EQ_PRESETS).map(name => `<option value="${name}">${name}</option>`).join('')
  eqPresetSel.onchange = async () => {
    if (!eqPresetSel.value) return
    _eqEditProfile().bands = [...CascadeCore.EQ_PRESETS[eqPresetSel.value]]
    _refreshEqUI()
    await _saveEqProfile()
  }

  document.querySelectorAll('.eq-band-slider').forEach((el, i) => {
    el.oninput = async () => {
      _eqEditProfile().bands[i] = parseFloat(el.value)
      _refreshEqUI()
      await _saveEqProfile()
    }
  })

  document.getElementById('eq-preamp-auto').onchange = async () => {
    const profile = _eqEditProfile()
    const isAuto = document.getElementById('eq-preamp-auto').checked
    // Seed manual mode with the current auto value instead of jumping to 0.
    profile.preamp = isAuto ? null : CascadeCore.autoPreamp(profile.bands)
    _refreshEqUI()
    await _saveEqProfile()
  }
  document.getElementById('eq-preamp-slider').oninput = async () => {
    _eqEditProfile().preamp = parseFloat(document.getElementById('eq-preamp-slider').value)
    _refreshEqUI()
    await _saveEqProfile()
  }

  _refreshEqUI()
}

document.getElementById('btn-save-settings').addEventListener('click', async () => {
  const url = document.getElementById('s-url').value.trim()
  const user = document.getElementById('s-user').value.trim()
  const pass = document.getElementById('s-pass').value

  if (!url || !user) return

  // Persist URL and username immediately so they survive a failed connection attempt
  await window.cascade.store.set('serverUrl', url)
  await window.cascade.store.set('username', user)

  try {
    // An account signed in with a code has no stored password, and sending an
    // empty one just 401s. If the existing token still works against this URL,
    // there is nothing to re-authenticate - keep the session and save.
    const effectivePass = pass || await window.cascade.store.get('password') || ''
    if (!effectivePass) {
      const token = await window.cascade.store.get('token')
      const userId = await window.cascade.store.get('userId')
      if (!token || !userId) { promptReauth('Sign in again to change these.'); return }
      await connect(url, token, userId)
      const okStatus = document.getElementById('save-status')
      okStatus.classList.add('visible')
      setTimeout(() => okStatus.classList.remove('visible'), 2500)
      return
    }

    const auth = await jfAuth(url, user, effectivePass)
    await window.cascade.store.set('token', auth.AccessToken)
    await window.cascade.store.set('userId', auth.User.Id)
    if (pass) await window.cascade.store.set('password', pass)

    const status = document.getElementById('save-status')
    status.classList.add('visible')
    setTimeout(() => status.classList.remove('visible'), 2500)

    await connect(url, auth.AccessToken, auth.User.Id)
  } catch (e) {
    const msg = e.message || ''
    if (msg.includes('401') || msg.toLowerCase().includes('unauthorized'))
      alert('Incorrect username or password.')
    else if (msg.includes('Failed to fetch') || msg.includes('NetworkError'))
      alert('Could not reach the server. Check your URL.')
    else
      alert(`Connection failed: ${msg}`)
  }
})

document.getElementById('btn-logout').addEventListener('click', async () => {
  // Tear down everything session/account-scoped before the account itself is
  // forgotten - a different user signing in next must not inherit this one's
  // playback, presence, or cached grids. Saved server URL, username, theme, EQ
  // profiles and volume are untouched: those are things a user keeps regardless
  // of who is signed in.
  cancelCrossfade()  // abandon the incoming deck too, not just the current one
  stopPlayback()      // pauses audio, clears the queue, drops the stream prefetch
                       // and the current encoding, clears Discord presence
  invalidateLibraryViews()
  invalidateVideoViews()
  jf.isAdmin = false     // a stale admin flag must not survive into the next account
  jf.canDelete = false   // same for the deletion right - it is per-account, not per-session
  _applyAdminGating()
  showView('home')

  await window.cascade.store.delete('token')
  await window.cascade.store.delete('userId')
  await window.cascade.store.delete('password')
  // Via promptReauth so the code option is offered here too, not just on a
  // stale-token bounce.
  promptReauth('')
})

// ── Setup overlay ─────────────────────────────────────────────────────────────

// ── Quick Connect ────────────────────────────────────────────────────────────
// Sign in by approving a code on a device you're already logged in on, instead
// of typing a password. Protocol lives in src/core/jellyfin.ts.
//
// Worth having beyond convenience: it means Cascade never has to store a
// password. The device-id migration falls back to the stored one, so an account
// signed in this way simply keeps its existing token.

let _qcAbort = null   // set while a request is live; calling it stops the poll

/**
 * Drop back to the sign-in screen because the session is no longer usable.
 *
 * Signing in with a code stores no password, so those accounts have nothing to
 * re-authenticate with silently - without this they would land on a form asking
 * for a password they never had. probeQuickConnect() re-runs so the code option
 * is showing by the time they read the message.
 */
function promptReauth(message) {
  document.getElementById('setup-overlay').classList.remove('hidden')
  document.getElementById('setup-error').textContent = message || ''
  document.getElementById('setup-password').value = ''
  probeQuickConnect()
}

// Only offer it if the server actually has it switched on. Debounced because
// this fires while the user is still typing the URL.
let _qcProbeTimer = null
function probeQuickConnect() {
  clearTimeout(_qcProbeTimer)
  _qcProbeTimer = setTimeout(async () => {
    const url = document.getElementById('setup-url').value.trim().replace(/\/+$/, '')
    const btn = document.getElementById('setup-quickconnect')
    if (!url) { btn.style.display = 'none'; return }
    btn.style.display = (await CascadeCore.quickConnectEnabled(url)) ? '' : 'none'
  }, 500)
}

document.getElementById('setup-url').addEventListener('input', probeQuickConnect)

function endQuickConnect() {
  if (_qcAbort) { _qcAbort(); _qcAbort = null }
  document.getElementById('setup-qc').style.display = 'none'
  document.getElementById('setup-connect').style.display = ''
  probeQuickConnect()
}

document.getElementById('setup-qc-cancel').addEventListener('click', endQuickConnect)

document.getElementById('setup-quickconnect').addEventListener('click', async () => {
  const err = document.getElementById('setup-error')
  const url = document.getElementById('setup-url').value.trim().replace(/\/+$/, '')
  if (!url) { err.textContent = 'Enter your server URL first.'; return }
  err.textContent = ''

  let start
  try {
    start = await CascadeCore.quickConnectInitiate(url, appVersion, deviceId)
  } catch {
    err.textContent = 'Could not start Quick Connect on that server.'
    return
  }

  document.getElementById('setup-qc-code').textContent = start.Code
  document.getElementById('setup-qc').style.display = ''
  document.getElementById('setup-connect').style.display = 'none'
  document.getElementById('setup-quickconnect').style.display = 'none'

  let cancelled = false
  _qcAbort = () => { cancelled = true }
  const deadline = Date.now() + CascadeCore.QUICK_CONNECT_TIMEOUT_MS

  while (!cancelled) {
    if (Date.now() > deadline) {
      err.textContent = 'That code expired. Try again.'
      endQuickConnect()
      return
    }
    await new Promise(r => setTimeout(r, CascadeCore.QUICK_CONNECT_POLL_MS))
    if (cancelled) return

    if (!await CascadeCore.quickConnectApproved(url, start.Secret)) continue

    try {
      const auth = await CascadeCore.quickConnectAuthenticate(url, start.Secret, appVersion, deviceId)
      await window.cascade.store.set('serverUrl', url)
      await window.cascade.store.set('token', auth.AccessToken)
      await window.cascade.store.set('userId', auth.User.Id)
      if (auth.User.Name) await window.cascade.store.set('username', auth.User.Name)
      // No password to store, and any previously saved one no longer matches how
      // this session was obtained - drop it rather than leave a stale secret.
      await window.cascade.store.delete('password')
      // This token is already bound to the current device id, so the one-time
      // re-auth migration has nothing left to do.
      await window.cascade.store.set('deviceIdMigrated', true)

      _qcAbort = null
      document.getElementById('setup-qc').style.display = 'none'
      document.getElementById('setup-overlay').classList.add('hidden')
      await connect(url, auth.AccessToken, auth.User.Id)
    } catch {
      err.textContent = 'Approved, but signing in failed. Try again.'
      endQuickConnect()
    }
    return
  }
})

document.getElementById('setup-connect').addEventListener('click', async () => {
  const btn = document.getElementById('setup-connect')
  const err = document.getElementById('setup-error')
  const url = document.getElementById('setup-url').value.trim()
  const user = document.getElementById('setup-username').value.trim()
  const pass = document.getElementById('setup-password').value

  if (!url || !user) { err.textContent = 'Server URL and username are required.'; return }

  btn.disabled = true
  btn.textContent = 'Connecting…'
  err.textContent = ''

  try {
    const auth = await jfAuth(url, user, pass)
    await window.cascade.store.set('serverUrl', url)
    await window.cascade.store.set('username', user)
    await window.cascade.store.set('password', pass)
    await window.cascade.store.set('token', auth.AccessToken)
    await window.cascade.store.set('userId', auth.User.Id)

    document.getElementById('setup-overlay').classList.add('hidden')
    await connect(url, auth.AccessToken, auth.User.Id)
  } catch (e) {
    const msg = e.message || ''
    if (msg.includes('401') || msg.toLowerCase().includes('unauthorized'))
      err.textContent = 'Incorrect username or password.'
    else if (msg.includes('404'))
      err.textContent = 'Server not found. Check your URL.'
    else if (msg.includes('Failed to fetch') || msg.includes('NetworkError') || msg.includes('ECONNREFUSED'))
      err.textContent = 'Could not reach the server. Is it running?'
    else
      err.textContent = `Connection failed: ${msg}`
    btn.disabled = false
    btn.textContent = 'Connect'
  }
})

// Allow Enter key in setup fields
document.getElementById('setup-password').addEventListener('keydown', e => {
  if (e.key === 'Enter') document.getElementById('setup-connect').click()
})

// ── Startup ───────────────────────────────────────────────────────────────────

document.getElementById('btn-check-updates').addEventListener('click', async () => {
  const btn = document.getElementById('btn-check-updates')
  btn.disabled = true
  try {
    const result = await window.cascade.checkForUpdates()
    if (result?.error) showNotice('Could not reach GitHub to check for updates.', 'Update check')
    else if (!result?.hasUpdate) showNotice("You're running the latest version.", 'Update check')
    // else: the updater window itself is the feedback
  } finally {
    btn.disabled = false
  }
})

// Tokens issued before per-install device ids are bound server-side to the old
// constant DeviceId "cascade-app", so every Cascade looked like one device to
// Jellyfin: two machines on one account collided in the session list and remote
// control could not target a specific client. The device id in the auth header
// only takes effect on a fresh login, so retiring it means re-authenticating.
//
// Runs once, needs a stored password, and only swaps the token on success -
// a failed re-auth must leave the working token untouched rather than logging
// the user out. If there is no stored password the flag is not set, so this
// retries on a later launch once there is one.
// Returns the credentials to connect with - the refreshed pair on success, the
// existing ones otherwise - so the new identity applies on this launch rather
// than the next one.
async function migrateDeviceId(serverUrl, username, password, token, userId) {
  const unchanged = { token, userId }

  if (await window.cascade.store.get('deviceIdMigrated')) return unchanged
  if (!serverUrl || !token) return unchanged   // not signed in; new logins already use the UUID
  if (!username || !password) return unchanged // cannot re-auth silently

  try {
    const auth = await jfAuth(serverUrl, username, password)
    if (!auth?.AccessToken || !auth?.User?.Id) return unchanged
    await window.cascade.store.set('token', auth.AccessToken)
    await window.cascade.store.set('userId', auth.User.Id)
    await window.cascade.store.set('deviceIdMigrated', true)
    console.info('[cascade] re-authenticated to retire the shared "cascade-app" device id')
    return { token: auth.AccessToken, userId: auth.User.Id }
  } catch (err) {
    console.warn('[cascade] device id migration deferred:', err?.message || err)
    return unchanged
  }
}

async function init() {
  // Before anything authenticates: the device id goes into the auth header.
  deviceId = await window.cascade.store.get('deviceId')
  if (!deviceId) {
    deviceId = crypto.randomUUID()
    await window.cascade.store.set('deviceId', deviceId)
  }

  document.documentElement.setAttribute('data-platform', window.cascade.platform)
  searchInput.placeholder = `Search songs, albums, artists… (${window.cascade.platform === 'darwin' ? '⌘K' : 'Ctrl+K'})`
  await window.cascade.getVersion().then(v => {
    appVersion = v
    const el = document.getElementById('app-version')
    if (el) el.textContent = `v${v}`
  })

  await loadTheme()
  buildPresets()
  await initDiscordRpc()

  crossfadeEnabled = (await window.cascade.store.get('crossfadeEnabled')) === true
  crossfadeSeconds = parseInt(await window.cascade.store.get('crossfadeSeconds'), 10) || 6
  maxStreamingBitrate = parseInt(await window.cascade.store.get('maxStreamingBitrate'), 10) || DEFAULT_MAX_BITRATE

  eqEnabled = (await window.cascade.store.get('eqEnabled')) === true
  eqMusicProfile = await _loadEqProfile('eqMusic')
  eqVideoProfile = await _loadEqProfile('eqVideo')

  videoFullMode = (await window.cascade.store.get('videoFullMode')) === true

  // Restore saved volume
  const savedVol = await window.cascade.store.get('volume')
  if (savedVol !== undefined && savedVol !== null) setVolumeRatio(parseFloat(savedVol))

  const serverUrl = await window.cascade.store.get('serverUrl')
  const username  = await window.cascade.store.get('username')
  const password  = await window.cascade.store.get('password')
  let token       = await window.cascade.store.get('token')
  let userId      = await window.cascade.store.get('userId')

  // Always pre-fill the setup form so the user never has to retype from scratch
  if (serverUrl) document.getElementById('setup-url').value      = serverUrl
  if (username)  document.getElementById('setup-username').value  = username
  if (password)  document.getElementById('setup-password').value  = password
  // The probe normally runs as the user types; a pre-filled URL never fires that.
  if (serverUrl) probeQuickConnect()

  ;({ token, userId } = await migrateDeviceId(serverUrl, username, password, token, userId))

  if (serverUrl && token && userId) {
    document.getElementById('setup-overlay').classList.add('hidden')
    try {
      await connect(serverUrl, token, userId)
    } catch (e) {
      // Token stale - silently re-auth with stored credentials before giving up
      if (serverUrl && username && password) {
        try {
          const auth = await jfAuth(serverUrl, username, password)
          await window.cascade.store.set('token', auth.AccessToken)
          await window.cascade.store.set('userId', auth.User.Id)
          await connect(serverUrl, auth.AccessToken, auth.User.Id)
          return
        } catch {}
      }
      // Nothing to retry with. An account set up via Quick Connect has no stored
      // password by design, so say what actually happened rather than presenting
      // a blank password field.
      promptReauth(password
        ? 'Your session expired. Sign in again.'
        : 'Your session expired. Sign in again with a code, or enter your password.')
    }
  }
  // else setup overlay stays visible (fields already pre-filled above)
}

// ── Full-screen now-playing overlay ──────────────────────────────────────────

const npOverlay = document.getElementById('np-overlay')
let overlayOpen = false
let overlayLyricsOpen = false
// Persisted, video only - see applyVideoMode() for where it gets applied and
// the .np-overlay.video.full CSS for what it actually changes.
let videoFullMode = false

// ── Beat-reactive background ───────────────────────────────────────────────
let _currentBgArtUrl = null  // current track's art URL for overlay background
let _beatRafId = null
let _blobColors = []  // extracted colors, stored for blob drift animation
let _driftParams = [] // randomized per-blob drift parameters, set on each color refresh

function randomizeDrift() {
  _driftParams = CascadeCore.randomizeDrift()
}

function startBeatLoop() {
  if (_beatRafId) return
  const overlay = document.getElementById('np-overlay')
  if (!overlay) return

  let _lastBlobFrameTs = 0
  function frame(ts) {
    _beatRafId = requestAnimationFrame(frame)

    // ── Blob drift - organic slow movement using randomized layered sin/cos ──
    // The drift is slow (periods of tens of seconds), so rebuilding this gradient
    // string at the full 60fps is wasted work - throttle to ~15fps, which is
    // visually indistinguishable for motion this gradual.
    if (ts - _lastBlobFrameTs < CascadeCore.BLOB_FRAME_MS) return
    _lastBlobFrameTs = ts
    if (_blobColors.length > 0 && themeAlbumArt && _driftParams.length > 0) {
      const blobs = CascadeCore.driftedBlobs(_blobColors, _driftParams, Date.now() / 1000, _isLightTheme())
      overlay.style.backgroundImage = CascadeCore.blobBackgroundCss(blobs)
    }
  }
  frame()
}

function stopBeatLoop() {
  if (_beatRafId) { cancelAnimationFrame(_beatRafId); _beatRafId = null }
}

// ── Now-playing equalizer ────────────────────────────────────────────────────
// Drives the three .track-eq bars from real playback via Web Audio instead of
// leaving them as a pure CSS loop. eqLevels() (src/core/eq.ts) turns one frame
// of frequency data into three 0..1 heights - everything here is just wiring:
// build the graph once, run a throttled rAF loop while something plays, and
// fall back to the plain CSS animation for the rest of the session if the
// graph ever produces silence for audio that is actually audible.
//
// Each deck gets its own permanent source + gain node (see _deckSource/
// _deckGain), both feeding the one shared 5-band EQ stage, then the one
// shared analyser, so a crossfade sums cleanly, both decks come out
// equalized the same way, and the bars follow whichever deck(s) are actually
// sounding instead of just the outgoing one.

let _audioCtx = null
let _mediaSrc = null    // MediaElementAudioSourceNode for the CURRENT deck, kept
                         // updated at every crossfade handoff - wip-waterfall/
                         // NOTES.md still names this as the tap point.
const _deckSourceNodes = new Map()   // deck element -> its permanent MediaElementAudioSourceNode
const _deckGainNodes = new Map()     // deck element -> its permanent GainNode (crossfade envelope only)
let _eqPreamp = null     // shared GainNode, auto or manual makeup gain for the bands below
let _eqBandNodes = null  // shared array of 5 BiquadFilterNodes, one per EQ_BANDS entry
let _eqAnalyser = null
let _eqFreqData = null
let _eqRafId = null
// Two different failures, deliberately not one flag. The graph failing to
// build means there are no gain nodes, so crossfade cannot run either. The
// analyser reading nothing is cosmetic: the gains still work, and only the
// bars need to stand down. Conflating them turned a dead visualiser into a
// dead crossfade.
let _eqGraphFailed = false   // no Web Audio graph at all - blocks the bars and crossfade
let _eqNoSignal = false      // graph is up but the tap never produced audio - bars only
let _eqEverHadSignal = false // a single non-zero sample proves the tap works
let _eqSilentSinceTs = 0     // wall-clock start of the current run of all-zero frames

const EQ_FFT_SIZE = 64
const EQ_SMOOTHING = 0.75
const EQ_FRAME_MS = 1000 / 30    // ~30fps is plenty for three bars
const EQ_SILENCE_MS = 5000       // how long a never-yet-heard graph gets before we stand down
const EQ_FILTER_Q = 1.0          // ~1.4 octave wide peaks - narrow enough that 5 bands spanning
                                  // 60Hz-12kHz do not smear into one big tilt
const EQ_RAMP_SEC = 0.015        // setTargetAtTime time constant - fast but click-free

// createMediaElementSource() may only be called once per element, ever - so
// each deck's source node is built on first request and cached forever.
function _deckSource(deck) {
  if (!_deckSourceNodes.has(deck)) _deckSourceNodes.set(deck, _audioCtx.createMediaElementSource(deck))
  return _deckSourceNodes.get(deck)
}

/** The permanent GainNode for a deck, or null if the graph was never built. */
function _deckGain(deck) {
  return _deckGainNodes.get(deck) || null
}

// Builds ctx -> {deckA, deckB source+gain} -> preamp -> band[0..4] -> analyser
// -> destination, once, lazily. Only ever called from startEqLoop() (which
// only runs from the `play` handler below, so ctx.resume() always lands
// after a user gesture instead of hitting an autoplay block) and defensively
// from startCrossfade().
function _ensureEqGraph() {
  if (_eqGraphFailed || _eqAnalyser) return
  try {
    _audioCtx = _audioCtx || new (window.AudioContext || window.webkitAudioContext)()
    if (_audioCtx.state === 'suspended') _audioCtx.resume()
    _eqAnalyser = _audioCtx.createAnalyser()
    _eqAnalyser.fftSize = EQ_FFT_SIZE
    _eqAnalyser.smoothingTimeConstant = EQ_SMOOTHING
    _eqFreqData = new Uint8Array(_eqAnalyser.frequencyBinCount)

    // The shared EQ stage: one preamp feeding a chain of 5 peaking filters,
    // both decks' gains sum into the preamp so the same chain equalizes
    // whichever deck(s) are actually sounding.
    _eqPreamp = _audioCtx.createGain()
    _eqBandNodes = CascadeCore.EQ_BANDS.map(freq => {
      const band = _audioCtx.createBiquadFilter()
      band.type = 'peaking'
      band.frequency.value = freq
      band.Q.value = EQ_FILTER_Q
      band.gain.value = 0
      return band
    })
    let node = _eqPreamp
    _eqBandNodes.forEach(band => { node.connect(band); node = band })
    node.connect(_eqAnalyser)

    // Routing a deck through Web Audio replaces its normal output path -
    // without a connection all the way to destination, that deck goes silent.
    DECKS.forEach(d => {
      const gain = _audioCtx.createGain()
      _deckSource(d).connect(gain)
      gain.connect(_eqPreamp)
      _deckGainNodes.set(d, gain)
    })
    _eqAnalyser.connect(_audioCtx.destination)
    _mediaSrc = _deckSource(audio)
    _applyEqToGraph()
  } catch (e) {
    console.error('EQ graph setup failed, falling back to the CSS animation', e)
    _eqGraphFailed = true
    // Whatever got captured above is already routed away from its normal
    // output, and a half-built graph would leave a deck's gain node - or bare
    // source node, if the failure landed before its gain existed - connected
    // nowhere, which is silence. gain.disconnect() drops every outgoing edge
    // regardless of whether it pointed at the preamp, a band, or the analyser,
    // so this still works no matter how far the EQ stage got built. Wire
    // every deck straight to destination so playback survives losing both
    // the EQ and the visualiser.
    DECKS.forEach(d => {
      const gain = _deckGainNodes.get(d)
      if (gain) { try { gain.disconnect(); gain.connect(_audioCtx.destination) } catch {} }
      else if (_deckSourceNodes.has(d)) { try { _deckSourceNodes.get(d).connect(_audioCtx.destination) } catch {} }
    })
    _eqAnalyser = null
    _eqPreamp = null
    _eqBandNodes = null
  }
}

// Which saved profile is currently wired into the live graph.
function _currentEqProfile() {
  return eqActiveMode === 'video' ? eqVideoProfile : eqMusicProfile
}

// Pushes eqEnabled + the active profile onto the actual filter nodes. Always
// ramps with setTargetAtTime rather than a bare assignment, so turning the EQ
// on/off or switching profiles never clicks. Safe to call before the graph
// exists (e.g. a settings change before anything has ever played) - it just
// does nothing until _ensureEqGraph runs.
function _applyEqToGraph() {
  if (!_audioCtx || !_eqPreamp || !_eqBandNodes) return
  const now = _audioCtx.currentTime
  if (!eqEnabled) {
    _eqPreamp.gain.setTargetAtTime(1, now, EQ_RAMP_SEC)
    _eqBandNodes.forEach(band => band.gain.setTargetAtTime(0, now, EQ_RAMP_SEC))
    return
  }
  const profile = _currentEqProfile()
  const preampDb = profile.preamp === null ? CascadeCore.autoPreamp(profile.bands) : profile.preamp
  _eqPreamp.gain.setTargetAtTime(CascadeCore.dbToGain(preampDb), now, EQ_RAMP_SEC)
  _eqBandNodes.forEach((band, i) => band.gain.setTargetAtTime(profile.bands[i], now, EQ_RAMP_SEC))
}

// Reads one EQ profile out of the store (JSON-stringified) and hands it
// through normalizeProfile - covers both a corrupt JSON string and a
// structurally-wrong-but-valid-JSON value.
async function _loadEqProfile(key) {
  let raw = null
  try { raw = JSON.parse(await window.cascade.store.get(key) || 'null') } catch {}
  return CascadeCore.normalizeProfile(raw)
}

// The profile the settings panel is currently editing - not necessarily the
// one wired into the live graph, see eqActiveMode/_currentEqProfile above.
function _eqEditProfile() {
  return _eqEditTarget === 'video' ? eqVideoProfile : eqMusicProfile
}

// Preset name whose gains match a profile's bands exactly, or '' (Custom).
function _eqMatchingPreset(bands) {
  for (const name in CascadeCore.EQ_PRESETS) {
    if (CascadeCore.EQ_PRESETS[name].every((g, i) => g === bands[i])) return name
  }
  return ''
}

async function _saveEqProfile() {
  const key = _eqEditTarget === 'video' ? 'eqVideo' : 'eqMusic'
  await window.cascade.store.set(key, JSON.stringify(_eqEditProfile()))
  // Only ramp the live graph if the profile just edited is the one actually
  // playing - editing Video while music plays should not be audible yet.
  if (_eqEditTarget === eqActiveMode) _applyEqToGraph()
}

// Syncs the settings-panel EQ controls to _eqEditProfile(). Called after
// every edit so the preset dropdown, the preamp's auto value, and the band
// labels never drift from the numbers actually in play.
function _refreshEqUI() {
  const profile = _eqEditProfile()
  document.querySelectorAll('.eq-band-slider').forEach((el, i) => {
    el.value = String(profile.bands[i])
    document.getElementById(`eq-band-value-${i}`).textContent = `${profile.bands[i].toFixed(1)} dB`
  })
  const auto = profile.preamp === null
  const preampAuto = document.getElementById('eq-preamp-auto')
  const preampSlider = document.getElementById('eq-preamp-slider')
  const shownPreamp = auto ? CascadeCore.autoPreamp(profile.bands) : profile.preamp
  preampAuto.checked = auto
  preampSlider.disabled = auto
  preampSlider.value = String(shownPreamp)
  document.getElementById('eq-preamp-value').textContent = `${shownPreamp.toFixed(1)} dB${auto ? ' (auto)' : ''}`
  document.getElementById('eq-preset').value = _eqMatchingPreset(profile.bands)
  document.getElementById('eq-edit-music').classList.toggle('active', _eqEditTarget === 'music')
  document.getElementById('eq-edit-video').classList.toggle('active', _eqEditTarget === 'video')
}

function startEqLoop() {
  if (_eqRafId || _eqGraphFailed || _eqNoSignal) return
  _ensureEqGraph()
  if (!_eqAnalyser) return

  let lastFrameTs = 0
  function frame(ts) {
    _eqRafId = requestAnimationFrame(frame)
    if (ts - lastFrameTs < EQ_FRAME_MS) return
    lastFrameTs = ts

    _eqAnalyser.getByteFrequencyData(_eqFreqData)

    let allZero = true
    for (let i = 0; i < _eqFreqData.length; i++) { if (_eqFreqData[i] !== 0) { allZero = false; break } }
    if (!allZero) _eqEverHadSignal = true

    // Stand down only for a tap that has produced nothing, ever. One non-zero
    // sample proves it works, after which a quiet passage is just a quiet
    // passage. Buffering is excluded too: a stalled stream is not paused, it is
    // playing nothing, and counting that as a dead graph is what used to take
    // the bars and crossfade out on a single slow track change. Same for a
    // seek, which reads as zeros until it lands.
    const producing = !audio.muted && audio.volume > 0 && !audio.paused &&
      !audio.seeking && audio.readyState >= 3
    if (!_eqEverHadSignal && producing && allZero) {
      if (!_eqSilentSinceTs) _eqSilentSinceTs = ts
      else if (ts - _eqSilentSinceTs > EQ_SILENCE_MS) {
        _eqNoSignal = true
        stopEqLoop()
        return
      }
    } else {
      _eqSilentSinceTs = 0
    }

    const eq = document.querySelector('.track-row.playing .track-eq')
    if (!eq) return
    eq.classList.add('live')
    const levels = CascadeCore.eqLevels(_eqFreqData)
    eq.querySelectorAll('i').forEach((bar, i) => { bar.style.transform = `scaleY(${levels[i]})` })
  }
  frame()
}

function stopEqLoop() {
  if (_eqRafId) { cancelAnimationFrame(_eqRafId); _eqRafId = null }
  // Drop 'live' off whatever currently has it so the CSS animation resumes -
  // covers both a normal stop and the silence-fallback giving up permanently.
  document.querySelectorAll('.track-eq.live').forEach(el => el.classList.remove('live'))
}

onDeck('play', startEqLoop)
onDeck('pause', stopEqLoop)
onDeck('ended', stopEqLoop)
onDeck('emptied', stopEqLoop)

function openOverlay() {
  overlayOpen = true
  npOverlay.classList.add('open')
  syncOverlayState()
  renderQueuePanel()
  if (overlayLyricsOpen) renderOverlayLyrics()
  document.getElementById('ov-vol-fill').style.width = `${audio.volume * 100}%`

  // Apply art theme every time the overlay opens - derive the URL from the
  // current queue item directly so we never depend on _currentBgArtUrl being set.
  // If _blobColors is already cached, apply them immediately (no flash), then
  // re-fetch in the background to refresh if the track changed.
  // The art theme and the beat-reactive background both exist to make an album
  // cover move to the music. A movie is already moving - recolouring the frame
  // around it just fights the picture.
  if (themeAlbumArt && !playingVideo()) {
    if (_blobColors.length > 0) {
      npOverlay.style.backgroundColor = _blobBaseColor()
      npOverlay.style.backgroundImage = buildBlobBackground(_blobColors, _isLightTheme())
      npOverlay.classList.add('art-theme')
    }
    const item = queue[queueIndex]
    if (item) {
      const art = _currentHighResArtUrl || artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
      if (art) {
        fetch(art)
          .then(r => r.blob())
          .then(blob => {
            const objectUrl = URL.createObjectURL(blob)
            const img = new Image()
            img.onload = () => { applyAlbumArtTheme(img); URL.revokeObjectURL(objectUrl) }
            img.onerror = () => URL.revokeObjectURL(objectUrl)
            img.src = objectUrl
          })
          .catch(() => {})
      }
    }
  }

  // A film supplies its own colour, so the art-derived gradient steps aside and
  // ambient takes over from the beat loop.
  if (playingVideo()) npOverlay.classList.remove('art-theme')
  else startBeatLoop()
  refreshAmbient()
}

function closeOverlay() {
  overlayOpen = false
  npOverlay.classList.remove('open')
  stopBeatLoop()
  stopAmbient()
}

// Idle fade for the overlay controls. They get out of the way of the artwork
// after a few still seconds, and any sign of life brings them straight back.
// The progress row is deliberately left up, so a glance still tells you where
// you are in the track without having to touch anything.
const OV_IDLE_MS = 3000
let _ovIdleTimer = null

function pokeOverlayControls() {
  const ov = document.getElementById('np-overlay')
  ov.classList.remove('idle')
  clearTimeout(_ovIdleTimer)
  // Paused is not idle. Hiding the controls of something that is not going
  // anywhere reads as broken rather than tidy, and pause is exactly when you
  // are most likely to reach for them next.
  if (!overlayOpen || audio.paused) return
  _ovIdleTimer = setTimeout(() => ov.classList.add('idle'), OV_IDLE_MS)
}

;['pointermove', 'pointerdown', 'wheel', 'keydown'].forEach(type =>
  document.getElementById('np-overlay').addEventListener(type, pokeOverlayControls, { passive: true }))
onDeck('play', pokeOverlayControls)
onDeck('pause', pokeOverlayControls)

// Only the left NP section (art + info) opens the overlay - everything else is a deadzone
document.querySelector('.statusbar').addEventListener('click', (e) => {
  if (!e.target.closest('.np') || e.target.closest('.np button')) return
  overlayOpen ? closeOverlay() : openOverlay()
})

document.getElementById('np-overlay-close').addEventListener('click', closeOverlay)
// The chevron on the left of the header closes it too. Two targets rather than
// one small x in the corner, which on Windows and Linux sat under the OS
// caption buttons and could not be clicked at all.
document.getElementById('np-overlay-collapse').addEventListener('click', closeOverlay)
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && overlayOpen) closeOverlay() })

// Lyrics toggle - queue slides left out, lyrics slides right in (and vice versa)
document.getElementById('ov-lyrics-toggle').addEventListener('click', () => {
  overlayLyricsOpen = !overlayLyricsOpen
  document.getElementById('ov-panel-lyrics').style.transform = overlayLyricsOpen ? 'translateX(0)' : 'translateX(100%)'
  document.getElementById('ov-panel-queue').style.transform  = overlayLyricsOpen ? 'translateX(-100%)' : 'translateX(0)'
  document.getElementById('ov-lyrics-toggle').classList.toggle('active', overlayLyricsOpen)
  if (overlayLyricsOpen) renderOverlayLyrics()
})

// ── Sleep timer ──────────────────────────────────────────────────────────────

let sleepTimerId = null      // setTimeout handle for a duration-based timer
let sleepAtTrackEnd = false  // true when "End of current track" is selected

function clearSleepTimer() {
  if (sleepTimerId) { clearTimeout(sleepTimerId); sleepTimerId = null }
  sleepAtTrackEnd = false
  document.getElementById('ov-sleep-timer').classList.remove('active')
}

function setSleepTimerMinutes(mins) {
  clearSleepTimer()
  sleepTimerId = setTimeout(() => {
    audio.pause()
    sleepTimerId = null
    document.getElementById('ov-sleep-timer').classList.remove('active')
    showToast('Sleep timer: playback paused')
  }, mins * 60 * 1000)
  document.getElementById('ov-sleep-timer').classList.add('active')
  showToast(`Sleep timer set for ${mins} minutes`)
}

function setSleepTimerAtTrackEnd() {
  clearSleepTimer()
  sleepAtTrackEnd = true
  document.getElementById('ov-sleep-timer').classList.add('active')
  showToast('Playback will pause after this track')
}

const sleepTimerDropdown = document.getElementById('sleep-timer-dropdown')

/**
 * Open `dd` under `btn`, nudged back on screen if it would overflow.
 *
 * Extracted when the subtitle and audio-track menus arrived: three copies of
 * the same edge-flip arithmetic is how one of them ends up opening off-screen
 * on a small window and nobody notices.
 */
function openDropdownUnder(dd, btnEl) {
  const btn = btnEl.getBoundingClientRect()
  dd.classList.add('open')
  dd.style.left = `${btn.left}px`
  dd.style.top  = `${btn.bottom + 6}px`
  const r = dd.getBoundingClientRect()
  if (r.right > window.innerWidth - 8) dd.style.left = `${window.innerWidth - dd.offsetWidth - 8}px`
  if (r.bottom > window.innerHeight - 8) dd.style.top = `${btn.top - dd.offsetHeight - 6}px`
}

/** Toggle helper: returns true when the menu ended up open. */
function toggleDropdownUnder(dd, btnEl) {
  if (dd.classList.contains('open')) { dd.classList.remove('open'); return false }
  openDropdownUnder(dd, btnEl)
  return true
}

document.getElementById('ov-sleep-timer').addEventListener('click', (e) => {
  e.stopPropagation()
  toggleDropdownUnder(sleepTimerDropdown, e.currentTarget)
})

sleepTimerDropdown.querySelectorAll('[data-sleep-mins]').forEach(btn => {
  btn.addEventListener('click', (e) => {
    e.stopPropagation()
    sleepTimerDropdown.classList.remove('open')
    const val = btn.dataset.sleepMins
    if (val === 'off') { clearSleepTimer(); showToast('Sleep timer off') }
    else if (val === 'end') setSleepTimerAtTrackEnd()
    else setSleepTimerMinutes(parseInt(val, 10))
  })
})

// One outside-click handler for every overlay dropdown, each paired with the
// button that opens it. A per-menu copy is how the third one ends up staying
// open behind the second.
const OV_DROPDOWNS = [
  ['sleep-timer-dropdown',  'ov-sleep-timer'],
  ['subs-dropdown',         'ov-subs'],
  ['audio-track-dropdown',  'ov-audio-track'],
]

document.addEventListener('mousedown', (e) => {
  for (const [ddId, btnId] of OV_DROPDOWNS) {
    const dd = document.getElementById(ddId)
    if (!dd || !dd.classList.contains('open')) continue
    if (dd.contains(e.target) || e.target.closest(`#${btnId}`)) continue
    dd.classList.remove('open')
  }
})

// Overlay "more options" opens the exact same context menu as right-clicking
// the album art in the bottom bar, not a separate hand-maintained copy.
document.getElementById('ov-more-btn').addEventListener('click', (e) => {
  e.stopPropagation()
  if (!queue[queueIndex]) return
  const menu = document.getElementById('ctx-menu')
  const btn = e.currentTarget.getBoundingClientRect()
  showCtxMenu(btn.left, btn.top)
  // showCtxMenu anchors top-left at (x,y) - reposition centered above the button
  const r = menu.getBoundingClientRect()
  let left = btn.left + btn.width / 2 - r.width / 2
  let top = btn.top - r.height - 8
  left = Math.max(8, Math.min(left, window.innerWidth - r.width - 8))
  top = Math.max(8, top)
  menu.style.left = `${left}px`
  menu.style.top = `${top}px`
  // Grows up out of the button instead of the cursor-anchored default, and
  // dims the rest of the overlay so the menu holds focus. hideCtxMenu()
  // clears both - it runs on every close, right-click menus included.
  menu.style.transformOrigin = 'bottom center'
  document.getElementById('ov-more-scrim').classList.add('show')
})

document.getElementById('ov-artist').addEventListener('click', () => openArtistFromTrack(queue[queueIndex]))

document.getElementById('ov-track').addEventListener('click', () => openAlbumFromTrack(queue[queueIndex]))

document.getElementById('ov-play').addEventListener('click', () => document.getElementById('btn-play').click())
document.getElementById('ov-prev').addEventListener('click', () => document.getElementById('btn-prev').click())
document.getElementById('ov-next').addEventListener('click', () => document.getElementById('btn-next').click())
document.getElementById('ov-shuffle').addEventListener('click', () => {
  document.getElementById('btn-shuffle').click()
  document.getElementById('ov-shuffle').classList.toggle('active', shuffle)
})
document.getElementById('ov-repeat').addEventListener('click', () => {
  document.getElementById('btn-repeat').click()
})
document.getElementById('ov-like').addEventListener('click', toggleLike)

// Overlay progress bar - shares wireProgressBar() with the statusbar one.
wireProgressBar('ov-prog-bar', 'ov-prog-fill', 'ov-cur')

// ── Ambient mode ──────────────────────────────────────────────────────────────
//
// The picture's own colours bled out around the frame, like YouTube's ambient
// mode. A frame is copied into a 32x18 canvas a few times a second and CSS does
// the rest - the blur is what makes the resolution irrelevant, so sampling any
// larger would be work thrown away.
//
// Gated on the existing album-art accent toggle rather than a new setting: that
// switch already means "let what is playing colour the UI", and this is the
// same idea with frames instead of cover art.

const AMBIENT_MS = 250
const ambientCanvas = document.getElementById('ov-ambient')
const ambientCtx = ambientCanvas.getContext('2d')
let _ambientTimer = null

function ambientShouldRun() {
  return themeAlbumArt && overlayOpen && playingVideo()
}

function startAmbient() {
  if (_ambientTimer) return
  npOverlay.classList.add('ambient')
  _ambientTimer = setInterval(() => {
    // readyState < 2 means there is no current frame to copy - during a seek
    // or a stream swap, drawing would either throw or smear the last frame.
    if (audio.readyState < 2) return
    try {
      ambientCtx.drawImage(audio, 0, 0, ambientCanvas.width, ambientCanvas.height)
    } catch { /* frame not decodable yet; the next tick will do */ }
  }, AMBIENT_MS)
}

function stopAmbient() {
  if (_ambientTimer) { clearInterval(_ambientTimer); _ambientTimer = null }
  npOverlay.classList.remove('ambient')
  ambientCtx.clearRect(0, 0, ambientCanvas.width, ambientCanvas.height)
}

/** Single entry point, so every caller stops having to know the conditions. */
function refreshAmbient() {
  if (ambientShouldRun()) startAmbient()
  else stopAmbient()
}

// ── Video controls ────────────────────────────────────────────────────────────
//
// Everything here is video-only and hidden by CSS while music plays, so none of
// it needs its own guard against being clicked during a song.

const SKIP_SECONDS = 10
/** Where a run of skips is heading. null when no run is in flight. */
let _skipTarget = null
let _skipTimer = null

/**
 * Jump by `delta` seconds.
 *
 * Direct play moves immediately. A transcode cannot: every skip is a new stream,
 * so a run of taps is collected and sent once. Without that, tapping forward
 * five times would fire five encodes and the server would still be starting the
 * first one. The scrubber follows each tap so the run stays legible.
 */
function skipBy(delta) {
  const dur = mediaDuration()
  if (!dur) return

  if (!(_playMethod === 'Transcode' && playingVideo())) {
    seekTo(mediaPosition() + delta)
    return
  }

  const base = _skipTarget ?? mediaPosition()
  _skipTarget = Math.max(0, Math.min(dur, base + delta))

  document.getElementById('ov-prog-fill').style.width = `${(_skipTarget / dur) * 100}%`
  document.getElementById('ov-cur').textContent = fmtTime(_skipTarget)
  setBarAriaNow(document.getElementById('ov-prog-bar'), _skipTarget, dur, fmtTime(_skipTarget))

  clearTimeout(_skipTimer)
  _skipTimer = setTimeout(() => {
    const target = _skipTarget
    _skipTarget = null
    if (target != null) seekTo(target)
  }, 350)
}

document.getElementById('ov-back10').addEventListener('click', () => skipBy(-SKIP_SECONDS))
document.getElementById('ov-fwd10').addEventListener('click', () => skipBy(SKIP_SECONDS))

// ── Fullscreen ──
// The overlay goes fullscreen, not the <video>: the transport controls live in
// the overlay, and handing the element to the browser would take them away and
// leave the native ones in their place.
function toggleVideoFullscreen() {
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {})
  else npOverlay.requestFullscreen().catch(() => {})
}

document.getElementById('ov-fullscreen').addEventListener('click', toggleVideoFullscreen)
// Defers to the status bar's mute button rather than duplicating the state
// handling - one button owns muted/unmuted, this is a second way to press it.
document.getElementById('ov-mute').addEventListener('click', () => document.getElementById('btn-mute').click())
onDeck('dblclick', () => { if (playingVideo()) toggleVideoFullscreen() })

// ── Full mode ──
// Independent of real OS fullscreen above - full mode is about the overlay's
// own chrome (header, docked vs floating controls), fullscreen is about
// whether the OS gives the window the whole screen. Either can be on without
// the other, same as VLC lets you keep on-screen controls in fullscreen.
async function setVideoFullMode(on) {
  videoFullMode = on
  npOverlay.classList.toggle('full', on && playingVideo())
  document.getElementById('ov-full-mode').classList.toggle('active', on)
  await window.cascade.store.set('videoFullMode', on)
}

document.getElementById('ov-full-mode').addEventListener('click', () => setVideoFullMode(!videoFullMode))
// Restores the exit the hidden header would otherwise have provided.
document.getElementById('ov-full-exit').addEventListener('click', closeOverlay)

// Escape is handled by the browser, which exits fullscreen without telling the
// overlay - so closing on Escape has to wait until it is no longer fullscreen,
// otherwise one press would both exit fullscreen and close the overlay.
document.addEventListener('keydown', (e) => {
  if (!overlayOpen || !playingVideo()) return
  const t = /** @type {HTMLElement} */ (e.target)
  if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return

  if (e.key === 'f' || e.key === 'F') { e.preventDefault(); toggleVideoFullscreen() }
  else if (e.key === 'ArrowLeft')     { e.preventDefault(); skipBy(-SKIP_SECONDS) }
  else if (e.key === 'ArrowRight')    { e.preventDefault(); skipBy(SKIP_SECONDS) }
  else if (e.key === ' ')             { e.preventDefault(); document.getElementById('btn-play').click() }
  else if (e.key === 'ArrowUp')       { e.preventDefault(); nudgeVolume(0.05) }
  else if (e.key === 'ArrowDown')     { e.preventDefault(); nudgeVolume(-0.05) }
  else if (e.key === 'm' || e.key === 'M') { e.preventDefault(); document.getElementById('btn-mute').click() }
})

/** Change volume by `delta`. Thin wrapper for the video overlay's own arrow-key
 *  handler above - setVolumeRatio() does the actual work of keeping both
 *  sliders and the stored setting in step. */
function nudgeVolume(delta) {
  setVolumeRatio(audio.volume + delta)
}

// ── Subtitle picker ──

const subsDropdown = document.getElementById('subs-dropdown')

document.getElementById('ov-subs').addEventListener('click', (e) => {
  e.stopPropagation()
  const tracks = [...audio.querySelectorAll('track')]
  const activeIdx = tracks.findIndex(t => t.track.mode === 'showing')

  subsDropdown.innerHTML = tracks.length
    ? ['<div class="ov-dd-head">Subtitles</div>',
       `<button class="ov-dd-item${activeIdx === -1 ? ' checked' : ''}" data-sub="off">Off</button>`,
       ...tracks.map((t, i) =>
         `<button class="ov-dd-item${i === activeIdx ? ' checked' : ''}" data-sub="${i}">${esc(t.label)}</button>`),
      ].join('')
    // Image subtitles never reach here - the server burns those into the
    // picture - so "none" genuinely means none to choose from.
    : '<div class="ov-dd-head">Subtitles</div><div class="ov-dd-item" style="opacity:0.6;cursor:default">None available</div>'

  subsDropdown.querySelectorAll('[data-sub]').forEach(btn => {
    btn.addEventListener('click', () => {
      const v = /** @type {HTMLElement} */ (btn).dataset.sub
      selectSubtitleTrack(v === 'off' ? null : Number(v))
      subsDropdown.classList.remove('open')
    })
  })

  toggleDropdownUnder(subsDropdown, e.currentTarget)
})

// ── Audio track picker ──

const audioTrackDropdown = document.getElementById('audio-track-dropdown')

document.getElementById('ov-audio-track').addEventListener('click', (e) => {
  e.stopPropagation()
  const item = queue[queueIndex]
  const streams = (item?.MediaStreams || []).filter(s => s.Type === 'Audio')

  audioTrackDropdown.innerHTML = streams.length > 1
    ? ['<div class="ov-dd-head">Audio</div>',
       ...streams.map(s =>
         `<button class="ov-dd-item${s.Index === _audioStreamIndex ? ' checked' : ''}" data-audio="${s.Index}">${
           esc(s.DisplayTitle || s.Language || `Track ${s.Index}`)}</button>`),
      ].join('')
    : '<div class="ov-dd-head">Audio</div><div class="ov-dd-item" style="opacity:0.6;cursor:default">Only one track</div>'

  audioTrackDropdown.querySelectorAll('[data-audio]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const idx = Number(/** @type {HTMLElement} */ (btn).dataset.audio)
      audioTrackDropdown.classList.remove('open')
      if (idx === _audioStreamIndex) return
      _audioStreamIndex = idx
      // Switching track means a different file from the server, so playback
      // restarts where it was rather than from the top. This is the one case
      // the cached URL cannot serve - the server has to pick the stream again.
      await restartStreamAt(mediaPosition(), { renegotiate: true })
    })
  })

  toggleDropdownUnder(audioTrackDropdown, e.currentTarget)
})

// Overlay volume slider - shares wireVolumeBar() with the statusbar one, both
// wired through setVolumeRatio() so neither can drift out of sync.
wireVolumeBar('ov-vol-bar')

// Overlay progress is filled by syncProgressUI() alongside the status bar.

onDeck('play', () => {
  document.getElementById('ov-icon-play').style.display = 'none'
  document.getElementById('ov-icon-pause').style.display = ''
})
onDeck('pause', () => {
  document.getElementById('ov-icon-play').style.display = ''
  document.getElementById('ov-icon-pause').style.display = 'none'
})

function syncOverlayState() {
  const item = queue[queueIndex]
  if (!item) return

  // Art - prefer high-res (iTunes if available, else Jellyfin 600px)
  const art = _currentHighResArtUrl || artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
  const artEl = document.getElementById('ov-art')
  artEl.innerHTML = art ? `<img src="${art}" alt="" onerror="this.innerHTML='♪'">` : '♪'

  // Info - wrapped so the marquee has an inline-block track to translate
  document.getElementById('ov-track').innerHTML  = `<span class="np-scroll-inner">${esc(item.Name || '')}</span>`
  document.getElementById('ov-artist').innerHTML = `<span class="np-scroll-inner">${esc(item.AlbumArtist || item.Artists?.[0] || '')}</span>`
  refreshMarquees()

  // Like state
  document.getElementById('ov-like').classList.toggle('liked', item.UserData?.IsFavorite || false)

  // Shuffle / repeat state
  document.getElementById('ov-shuffle').classList.toggle('active', shuffle)
  updateRepeatButtons()
}

// Auto-mix: when the queue runs dry, keep playing with an instant mix off the last track
let autoMixEnabled = false
document.getElementById('btn-automix').addEventListener('click', () => {
  autoMixEnabled = !autoMixEnabled
  document.getElementById('btn-automix').classList.toggle('active', autoMixEnabled)
  showToast(autoMixEnabled ? 'Auto-mix on - similar tracks will keep playing after the queue ends' : 'Auto-mix off')
})

function renderQueuePanel() {
  const container = document.getElementById('ov-queue-rows')
  const panel     = document.getElementById('ov-panel-queue')
  if (!queue.length) { container.innerHTML = '<div class="empty-state" style="padding:40px 0">Queue is empty</div>'; return }

  // Bind scroll listener once - shifts the render window as the user scrolls
  if (!_queueScrollBound) {
    _queueScrollBound = true
    panel.addEventListener('scroll', () => {
      if (!queue.length) return
      // container.offsetTop is the in-panel "Queue" header - scrollTop 0 is not row 0
      const visStart = Math.max(0, Math.floor((panel.scrollTop - container.offsetTop) / QUEUE_ROW_H))
      const visEnd   = visStart + Math.ceil(panel.clientHeight / QUEUE_ROW_H)
      const nearTop  = visStart < _queueWinStart + 3
      const nearBot  = visEnd   > _queueWinStart + QUEUE_WIN - 3
      if (nearTop || nearBot) {
        // Only redraw on a real window change, otherwise the programmatic scroll in
        // _drawQueueRows re-triggers this and fights it.
        const next = Math.max(0, Math.min(visStart - 3, queue.length - QUEUE_WIN))
        if (next !== _queueWinStart) { _queueWinStart = next; _drawQueueRows(container, false) }
      }
    }, { passive: true })
  }

  // Re-centre window on the current track
  _queueWinStart = Math.max(0, Math.min(queueIndex - QUEUE_BEFORE, queue.length - QUEUE_WIN))
  _drawQueueRows(container, true)
}

function _drawQueueRows(container, scrollToCurrent) {
  const winEnd = Math.min(queue.length, _queueWinStart + QUEUE_WIN)
  const topH   = _queueWinStart * QUEUE_ROW_H
  const botH   = (queue.length - winEnd) * QUEUE_ROW_H

  // A guest mirrors the host's queue. Reordering or removing locally would
  // desync it immediately, so those controls are not rendered at all.
  const follower = isWaterfallFollower()

  const rows = queue.slice(_queueWinStart, winEnd).map((item, idx) => {
    const i     = _queueWinStart + idx
    const art   = item.__wfUnavailable ? null
      : artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
    const thumb = art ? `<img src="${art}" alt="" loading="lazy" onerror="this.style.display='none'">` : '♪'
    const dur   = fmtTime((item.RunTimeTicks || 0) / 10000000)
    const by    = queueAddedBy(i)
    const sub   = item.__wfUnavailable ? '' : esc(item.AlbumArtist || item.Artists?.[0] || '')

    return `<div class="queue-row${i === queueIndex ? ' current' : ''}${item.__wfUnavailable ? ' unavailable' : ''}" data-qi="${i}"${follower ? '' : ' draggable="true"'}>
      ${follower ? '' : `<div class="queue-row-drag" title="Drag to reorder">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="8" y1="6" x2="16" y2="6"/><line x1="8" y1="12" x2="16" y2="12"/><line x1="8" y1="18" x2="16" y2="18"/></svg>
      </div>`}
      <div class="queue-row-art">${thumb}</div>
      <div style="min-width:0;flex:1">
        <div class="queue-row-title">${esc(item.Name)}</div>
        <div class="queue-row-artist">${sub}${by ? `<span class="queue-row-by">added by ${esc(by)}</span>` : ''}</div>
      </div>
      <div class="queue-row-dur">${dur}</div>
      ${follower ? '' : `<button class="queue-row-remove" data-qi="${i}" title="Remove from queue">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
      </button>`}
    </div>`
  }).join('')

  // Spacer divs preserve the panel's total scroll height
  container.innerHTML =
    `<div style="height:${topH}px;flex-shrink:0"></div>` +
    rows +
    `<div style="height:${botH}px;flex-shrink:0"></div>`

  let dragSrc = null

  container.querySelectorAll('.queue-row').forEach(el => {
    const qi = parseInt(el.dataset.qi)

    el.addEventListener('click', (e) => {
      if (e.target.closest('.queue-row-drag, .queue-row-remove')) return
      // A follower jumping tracks would move queueIndex out of alignment with
      // the host until the next broadcast dragged it back.
      if (follower) { if (typeof wfNotifyHostControls === 'function') wfNotifyHostControls(); return }
      queueIndex = qi
      playCurrentTrack()
      renderQueuePanel()
    })

    // Absent for followers - see the row markup above.
    el.querySelector('.queue-row-remove')?.addEventListener('click', (e) => {
      e.stopPropagation()
      const idx = parseInt(el.dataset.qi)
      queue.splice(idx, 1)
      // Only rows *before* the current one shift it. Removing the current row leaves
      // queueIndex pointing at whatever took its place - the next track - unless it
      // was the last row, in which case clamp back inside the queue.
      if (idx < queueIndex) queueIndex--
      else if (queueIndex >= queue.length) queueIndex = Math.max(0, queue.length - 1)
      _reprefetch()   // the removed row may have been the prefetched track
      renderQueuePanel()
    })

    el.addEventListener('dragstart', (e) => {
      dragSrc = el
      el.classList.add('dragging')
      e.dataTransfer.effectAllowed = 'move'
      e.dataTransfer.setData('text/plain', el.dataset.qi)
    })
    el.addEventListener('dragend', () => {
      el.classList.remove('dragging')
      container.querySelectorAll('.queue-row').forEach(r => r.classList.remove('drag-over'))
    })
    el.addEventListener('dragover', (e) => {
      e.preventDefault()
      e.dataTransfer.dropEffect = 'move'
      container.querySelectorAll('.queue-row').forEach(r => r.classList.remove('drag-over'))
      if (el !== dragSrc) el.classList.add('drag-over')
    })
    el.addEventListener('drop', (e) => {
      e.preventDefault()
      if (!dragSrc || dragSrc === el) return
      const from = parseInt(dragSrc.dataset.qi)
      const to   = parseInt(el.dataset.qi)
      const [moved] = queue.splice(from, 1)
      queue.splice(to, 0, moved)
      if (queueIndex === from) queueIndex = to
      else if (from < queueIndex && to >= queueIndex) queueIndex--
      else if (from > queueIndex && to <= queueIndex) queueIndex++
      _reprefetch()   // the reorder may have changed what plays next
      renderQueuePanel()
    })
  })

  if (scrollToCurrent) {
    // Explicit scrollTop rather than scrollIntoView: 'nearest' moves the minimum
    // distance, which parks the current row at the *bottom* edge and can never bring
    // it to the top. container.offsetTop is the in-panel header height.
    const panel = document.getElementById('ov-panel-queue')
    panel.scrollTop = container.offsetTop + queueIndex * QUEUE_ROW_H
  }
}

async function renderOverlayLyrics() {
  const body = document.getElementById('ov-lyrics-body')
  const item = queue[queueIndex]
  if (!item) { body.innerHTML = '<div class="lyrics-empty" style="padding:40px 0;text-align:center">Nothing playing</div>'; return }

  if (!lyricsData.length) {
    body.innerHTML = skeletonHTML('lyrics', 1)
    const gen    = ++_lyricsFetchGen
    const result = await fetchLyricsWaterfall(item)
    if (gen !== _lyricsFetchGen) return
    if (result?.instrumental) {
      body.innerHTML = '<div class="lyrics-empty" style="padding:40px 0;text-align:center">This track is instrumental</div>'
      return
    }
    _showLyricsFetchToast(result)
    if (!result) {
      lyricsSource = null
      updateSourcePills()
      body.innerHTML = '<div class="lyrics-empty" style="padding:40px 0;text-align:center">No lyrics available</div>'
      return
    }
    lyricsData   = result.lines
    lyricsSource = result.source
    updateSourcePills()
    _stopWordLoop()
    if (!audio.paused) _startWordLoop()
  }

  if (!lyricsData.length) {
    body.innerHTML = '<div class="lyrics-empty" style="padding:40px 0;text-align:center">No lyrics available</div>'
    return
  }

  renderOverlayLyricLines()
  _resetOverlayManualScroll()

  // Jump to a neutral position instantly, then let the spring glide in to the
  // actual current line - no CSS-transition reflow trick needed since jumpTo()
  // bypasses the animation loop entirely.
  ovLyricsSpring.jumpTo(0)
  const nowSec0 = audio.currentTime + 0.225
  let initialIdx = 0
  for (let i = 0; i < lyricsData.length; i++) {
    if (lyricsData[i].Start != null && lyricsData[i].Start / 10000000 <= nowSec0) initialIdx = i
  }
  updateOverlayLyricsActive(initialIdx)

  // Detect language and show translate button if non-English
  detectOverlayLyricsLanguage()
}

let ovLyricsTranslated = false

function renderOverlayLyricLines(translated = false) {
  const body = document.getElementById('ov-lyrics-body')
  body.innerHTML = lyricsData.map((line, i) => {
    const hasTimestamp = line.Start != null
    const transText = translated && lyricsTranslated[i]
    let content
    if (line.Words && !transText) {
      content = line.Words.map(w =>
        `<span class="ov-lyric-word" data-ws="${w.Start}" data-we="${w.End ?? ''}">${esc(w.Text)}</span>`
      ).join('')
    } else {
      content = esc(transText ? lyricsTranslated[i] : (line.Text || ''))
    }
    return `<div class="ov-lyric-line${hasTimestamp ? ' seekable' : ''}" data-idx="${i}"${hasTimestamp ? ` data-start="${line.Start}"` : ''}>${content}</div>`
  }).join('')
  body.querySelectorAll('.ov-lyric-line.seekable').forEach(el => {
    el.addEventListener('click', () => {
      const ticks = parseInt(el.dataset.start)
      if (!isNaN(ticks) && audio.duration) audio.currentTime = ticks / 10000000
      // Clicking a line is the same intent as the settle timer firing: you are
      // done browsing and back on the current lyric. Drop the manual offset now
      // instead of leaving the view parked until the timer catches up.
      _resetOverlayManualScroll()
    })
  })
}

async function detectOverlayLyricsLanguage() {
  const btn = document.getElementById('ov-translate-btn')
  btn.style.display = 'none'
  ovLyricsTranslated = false
  btn.classList.remove('translated')
  const sample = lyricsData.find(l => l.Text?.trim())?.Text?.trim()
  if (!sample) return
  try {
    const res = await fetch(`https://api.mymemory.translated.net/get?q=${encodeURIComponent(sample.slice(0, 100))}&langpair=autodetect|en`)
    const data = await res.json()
    const detected = data.responseData?.detectedLanguage || ''
    if (detected && !detected.toLowerCase().startsWith('en')) btn.style.display = 'flex'
  } catch {}
}

document.getElementById('ov-translate-btn').addEventListener('click', async () => {
  const btn = document.getElementById('ov-translate-btn')

  // Toggle back to original
  if (ovLyricsTranslated) {
    ovLyricsTranslated = false
    btn.classList.remove('translated')
    btn.title = 'Translate to English'
    renderOverlayLyricLines(false)
    return
  }

  btn.classList.add('loading')

  try {
    // Reuse existing translation if already fetched by the side panel
    if (!lyricsTranslated.length || lyricsTranslated.every(t => !t)) {
      const lines = lyricsData.map(l => l.Text || '')
      const chunkSize = 10
      lyricsTranslated = new Array(lines.length).fill('')
      for (let i = 0; i < lines.length; i += chunkSize) {
        const chunk = lines.slice(i, i + chunkSize)
        const url = `https://api.mymemory.translated.net/get?q=${encodeURIComponent(chunk.join('\n'))}&langpair=autodetect|en`
        const res = await fetch(url)
        const data = await res.json()
        const translated = (data.responseData?.translatedText || chunk.join('\n')).split('\n')
        translated.forEach((t, j) => { lyricsTranslated[i + j] = t })
      }
    }
    ovLyricsTranslated = true
    btn.classList.add('translated')
    btn.title = 'Show original'
    renderOverlayLyricLines(true)
  } catch (e) {
    console.error('Overlay translation failed', e)
  } finally {
    btn.classList.remove('loading')
  }
})

// Lightweight critically-damped-ish spring for scroll position. Unlike a CSS
// transition, it carries velocity across target changes - when a new line
// comes in before the previous move has settled (common in fast verses), it
// keeps moving from its current speed toward the new target instead of
// restarting from a standstill, which is what makes back-to-back line changes
// read as one continuous glide instead of a stutter-restart.
function createSpring(onUpdate, stiffness = 210, damping = 26) {
  let pos = 0, vel = 0, target = 0
  let raf = null
  let lastTs = null

  function frame(ts) {
    if (lastTs == null) lastTs = ts
    const dt = Math.min((ts - lastTs) / 1000, 0.05)  // clamp so a stalled tab doesn't fling on resume
    lastTs = ts

    const accel = (target - pos) * stiffness - vel * damping
    vel += accel * dt
    pos += vel * dt

    const settled = Math.abs(target - pos) < 0.05 && Math.abs(vel) < 0.05
    if (settled) { pos = target; vel = 0 }
    onUpdate(pos)

    if (!settled) raf = requestAnimationFrame(frame)
    else { raf = null; lastTs = null }
  }

  function ensureRunning() {
    if (raf == null) { lastTs = null; raf = requestAnimationFrame(frame) }
  }

  return {
    setTarget(t) { target = t; ensureRunning() },
    jumpTo(t) {
      target = t; pos = t; vel = 0
      if (raf) { cancelAnimationFrame(raf); raf = null; lastTs = null }
      onUpdate(pos)
    },
    setPos(p) {   // direct 1:1 tracking (manual drag) - no physics involved
      pos = p; vel = 0; target = p
      if (raf) { cancelAnimationFrame(raf); raf = null; lastTs = null }
      onUpdate(pos)
    },
  }
}

const ovLyricsSpring = createSpring(pos => {
  const el = document.getElementById('ov-lyrics-body')
  if (el) el.style.transform = `translateY(${pos}px)`
})

const sideLyricsSpring = createSpring(pos => {
  const el = document.getElementById('lyrics-inner')
  if (el) el.style.transform = `translateY(${pos}px)`
})

function updateOverlayLyricsActive(activeIdx, instant) {
  const body = document.getElementById('ov-lyrics-body')
  const panel = document.getElementById('ov-panel-lyrics')
  body.querySelectorAll('.ov-lyric-line').forEach(el => {
    const idx = parseInt(el.dataset.idx)
    const dist = idx - activeIdx  // signed: negative = past, positive = upcoming
    el.classList.remove('active', 'near-1', 'near-2', 'near-3', 'past', 'near-past')
    if (dist === 0) el.classList.add('active')
    else if (dist === 1) el.classList.add('near-1')
    else if (dist === 2) el.classList.add('near-2')
    else if (dist === 3) el.classList.add('near-3')
    else if (dist < 0) {
      el.classList.add('past')
      if (dist === -1) el.classList.add('near-past')
    }
    // Ripple: lines further from the active one settle in slightly later,
    // so the stack cascades outward instead of moving as one rigid block.
    el.style.transitionDelay = dist > 0 ? `${Math.min(dist, 3) * 65}ms` : '0ms'
  })
  // GPU-accelerated: translate the container so active line sits at panel center
  _scrollOverlayLyricsTo(activeIdx, instant)
}

// Centers the given line in the overlay lyrics panel. `instant` skips the
// spring animation - used when snap-scrolling right as a karaoke line's last
// word finishes, so the jump isn't a glide disconnected from the vocal.
function _scrollOverlayLyricsTo(idx, instant) {
  const body = document.getElementById('ov-lyrics-body')
  const panel = document.getElementById('ov-panel-lyrics')
  const el = body.querySelector(`.ov-lyric-line[data-idx="${idx}"]`)
  if (!el) return
  const panelMid = panel.clientHeight / 2
  const activeMid = el.offsetTop + el.offsetHeight / 2
  ovLyricsBaseY = panelMid - activeMid
  // While the user is manually scrolling, leave the spring alone - it gets
  // redirected (base + their offset) from the wheel handler instead.
  if (ovLyricsUserScrolling) return
  if (instant) ovLyricsSpring.jumpTo(ovLyricsBaseY)
  else ovLyricsSpring.setTarget(ovLyricsBaseY)
}

// lyricsData is sorted by Start time, and playback only moves forward except on
// seeks - so resume scanning from the last known index instead of rescanning
// from 0 on every timeupdate tick (was O(n) per tick, now amortized O(1)).
function _scanLyricsBaseIdx(nowSec, fromIdx) {
  let idx = fromIdx
  if (idx > 0 && lyricsData[idx].Start / 10_000_000 > nowSec) idx = 0  // seeked backward
  let baseIdx = idx
  for (let i = idx; i < lyricsData.length; i++) {
    const start = lyricsData[i].Start
    if (start == null) continue
    if (start / 10_000_000 <= nowSec) baseIdx = i
    else break
  }
  return baseIdx
}

// Returns the translateY that would center a given line, independent of the
// element's current transform (offsetTop is unaffected by CSS transforms).
function _ovLyricsTranslateYFor(idx) {
  const body  = document.getElementById('ov-lyrics-body')
  const panel = document.getElementById('ov-panel-lyrics')
  const el    = body.querySelector(`.ov-lyric-line[data-idx="${idx}"]`)
  if (!el) return 0
  return panel.clientHeight / 2 - (el.offsetTop + el.offsetHeight / 2)
}

// Sync overlay lyrics highlight
let lastOverlayLyricsIdx = -1
let _ovLyricsScanIdx = 0   // cursor into lyricsData so timeupdate scans forward instead of from 0 each tick
let ovLyricsBaseY = 0            // auto-follow position for the current active line
let ovLyricsManualOffset = 0     // extra offset applied while the user scrolls by hand
let ovLyricsUserScrolling = false
let ovLyricsScrollTimer = null

function _resetOverlayManualScroll() {
  clearTimeout(ovLyricsScrollTimer)
  ovLyricsUserScrolling  = false
  ovLyricsManualOffset   = 0
  document.getElementById('ov-panel-lyrics').classList.remove('browsing')
}

// Reset when track changes
const _ovLyricsReset = updateNowPlaying
updateNowPlaying = function(item) { _ovLyricsReset(item); lastOverlayLyricsIdx = -1; _ovLyricsScanIdx = 0; _resetOverlayManualScroll() }

document.getElementById('ov-panel-lyrics').addEventListener('wheel', (e) => {
  if (!lyricsData.length) return
  e.preventDefault()
  const minY = _ovLyricsTranslateYFor(lyricsData.length - 1)
  const maxY = _ovLyricsTranslateYFor(0)
  const wantedY = ovLyricsBaseY + ovLyricsManualOffset - e.deltaY
  const clampedY = Math.min(maxY, Math.max(minY, wantedY))
  ovLyricsManualOffset = clampedY - ovLyricsBaseY
  ovLyricsUserScrolling = true
  ovLyricsSpring.setPos(clampedY)  // 1:1 tracking under the cursor, no physics lag
  // Reveals the lines the karaoke fade keeps at opacity 0, which is everything
  // you scroll toward. CSS handles the fade in and back out.
  e.currentTarget.classList.add('browsing')

  clearTimeout(ovLyricsScrollTimer)
  ovLyricsScrollTimer = setTimeout(() => {
    ovLyricsUserScrolling = false
    ovLyricsManualOffset = 0
    document.getElementById('ov-panel-lyrics').classList.remove('browsing')
    ovLyricsSpring.setTarget(ovLyricsBaseY)  // spring settles back with a bit of momentum
  }, 2200)
}, { passive: false })

onDeck('timeupdate', () => {
  if (!overlayOpen || !overlayLyricsOpen || !lyricsData.length) return
  // Same lookahead as word-fill (_wordHighlightFrame) so the last word's fill
  // animation and the line-promotion check complete in lockstep - no gap in
  // either direction (mid-fill cutoff if promotion is earlier, a visible
  // "stick" on the finished word if promotion is later).
  const nowSec = audio.currentTime + 0.225
  const baseIdx = _scanLyricsBaseIdx(nowSec, _ovLyricsScanIdx)
  _ovLyricsScanIdx = baseIdx

  // Karaoke lines: promote to the next line (position AND highlight together)
  // the instant the current line's last word finishes, instead of waiting for
  // the next line's own start - otherwise the view snaps into place early but
  // sits dim/inactive for a beat, which reads as stuck.
  let activeIdx = baseIdx
  const words = lyricsData[baseIdx]?.Words
  if (words?.length && lyricsData[baseIdx + 1]) {
    const lastWordEnd = words[words.length - 1].End
    if (lastWordEnd != null && nowSec >= lastWordEnd / 10_000_000) activeIdx = baseIdx + 1
  }

  if (activeIdx === lastOverlayLyricsIdx) return
  const advancedEarly = activeIdx > baseIdx
  lastOverlayLyricsIdx = activeIdx
  updateOverlayLyricsActive(activeIdx, advancedEarly)
})

// Update overlay when track changes
const _baseUpdateNP = updateNowPlaying
updateNowPlaying = function(item) {
  _baseUpdateNP(item)
  if (overlayOpen) { syncOverlayState(); renderQueuePanel() }
}

// ── Context menu ──────────────────────────────────────────────────────────────

const ctxMenu = document.getElementById('ctx-menu')

function showCtxMenu(x, y) {
  ctxMenu.style.left = `${x}px`
  ctxMenu.style.top = `${y}px`
  ctxMenu.classList.add('open')
  const rect = ctxMenu.getBoundingClientRect()
  if (rect.right > window.innerWidth) ctxMenu.style.left = `${x - rect.width}px`
  if (rect.bottom > window.innerHeight) ctxMenu.style.top = `${y - rect.height}px`
}
function hideCtxMenu() {
  ctxMenu.classList.remove('open')
  ctxMenu.style.transformOrigin = ''
  document.getElementById('ov-more-scrim').classList.remove('show')
}
// Close when clicking outside the menu - mousedown fires before click so it's reliable.
// The scrim sits behind the menu and above everything else, so a click meant to
// dismiss the menu lands on it and hits this same "outside the menu" case.
document.addEventListener('mousedown', (e) => {
  if (!ctxMenu.contains(e.target)) hideCtxMenu()
})

document.getElementById('np-art').addEventListener('contextmenu', (e) => {
  e.preventDefault()
  if (!queue[queueIndex]) return
  showCtxMenu(e.clientX, e.clientY)
})
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { hideCtxMenu(); hideLyrics() } })

// Stop playback. Defined next to the other transport handlers but used by three
// callers - this menu item, the OS media keys, and a remote controller - so
// they cannot drift into three different meanings of "stop".
document.getElementById('ctx-stop').addEventListener('click', () => stopPlayback())

// Clear queue
document.getElementById('ctx-clear-queue').addEventListener('click', () => {
  queue = []; queueIndex = -1
  _clearStreamPrefetch()   // nothing left to prefetch for
})

// Instant mix
document.getElementById('ctx-instant-mix').addEventListener('click', async () => {
  const item = queue[queueIndex]
  if (!item) return
  try {
    const data = await jfGet(`/Items/${item.Id}/InstantMix`, {
      UserId: jf.userId, Limit: 25,
      Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag'
    })
    if (data.Items?.length) playItems(data.Items, 0)
  } catch (e) { console.error('Instant mix failed', e) }
})

// Add to playlist
let _atpTargetItem = null  // set by context menu; falls back to now-playing

function openAtpModal() {
  const modal = document.getElementById('atp-modal')
  const createRow = document.getElementById('atp-create-row')
  createRow.classList.remove('visible')
  document.getElementById('atp-new-name').value = ''
  modal.classList.remove('hidden')
  atpLoadPlaylists()
}

async function atpLoadPlaylists() {
  const list = document.getElementById('atp-list')
  list.innerHTML = '<div class="skel skel-text" style="width:100%;height:30px"></div><div class="skel skel-text" style="width:100%;height:30px"></div><div class="skel skel-text" style="width:100%;height:30px"></div>'
  try {
    const data = await jfGet(`/Users/${jf.userId}/Items`, {
      IncludeItemTypes: 'Playlist', Recursive: true, SortBy: 'SortName'
    })
    list.innerHTML = (data.Items || []).map(pl =>
      `<div class="modal-pl-item" data-id="${pl.Id}">${esc(pl.Name)}</div>`
    ).join('') || '<div style="font-size:12px;color:var(--text3);text-align:center;padding:20px 0">No playlists</div>'
    list.querySelectorAll('.modal-pl-item').forEach(el => {
      el.addEventListener('click', async () => {
        const item = _atpTargetItem || queue[queueIndex]
        _atpTargetItem = null
        if (!item) return
        try {
          const res = await fetch(`${jf.url}/Playlists/${el.dataset.id}/Items?Ids=${encodeURIComponent(item.Id)}&UserId=${encodeURIComponent(jf.userId)}`, {
            method: 'POST',
            headers: { 'X-Emby-Token': jf.token }
          })
          if (!res.ok) {
            const errMsg = await CascadeCore.readErrorMessage(res)
            showNotice(`Could not add to that playlist.\n\n${errMsg}`, 'Playlist')
          } else {
            showToast(`Added to "${el.textContent}"`)
            playlistMutated(el.dataset.id)
          }
        } catch (e) {
          showNotice('Could not reach the server to add to that playlist.', 'Playlist')
          console.error('Add to playlist failed', e)
        }
        document.getElementById('atp-modal').classList.add('hidden')
      })
    })
  } catch { list.innerHTML = '<div style="font-size:12px;color:var(--text3);text-align:center;padding:20px 0">Failed to load</div>' }
}

document.getElementById('ctx-add-playlist').addEventListener('click', () => {
  _atpTargetItem = null  // use now-playing
  openAtpModal()
})

document.getElementById('atp-cancel').addEventListener('click', () => { _atpTargetItem = null; document.getElementById('atp-modal').classList.add('hidden') })

// New playlist inline form
document.getElementById('atp-new-playlist').addEventListener('click', () => {
  const row = document.getElementById('atp-create-row')
  row.classList.add('visible')
  document.getElementById('atp-new-name').focus()
})

document.getElementById('atp-create-cancel-btn').addEventListener('click', () => {
  document.getElementById('atp-create-row').classList.remove('visible')
  document.getElementById('atp-new-name').value = ''
})

async function atpCreatePlaylist() {
  const item = queue[queueIndex]
  const name = document.getElementById('atp-new-name').value.trim()
  if (!name || !item) return
  document.getElementById('atp-create-confirm').disabled = true
  try {
    const res = await fetch(`${jf.url}/Playlists?Name=${encodeURIComponent(name)}&Ids=${encodeURIComponent(item.Id)}&UserId=${encodeURIComponent(jf.userId)}&MediaType=Audio`, {
      method: 'POST',
      headers: { 'X-Emby-Token': jf.token }
    })
    if (!res.ok) throw new Error(res.status)
    showToast(`Playlist "${name}" created`)
    document.getElementById('atp-modal').classList.add('hidden')
    document.getElementById('atp-create-row').classList.remove('visible')
    document.getElementById('atp-new-name').value = ''
    playlistMutated(null) // new playlist, so never the one currently open - just invalidate the index grid
  } catch (e) {
    showNotice('Could not create the playlist.', 'Playlist')
    console.error('Create playlist failed', e)
  }
  document.getElementById('atp-create-confirm').disabled = false
}

document.getElementById('atp-create-confirm').addEventListener('click', atpCreatePlaylist)
document.getElementById('atp-new-name').addEventListener('keydown', e => { if (e.key === 'Enter') atpCreatePlaylist() })

// Download
document.getElementById('ctx-download').addEventListener('click', () => {
  const item = queue[queueIndex]
  if (!item) return
  const url = `${jf.url}/Items/${item.Id}/Download?api_key=${jf.token}`
  window.cascade.download(url, item.Name)
})

// Copy stream URL
document.getElementById('ctx-copy-url').addEventListener('click', () => {
  const item = queue[queueIndex]
  if (!item) return
  window.cascade.clipboard.write(streamUrl(item.Id, isVideoItem(item) ? 'Video' : 'Audio'))
})

// Media info
document.getElementById('ctx-media-info').addEventListener('click', async () => {
  const item = queue[queueIndex]
  if (!item) return
  const modal = document.getElementById('mi-modal')
  const grid = document.getElementById('mi-grid')
  modal.classList.remove('hidden')
  try {
    const d = await jfGet(`/Users/${jf.userId}/Items/${item.Id}`)
    const ms = (d.RunTimeTicks || 0) / 10000
    const rows = [
      ['Title', d.Name],
      ['Artist', d.AlbumArtist || d.Artists?.join(', ')],
      ['Album', d.Album],
      ['Year', d.ProductionYear],
      ['Track', d.IndexNumber],
      ['Duration', fmtTime(ms / 1000)],
      ['Bitrate', d.MediaStreams?.[0]?.BitRate ? `${Math.round(d.MediaStreams[0].BitRate / 1000)} kbps` : '-'],
      ['Codec', d.MediaStreams?.[0]?.Codec?.toUpperCase() || '-'],
      ['Container', d.Container?.toUpperCase() || '-'],
      ['Sample rate', d.MediaStreams?.[0]?.SampleRate ? `${d.MediaStreams[0].SampleRate} Hz` : '-'],
      ['Channels', d.MediaStreams?.[0]?.Channels],
      ['Size', d.Size ? `${(d.Size / 1048576).toFixed(1)} MB` : '-'],
      ['Added', d.DateCreated ? new Date(d.DateCreated).toLocaleDateString() : '-'],
      ['Played', d.UserData?.PlayCount ? `${d.UserData.PlayCount}×` : 'Never'],
    ]
    grid.innerHTML = rows.filter(([,v]) => v).map(([k,v]) =>
      `<span class="mi-key">${k}</span><span class="mi-val">${esc(String(v))}</span>`
    ).join('')
  } catch { grid.innerHTML = '<span class="mi-key">Error</span><span class="mi-val">Could not load</span>' }
})
document.getElementById('mi-close').addEventListener('click', () => document.getElementById('mi-modal').classList.add('hidden'))

// Refresh metadata
document.getElementById('ctx-refresh-meta').addEventListener('click', async () => {
  const item = queue[queueIndex]
  if (!item || !jf.isAdmin) return
  try {
    const res = await fetch(`${jf.url}/Items/${item.Id}/Refresh?MetadataRefreshMode=FullRefresh&ImageRefreshMode=FullRefresh&ReplaceAllMetadata=false`, {
      method: 'POST', headers: { 'X-Emby-Token': jf.token }
    })
    if (!res.ok) throw new Error(String(res.status))
    showToast('Metadata refresh queued')
  } catch { showNotice('Could not queue a metadata refresh on the server.', 'Refresh failed') }
})

// Edit images - open the item in the Jellyfin web UI. There is no in-app image
// uploader here, unlike metadata and lyrics, which both have their own editor
// (wired below and above respectively).
// Jellyfin's metadata manager (#/libraries/metadata) is a standalone tree browser with
// no id parameter, so an item can't be deep-linked to it. #/details is the only
// item-scoped route left, and its page carries the edit actions - so both land there.
// Note the scheme is #/ ; the old #!/ prefix and the edititem* routes are long gone.
function openInJellyfinWeb(item) {
  if (!item) return
  // The context items are greyed for a non-admin, but a disabled-looking div
  // can still be clicked programmatically - and the destination page would
  // just refuse the edit anyway, so there is no reason to open it.
  if (!jf.isAdmin) return
  window.cascade.shell.openExternal(`${jf.url}/web/index.html#/details?id=${item.Id}`)
}
document.getElementById('ctx-edit-images').addEventListener('click', () => openInJellyfinWeb(queue[queueIndex]))

// Metadata has its own in-app editor, same reasoning as lyrics below - no
// reason to bounce to a browser for it either.
document.getElementById('ctx-edit-meta').addEventListener('click', () => openMetadataEditorFor(queue[queueIndex]))

// Lyrics are the one thing we can edit in-app - no reason to bounce to a browser
document.getElementById('ctx-edit-lyrics').addEventListener('click', () => {
  openLyricsEditorFor(queue[queueIndex])
})

// View album - navigate to the album's detail page
document.getElementById('ctx-view-album').addEventListener('click', () => openAlbumFromTrack(queue[queueIndex]))

// View album artist - navigate to the artist's detail page
document.getElementById('ctx-view-artist').addEventListener('click', () => openArtistFromTrack(queue[queueIndex]))

// View lyrics
document.getElementById('ctx-view-lyrics').addEventListener('click', () => showLyrics())

// Delete media
document.getElementById('ctx-delete').addEventListener('click', async () => {
  const item = queue[queueIndex]
  if (!item) return
  // The entry is greyed for an account without the deletion right, but a
  // disabled-looking div can still be clicked programmatically - don't trust
  // the DOM state alone against a server call that would just 403 anyway.
  if (!jf.canDelete) return
  if (!confirm(`Delete "${item.Name}" from your server? This cannot be undone.`)) return
  try {
    const res = await fetch(`${jf.url}/Items/${item.Id}`, {
      method: 'DELETE', headers: { 'X-Emby-Token': jf.token }
    })
    // The response was never read, so a 403 (e.g. a library outside this
    // account's granted folders) reported success for a delete the server
    // had refused outright.
    if (!res.ok) throw new Error(String(res.status))
    audio.pause(); _detachDeck(audio)
    queue.splice(queueIndex, 1)
    queueIndex = Math.min(queueIndex, queue.length - 1)
    // playCurrentTrack() below re-checks the prefetch for the new current
    // item; an empty queue has nothing left to play it into.
    if (queue.length) playCurrentTrack()
    else _clearStreamPrefetch()
  } catch (e) {
    console.error('Delete failed', e)
    showNotice('Could not delete this item from the server.', 'Delete failed')
  }
})

// ── Lyrics panel ──────────────────────────────────────────────────────────────

let lyricsSource        = null   // source that was actually used: 'Kugou' | 'LRCLIB' | 'LRCLIB (plain)' | 'Jellyfin' | 'Karaoke' | 'Synced'
let lyricsForcedSource  = 'auto' // 'auto' | 'Kugou' | 'LRCLIB' | 'Jellyfin' | 'cascade-karaoke' | 'cascade-synced'
let serverOnlyMode    = false  // fetch exclusively from Cascade plugin when true

// Valid lyrics source keys - any stored value not in this set is stale and gets reset
const VALID_LYRICS_SOURCES = new Set(['auto', 'Kugou', 'LRCLIB', 'Jellyfin', 'cascade-karaoke', 'cascade-synced'])

// ── CascadeSLRC plugin detection ────────────────────────────────────────────
// Whether the connected server has the plugin at all. Probed once per
// connection (see probeCascadePlugin, called from connect()) and cached here
// for the session - not worth a round trip per track.
let _cascadePluginAbsent = false
const NO_PLUGIN_TIP = 'No SLRC Plugin'

/**
 * GET {jf.url}/CascadeLyrics/Info with the normal auth header. The plugin
 * exposes that route for exactly this question, so reaching it is the answer
 * and the body is not read here.
 *
 * Neither of the obvious alternatives works. Jellyfin's own /Plugins needs
 * elevation and Cascade signs in as a normal user, and the lyrics route
 * cannot answer either, since a server without the plugin and a track with
 * genuinely no lyrics both return a bare 404.
 */
async function probeCascadePlugin() {
  let status = null
  try {
    const r = await fetch(`${jf.url}/CascadeLyrics/Info`, {
      headers: { 'X-Emby-Token': jf.token },
      signal: AbortSignal.timeout(8000),
    })
    status = r.status
  } catch {
    // Network failure - status stays null, which reads as 'unknown' below.
  }
  const verdict = CascadeCore.interpretCascadePluginProbe(status)
  // 'unknown' (401, 5xx, network failure) is treated as present: never grey
  // out a working feature because the network hiccuped.
  _cascadePluginAbsent = verdict === 'absent'
  _applyCascadePluginAvailability()
}

/** Disables what depends on the plugin once probeCascadePlugin() has found it
 *  missing. Safe to call anytime, including before the probe resolves or
 *  while the settings view isn't open. */
function _applyCascadePluginAvailability() {
  const absent = _cascadePluginAbsent

  const toggle = document.getElementById('server-only-lyrics-toggle')
  if (toggle) toggle.disabled = absent
  document.getElementById('server-only-lyrics-row')?.classList.toggle('locked', absent)
  const note = document.getElementById('server-only-plugin-missing')
  if (note) note.style.display = absent ? '' : 'none'

  ;['lyrics-edit-btn', 'ov-lyrics-edit-btn'].forEach(id => {
    const btn = document.getElementById(id)
    if (btn) btn.disabled = absent
  })

  // A dimmed control does not say why it is dimmed, and the settings row's
  // explanation is not visible from the lyrics panel. The tip goes on the
  // hover host rather than the control itself, because a disabled control
  // does not fire the hover that would show it.
  ;['server-only-toggle-label', 'lyrics-edit-btn-tip', 'ov-lyrics-edit-btn-tip'].forEach(id => {
    const host = document.getElementById(id)
    if (!host) return
    if (absent) host.setAttribute('data-tip', NO_PLUGIN_TIP)
    else host.removeAttribute('data-tip')
  })

  // Server-only mode was already on and the plugin turned out to be absent -
  // a broken state, not just a disabled toggle. Turn it off and say why.
  if (absent && serverOnlyMode) {
    serverOnlyMode = false
    window.cascade.store.set('serverOnlyMode', false)
    if (toggle) toggle.checked = false
    _applyServerOnlyMode(false)
    showToast('Server-only lyrics mode turned off - the CascadeSLRC plugin was not found on this server')
  }
}

// Load persisted preferences immediately
;(async () => {
  const stored = (await window.cascade.store.get('lyricsForcedSource')) || 'auto'
  if (!VALID_LYRICS_SOURCES.has(stored)) {
    console.warn(`[Lyrics] Stale lyricsForcedSource "${stored}" - resetting to auto`)
    await window.cascade.store.set('lyricsForcedSource', 'auto')
    lyricsForcedSource = 'auto'
  } else {
    lyricsForcedSource = stored
  }
  serverOnlyMode   = (await window.cascade.store.get('serverOnlyMode')) === true
  _applyServerOnlyMode(serverOnlyMode)
})()

// Drop the cached fetch for a track and, if it is the one playing, reload the panel.
// itemId defaults to the current track.
function _reloadLyricsFor(itemId) {
  const cur = queue[queueIndex]
  _lyricsCache.delete(itemId ?? cur?.Id)
  if (!cur || (itemId != null && itemId !== cur.Id)) return
  lyricsData = []; lastLyricsIdx = -1; lastOverlayLyricsIdx = -1; _lyricsScanIdx = 0; _ovLyricsScanIdx = 0
  fetchLyrics()
}

// The editor writes straight to the server from its own window, so without this the
// cache below keeps handing back the copy from before the edit.
window.cascade.lyricsEditor.onSaved(itemId => _reloadLyricsFor(itemId))

function _applyServerOnlyMode(on) {
  // Dropdown: hide external sources and sep, show/hide server-only items; Auto always visible
  document.querySelectorAll('#lyrics-source-dropdown .lsd-non-server')
    .forEach(el => { el.style.display = on ? 'none' : '' })
  document.querySelectorAll('#lyrics-source-dropdown .lsd-server-only')
    .forEach(el => { el.style.display = on ? '' : 'none' })
  // Update Auto hint to reflect mode
  const autoHint = document.getElementById('lsd-auto-hint')
  if (autoHint) autoHint.textContent = on ? 'Server · karaoke preferred' : 'Kugou → LRCLIB → Jellyfin'
  // Settings select options (Auto option has no class so is always visible)
  const sel = document.getElementById('s-lyrics-source')
  if (!sel) return
  sel.querySelectorAll('.lsd-non-server').forEach(o => { o.style.display = on ? 'none' : '' })
  sel.querySelectorAll('.lsd-server-only').forEach(o => { o.style.display = on ? '' : 'none' })
}

let lyricsData = []
let lyricsTranslated = []

// ── Source pill helpers ───────────────────────────────────────────────────────

function _showLyricsFetchToast(result) {
  const tried = result?.tried ?? _lastFetchStatus
  const failed = Object.entries(tried).filter(([, v]) => v === 'fail').map(([k]) => k)
  if (!failed.length) return

  const succeeded = result?.source
  if (succeeded) {
    const msg = failed.length === 1
      ? `${failed[0]} unavailable · using ${succeeded}`
      : `${failed.join(', ')} unavailable · using ${succeeded}`
    showToast(msg, 3500)
  } else {
    // All tried sources failed (no result)
    const tried_names = Object.entries(tried).filter(([, v]) => v === 'fail').map(([k]) => k)
    if (tried_names.length) showToast(`No lyrics - ${tried_names.join(', ')} all failed`, 3500)
  }
}

function updateSourcePills() {
  const forced   = lyricsForcedSource && lyricsForcedSource !== 'auto'
  const label    = forced
    ? (lyricsForcedSource === 'cascade-karaoke' ? 'Karaoke'
       : lyricsForcedSource === 'cascade-synced' ? 'Synced'
       : lyricsForcedSource)
    : (lyricsSource || 'Auto')
  document.querySelectorAll('.lyrics-source-pill').forEach(p => {
    p.textContent = label
    p.classList.toggle('forced', forced)
  })
}

function _openSourceDropdown(nearEl) {
  const dd   = document.getElementById('lyrics-source-dropdown')
  const rect = nearEl.getBoundingClientRect()
  dd.style.left = `${Math.max(8, rect.left)}px`
  dd.style.top  = `${rect.bottom + 6}px`
  dd.classList.add('open')
  requestAnimationFrame(() => {
    const dr = dd.getBoundingClientRect()
    if (dr.right  > window.innerWidth  - 8) dd.style.left = `${window.innerWidth  - dr.width - 8}px`
    if (dr.bottom > window.innerHeight - 8) dd.style.top  = `${rect.top - dr.height - 6}px`

    const cur = lyricsForcedSource || 'auto'
    dd.querySelectorAll('.lsd-item').forEach(el => {
      const src    = el.dataset.source
      el.classList.toggle('active', src === cur)

      // Status badge - remove old one first
      el.querySelector('.lsd-status')?.remove()
      const status = _lastFetchStatus[src]  // 'ok'|'fail'|'skip'|null
      if (status && src !== 'auto') {
        const badge = document.createElement('span')
        badge.className = `lsd-status lsd-status-${status}`
        badge.title = status === 'ok' ? 'Succeeded last fetch'
                    : status === 'fail' ? 'Failed last fetch'
                    : 'Skipped (earlier source succeeded)'
        el.appendChild(badge)
      }
    })
  })
}

// ── CascadeSLRC plugin one-time info modal ────────────────────────────────────
// Resolves true if user clicks "Continue", false if they click "Cancel".
// After first "Continue" the modal is never shown again (persisted in store).
async function _ensureCascadePluginNotice() {
  const seen = await window.cascade.store.get('cascadePluginNoticeSeen')
  if (seen) return true
  return new Promise(resolve => {
    const modal = document.getElementById('cascade-plugin-modal')
    modal.classList.remove('hidden')
    const onCancel = () => {
      modal.classList.add('hidden')
      document.getElementById('cascade-plugin-continue').removeEventListener('click', onContinue)
      resolve(false)
    }
    const onContinue = async () => {
      modal.classList.add('hidden')
      document.getElementById('cascade-plugin-cancel').removeEventListener('click', onCancel)
      await window.cascade.store.set('cascadePluginNoticeSeen', true)
      resolve(true)
    }
    document.getElementById('cascade-plugin-cancel').addEventListener('click', onCancel, { once: true })
    document.getElementById('cascade-plugin-continue').addEventListener('click', onContinue, { once: true })
  })
}

// ── Lyrics edit button ────────────────────────────────────────────────────────
async function openLyricsEditorFor(item) {
  if (!item || !jf) return
  // Root-cause gate: every entry point (both buttons and the context menu
  // item) routes through here, so this is the one place that needs to know
  // the plugin is missing.
  if (_cascadePluginAbsent) {
    showToast('The lyrics editor needs the CascadeSLRC plugin, which was not found on this server')
    return
  }
  const proceed = await _ensureCascadePluginNotice()
  if (!proceed) return
  // lyricsData holds the playing track's lines - only seed the editor with it when
  // that is actually the track being edited, otherwise let the editor fetch its own.
  const seed = item.Id === queue[queueIndex]?.Id ? (lyricsData || []) : []
  // Pass `volume`, not audio.volume: mid-crossfade the element is partway
  // through a fade and would hand the editor whatever that transient value is.
  window.cascade.lyricsEditor.open({ item, jf, lyricsData: seed, volume })
}

;['lyrics-edit-btn', 'ov-lyrics-edit-btn'].forEach(id => {
  const btn = document.getElementById(id)
  if (!btn) return
  btn.addEventListener('click', e => {
    e.stopPropagation()
    openLyricsEditorFor(queue[queueIndex])
  })
})

// ── Metadata editor ───────────────────────────────────────────────────────────
// POST /Items/{id} is RequiresElevation - admin only, verified against the
// live server (see CODEMAP). The ctx-edit-meta / tctx-edit-meta entries that
// call this are already greyed with .needs-admin for a non-admin (same
// treatment as Refresh metadata), so this check is the second gate: a
// disabled-looking menu item can still be clicked programmatically, and the
// window itself checks jf.isAdmin again before its save button does anything.
function openMetadataEditorFor(item) {
  if (!item || !jf.isAdmin) return
  window.cascade.metadataEditor.open({ item, jf })
}

// Refresh whatever already-loaded views hold the edited item. Same local
// refresh path as the "Refresh from server" settings button - invalidate the
// lazy grid caches and reload whatever is on screen and Home - plus a direct
// patch for the currently playing track, since its title/artist in the status
// bar and now-playing overlay come from the in-memory queue, not from either
// of those caches.
window.cascade.metadataEditor.onSaved(async (itemId) => {
  invalidateLibraryViews()
  invalidateVideoViews()
  showView(_currentView)
  await loadHome()

  if (queue[queueIndex]?.Id !== itemId) return
  try {
    const res = await jfGet(`/Users/${jf.userId}/Items`, {
      Ids: itemId,
      Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag,UserData',
    })
    const fresh = res?.Items?.[0]
    // The track playing may have moved on while this was in flight.
    if (!fresh || queue[queueIndex]?.Id !== itemId) return
    queue[queueIndex] = fresh
    updateNowPlaying(fresh)
    if (overlayOpen) syncOverlayState()
  } catch {
    // Best-effort - the grid/Home reload above already has the fresh copy for
    // next time this item is opened from there.
  }
})

;['sidebar-source-pill', 'ov-source-pill'].forEach(id => {
  const pill = document.getElementById(id)
  if (!pill) return
  pill.addEventListener('click', e => {
    e.stopPropagation()
    const dd = document.getElementById('lyrics-source-dropdown')
    if (dd.classList.contains('open')) { dd.classList.remove('open'); return }
    _openSourceDropdown(pill)
  })
})

document.getElementById('lyrics-source-dropdown').querySelectorAll('.lsd-item').forEach(item => {
  item.addEventListener('click', async e => {
    e.stopPropagation()
    lyricsForcedSource = item.dataset.source
    await window.cascade.store.set('lyricsForcedSource', lyricsForcedSource)
    // Sync the settings select if it's rendered
    const sel = document.getElementById('s-lyrics-source')
    if (sel) sel.value = lyricsForcedSource
    document.getElementById('lyrics-source-dropdown').classList.remove('open')
    updateSourcePills()
    _reloadLyricsFor()
  })
})

document.addEventListener('click', () => {
  document.getElementById('lyrics-source-dropdown').classList.remove('open')
})

// ── Word-highlight RAF loop ───────────────────────────────────────────────────
// Runs at 60fps while playing so word spans update smoothly instead of jumping
// every ~250ms with timeupdate.

let _wordRafId = null

function _wordProgress(w, nowTicks) {
  const ws = parseInt(w.dataset.ws)
  const we = w.dataset.we ? parseInt(w.dataset.we) : null
  if (nowTicks < ws) return 0
  if (!we || nowTicks >= we) return 100
  return (nowTicks - ws) / (we - ws) * 100
}

function _wordHighlightFrame() {
  _wordRafId = requestAnimationFrame(_wordHighlightFrame)
  const nowTicks = (audio.currentTime + 0.225) * 10_000_000

  // Side panel - CSS scoping (.lyrics-line.active .lyric-word) handles inactive lines.
  // Guard on the view actually being visible: the panel stays mounted (just hidden via
  // CSS) when the user navigates elsewhere, so without this the loop would keep querying
  // and restyling word spans at 60fps for the entire track even off-screen.
  const panelIdx = lastLyricsIdx
  if (document.getElementById('view-lyrics')?.classList.contains('active') && lyricsData[panelIdx]?.Words) {
    document.getElementById('lyrics-inner')
      ?.querySelector(`.lyrics-line[data-idx="${panelIdx}"]`)
      ?.querySelectorAll('.lyric-word').forEach(w => {
        const p = _wordProgress(w, nowTicks)
        w.style.setProperty('--p', `${p.toFixed(2)}%`)
        const ws = parseInt(w.dataset.ws)
        const we = w.dataset.we ? parseInt(w.dataset.we) : null
        w.classList.toggle('active', nowTicks >= ws && (!we || nowTicks < we))
      })
  }

  // Overlay - same: CSS scoping handles inactive lines automatically
  if (overlayOpen && overlayLyricsOpen) {
    const ovIdx = lastOverlayLyricsIdx
    if (lyricsData[ovIdx]?.Words) {
      document.getElementById('ov-lyrics-body')
        ?.querySelector(`.ov-lyric-line[data-idx="${ovIdx}"]`)
        ?.querySelectorAll('.ov-lyric-word').forEach(w => {
          const p = _wordProgress(w, nowTicks)
          w.style.setProperty('--p', `${p.toFixed(2)}%`)
          const ws = parseInt(w.dataset.ws)
          const we = w.dataset.we ? parseInt(w.dataset.we) : null
          w.classList.toggle('active', nowTicks >= ws && (!we || nowTicks < we))
        })
    }
  }
}

function _startWordLoop() {
  if (_wordRafId) return
  if (lyricsData.some(l => l.Words)) _wordHighlightFrame()
}

function _stopWordLoop() {
  if (_wordRafId) { cancelAnimationFrame(_wordRafId); _wordRafId = null }
}

onDeck('play',  () => _startWordLoop())
onDeck('pause', () => _stopWordLoop())
onDeck('ended', () => _stopWordLoop())

// ── Lyrics panel ─────────────────────────────────────────────────────────────

function showLyrics() {
  document.getElementById('lyrics-panel').classList.add('open')
  fetchLyrics()
}
function hideLyrics() { document.getElementById('lyrics-panel').classList.remove('open') }

document.getElementById('lyrics-close').addEventListener('click', hideLyrics)

// ── Lyrics waterfall helpers ──────────────────────────────────────────────────


// Lyric parsing lives in src/core/lyrics.ts; parseLRC/parseKrc are bound at the
// top of this file with the rest of the core imports. `lyricsTextMatch` is
// exported from core too, but nothing here calls it - the old local copy was
// dead code, so it is not re-aliased.

// Per-source status from the most recent waterfall run.
// Values: 'ok' | 'fail' | 'skip' | null (never tried this session)
let _lastFetchStatus = { Cascade: null, Kugou: null, LRCLIB: null, Jellyfin: null }

// Cache: itemId → result object. Keeps the last 50 tracks so reopening
// lyrics or the overlay is instant without re-fetching.
const _lyricsCache = new Map()
function _cachePut(id, result) {
  if (_lyricsCache.size >= 50) _lyricsCache.delete(_lyricsCache.keys().next().value)
  _lyricsCache.set(id, result)
}

// Main fetch: LRCLIB · Jellyfin - all fired in parallel,
// resolved in priority order. Respects lyricsForcedSource.
// Returns { lines, source, tried } | { instrumental: true } | null.
const _isAbort = e => e?.name === 'AbortError' || e?.name === 'TimeoutError'

async function fetchLyricsWaterfall(item) {
  const forced = lyricsForcedSource && lyricsForcedSource !== 'auto' ? lyricsForcedSource : null

  // Bypass cache when a source is forced so the user always gets a fresh fetch
  if (!forced && _lyricsCache.has(item.Id)) return _lyricsCache.get(item.Id)

  const title    = encodeURIComponent(item.Name || '')
  const artist   = encodeURIComponent(item.AlbumArtist || item.Artists?.[0] || '')
  const album    = encodeURIComponent(item.Album || '')
  const duration = Math.round((item.RunTimeTicks || 0) / 10_000_000)
  const sig      = { signal: AbortSignal.timeout(8000) }

  // Strip metadata/credits lines sometimes embedded by lyrics sources
  const metaPattern = new RegExp(
    [
      // "Song Title - " prefix (was the original filter)
      `^${(item.Name || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*-\\s*`,
      // Credits: "Composed by:", "Written by:", "Produced by:", etc.
      '^(composed|written|produced|arranged|performed|lyrics|music|words|publisher|\\u4f5c\\u8bcd|\\u4f5c\\u66f2|\\u7f16\\u66f2|\\u7f16\\u8bcd|\\u5236\\u4f5c\\u4eba)\\s*(by)?\\s*[:\\uff1a]',
    ].join('|'),
    'i'
  )
// ── Server-only mode: exclusively hit the Cascade plugin ─────────────────────
  if (serverOnlyMode) {
    const wantType = forced === 'cascade-karaoke' ? 'karaoke'
                   : forced === 'cascade-synced'  ? 'synced'
                   : null   // auto = accept either (plugin returns karaoke first)
    const tried = { Cascade: null }
    try {
      const r = await fetch(`${jf.url}/Audio/${item.Id}/CascadeLyrics`,
        { headers: { 'X-Emby-Token': jf.token }, signal: AbortSignal.timeout(8000) })
      if (!r.ok) throw new Error(`HTTP ${r.status}`)
      const d = await r.json()
      if (!d.lrc || (wantType && d.type !== wantType)) {
        tried.Cascade = 'fail'; _lastFetchStatus = tried; return null
      }
      const lines = parseLRC(d.lrc).filter(l => !metaPattern.test(l.Text))
      if (!lines.length) { tried.Cascade = 'fail'; _lastFetchStatus = tried; return null }
      tried.Cascade = 'ok'
      _lastFetchStatus = tried
      const srcLabel = forced === 'cascade-karaoke' ? 'Karaoke'
                     : forced === 'cascade-synced'  ? 'Synced'
                     : 'Cascade'
      const out = { lines, source: srcLabel, tried }
      if (!forced) _cachePut(item.Id, out)
      return out
    } catch (err) {
      if (!_isAbort(err)) console.error('[Lyrics] Cascade error:', err)
      tried.Cascade = 'fail'; _lastFetchStatus = tried; return null
    }
  }

  const sources = [
    ['Kugou', async () => {
      // Kugou KRC - word-level, no auth required. Main process handles decrypt.
      const rawTitle  = item.Name || ''
      const rawArtist = item.AlbumArtist || item.Artists?.[0] || ''
      const krcText   = await window.cascade.kugouGetLyrics({
        title:      rawTitle,
        artist:     rawArtist,
        durationMs: (item.RunTimeTicks || 0) / 10_000,
      })
      if (!krcText) return null
      const lines = parseKrc(krcText).filter(l => !metaPattern.test(l.Text))
      // Only return if we got actual word-level data (otherwise let LRCLIB handle it)
      if (!lines.length || !lines.some(l => l.Words?.length > 0)) return null
      return { lines, source: 'Kugou' }
    }],
    ['LRCLIB', async () => {
      const r = await fetch(
        `https://lrclib.net/api/get?artist_name=${artist}&track_name=${title}&album_name=${album}&duration=${duration}`, sig)
      if (!r.ok) throw new Error(`HTTP ${r.status}`)
      const d = await r.json()
      if (d.instrumental) return { instrumental: true }
      if (d.syncedLyrics) {
        const lines = parseLRC(d.syncedLyrics)
        if (lines.length) return { lines, source: 'LRCLIB' }
      }
      if (d.plainLyrics) {
        const lines = d.plainLyrics.split('\n').map(t => t.trim()).filter(Boolean)
          .map(t => ({ Start: null, End: null, Text: t, Words: null }))
        if (lines.length) return { lines, source: 'LRCLIB (plain)' }
      }
      return null
    }],
    ['Jellyfin', async () => {
      const r = await fetch(`${jf.url}/Audio/${item.Id}/Lyrics`,
        { headers: { 'X-Emby-Token': jf.token }, ...sig })
      if (!r.ok) throw new Error(`HTTP ${r.status}`)
      const d = await r.json()
      const lines = (d.Lyrics || [])
        .map(l => ({ Start: l.Start, End: null, Text: l.Text, Words: null }))
        .filter(l => l.Text)
      return lines.length ? { lines, source: 'Jellyfin' } : null
    }]
  ]

  const tried = { Kugou: null, LRCLIB: null, Jellyfin: null }

  // Forced source: single fetch only, never cache result
  if (forced) {
    const entry = sources.find(([name]) => name === forced)
    if (!entry) return null
    try {
      const result = await entry[1]()
      if (result?.instrumental) { _lastFetchStatus = tried; return { instrumental: true } }
      tried[forced] = result ? 'ok' : 'fail'
      _lastFetchStatus = tried
      return result ? { ...result, tried } : null
    } catch (err) {
      if (!_isAbort(err)) console.error(`[Lyrics] ${forced} error:`, err)
      tried[forced] = 'fail'
      _lastFetchStatus = tried
      return null
    }
  }

  // Fire all sources simultaneously
  const [kugouProm, lrcProm, jfProm] = sources.map(([name, fn]) =>
    fn().then(r => ({ name, result: r }))
      .catch(err => { if (!_isAbort(err)) console.error(`[Lyrics] ${name} error:`, err); return { name, result: null } })
  )

  const [kugouRes, lrcRes, jfRes] = await Promise.all([kugouProm, lrcProm, jfProm])

  // Instrumental check (any source can flag it)
  for (const { result } of [kugouRes, lrcRes, jfRes]) {
    if (result?.instrumental) {
      _lastFetchStatus = tried
      _cachePut(item.Id, { instrumental: true })
      return { instrumental: true }
    }
  }

  tried['Kugou']    = kugouRes.result ? 'ok' : 'fail'
  tried['LRCLIB']   = lrcRes.result   ? 'ok' : 'fail'
  tried['Jellyfin'] = jfRes.result    ? 'ok' : 'fail'

  const winner = kugouRes.result || lrcRes.result || jfRes.result
  if (winner) {
    _lastFetchStatus = tried
    const out = { ...winner, tried }
    _cachePut(item.Id, out)
    return out
  }

  _lastFetchStatus = tried
  return null
}

// ── Lyrics fetch ──────────────────────────────────────────────────────────────

let _lyricsFetchGen = 0  // incremented on every fetchLyrics() call; stale results are discarded

async function fetchLyrics() {
  const gen  = ++_lyricsFetchGen
  const item = queue[queueIndex]
  const body = document.getElementById('lyrics-body')
  const translateBar = document.getElementById('lyrics-translate-bar')
  if (!item) { body.innerHTML = '<div class="lyrics-empty">Nothing playing</div>'; return }

  body.innerHTML = skeletonHTML('lyrics', 1)
  translateBar.classList.remove('visible')
  lyricsData = []
  lyricsTranslated = []
  lastLyricsIdx = -1
  _lyricsScanIdx = 0

  const result = await fetchLyricsWaterfall(item)
  if (gen !== _lyricsFetchGen) return  // a newer fetch superseded this one

  if (result?.instrumental) {
    body.innerHTML = '<div class="lyrics-empty">This track is instrumental</div>'
    return
  }
  _showLyricsFetchToast(result)
  if (!result) {
    lyricsSource = null
    updateSourcePills()
    body.innerHTML = '<div class="lyrics-empty">No lyrics available for this track</div>'
    return
  }
  lyricsData   = result.lines
  lyricsSource = result.source
  updateSourcePills()
  renderLyrics()
  detectAndShowTranslateBar()
  _stopWordLoop()
  if (!audio.paused) _startWordLoop()
}

async function detectAndShowTranslateBar() {
  // Sample the first non-empty line for language detection
  const sample = lyricsData.find(l => l.Text?.trim())?.Text?.trim()
  if (!sample) return
  try {
    const res = await fetch(
      `https://api.mymemory.translated.net/get?q=${encodeURIComponent(sample.slice(0, 100))}&langpair=autodetect|en`
    )
    const data = await res.json()
    const detected = data.responseData?.detectedLanguage || ''
    // Show translate bar if detected language is not English
    if (detected && !detected.toLowerCase().startsWith('en')) {
      // Pre-select a sensible target language
      document.getElementById('lyrics-translate-bar').classList.add('visible')
    }
  } catch {
    // Detection failed silently - leave bar hidden
  }
}

function renderLyrics(showTranslation = false) {
  const body = document.getElementById('lyrics-body')
  const lines = lyricsData.map((line, i) => {
    const hasTimestamp = line.Start != null
    const transText = showTranslation && lyricsTranslated[i]
    const trans = transText ? `<div class="lyrics-line translated">${esc(lyricsTranslated[i])}</div>` : ''
    let content
    if (line.Words && !transText) {
      content = line.Words.map(w =>
        `<span class="lyric-word" data-ws="${w.Start}" data-we="${w.End ?? ''}">${esc(w.Text)}</span>`
      ).join('')
    } else {
      content = esc(transText ? lyricsTranslated[i] : (line.Text || ''))
    }
    return `<div class="lyrics-line${hasTimestamp ? ' seekable' : ''}" data-idx="${i}"${hasTimestamp ? ` data-start="${line.Start}"` : ''}>${content}</div>${trans}`
  }).join('')

  // Wrap in a translateY-driven inner div - position is spring-animated in JS
  // (see sideLyricsSpring), not CSS transitions, so no transition property here.
  body.innerHTML = `<div id="lyrics-inner" style="will-change:transform;padding-bottom:50%">${lines}</div>`
  sideLyricsSpring.jumpTo(0)  // fresh element, don't carry over the previous track's position

  body.querySelectorAll('.lyrics-line.seekable').forEach(el => {
    el.style.cursor = 'pointer'
    el.addEventListener('click', () => {
      const ticks = parseInt(el.dataset.start)
      if (isNaN(ticks) || !audio.duration) return
      lyricsScrollSuppressed = true
      clearTimeout(lyricsScrollTimer)
      lyricsScrollTimer = setTimeout(() => { lyricsScrollSuppressed = false }, 1500)
      audio.currentTime = ticks / 10000000
      lastLyricsIdx = -1
      _lyricsScanIdx = 0
    })
  })
}

// Sync lyrics highlight to playback position
let lastLyricsIdx = -1
let _lyricsScanIdx = 0   // cursor into lyricsData so timeupdate scans forward instead of from 0 each tick
let lyricsScrollSuppressed = false
let lyricsScrollTimer = null

onDeck('timeupdate', () => {
  if (!lyricsData.length) return
  // Same lookahead as word-fill (_wordHighlightFrame) so the last word's fill
  // animation and the line-promotion check complete in lockstep - no gap in
  // either direction (mid-fill cutoff if promotion is earlier, a visible
  // "stick" on the finished word if promotion is later).
  const nowSec = audio.currentTime + 0.225
  const baseIdx = _scanLyricsBaseIdx(nowSec, _lyricsScanIdx)
  _lyricsScanIdx = baseIdx

  // For karaoke lines, promote to the next line (highlight AND scroll together)
  // the instant its last word finishes, instead of waiting for the next line's
  // own start - otherwise the view snaps into place early but sits dim/inactive
  // for a beat, which reads as stuck.
  let activeIdx = baseIdx
  const words = lyricsData[baseIdx]?.Words
  if (words?.length && lyricsData[baseIdx + 1]) {
    const lastWordEnd = words[words.length - 1].End
    if (lastWordEnd != null && nowSec >= lastWordEnd / 10_000_000) activeIdx = baseIdx + 1
  }

  if (activeIdx === lastLyricsIdx) return
  const instant = activeIdx > baseIdx
  lastLyricsIdx = activeIdx

  const body = document.getElementById('lyrics-body')
  body.querySelectorAll('.lyrics-line[data-idx]').forEach(el => {
    el.classList.toggle('active', parseInt(el.dataset.idx) === activeIdx)
  })

  if (!lyricsScrollSuppressed) {
    const inner = document.getElementById('lyrics-inner')
    const target = inner?.querySelector(`.lyrics-line[data-idx="${activeIdx}"]`)
    if (target) {
      const panelMid  = body.clientHeight / 2
      const activeMid = target.offsetTop + target.offsetHeight / 2
      const y = panelMid - activeMid
      if (instant) sideLyricsSpring.jumpTo(y)
      else sideLyricsSpring.setTarget(y)
    }
  }
})

// Translation via MyMemory free API
document.getElementById('lyrics-translate-btn').addEventListener('click', async () => {
  if (!lyricsData.length) return
  const btn = document.getElementById('lyrics-translate-btn')
  const lang = document.getElementById('lyrics-lang').value
  btn.disabled = true; btn.textContent = 'Translating…'

  try {
    // Batch lines into chunks to avoid URL length limits
    const lines = lyricsData.map(l => l.Text || '')
    const chunkSize = 10
    lyricsTranslated = new Array(lines.length).fill('')

    for (let i = 0; i < lines.length; i += chunkSize) {
      const chunk = lines.slice(i, i + chunkSize)
      const joined = chunk.join('\n')
      const url = `https://api.mymemory.translated.net/get?q=${encodeURIComponent(joined)}&langpair=autodetect|${lang}`
      const res = await fetch(url)
      const data = await res.json()
      const translated = (data.responseData?.translatedText || joined).split('\n')
      translated.forEach((t, j) => { lyricsTranslated[i + j] = t })
    }
    renderLyrics(true)
  } catch (e) {
    console.error('Translation failed', e)
  } finally {
    btn.disabled = false
    btn.textContent = 'Translate'
  }
})

// Re-fetch lyrics when track changes
const _origUpdateNP = updateNowPlaying
updateNowPlaying = function(item) {
  _origUpdateNP(item)
  // Always clear stale lyrics so panels re-fetch for the new track
  lyricsData = []
  lyricsTranslated = []
  lastLyricsIdx = -1
  _lyricsScanIdx = 0
  ovLyricsTranslated = false
  document.getElementById('ov-translate-btn').style.display = 'none'
  document.getElementById('ov-translate-btn').classList.remove('translated')
  if (document.getElementById('lyrics-panel').classList.contains('open')) fetchLyrics()
  if (overlayOpen && overlayLyricsOpen) renderOverlayLyrics()
}

// ── Discord RPC ───────────────────────────────────────────────────────────────

let discordEnabled = false
let rpcTrackStart = 0

// How long a paused track keeps its Discord presence before giving up on it.
const RPC_PAUSE_CLEAR_MS = 60_000
let _rpcPauseTimer = null      // pending "give up on the paused presence" timeout, or null
let _rpcClearedByPause = false // true once that timer has actually cleared the presence -
                                // tells the next play event it needs to restore, not just resume

/** Cancels any pending pause-clear timer and drops the "cleared by pause" flag.
 *  Called by every deliberate clear (stop, sign-out, turning Discord off) so a
 *  timer scheduled for a pause that no longer matters cannot fire later and
 *  clear a presence that has moved on. */
function _clearRpcPauseTimer() {
  if (_rpcPauseTimer) { clearTimeout(_rpcPauseTimer); _rpcPauseTimer = null }
  _rpcClearedByPause = false
}

// Discord renders large_image by fetching the URL from its own servers, so it
// has to be reachable from the public internet. A Jellyfin on a LAN, a
// Tailscale address or any private host never is, and the https check this used
// to do could not tell the difference.
//
// It was also handing over a Jellyfin image URL, and those carry api_key, so
// the user's server token went to a third party and ended up baked into the
// proxied image URL that hangs off their presence. iTunes art is public,
// keyless, needs no reachable server, and the app already fetches it elsewhere
// through the same cache.
//
// A track iTunes has never heard of gets no image rather than a wrong one, and
// Discord falls back to the app icon. Same for video, which iTunes is not being
// asked about.
let _rpcArtToken = 0

async function updateDiscordPresence(item) {
  if (!discordEnabled || !item) return
  const video = isVideoItem(item)
  const activity = {
    details:        item.Name?.slice(0, 128) || 'Unknown Track',
    state:          (secondaryLine(item) || (video ? '' : 'Unknown Artist')).slice(0, 128),
    startTimestamp: rpcTrackStart,
    // Flips Discord from "Listening to Cascade" to "Watching Cascade". Read and
    // stripped in main.js - setActivity() would drop it.
    watching:       video,
  }

  // Push what we have first: the art lookup is a network round trip, and a
  // presence that appears immediately and gains a cover a moment later beats
  // one that shows up late.
  const token = ++_rpcArtToken
  window.cascade.discord.update(activity)
  if (video) return

  const artist = item.AlbumArtist || item.Artists?.[0] || ''
  const album  = item.Album || ''
  if (!artist && !album) return

  const art = await fetchItunesArt(artist, album)
  // The track can change while that is in flight, and a late answer for the
  // previous one would overwrite the presence that replaced it.
  if (!art || token !== _rpcArtToken || !discordEnabled) return
  activity.largeImageKey  = art
  activity.largeImageText = album.slice(0, 128)
  window.cascade.discord.update(activity)
}

const DEFAULT_DISCORD_CLIENT_ID = '1512373702522835004'
let _rpcConnected = false

async function initDiscordRpc() {
  const enabled  = await window.cascade.store.get('discordRpcEnabled')
  const clientId = await window.cascade.store.get('discordClientId') || DEFAULT_DISCORD_CLIENT_ID
  discordEnabled = enabled === 'true'
  if (discordEnabled) window.cascade.discord.connect(clientId)

  // Single listener - updates dot + label; tracks state for when settings view opens later
  window.cascade.discord.onStatus((connected) => {
    _rpcConnected = connected
    const dot   = document.getElementById('discord-rpc-dot')
    const label = document.getElementById('discord-rpc-status-label')
    if (dot)   dot.className   = 'ws-dot' + (connected ? ' connected' : '')
    if (label) label.textContent = connected ? 'Connected' : 'Not connected'
  })
}

// ── Search (persistent top bar, live dropdown) ─────────────────────────────────

let searchDebounce = null
const searchInput    = document.getElementById('search-input')
const searchDropdown = document.getElementById('search-results')

function closeSearchDropdown() { searchDropdown.classList.remove('open') }

document.getElementById('search-input').addEventListener('input', (e) => {
  const q = e.target.value.trim()
  document.getElementById('search-clear').style.display = q ? '' : 'none'
  clearTimeout(searchDebounce)
  if (!q) { closeSearchDropdown(); return }
  searchDropdown.classList.add('open')
  searchDebounce = setTimeout(() => runSearch(q), 300)
})

document.getElementById('search-clear').addEventListener('click', () => {
  document.getElementById('search-input').value = ''
  document.getElementById('search-clear').style.display = 'none'
  closeSearchDropdown()
  document.getElementById('search-input').focus()
})

// Re-open on refocus if there's already a query with results rendered
searchInput.addEventListener('focus', () => {
  if (searchInput.value.trim()) searchDropdown.classList.add('open')
})

// Dismiss on Escape, on an outside click, or once a result is actually acted on
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && searchDropdown.classList.contains('open')) {
    closeSearchDropdown()
    searchInput.blur()
  }
})
document.addEventListener('mousedown', (e) => {
  if (!e.target.closest('.top-search-bar')) closeSearchDropdown()
})
searchDropdown.addEventListener('click', closeSearchDropdown)
searchDropdown.addEventListener('dblclick', closeSearchDropdown)

// Global jump-to-search shortcut
document.addEventListener('keydown', (e) => {
  const mod = window.cascade.platform === 'darwin' ? e.metaKey : e.ctrlKey
  if (mod && e.key.toLowerCase() === 'k') {
    e.preventDefault()
    searchInput.focus()
    searchInput.select()
  }
})

async function runSearch(query) {
  const results = document.getElementById('search-results')
  results.innerHTML = '<div class="search-empty-state">Searching…</div>'
  try {
    // A music-only user has no movie/show libraries configured, so those
    // queries are skipped outright rather than fired and thrown away - same
    // rule Home's Recently Watched section follows.
    const movieLibIds = jf.movieLibraryIds || []
    const showLibIds  = jf.showLibraryIds  || []
    const wantMovies  = movieLibIds.length > 0
    const wantShows   = showLibIds.length  > 0

    const [songsRes, albumsRes, artistsRes, moviesRes, showsRes] = await Promise.allSettled([
      jfGetMerged(`/Users/${jf.userId}/Items`, { SearchTerm: query, Recursive: true, Limit: 10, IncludeItemTypes: 'Audio', Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag' }),
      jfGetMerged(`/Users/${jf.userId}/Items`, { SearchTerm: query, Recursive: true, Limit: 8,  IncludeItemTypes: 'MusicAlbum', Fields: 'PrimaryImageAspectRatio' }),
      jfGetMerged(`/Artists`,                  { SearchTerm: query, UserId: jf.userId, Limit: 8 }),
      wantMovies
        ? jfClient.getMerged(`/Users/${jf.userId}/Items`, { SearchTerm: query, Recursive: true, Limit: 8, IncludeItemTypes: 'Movie', Fields: 'PrimaryImageAspectRatio,ProductionYear' }, movieLibIds)
        : Promise.resolve({ Items: [] }),
      wantShows
        ? jfClient.getMerged(`/Users/${jf.userId}/Items`, { SearchTerm: query, Recursive: true, Limit: 8, IncludeItemTypes: 'Series', Fields: 'PrimaryImageAspectRatio,ProductionYear' }, showLibIds)
        : Promise.resolve({ Items: [] }),
    ])
    // jfGetMerged returns up to Limit x libraryCount - trim back to the intended size.
    // ponytail: concat-then-slice biases toward the first library when a term matches
    // in several. Interleave per library if that shows up in practice.
    const take = (res, n) =>
      ({ Items: (res.status === 'fulfilled' ? res.value.Items || [] : []).slice(0, n) })
    const songs   = take(songsRes, 10)
    const albums  = take(albumsRes, 8)
    const artists = take(artistsRes, 8)
    const movies  = take(moviesRes, 8)
    const shows   = take(showsRes, 8)

    const hasSongs   = songs.Items?.length
    const hasAlbums  = albums.Items?.length
    const hasArtists = artists.Items?.length
    const hasMovies  = movies.Items?.length
    const hasShows   = shows.Items?.length

    if (!hasSongs && !hasAlbums && !hasArtists && !hasMovies && !hasShows) {
      results.innerHTML = `<div class="search-no-results">No results for "${esc(query)}"</div>`
      return
    }

    let html = ''

    if (hasSongs) {
      html += `<div class="search-section">
        <div class="search-section-title">Songs</div>
        <div class="track-list">
          <div id="search-song-rows">${songs.Items.map((item, i) =>
            trackRowHtml(item, i, { idxAttr: 'data-search-song' })
          ).join('')}</div>
        </div>
      </div>`
    }

    if (hasAlbums) {
      html += `<div class="search-section">
        <div class="search-section-title">Albums</div>
        <div class="album-grid">${albums.Items.map(item => albumCard(item, { idAttr: 'data-search-album' })).join('')}</div>
      </div>`
    }

    if (hasArtists) {
      html += `<div class="search-section">
        <div class="search-section-title">Artists</div>
        <div class="artist-grid">${artists.Items.map(item =>
          artistCardHtml(item, { idAttr: 'data-search-artist' })
        ).join('')}</div>
      </div>`
    }

    if (hasMovies) {
      html += `<div class="search-section">
        <div class="search-section-title">Movies</div>
        <div class="poster-grid" id="search-movie-grid">${movies.Items.map(item =>
          posterCard(item, item.ProductionYear || '')
        ).join('')}</div>
      </div>`
    }

    if (hasShows) {
      html += `<div class="search-section">
        <div class="search-section-title">TV Shows</div>
        <div class="poster-grid" id="search-show-grid">${shows.Items.map(item =>
          posterCard(item, item.ProductionYear || '')
        ).join('')}</div>
      </div>`
    }

    results.innerHTML = html
    highlightPlayingRow()

    // Wire up song rows
    if (hasSongs) {
      results.querySelectorAll('[data-search-song]').forEach(el => {
        const idx = parseInt(el.dataset.searchSong)
        wireTrackRow(el, songs.Items[idx], songs.Items, idx, { clickToPlay: true })
      })
    }

    // Wire up album cards
    results.querySelectorAll('[data-search-album]').forEach(el => {
      el.addEventListener('click', () => { showView('albums'); openAlbum(el.dataset.searchAlbum) })
    })

    // Wire up artist cards - open artist detail view
    results.querySelectorAll('[data-search-artist]').forEach(el => {
      el.addEventListener('click', () => {
        showView('artists')
        openArtist(el.dataset.searchArtist, el.querySelector('.artist-name')?.textContent || '')
      })
    })

    // Wire up movie/show cards - same detail views Movies/TV browsing opens
    if (hasMovies) wirePosterCards(document.getElementById('search-movie-grid'), movies.Items,
      item => { showView('movies'); openMovie(item.Id) })
    if (hasShows) wirePosterCards(document.getElementById('search-show-grid'), shows.Items,
      item => { showView('shows'); openSeries(item.Id) })
  } catch (e) {
    results.innerHTML = `<div class="search-no-results">Search failed: ${esc(e.message)}</div>`
  }
}

// ── Theme system ──────────────────────────────────────────────────────────────

const THEME_PRESETS = [
  { label: 'Default',   start: '#4ade80', end: '#7c3aed' },
  { label: 'Sunset',    start: '#f97316', end: '#ec4899' },
  { label: 'Ocean',     start: '#06b6d4', end: '#3b82f6' },
  { label: 'Rose',      start: '#fb7185', end: '#e11d48' },
  { label: 'Gold',      start: '#fbbf24', end: '#f59e0b' },
  { label: 'Mint',      start: '#34d399', end: '#059669' },
  { label: 'Candy',     start: '#f472b6', end: '#818cf8' },
  { label: 'Fire',      start: '#ef4444', end: '#f97316' },
]

let themeAlbumArt = false
let _lastAlbumColors = null

function perceivedLuminance(hex) {
  const r = parseInt(hex.slice(1,3), 16)
  const g = parseInt(hex.slice(3,5), 16)
  const b = parseInt(hex.slice(5,7), 16)
  return 0.299 * r + 0.587 * g + 0.114 * b
}

function applyGradient(start, end) {
  const grad = `linear-gradient(160deg, ${start} 0%, ${end} 100%)`
  document.documentElement.style.setProperty('--grad', grad)
  document.documentElement.style.setProperty('--accent', end)
  document.documentElement.style.setProperty('--accent-glow', hexToRgba(end, 0.25))
  document.getElementById('theme-dot').style.background = grad
  // Switch play/pause icon to black on light gradients so it stays readable
  const fg = perceivedLuminance(end) > 160 ? '#111111' : 'white'
  document.documentElement.style.setProperty('--play-btn-fg', fg)
}

function hexToRgba(hex, alpha) {
  const r = parseInt(hex.slice(1,3),16), g = parseInt(hex.slice(3,5),16), b = parseInt(hex.slice(5,7),16)
  return `rgba(${r},${g},${b},${alpha})`
}

function setThemeMode(mode) {
  document.documentElement.setAttribute('data-theme', mode === 'light' ? 'light' : '')
  document.getElementById('seg-dark').classList.toggle('active', mode !== 'light')
  document.getElementById('seg-light').classList.toggle('active', mode === 'light')
  // Recolour the OS-drawn Windows/Linux caption buttons to match. No-op on
  // macOS (main.js checks platform), so this is safe to call unconditionally.
  window.cascade.setTitleBarOverlay(mode === 'light' ? 'light' : 'dark')
}

function buildPresets() {
  const container = document.getElementById('tp-presets')
  const saved = { start: document.getElementById('grad-start').value, end: document.getElementById('grad-end').value }
  container.innerHTML = THEME_PRESETS.map((p, i) =>
    `<div class="tp-preset" data-i="${i}" title="${p.label}"
      style="background:linear-gradient(135deg,${p.start},${p.end})"></div>`
  ).join('')
  container.querySelectorAll('.tp-preset').forEach(el => {
    el.addEventListener('click', () => {
      const p = THEME_PRESETS[parseInt(el.dataset.i)]
      document.getElementById('grad-start').value = p.start
      document.getElementById('grad-end').value = p.end
      applyGradient(p.start, p.end)
      markActivePreset()
      saveTheme()
    })
  })
  markActivePreset()
}

function markActivePreset() {
  const s = document.getElementById('grad-start').value
  const e = document.getElementById('grad-end').value
  document.querySelectorAll('.tp-preset').forEach((el, i) => {
    const p = THEME_PRESETS[i]
    el.classList.toggle('active', p.start === s && p.end === e)
  })
}

async function saveTheme() {
  await window.cascade.store.set('theme', JSON.stringify({
    mode: document.documentElement.getAttribute('data-theme') || 'dark',
    gradStart: document.getElementById('grad-start').value,
    gradEnd: document.getElementById('grad-end').value,
    albumArt: themeAlbumArt,
  }))
}

async function loadTheme() {
  try {
    const raw = await window.cascade.store.get('theme')
    if (!raw) return
    const t = JSON.parse(raw)
    if (t.mode === 'light') setThemeMode('light')
    if (t.gradStart && t.gradEnd) {
      document.getElementById('grad-start').value = t.gradStart
      document.getElementById('grad-end').value = t.gradEnd
      applyGradient(t.gradStart, t.gradEnd)
    }
    if (t.albumArt) {
      themeAlbumArt = true
      document.getElementById('toggle-album-art').checked = true
    }
  } catch {}
  buildPresets()
  updateAccentLock()
}

/** Album art accent mode overrides whatever gradient/preset is picked, so
 *  those controls do nothing while it's on - dim them and say why rather
 *  than leaving them clickable but inert. */
function updateAccentLock() {
  const locked = themeAlbumArt
  ;[document.querySelector('.tp-colors'), document.getElementById('tp-presets')].forEach(host => {
    if (!host) return
    host.classList.toggle('locked', locked)
    if (locked) host.setAttribute('data-tip', 'Album art accent overrides this')
    else host.removeAttribute('data-tip')
  })
}


function rgbToHex(r, g, b) {
  return '#' + [r,g,b].map(v => v.toString(16).padStart(2,'0')).join('')
}

// Extract top N hue-diverse colors from an image element.
// Reading the cover's pixels is the only part of this the browser has to do;
// the colour maths lives in core so the React Native app produces the same
// palette from the same cover (it decodes a PNG instead of drawing a canvas).
function extractTopColors(img, n = 3, light = false) {
  try {
    const canvas = document.createElement('canvas')
    canvas.width = canvas.height = 80
    const ctx = canvas.getContext('2d', { willReadFrequently: true })
    // Nearest-neighbour, not the default smooth scale. Smoothing blends
    // neighbouring pixels, so red beside blue produces purple that appears
    // nowhere in the artwork - and with only 6400 samples an invented colour
    // could win outright. Sampling real pixels can miss a very small detail;
    // inventing colours misreports the whole cover, which is worse.
    ctx.imageSmoothingEnabled = false
    ctx.drawImage(img, 0, 0, 80, 80)
    return CascadeCore.extractTopColors(ctx.getImageData(0, 0, 80, 80).data, n, light)
  } catch { return [] }
}

// Whichever base the now-playing overlay's blobs sit on. The light theme
// swaps the overlay to a near-white background (index.html), and a blob
// normalised to glow on black reads as a heavy, muddy stain on white instead -
// see the light-mode pair in album-colors.ts (toBlobColor, driftedBlobs).
// Both callers below go through this one function so they cannot disagree
// about which theme is active, the way the accent and the blobs once
// disagreed about which colour to use (2edb864).
function _isLightTheme() {
  return document.documentElement.getAttribute('data-theme') === 'light'
}
function _blobBaseColor() {
  return _isLightTheme() ? CascadeCore.BLOB_BASE_COLOR_LIGHT : CascadeCore.BLOB_BASE_COLOR
}

// The static placement, used before the drift loop takes over. Both go through
// the same core helpers now, so the two no longer disagree about blob size and
// falloff - which used to show as a visible jump the moment drift started.
function buildBlobBackground(colors, light = false) {
  return CascadeCore.blobBackgroundCss(CascadeCore.driftedBlobs(colors, [], 0, light))
}

// Saturation and hue of an RGB triple, HSL style. Only used to judge whether a
// palette colour is worth deriving an accent from, and which way to push it.
function _rgbHueSat(r, g, b) {
  const nr = r/255, ng = g/255, nb = b/255
  const mx = Math.max(nr,ng,nb), mn = Math.min(nr,ng,nb), d = mx - mn
  const l = (mx + mn) / 2
  const s = d === 0 ? 0 : d / (1 - Math.abs(2*l - 1))
  let h = 0
  if (d > 0) {
    if (mx === nr)      h = ((ng-nb)/d + (ng<nb?6:0))/6
    else if (mx === ng) h = ((nb-nr)/d + 2)/6
    else                h = ((nr-ng)/d + 4)/6
  }
  return { h, s, l }
}

function _hslToRgb(hue, s, l) {
  const c = (1-Math.abs(2*l-1))*s, x = c*(1-Math.abs((hue*6)%2-1)), m = l-c/2
  const idx = Math.floor(hue*6)%6
  const [r,g,b] = [[c,x,0],[x,c,0],[0,c,x],[0,x,c],[x,0,c],[c,0,x]][idx]
  return [Math.round((r+m)*255), Math.round((g+m)*255), Math.round((b+m)*255)]
}

// Below this there is no hue worth trusting: what is left is JPEG noise on
// essentially monochrome art, and normalising it would invent a colour that
// appears nowhere on the cover.
const NEUTRAL_ART_SAT = 0.18

function applyAlbumArtTheme(imgEl) {
  if (!themeAlbumArt || !imgEl) return

  const light = _isLightTheme()

  // One palette for the whole theme. The accent used to run a second, separate
  // extraction of its own, scored so heavily on saturation that a small vivid
  // detail beat the rest of the cover - so the player bar could go hot pink
  // off a shopfront while the overlay behind it, clustering the same artwork
  // in Oklab, settled on beige and green. Same cover, two answers. The blobs
  // decide now, and the accent follows them.
  _blobColors = extractTopColors(imgEl, 3, light)
  const top = _blobColors[0]
  const { h, s, l } = top ? _rgbHueSat(top.r, top.g, top.b) : { h: 0, s: 0, l: 0 }

  const overlay = document.getElementById('np-overlay')

  if (!top || s < NEUTRAL_ART_SAT) {
    // Monochrome or near enough. Grey blobs off the art's own lightness where
    // there is one, so a bright black-and-white cover does not get the same
    // treatment as a dark one, and a neutral gradient so the previous track's
    // colour does not bleed through.
    const lum = top ? Math.round(l * 255) : 70
    const gHi = Math.min(255, Math.round(lum * 1.2))
    const gLo = Math.max(0,   Math.round(lum * 0.6))
    _blobColors = [{ r: gHi, g: gHi, b: gHi, hue: 0 }, { r: gLo, g: gLo, b: gLo, hue: 0 }]
    applyGradient('#505050', '#202020')
    _lastAlbumColors = null
  } else {
    // Normalised to a fixed lightness and saturation so muted covers still
    // produce a gradient you can tell apart from the last one. The hue is the
    // palette's, so this only changes how loud it is, not which colour it is.
    const [sr,sg,sb] = _hslToRgb(h, 0.85, 0.62)   // bright vivid
    const [er,eg,eb] = _hslToRgb(h, 0.90, 0.36)   // dark vivid
    const startHex = rgbToHex(sr,sg,sb)
    const endHex   = rgbToHex(er,eg,eb)
    _lastAlbumColors = { start: startHex, end: endHex }
    applyGradient(startHex, endHex)
  }

  randomizeDrift()
  // Set gradient directly on the overlay - no z-index/clipping issues
  overlay.style.backgroundColor = _blobBaseColor()
  overlay.style.backgroundImage = buildBlobBackground(_blobColors, light)
  overlay.classList.add('art-theme')
}

function clearAlbumArtTheme() {
  const overlay = document.getElementById('np-overlay')
  overlay.classList.remove('art-theme')
  overlay.style.backgroundImage = ''
  overlay.style.backgroundColor = ''
  document.documentElement.style.removeProperty('--art-overlay-bg')
  _blobColors = []
  _driftParams = []
  const bgEl = document.getElementById('ov-bg-pulse')
  if (bgEl) { bgEl.style.opacity = '0' }
}

// Wire up theme picker UI
document.getElementById('theme-dot').addEventListener('click', (e) => {
  e.stopPropagation()
  document.getElementById('theme-picker').classList.toggle('open')
})
document.getElementById('tp-close').addEventListener('click', () => {
  document.getElementById('theme-picker').classList.remove('open')
})
document.addEventListener('mousedown', (e) => {
  const picker = document.getElementById('theme-picker')
  if (!picker.contains(e.target) && e.target.id !== 'theme-dot') {
    picker.classList.remove('open')
  }
})

document.getElementById('seg-dark').addEventListener('click', () => { setThemeMode('dark'); saveTheme() })
document.getElementById('seg-light').addEventListener('click', () => { setThemeMode('light'); saveTheme() })

document.getElementById('grad-start').addEventListener('input', () => {
  applyGradient(document.getElementById('grad-start').value, document.getElementById('grad-end').value)
  markActivePreset()
  saveTheme()
})
document.getElementById('grad-end').addEventListener('input', () => {
  applyGradient(document.getElementById('grad-start').value, document.getElementById('grad-end').value)
  markActivePreset()
  saveTheme()
})

/** The one code path for turning album art accent on/off - the theme popover's
 *  toggle and the first-run wizard both call this instead of duplicating the
 *  immediate-apply/restore logic. */
function setAlbumArtAccent(enabled) {
  themeAlbumArt = enabled
  document.getElementById('toggle-album-art').checked = enabled
  updateAccentLock()
  // The same switch drives ambient mode during a film - see refreshAmbient().
  refreshAmbient()
  if (themeAlbumArt) {
    // Apply immediately from current art
    const img = document.querySelector('#ov-art img') || document.querySelector('#np-art img')
    if (img?.complete) applyAlbumArtTheme(img)
  } else {
    // Restore manual gradient and clear overlay tint
    clearAlbumArtTheme()
    applyGradient(document.getElementById('grad-start').value, document.getElementById('grad-end').value)
  }
  saveTheme()
}

document.getElementById('toggle-album-art').addEventListener('change', (e) => {
  setAlbumArtAccent(e.target.checked)
})

// ── Utility ───────────────────────────────────────────────────────────────────

function esc(str) {
  return String(str || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')
}

// ── Debug panel ──────────────────────────────────────────────────────────────
// Entirely behind window.cascade.isDebugMode() (main.js: a `.cascade-debug`
// sentinel file's mere presence, checked once at startup). Nothing below runs,
// no DOM gets built and no interval gets started unless that resolved true -
// there is no settings toggle for this and no keyboard shortcut, on purpose.
// Plain monospace text over any real styling: this is a diagnostic, not a
// feature, and the less of it there is to maintain the better.
// ── Undecodable audio codec detection ────────────────────────────────────────
//
// Answers "the movie plays but has no sound" without guessing. canPlayType is
// a claim from a codec registry, not from a decoder that has run, and when it
// is wrong the failure is completely silent: the container demuxes, the
// picture plays, and the audio decoder produces nothing.
//
// webkitAudioDecodedByteCount is the measurement, NOT the analyser's level. A
// quiet scene, a silent studio logo and a broken decoder all read as zero
// level, but only a broken decoder has decoded zero BYTES while the clock ran.
// That distinction is the whole reason this can act automatically instead of
// asking. Where the property is missing the check simply does not run, because
// a false positive here would transcode files that were playing perfectly.

const AUDIO_DECODE_GRACE_MS = 6000

let _audioDecodeTimer = null

function _cancelAudioDecodeCheck() {
  if (_audioDecodeTimer) { clearTimeout(_audioDecodeTimer); _audioDecodeTimer = null }
}

/** Arm the check for a video that is direct playing. Music is untouched: it is
 *  single stream and the server picked its codec against this same list. */
function _armAudioDecodeCheck(item) {
  _cancelAudioDecodeCheck()
  if (!item || !isVideoItem(item)) return
  if (_playMethod && String(_playMethod).toLowerCase().includes('transcode')) return
  if (audio.webkitAudioDecodedByteCount === undefined) return

  const deck = audio
  const startedAt = deck.currentTime
  const itemId = item.Id
  _audioDecodeTimer = setTimeout(() => {
    _audioDecodeTimer = null
    if (deck !== audio || queue[queueIndex]?.Id !== itemId) return
    if (deck.paused || deck.seeking) return
    // The clock has to have actually run, or this is a stall rather than a
    // decode failure - the exact confusion that once latched the visualiser off
    // for a whole session.
    if (deck.currentTime - startedAt < 2) return
    if ((deck.webkitAudioDecodedByteCount || 0) > 0) return
    _handleUndecodableAudio(item)
  }, AUDIO_DECODE_GRACE_MS)
}

async function _handleUndecodableAudio(item) {
  const track = _audioStreamIndex != null
    ? item.MediaStreams?.find(s => s.Index === _audioStreamIndex)
    : item.MediaStreams?.find(s => s.Type === 'Audio')
  const codec = (track?.Codec || '').toLowerCase()
  if (!codec || _undecodableAudioCodecs.has(codec)) return

  _undecodableAudioCodecs.add(codec)
  try {
    await window.cascade.store.set('undecodableAudioCodecs', JSON.stringify([..._undecodableAudioCodecs]))
  } catch {}
  console.warn(`[cascade] ${codec} was claimed decodable but produced no audio - withdrawing the claim and asking the server to transcode it`)
  showToast(`No audio from ${codec.toUpperCase()} on this machine - switching to a transcode`)

  // Re-negotiate from where they are, not from the top.
  const at = mediaPosition()
  playCurrentTrack({ startTicks: Math.round(at * 10_000_000) })
}

/** Restored at startup so the second launch does not have to rediscover it. */
async function _loadUndecodableAudioCodecs() {
  try {
    const raw = await window.cascade.store.get('undecodableAudioCodecs')
    const list = raw ? JSON.parse(raw) : []
    if (Array.isArray(list)) _undecodableAudioCodecs = new Set(list.filter(c => typeof c === 'string'))
  } catch {}
}
_loadUndecodableAudioCodecs()

onDeck('playing', () => _armAudioDecodeCheck(queue[queueIndex]))
onDeck('pause', _cancelAudioDecodeCheck)
onDeck('emptied', _cancelAudioDecodeCheck)

/**
 * Peak level the analyser is seeing RIGHT NOW, 0-255, or null if there is no
 * graph to read.
 *
 * The decisive measurement for "this file plays but I hear nothing". The tap
 * sits after the decoder, so a non-zero peak proves the decoder produced
 * samples and the problem is downstream (routing, gain, the OS). A flat zero
 * while the clock is advancing proves the opposite: the container demuxed, the
 * video plays, and the audio decoder handed over nothing at all, which is what
 * an undecodable codec looks like from here.
 *
 * _eqEverHadSignal cannot answer this. It is sticky and session-wide, so a
 * music track played earlier leaves it true for the rest of the session, silent
 * movie included.
 */
function debugLivePeak() {
  if (!_eqAnalyser || !_eqFreqData) return null
  _eqAnalyser.getByteFrequencyData(_eqFreqData)
  let peak = 0
  for (let i = 0; i < _eqFreqData.length; i++) if (_eqFreqData[i] > peak) peak = _eqFreqData[i]
  return peak
}

/** Every audio track on the item, with whether this build claims to decode it.
 *  Silence with several tracks listed is a different bug from silence with one
 *  undecodable track, and the two are indistinguishable without the list. */
function debugAudioTracks(item) {
  const tracks = (item?.MediaStreams || []).filter(s => s.Type === 'Audio')
  if (!tracks.length) return ['  (none listed - MediaStreams was not fetched for this item)']
  const decodable = new Set(decodableVideoAudioCodecs().map(c => c.toLowerCase()))
  return tracks.map(t => {
    const claimed = decodable.has((t.Codec || '').toLowerCase())
    const marks = [
      t.IsDefault ? 'default' : null,
      t.Index === _audioStreamIndex ? 'SELECTED' : null,
      claimed ? 'we claim decodable' : 'WE CANNOT DECODE',
    ].filter(Boolean)
    return `  [${t.Index}] ${t.Codec || '?'} ${t.Channels || '?'}ch ${t.Language || ''} - ${marks.join(', ')}`
  })
}

function debugPanelText() {
  const item = queue[queueIndex] || null
  const src = item?.MediaSources?.[0] || null
  const videoStream = item?.MediaStreams?.find(s => s.Type === 'Video')
  const audioStream = _audioStreamIndex != null
    ? item?.MediaStreams?.find(s => s.Index === _audioStreamIndex)
    : item?.MediaStreams?.find(s => s.Type === 'Audio')
  const p = _lastPrefetchOutcome
  // readyState is only recorded on a crossfade hit, and it is the interesting
  // part: a HIT at readyState under 4 had the right track but had not buffered
  // it, which behaves like a miss and is the leading suspect for the
  // intermittent stutter. 4 = HAVE_ENOUGH_DATA.
  const prefetchLine = p
    ? `${p.hit ? 'HIT' : 'MISS'}${p.readyState !== undefined ? ` rs=${p.readyState}${p.readyState < 4 ? ' COLD' : ''}` : ''} (${p.from}, ${Math.round((Date.now() - p.at) / 1000)}s ago)`
    : 'none yet'

  return [
    `playing: ${!audio.paused}   live deck: ${audio.id}   pos: ${audio.currentTime.toFixed(1)}s / ${mediaDuration().toFixed(1)}s`,
    `item: ${item ? `${item.Name}  (${item.Id})` : 'none'}`,
    '',
    '── stream ──',
    `playMethod: ${_playMethod}   container: ${src?.Container ?? '?'}`,
    `video codec: ${videoStream?.Codec ?? '-'}   audio codec: ${audioStream?.Codec ?? '-'}`,
    `audioStreamIndex: ${_audioStreamIndex ?? '(server default)'}`,
    `mediaSourceId: ${_mediaSourceId ?? '-'}`,
    `playSessionId: ${_playSessionId ?? '-'}`,
    `url: ${audio.currentSrc || audio.src || '-'}`,
    '',
    '── crossfade / prefetch ──',
    `active: ${_cfActive}   armed: ${_cfArmed}   session: ${_cfSession}`,
    `prefetched next: ${_streamPrefetch ? _streamPrefetch.itemId : 'none'}`,
    `last prefetch: ${prefetchLine}`,
    '',
    '── audio diagnosis ──',
    `live peak: ${(() => { const pk = debugLivePeak(); return pk === null ? 'no graph' : `${pk}${pk === 0 && !audio.paused ? '  <- DECODER PRODUCED NOTHING' : ''}` })()}`,
    `element volume: ${audio.volume.toFixed(2)}   muted: ${audio.muted}`,
    `profile claims decodable: ${decodableVideoAudioCodecs().join(',')}`,
    `withdrawn at runtime: ${[..._undecodableAudioCodecs].join(',') || 'none'}`,
    `decoded audio bytes: ${audio.webkitAudioDecodedByteCount ?? 'n/a'}`,
    'audio tracks on this item:',
    ...debugAudioTracks(item),
    '',
    '── web audio / eq ──',
    `graph failed: ${_eqGraphFailed}   no signal: ${_eqNoSignal}   ever had signal: ${_eqEverHadSignal}`,
    '',
    `CascadeSLRC plugin absent: ${_cascadePluginAbsent}`,
  ].join('\n')
}

function initDebugPanel() {
  const el = document.createElement('pre')
  el.id = 'cascade-debug-panel'
  el.style.cssText = 'position:fixed;left:8px;bottom:8px;z-index:9999;'
    + 'max-width:44vw;max-height:56vh;overflow:auto;margin:0;padding:8px 10px;'
    + 'border-radius:6px;background:rgba(0,0,0,0.82);color:#7CFC7C;'
    + 'font:11px/1.5 ui-monospace,Menlo,Consolas,monospace;white-space:pre-wrap;'
    + 'word-break:break-all;user-select:text;cursor:pointer;'
  el.title = 'Cascade debug panel - click to collapse, Shift-click to copy. Force CascadeSLRC absent: Alt-click.'

  let collapsed = false
  function render() {
    if (collapsed) { el.textContent = '[cascade debug - click to expand]'; return }
    el.textContent = debugPanelText()
  }
  el.addEventListener('click', (e) => {
    if (window.getSelection()?.toString()) return   // selecting text to copy, not toggling
    if (e.shiftKey) {
      // Selecting eleven lines of wrapped monospace by hand to report a bug is
      // miserable, and this text exists to be pasted somewhere.
      window.cascade.clipboard.write(debugPanelText())
      showToast('Debug info copied')
      return
    }
    if (e.altKey) {
      // The one internal flag worth flipping by hand that has no real Settings
      // UI of its own - lets a working plugin's greyed-out state be previewed
      // without a second server to test against. Everything else worth toggling
      // (crossfade, album art theming, ...) already has a real control in
      // Settings; duplicating those here would just be two sources of truth.
      _cascadePluginAbsent = !_cascadePluginAbsent
      _applyCascadePluginAvailability()
    } else {
      collapsed = !collapsed
    }
    render()
  })

  document.body.appendChild(el)
  render()
  setInterval(render, 1000)
}

// ── Light-mode blob tuning (debug only) ─────────────────────────────────────
// Live knobs for the now-playing overlay's light-theme blobs and scrims, so
// tuning "washed out" is a slider drag instead of a rebuild-and-squint loop.
// Two different plumbing paths, both live with no rebuild:
//   - blob alpha/lightness: CascadeCore.lightTuning, a mutable runtime copy of
//     album-colors.ts's LIGHT_ALPHA_SCALE/MIN_L_LIGHT/MAX_L_LIGHT constants.
//     The alpha scale is read every drift frame, so it updates within a beat.
//     Lightness only applies at extraction, so its slider forces a reapply.
//   - scrims and blend mode: CSS custom properties (--np-blend, --np-scrim-*)
//     that index.html's light-theme rules already read with a fallback equal
//     to the shipped value - setting them here overrides nothing when this
//     panel does not exist.
function _debugReapplyBlobs() {
  if (!themeAlbumArt) return
  const img = document.querySelector('#ov-art img') || document.querySelector('#np-art img')
  if (img?.complete) applyAlbumArtTheme(img)
}

function initLightTuningPanel() {
  const root = document.documentElement
  const cssVar = (name, fallback) =>
    parseFloat(getComputedStyle(root).getPropertyValue(name)) || fallback

  const defs = [
    { key: 'alphaScale', label: 'Blob alpha scale', min: 0, max: 1, step: 0.01,
      get: () => CascadeCore.lightTuning.alphaScale,
      set: v => { CascadeCore.lightTuning.alphaScale = v } },
    { key: 'minL', label: 'Blob min lightness', min: 0, max: 1, step: 0.01,
      get: () => CascadeCore.lightTuning.minL,
      set: v => { CascadeCore.lightTuning.minL = v; _debugReapplyBlobs() } },
    { key: 'maxL', label: 'Blob max lightness', min: 0, max: 1, step: 0.01,
      get: () => CascadeCore.lightTuning.maxL,
      set: v => { CascadeCore.lightTuning.maxL = v; _debugReapplyBlobs() } },
    { key: 'scrimLeft', label: 'Left scrim opacity', min: 0, max: 1, step: 0.01,
      get: () => cssVar('--np-scrim-left', 0.35),
      set: v => root.style.setProperty('--np-scrim-left', v) },
    { key: 'scrimRight', label: 'Right scrim opacity', min: 0, max: 1, step: 0.01,
      get: () => cssVar('--np-scrim-right', 0.16),
      set: v => root.style.setProperty('--np-scrim-right', v) },
    { key: 'scrimHeader', label: 'Header scrim opacity', min: 0, max: 1, step: 0.01,
      get: () => cssVar('--np-scrim-header', 0.4),
      set: v => root.style.setProperty('--np-scrim-header', v) },
  ]

  const panel = document.createElement('div')
  panel.id = 'cascade-debug-light-tuning'
  panel.style.cssText = 'position:fixed;right:8px;bottom:8px;z-index:9999;'
    + 'width:270px;padding:8px 10px;border-radius:6px;background:rgba(0,0,0,0.82);'
    + 'color:#7CFC7C;font:11px/1.5 ui-monospace,Menlo,Consolas,monospace;user-select:text;'
  panel.innerHTML = '<div style="margin-bottom:6px;opacity:0.7">Light-mode blob tuning (debug)</div>'

  const rows = {}
  for (const d of defs) {
    const row = document.createElement('div')
    row.style.cssText = 'display:flex;align-items:center;gap:6px;margin:4px 0;'
    const label = document.createElement('span')
    label.style.cssText = 'flex:1 1 auto;'
    label.textContent = d.label
    const input = document.createElement('input')
    input.type = 'range'
    input.min = String(d.min); input.max = String(d.max); input.step = String(d.step)
    input.value = String(d.get())
    input.style.cssText = 'flex:1 1 auto;width:90px;'
    const val = document.createElement('span')
    val.style.cssText = 'width:38px;text-align:right;'
    val.textContent = Number(input.value).toFixed(2)
    input.addEventListener('input', () => {
      const v = parseFloat(input.value)
      d.set(v)
      val.textContent = v.toFixed(2)
    })
    row.append(label, input, val)
    panel.appendChild(row)
    rows[d.key] = input
  }

  const blendRow = document.createElement('label')
  blendRow.style.cssText = 'display:flex;align-items:center;gap:6px;margin:6px 0;cursor:pointer;'
  const blendCheck = document.createElement('input')
  blendCheck.type = 'checkbox'
  blendCheck.checked = (getComputedStyle(root).getPropertyValue('--np-blend').trim() || 'multiply') !== 'normal'
  blendCheck.addEventListener('change', () => {
    root.style.setProperty('--np-blend', blendCheck.checked ? 'multiply' : 'normal')
  })
  blendRow.append(blendCheck, document.createTextNode('multiply blend mode'))
  panel.appendChild(blendRow)

  const copyBtn = document.createElement('button')
  copyBtn.textContent = 'Copy current values'
  copyBtn.style.cssText = 'margin-top:4px;width:100%;padding:4px;border-radius:4px;'
    + 'border:1px solid #7CFC7C;background:transparent;color:#7CFC7C;cursor:pointer;font:inherit;'
  copyBtn.addEventListener('click', () => {
    const lines = defs.map(d => `${d.label} = ${parseFloat(rows[d.key].value).toFixed(2)}`)
    lines.push(`multiply blend mode = ${blendCheck.checked}`)
    window.cascade.clipboard.write(lines.join('\n'))
    showToast('Tuning values copied')
  })
  panel.appendChild(copyBtn)

  document.body.appendChild(panel)
}

window.cascade.isDebugMode().then(on => { if (on) { initDebugPanel(); initLightTuningPanel() } })

init()
