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
let queueSource = null   // what the queue was started from, for "Up Next, from ..."; see playItems
let queueIndex = -1
let shuffle = false
let repeatMode = 'none' // 'none' | 'all' | 'one'
let _unshuffledQueue = []   // original order saved when shuffle is enabled
let _restoredResume = null   // { sec } while a restored queue's track waits for play (see Last queue)
// Offline downloads (see the section of that name). Declared up here because
// artUrl() and resolveTrackStream() read it from the very first render.
// In Local mode it is the folder's summary instead (section "Local mode"), in
// the same shape, with `artBase` naming where its covers are served.
let _offline = { ready: {}, art: new Set(), artBase: 'cascade-offline://local/art/', collections: [], totalBytes: 0, active: [], failed: {}, plays: 0, playsHeld: false, changes: 0, limitBytes: null }
/** Offline Mode: 'online', 'manual' (the Settings switch) or 'unreachable'
 *  (turned on by itself). See the section "Offline Mode" and
 *  src/core/offline-mode.ts. 'local' is Local mode, a folder on this computer
 *  instead of a server (section "Local mode"). */
/** @type {'online' | 'manual' | 'unreachable' | 'local'} */
let _offlineState = 'online'
/** Live bytes per track being downloaded, from the main process's progress events. */
const _offlineProgress = new Map()

// Queue panel virtualisation
const QUEUE_WIN      = 20   // minimum rows kept in DOM at once; see _queueWin()
const QUEUE_ROW_H    = 53   // px per row - .queue-row pins this exact height in CSS
const QUEUE_BEFORE   = 5    // rows to show before current track when re-centering
let _queueWinStart   = 0    // index of first rendered row
let _queueScrollBound = false
let volume = 1.0
let crossfadeEnabled = false
let crossfadeSeconds = 6
// Lyric translation, restored from the store in init(). Two switches on purpose:
// lyricsTranslationEnabled is whether the feature exists at all (Settings and
// the wizard, default on); lyricsTranslateOn is whether translations are showing
// right now (the Translate button, remembered across songs, default off).
let lyricsTranslationEnabled = true
let lyricsTranslateOn = false
// Apple's built-in translation instead of Mozilla's models, on a Mac that can
// use it (macOS 26+): on by default there. _appleTranslationSupported is filled
// in by init() and stays false on every other platform. _appleMozillaChosen
// holds the languages the user picked Cascade's model for from the install
// prompt.
let appleTranslationEnabled = true
let _appleTranslationSupported = false
const _appleMozillaChosen = new Set()
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

// Off by default: a loudness-evening feature shipping in an update should not
// silently change how an existing library sounds the moment someone updates.
// It is opt-in, same reasoning as crossfade above.
let normalizationEnabled = false
// 'track' evens out each song; 'album' keeps a record's own dynamics and
// evens out between records instead. Track is the finer-grained, more common
// choice - offered as an option because it is free (same lookup, different id).
let normalizationSource = 'track'
async function setNormalizationEnabled(enabled) {
  normalizationEnabled = enabled
  await window.cascade.store.set('normalizationEnabled', normalizationEnabled)
  _reapplyNormalizationToLiveDecks()
}
async function setNormalizationSource(source) {
  // Stored/UI value is untrusted - anything else falls back to 'track'.
  normalizationSource = source === 'album' ? 'album' : 'track'
  await window.cascade.store.set('normalizationSource', normalizationSource)
  _normGainCache.clear()   // stale either way once the source changes; cheap to refetch
  _reapplyNormalizationToLiveDecks()
}

// 'default' means the system's own default output, same as never having
// called setSinkId at all - not a real device id, so it is never looked up
// against the enumerated list, only ever compared against by name.
let outputDeviceId = 'default'
async function setOutputDeviceId(deviceId) {
  outputDeviceId = typeof deviceId === 'string' && deviceId ? deviceId : 'default'
  await window.cascade.store.set('outputDeviceId', outputDeviceId)
  await _applyOutputDevice()
}

let eqEnabled = false
let eqActiveMode = 'music'   // which saved profile is wired into the live graph right now
let eqMusicProfile = { preamp: null, bands: [0, 0, 0, 0, 0] }
let eqVideoProfile = { preamp: null, bands: [0, 0, 0, 0, 0] }   // all overridden from the store in init()

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

// Volume and mute are the same on BOTH decks at all times - the crossfade
// envelope lives entirely in Web Audio gain nodes (see _ensureEqGraph), never
// on the element, so whichever deck becomes current next already has the
// right level with nothing left to sync. Once the graph is up, volume is
// _masterGain, after the analyser, and the elements stay at 1: an element's
// volume is applied before the tap, so the playing-row bars shrank with the
// volume knob. Without a graph (it failed to build) the elements carry it.
// volumechange is fired by hand so its listeners still hear about a change.
// Mute goes the same way, so muted playback still has real bars; read it
// from _muted, not audio.muted.
let _masterGain = null
let _muted = false
function setDeckVolume(v) {
  if (_masterGain) {
    _masterGain.gain.value = _muted ? 0 : v
    DECKS.forEach(d => { d.volume = 1; d.muted = false })
    audio.dispatchEvent(new Event('volumechange'))
  } else {
    DECKS.forEach(d => { d.volume = v; d.muted = _muted })
  }
}
function setDeckMuted(m) {
  _muted = m
  setDeckVolume(volume)
}

/**
 * Sets playback volume to `ratio` (0..1) and keeps everything that depends on it
 * in step: both decks, both volume bars' fill and aria-valuenow (they mirror each
 * other), and the persisted setting. Every volume-changing input - drag, keyboard,
 * the remote-control API, and the saved-value restore on launch - goes through
 * this so none of them can drift from the others.
 *
 * `sourceBar`, when given, is the bar the user is actively working (dragging or
 * has focused via keyboard) - the one whose tooltip should live-update. Both
 * bars always get the refreshed data-tip text either way, so a later plain
 * hover on the other one shows the current value too.
 */
function setVolumeRatio(ratio, sourceBar) {
  ratio = Math.max(0, Math.min(1, ratio))
  volume = ratio
  setDeckVolume(ratio)
  const pct = `${ratio * 100}%`
  document.getElementById('vol-fill').style.width = pct
  document.getElementById('ov-vol-fill').style.width = pct
  const now = String(Math.round(ratio * 100))
  const volBar = document.getElementById('vol-bar')
  const ovVolBar = document.getElementById('ov-vol-bar')
  volBar.setAttribute('aria-valuenow', now)
  ovVolBar.setAttribute('aria-valuenow', now)
  const tip = `Volume ${now}%`
  volBar.setAttribute('data-tip', tip)
  ovVolBar.setAttribute('data-tip', tip)
  if (sourceBar && (sourceBar.classList.contains('dragging') || document.activeElement === sourceBar)) {
    _positionTooltip(sourceBar)
  }
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

// A button clicked with the mouse keeps focus, and the next key pressed for
// any reason makes Chromium draw its keyboard focus ring around it (an orange
// box, before base.css gave it the accent). It also meant Space re-pressed
// whatever was clicked last. So a pointer click lets go of focus; detail is 0
// for a click made with Enter or Space, which keeps focus where keyboard
// navigation put it.
document.addEventListener('click', (e) => {
  if (e.detail === 0) return
  const control = e.target instanceof Element && e.target.closest('button, [role="button"], [role="tab"], [role="slider"]')
  if (control && control === document.activeElement) control.blur()
})

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
  sortSongs, songSortValue, shuffleInPlace, nextQueueIndex,
  resolveStream, universalStreamUrl, withStartTicks, stopActiveEncoding,
  buildElectronProfile, DEFAULT_MAX_BITRATE,
  resumeTicks, neededAudioStreamIndex,
  entryIdOf, removeSelected, moveSelectedToTop, moveSelectedToBottom,
  onePerSeries,
} = CascadeCore

// Passed as a getter, not as `jf` itself: connect() replaces the whole object,
// and a captured reference would keep serving stale credentials.
const jfClient = new CascadeCore.JellyfinClient(() => jf)

// ── Helpers ───────────────────────────────────────────────────────────────────

function fmtTime(sec) {
  if (!sec || isNaN(sec)) return '0:00'
  // Hours only once there are any: a film read "143:21" without them.
  const h = Math.floor(sec / 3600)
  const m = Math.floor((sec % 3600) / 60)
  const s = Math.floor(sec % 60).toString().padStart(2, '0')
  return h ? `${h}:${m.toString().padStart(2, '0')}:${s}` : `${m}:${s}`
}

function greeting() {
  const h = new Date().getHours()
  if (h < 12) return 'Good morning'
  if (h < 18) return 'Good afternoon'
  return 'Good evening'
}

// A downloaded album's cover comes from disk (cascade-offline://), so it still
// shows with no server and loads without a round trip with one. Local mode's
// covers come from disk too (cascade-local://).
// Offline, art not on disk is a placeholder rather than a request.
const artUrl       = (itemId, tag) => (_offline.art.has(itemId) ? `${_offline.artBase || 'cascade-offline://local/art/'}${itemId}.jpg` : null) || (jfClient.offline ? null : jfClient.artUrl(itemId, tag))
// Local mode keeps no artist pictures: an empty src fails at once into the
// callers' onerror fallback, where a server URL would point at file://.
const artistArtUrl = (itemId)      => isLocalMode() ? '' : jfClient.artistArtUrl(itemId)

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

// Apple's *search* index does not contain every album Apple *sells*. Panic! At
// The Disco's "A Fever You Can't Sweat Out" is the reproducible case: searching
// for it by artist+album, by album alone, or with attribute=artistTerm returns
// three unrelated records and never the album, yet the album is right there in
// the catalogue under collectionId 80456435. Only /lookup on the artist id
// finds it.
//
// So when the search comes back with nothing that matches, ask for the artist's
// whole discography instead and match against that. Two extra requests, but
// only on a miss, and the answer is cached per artist - so an album playthrough
// pays for it once and every later track by that artist is free.
const _ITUNES_DISCOG_CACHE_MAX = 100
const _itunesDiscogCache = new Map()

async function fetchItunesDiscography(artist) {
  const key = artist.toLowerCase()
  if (_itunesDiscogCache.has(key)) {
    const v = _itunesDiscogCache.get(key)
    _itunesDiscogCache.delete(key)
    _itunesDiscogCache.set(key, v)  // most-recently-used
    return v
  }
  if (_itunesDiscogCache.size >= _ITUNES_DISCOG_CACHE_MAX) {
    _itunesDiscogCache.delete(_itunesDiscogCache.keys().next().value)
  }
  const inFlight = (async () => {
    try {
      const a = await webFetch(
        `https://itunes.apple.com/search?term=${encodeURIComponent(artist)}&entity=musicArtist&limit=1`,
        { signal: AbortSignal.timeout(7000) }
      )
      if (!a.ok) { _itunesDiscogCache.delete(key); return [] }
      const hit = (await a.json()).results?.[0]
      // A wrong artist here would hand back a whole wrong discography for
      // pickItunesArt to match titles against, which is exactly how you get a
      // confident wrong cover.
      if (!hit?.artistId || !CascadeCore.itunesArtistMatches(hit.artistName || '', artist)) return []
      const r = await webFetch(
        `https://itunes.apple.com/lookup?id=${hit.artistId}&entity=album&limit=200`,
        { signal: AbortSignal.timeout(7000) }
      )
      if (!r.ok) { _itunesDiscogCache.delete(key); return [] }
      // Keep only the four fields the matcher reads - the full records are ~200
      // per artist and the rest of each one is pricing and genre metadata.
      const albums = ((await r.json()).results || [])
        .filter(x => x.wrapperType === 'collection' && x.artworkUrl100)
        .map(({ collectionName, collectionArtistName, artistName, artworkUrl100 }) =>
          ({ collectionName, collectionArtistName, artistName, artworkUrl100 }))
      _itunesDiscogCache.set(key, albums)
      return albums
    } catch {
      _itunesDiscogCache.delete(key)
      return []
    }
  })()
  _itunesDiscogCache.set(key, inFlight)
  return inFlight
}

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
      const r = await webFetch(
        `https://itunes.apple.com/search?term=${term}&entity=album&limit=15&media=music`,
        { signal: AbortSignal.timeout(7000) }
      )
      // Unauthenticated iTunes search allows roughly 20 requests a minute, which
      // a shuffle through an unfamiliar library will trip. A 403 is not an
      // answer about the album, so it must not be remembered as one: drop the
      // entry and let the next play ask again. Same for a timeout or a blip.
      if (!r.ok) { _itunesArtCache.delete(key); return null }
      const d = await r.json()
      // Not results[0] - see CascadeCore.pickItunesArt. The search is fuzzy, and
      // the top hit for a common album title is often a tribute record, a
      // karaoke version or somebody else's single.
      let url = CascadeCore.pickItunesArt(d.results, artist, album)
      // Nothing matched, so the search index may simply not have the album.
      // See fetchItunesDiscography.
      if (!url && artist && album) {
        url = CascadeCore.pickItunesArt(await fetchItunesDiscography(artist), artist, album)
      }
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

// Tracks the best available art URL for the current track
// (animated local cover > iTunes > Jellyfin still)
let _currentHighResArtUrl = null

// Set to the item id whose library cover turned out to be animated. The iTunes
// upgrade resolves independently and would otherwise overwrite a moving cover
// with a still, and the two race - so whichever lands first, this decides.
let _animatedArtItemId = null

// Jellyfin re-encodes whenever a size is requested, which flattens an animated
// cover to its first frame. So the now-playing view asks for the untransformed
// original, but only when the stored file is a format that can actually move -
// otherwise every track would be pulling an unbounded full-size image for no
// gain. Grids are untouched on purpose: dozens of animated tiles decoding at
// once is not a feature.
//
// One HEAD per album, cached, so an album playthrough pays for it once.
const _ANIMATED_ART_CACHE_MAX = 200
const _animatedArtCache = new Map()

// async, and load-bearing so: the cache holds the in-flight promise first and
// then overwrites it with the resolved value, so a hit returns a bare null or a
// bare URL string. Callers use .then(), which threw on every lookup after an
// album's first - and since that throw escaped updateNowPlaying uncaught, it
// took the whole tail of it with it: the track name and artist, the mediaSession
// metadata, and the Discord presence push all stopped running.
/** Puts a still cover in the player bar's or overlay's art, keeping a video
 *  cover (pluginCoverVideoUrl) that is over it when it is the playing album's. */
function _setArtStill(host, url) {
  if (!host) return
  const video = host.querySelector('.art-video')
  // More than one after a skip mid-crossfade (trailArtSlice), kept in order.
  const slices = host.querySelectorAll('.art-slice')
  host.innerHTML = url ? `<img src="${url}" alt="" onerror="this.innerHTML='♪'">` : '♪'
  const cur = queue[queueIndex]
  if (video && cur && video.dataset.album === (cur.AlbumId || cur.Id)) host.appendChild(video)
  host.append(...slices)
}

// Video covers from Cascade Server (the `animated-art` capability): the
// album's cover.mp4, or one from TIDAL. Album id -> playable URL or null.
const _coverVideoCache = new Map()
async function pluginCoverVideoUrl(albumId, stillWanted = () => true) {
  if (!albumId || !displayPrefs.videoCovers || !_cascadePluginCaps.has('animated-art')) return null
  if (_coverVideoCache.has(albumId)) return _coverVideoCache.get(albumId)
  // "pending" is TIDAL still being asked, or its video still downloading (a
  // second or so): ask again a few times while the album is still showing.
  for (let attempt = 0; attempt < 6; attempt++) {
    if (attempt) { await new Promise(r => setTimeout(r, 3000)); if (!stillWanted()) return null }
    try {
      const r = await jfFetch(`${jf.url}/CascadeServer/AnimatedArt/${encodeURIComponent(albumId)}`, {
        headers: CascadeCore.authHeaders(jf), signal: AbortSignal.timeout(8000),
      })
      const info = r.ok ? await r.json() : null
      // A video element sends no headers, so the key goes in the query (the
      // plugin's /File route accepts it).
      const url = info?.source && typeof info.url === 'string' && info.url.startsWith('/')
        ? `${jf.url}${info.url}?ApiKey=${encodeURIComponent(jf.token)}` : null
      if (info?.pending) continue
      _coverVideoCache.set(albumId, url)
      if (_coverVideoCache.size > 200) _coverVideoCache.delete(_coverVideoCache.keys().next().value)
      return url
    } catch {
      return null
    }
  }
  return null
}

async function animatedArtUrl(artItemId) {
  if (_animatedArtCache.has(artItemId)) {
    const v = _animatedArtCache.get(artItemId)
    _animatedArtCache.delete(artItemId)
    _animatedArtCache.set(artItemId, v)  // most-recently-used
    return v
  }
  if (_animatedArtCache.size >= _ANIMATED_ART_CACHE_MAX) {
    _animatedArtCache.delete(_animatedArtCache.keys().next().value)
  }
  const inFlight = (async () => {
    try {
      const url = jfClient.originalArtUrl(artItemId)
      const r = await jfFetch(url, { method: 'HEAD', signal: AbortSignal.timeout(5000) })
      // ponytail: HEAD only. If some Jellyfin build ever refuses it, this reads
      // as "not animated" and the still is used - which is today's behaviour,
      // so the failure mode is exactly the status quo. Swap in a ranged GET if
      // that ever actually happens.
      const result = r.ok && CascadeCore.isAnimatedImageType(r.headers.get('content-type'))
        ? url : null
      _animatedArtCache.set(artItemId, result)
      return result
    } catch {
      // A timeout or a blip is not an answer about the image, so do not
      // remember it as one.
      _animatedArtCache.delete(artItemId)
      return null
    }
  })()
  _animatedArtCache.set(artItemId, inFlight)
  return inFlight
}

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
const resolveTrackStream = (itemId, kind = 'Audio', opts = {}) => {
  // A downloaded track plays from disk, before the server is asked anything:
  // it is the file the person chose to keep, it needs no transcode, and with
  // no network there is nobody to ask. Direct, from the start, no session.
  // A downloaded movie or episode too: its subtitles are files beside it
  // (applySubtitles reads `local`), and it seeks on the element.
  const local = _offline.ready[itemId]
  if (local) return Promise.resolve({ url: local, playSessionId: null, mediaSourceId: null, direct: true, startTicks: 0, local: true })
  return resolveStream(jfClient, jf, itemId, currentDeviceProfile(), maxStreamingBitrate, kind, opts)
}

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
 * Add tracks to the end of the queue ("Play last"), routed through the
 * arbiter.
 *
 * A guest must not mutate locally - the next host broadcast would wipe it,
 * which is exactly how "Add to queue" used to look like it worked and then
 * silently do nothing.
 */
/**
 * Insert tracks straight after the current one ("Play next").
 *
 * Deliberately stricter than enqueueTracks: a guest is refused outright rather
 * than allowed to propose. Appending is fair game, but letting guests jump the
 * line would let the last clicker always win the next slot.
 *
 * Returns whether it happened, so a caller with somewhere else to put the
 * tracks (the remote handler falls back to playing them) can tell.
 */
function playNextTracks(items, label) {
  if (!items.length) return false
  if (isWaterfallFollower()) { showToast('Only the host can choose what plays next'); return false }
  queue = CascadeCore.insertAfterCurrent(queue, queueIndex, items)
  showToast(`${label} plays next`)
  return true
}

function enqueueTracks(items, label) {
  const mode = queueAdditionMode()

  if (mode === 'blocked') {
    showToast('The host has turned off guest additions')
    return
  }
  if (mode === 'propose') {
    if (wfRequestEnqueue(items)) showToast(`Asked the host to play ${label} last`)
    return
  }

  queue.push(...items)
  showToast(`${label} plays last`)
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
// Three kinds, and each call says which:
//   default   confirms something you just did ("Added to playlist") or says it
//             failed. Settings > About "Show messages", on unless turned off.
//   advanced  background detail nobody asked for: which lyrics source answered,
//             a codec falling back to a transcode. "Advanced messages", off
//             unless turned on, and only while messages are on at all.
//   debug     the debug panels' own feedback. A development run or the
//             `.cascade-debug` sentinel only, never a setting.
let _toastPrefs = { off: false, advanced: false }
let _toastDebug = false
window.cascade.store.get('toasts').then(v => {
  _toastPrefs = { off: !!v?.off, advanced: !!v?.advanced }
  _syncToastSettings()
})
window.cascade?.isPackaged?.().then(packaged => { if (!packaged) _toastDebug = true })
window.cascade?.isDebugMode?.().then(on => { if (on) _toastDebug = true })

function _syncToastSettings() {
  const main = /** @type {HTMLInputElement} */ (document.getElementById('s-toasts-toggle'))
  const adv = /** @type {HTMLInputElement} */ (document.getElementById('s-toasts-advanced-toggle'))
  main.checked = !_toastPrefs.off
  adv.checked = _toastPrefs.advanced
  adv.disabled = _toastPrefs.off
  adv.closest('.setting-row').classList.toggle('locked', _toastPrefs.off)
}

for (const [id, field] of [['s-toasts-toggle', 'off'], ['s-toasts-advanced-toggle', 'advanced']]) {
  document.getElementById(id).addEventListener('change', (e) => {
    const on = /** @type {HTMLInputElement} */ (e.target).checked
    _toastPrefs[field] = field === 'off' ? !on : on
    window.cascade.store.set('toasts', _toastPrefs)
    _syncToastSettings()
  })
}

// Messages can be switched off (see Toast above), so anything the user
// genuinely needs to read has to be a modal they dismiss. Resolves once
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

// A question with two answers, as a modal that must be answered. Resolves true
// for yes. Returns false at once if one is already on screen.
function showChoice(title, message, yes, no) {
  const modal = document.getElementById('choice-modal')
  if (!modal || !modal.classList.contains('hidden')) return Promise.resolve(false)
  document.getElementById('choice-title').textContent = title
  document.getElementById('choice-body').textContent = message
  const yesBtn = document.getElementById('choice-yes')
  const noBtn = document.getElementById('choice-no')
  yesBtn.textContent = yes
  noBtn.textContent = no
  modal.classList.remove('hidden')
  return new Promise(resolve => {
    const done = answer => {
      modal.classList.add('hidden')
      yesBtn.removeEventListener('click', onYes)
      noBtn.removeEventListener('click', onNo)
      resolve(answer)
    }
    const onYes = () => done(true)
    const onNo = () => done(false)
    yesBtn.addEventListener('click', onYes)
    noBtn.addEventListener('click', onNo)
  })
}

/** `level` is 'default', 'advanced' or 'debug'; see Toast above. */
function showToast(msg, { level = 'default', duration = 2200 } = {}) {
  if (level === 'debug' ? !_toastDebug : _toastPrefs.off || (level === 'advanced' && !_toastPrefs.advanced)) return
  const t = document.getElementById('toast')
  t.textContent = msg
  t.style.opacity = '1'
  clearTimeout(t._to)
  t._to = setTimeout(() => { t.style.opacity = '0' }, duration)
}

// ── Feature tips ──────────────────────────────────────────────────────────────
//
// One-time bubbles pointing at a control the first time it matters: the mark
// on the lyrics button, right-click menus, Cmd+K. Each is a showTipOnce() at
// its trigger plus a markTipSeen() wherever the feature itself gets used, so
// someone who already right-clicks is never told to.
//
// Every bubble has "Turn off tips", which stops all of them for good; Settings
// > About turns them back on and forgets what was seen. Store key `tips`:
// { off, seen: [keys] }. Kept apart from WIZARD_REVISION on purpose: bumping
// that re-shows the wizard to everyone.
//
// #feature-tip is its own element on <body>, for the same reason #tooltip is
// (rule 7: nothing inside a view can escape its clipping), but not #tooltip
// itself, which hides on mouseout.

let _tips = null       // null until the store answers, and nothing shows before then
let _tipShown = null   // { key, anchor, next }
let _tipTimer = null
let _tipQuietUntil = 0
// ponytail: one global gap between unrelated tips, per-tip priorities if it ever feels wrong
const TIP_QUIET_MS = 90000
const TIP_GAP = 10

window.cascade.store.get('tips').then(v => {
  _tips = { off: !!v?.off, seen: new Set(Array.isArray(v?.seen) ? v.seen : []) }
  _syncTipsSetting()
})

function _saveTips() {
  window.cascade.store.set('tips', { off: _tips.off, seen: [..._tips.seen] })
}

function _syncTipsSetting() {
  const toggle = /** @type {HTMLInputElement} */ (document.getElementById('s-tips-toggle'))
  if (toggle && _tips) toggle.checked = !_tips.off
}

function tipSeen(key) {
  return !_tips || _tips.seen.has(key)
}

/** The feature was used, so its tip has nothing left to teach. */
function markTipSeen(key) {
  if (_tipShown?.key === key) _hideTip()
  if (!_tips || _tips.seen.has(key)) return
  _tips.seen.add(key)
  _saveTips()
}

/** Shows `text` under (or above) `anchor` unless tips are off, this one was
 *  seen, another is up, or one showed in the last TIP_QUIET_MS. `next` runs on
 *  "Got it" and may chain another tip with `chained`, which skips the quiet
 *  gap. Returns whether it showed, so callers can try a few in order. */
function showTipOnce(key, anchor, text, { next = null, chained = false } = {}) {
  if (!_tips || _tips.off || _tips.seen.has(key) || _tipShown) return false
  if (!chained && Date.now() < _tipQuietUntil) return false
  if (!_tipAnchorVisible(anchor)) return false
  const el = document.getElementById('feature-tip')
  el.querySelector('.ft-text').textContent = text
  el.hidden = false
  _tipShown = { key, anchor, next }
  _tipQuietUntil = Date.now() + TIP_QUIET_MS
  _placeTip()
  // ponytail: polled, not observed. Catches an anchor that was removed or
  // covered; twice a second while one tip is up costs nothing.
  _tipTimer = setInterval(_placeTip, 500)
  return true
}

/** On screen and not under something else: a tip pointing at a button behind
 *  a modal, or inside a closed overlay, points at nothing. */
function _tipAnchorVisible(anchor) {
  if (!anchor?.isConnected) return false
  const r = anchor.getBoundingClientRect()
  if (!r.width || !r.height) return false
  const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
  return !!hit && (hit === anchor || anchor.contains(hit) || !!hit.closest?.('#feature-tip'))
}

function _placeTip() {
  if (!_tipShown) return
  const anchor = _tipShown.anchor
  if (!_tipAnchorVisible(anchor)) { _hideTip(); return }
  const el = document.getElementById('feature-tip')
  const h = anchor.getBoundingClientRect()
  const b = el.getBoundingClientRect()
  let top = h.bottom + TIP_GAP
  const above = top + b.height > window.innerHeight - 8
  if (above) top = h.top - b.height - TIP_GAP
  const left = Math.max(8, Math.min(window.innerWidth - b.width - 8, h.left + h.width / 2 - b.width / 2))
  el.classList.toggle('above', above)
  el.style.setProperty('--ft-arrow-x', `${Math.round(Math.max(16, Math.min(b.width - 16, h.left + h.width / 2 - left)))}px`)
  el.style.transform = `translate(${Math.round(left)}px, ${Math.round(Math.max(8, top))}px)`
}

function _hideTip() {
  if (!_tipShown) return
  _tipShown = null
  clearInterval(_tipTimer)
  document.getElementById('feature-tip').hidden = true
  // The overlay holds its controls up while a tip points at one of them.
  if (overlayOpen) pokeOverlayControls()
}

document.getElementById('ft-ok').addEventListener('click', () => {
  const t = _tipShown
  if (!t) return
  markTipSeen(t.key)
  t.next?.()
})
document.getElementById('ft-off').addEventListener('click', () => {
  _hideTip()
  _tips.off = true
  _saveTips()
  _syncTipsSetting()
  showToast('Tips are off. Settings > About turns them back on.', { duration: 3500 })
})
window.addEventListener('resize', _placeTip)
window.addEventListener('scroll', _placeTip, true)

document.getElementById('s-tips-toggle').addEventListener('change', (e) => {
  if (!_tips) return
  _tips.off = !(/** @type {HTMLInputElement} */ (e.target).checked)
  if (_tips.off) _hideTip()
  _saveTips()
})
document.getElementById('s-tips-reset').addEventListener('click', () => {
  if (!_tips) return
  _tips = { off: false, seen: new Set() }
  _tipQuietUntil = 0
  _saveTips()
  _syncTipsSetting()
  showToast('Tips will show again as features come up')
})

// Rows and cards: the first one the pointer rests on teaches its right-click
// menu. Delegated, so the Songs view, which wires its own rows, gets it too.
let _tipHoverEl = null
let _tipHoverTimer = null
document.addEventListener('mouseover', (e) => {
  if (!_tips || _tips.off || _tipShown) return
  const el = /** @type {HTMLElement} */ (e.target).closest?.('.track-row, .queue-row, .album-card, .artist-card, .playlist-card, .poster-card')
  if (el === _tipHoverEl) return
  _tipHoverEl = el
  clearTimeout(_tipHoverTimer)
  if (el) _tipHoverTimer = setTimeout(() => { if (el.matches(':hover')) _hoverTip(el) }, 700)
})

function _hoverTip(el) {
  const drags = el.getAttribute('draggable') === 'true'
  if (el.classList.contains('queue-row')) {
    showTipOnce('queue-row', el, drags
      ? 'In the queue, one click plays a song. Drag songs to reorder them, and right-click for more.'
      : 'In the queue, one click plays a song. Right-click for more.')
  } else if (el.classList.contains('track-row')) {
    if (drags && tipSeen('track-menu')) showTipOnce('playlist-drag', el, 'Drag songs to reorder this playlist.')
    else showTipOnce('track-menu', el, 'Right-click any song for more, like Play next, Add to playlist and Download. Double-click plays it.')
  } else {
    showTipOnce('card-menu', el, 'Right-click albums, artists, playlists and videos for more, like Shuffle, Play next and Download.')
  }
}

// The short pass after a first run's wizard. Two stops on purpose: the rest is
// taught where it comes up, which is when anyone actually reads it.
function _startTipTour() {
  const keys = window.cascade.platform === 'darwin' ? '⌘K' : 'Ctrl+K'
  showTipOnce('search-key', document.getElementById('search-input'),
    `Search your whole library here. ${keys} jumps here from anywhere.`, {
      next: () => showTipOnce('tour-settings', document.querySelector('.nav-item[data-view="settings"]'),
        'Everything you just set up lives in Settings, along with a lot more. Tips like this one point out the rest as you go.',
        { chained: true }),
    })
}

// ── Jellyfin API ──────────────────────────────────────────────────────────────

// Typed loosely on purpose: callers here hit list endpoints, single-item
// endpoints and /System/Info alike, so the client's JfItemsResponse default is
// wrong for most of them. src/ code calls jfClient.get directly and does get
// the strict types.
//
// Library reads use /Items, /Items/{id} and /UserViews, never the
// /Users/{userId}/Items, /Users/{userId}/Items/{id} and /Users/{userId}/Views
// forms: those are marked Obsolete in Jellyfin 12 (checked in the v12.0 source)
// and 12.0 already deleted other routes it had marked that way. No userId is
// sent: both 10.11 and 12 fall back to the signed-in user (RequestHelpers.GetUserId).
/** @type {(path: string, params?: Record<string, any>) => Promise<any>} */
const jfGet  = (path, params = {}) => jfClient.get(path, params)

// Every request outside jfClient goes through one of these two, so Offline
// Mode refuses it before anything is sent (docs/offline-mode-plan.md, section
// 2): jfFetch for the Jellyfin server (writes, the Cascade plugin, lyrics),
// webFetch for other services (iTunes, MusicBrainz, LRCLIB). Main also blocks
// the server's origin while the switch is on; this is what keeps the
// unreachable state quiet too, and what callers catch. test/offline-guard
// fails on a new raw fetch( in this file.
//
// They part ways in Local mode (docs/local-mode-plan.md): there is no server,
// so jfFetch refuses, but the web is there, so webFetch goes out
// (CascadeCore.blocksWeb).
/** @type {(input: string, init?: RequestInit) => Promise<Response>} */
//
// In Local mode the playlist writes the screens send Jellyfin are answered by
// Cascade's own playlists instead (localServerWrite, section "Local mode"):
// nothing leaves the machine either way.
const jfFetch = (input, init) => jfClient.offline
  ? (isLocalMode() ? localServerWrite(input, init) : Promise.reject(new CascadeCore.OfflineError()))
  // offline-ok: the guard itself.
  : fetch(input, init)
/** @type {(input: string, init?: RequestInit) => Promise<Response>} */
const webFetch = (input, init) => CascadeCore.blocksWeb(_offlineState)
  ? Promise.reject(new CascadeCore.OfflineError())
  // offline-ok: the guard itself.
  : fetch(input, init)

// Items by id, in chunks: past roughly 240 ids the URL outgrows the server's
// request line limit and Jellyfin answers 414, failing the whole lookup. A
// failed chunk is skipped rather than failing the rest. Server order, not `ids`
// order.
async function jfItemsByIds(ids, fields) {
  const chunks = []
  for (let i = 0; i < ids.length; i += 100) chunks.push(ids.slice(i, i + 100))
  const pages = await Promise.all(chunks.map(c =>
    jfGet(`/Items`, { Ids: c.join(','), Fields: fields }).catch(() => null)))
  return pages.flatMap(p => p?.Items || [])
}
const jfAuth = (serverUrl, username, password) =>
  CascadeCore.authenticate(serverUrl, username, password, appVersion, deviceId)

// ── Connection ────────────────────────────────────────────────────────────────

async function connect(serverUrl, token, userId) {
  jf = { url: serverUrl.replace(/\/$/, ''), token, userId, deviceId, appVersion }

  // Hand the session to the control server so Cha0s Stream can search and queue
  // against the same Jellyfin without the user configuring it a second time.
  // Sent on every connect() so a re-auth replaces a token that has gone stale.
  window.cascade.jellyfinCredentialsUpdate?.({ url: jf.url, token: jf.token, userId: jf.userId })

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
  const viewsPromise = jfGet(`/UserViews`).catch(() => null)

  // Offline (Offline Mode set jfClient's source before calling this), every
  // read below answers from the downloads, so the same steps draw the app
  // from them. What needs the server itself is skipped further down.
  const offline = jfClient.offline

  // Verify the token is still valid with a lightweight ping, retry up to 3x
  let verified = offline
  let userInfo = offline ? await jfGet(`/Users/${userId}`).catch(() => null) : null
  let lastError = null
  for (let attempt = 1; attempt <= 3 && !verified; attempt++) {
    showLoading(attempt === 1 ? 'Connecting…' : `Retrying… (${attempt}/3)`)
    try {
      userInfo = await jfGet(`/Users/${userId}`)
      verified = true
      break
    } catch (e) {
      lastError = e
      // No network at all: waiting and asking again will not change that.
      if (!navigator.onLine) break
      if (attempt < 3) await new Promise(r => setTimeout(r, 1500 * attempt))
    }
  }

  hideLoading()

  if (!verified) {
    if (errorEl) errorEl.textContent = 'Connection failed. Check your server URL and try again.'
    // The HTTP status when the server answered ("401 Unauthorized"), none when
    // it never did: launch tells a rejected token from a missing network by it.
    throw Object.assign(new Error('Could not reach Jellyfin server'), { status: Number(/^(\d{3}) /.exec(lastError?.message || '')?.[1]) || null })
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
  // Whether the account may download media: Jellyfin answers /Download with a
  // 403 otherwise, which the offline downloads report as such track by track.
  jf.canDownload = userInfo?.Policy?.EnableContentDownloading !== false
  // Same free response again - whether the account can see Live TV at all,
  // which the Radio nav row is gated on (see applyRadioNavVisibility). A
  // server with no Live TV access denied would otherwise show a Radio tab
  // that 403s on first click.
  jf.hasLiveTv = !!userInfo?.Policy?.EnableLiveTvAccess
  radioEnabled = (await window.cascade.store.get('radioEnabled')) === true
  applyRadioNavVisibility()
  _applyAdminGating()

  if (!offline) {
    startRemoteControl()
    probeCascadePlugin()  // not awaited - cheap, and nothing here depends on the result yet
  }
  // This account's downloads (another's are never shown or resumed). Back
  // online: carry on with downloads that were waiting, and tell the server
  // about plays made while it was out of reach.
  await window.cascade.offline.setOwner(jf.userId)
  await refreshOffline()
  if (!offline) {
    window.cascade.offline.resume(offlineSession()).catch(() => {})
    // Before anything else can add to the server's history.
    await syncOffline()
    // What Offline Mode needs to know later: who this is, which libraries
    // there are, and which library each download is in.
    window.cascade.offline.setUser(userInfo).catch(() => {})
    viewsPromise.then(v => v && window.cascade.offline.setLibraries(v.Items || []))
      .then(() => placeOfflineDownloads()).catch(() => {})
    refreshExpiredLyrics().catch(() => {})
    syncFollowedSeries().catch(() => {})
  }
  sweepWatchedEpisodes()
  await populateLibraryPicker(viewsPromise)
  invalidateLibraryViews()
  invalidateVideoViews()
  await loadHome()
  await restoreLastQueue()
  _connectedOnline = !offline
  // Both sit over a populated app rather than a blank one, hence after loadHome.
  // The wizard runs itself off its stored revision, so an ordinary launch on the
  // current revision shows nothing - and when it does run it has already marked
  // the video intro seen, since its library step covers the same ground.
  if (!offline && !await maybeShowSetupWizard()) await maybeShowVideoIntro()
}

// ── Remote control (cast target) ─────────────────────────────────────────────
// Registers this client with Jellyfin so the web UI, a phone, or a future TV
// client can drive it. Protocol lives in src/core/remote-control.ts; only the
// "actually do it" callbacks are here, because only they touch the DOM.

let _remote = null

// A message an admin sent this session from Jellyfin's dashboard: a card at the
// top until closed, or for as long as the sender asked. Text only.
let _serverMessageTimer = null
function showServerMessage(message) {
  const card = document.getElementById('server-message')
  document.getElementById('server-message-title').textContent = message.header
  document.getElementById('server-message-body').textContent = message.text
  document.getElementById('server-message-body').hidden = !message.text
  card.classList.remove('hidden')
  clearTimeout(_serverMessageTimer)
  if (message.timeoutMs) _serverMessageTimer = setTimeout(() => card.classList.add('hidden'), message.timeoutMs)
}
document.getElementById('server-message-close').addEventListener('click', () => {
  clearTimeout(_serverMessageTimer)
  document.getElementById('server-message').classList.add('hidden')
})

function startRemoteControl() {
  if (_remote) _remote.stop()

  _remote = new CascadeCore.RemoteControl(jfClient, () => jf, {
    // playCommand was accepted by remote-control.ts and then dropped here, so
    // PlayNext and PlayLast both behaved as PlayNow and wiped the queue instead
    // of adding to it. Jellyfin controllers (and Cha0s Stream's song requests)
    // send all three.
    async play(itemIds, startIndex, playCommand) {
      if (!itemIds.length) return
      // MediaStreams/MediaSources are what applySubtitles() needs. Without
      // them a movie pushed from Jellyfin's "Play On" would play with no
      // subtitles even when the file has them.
      const items = await jfItemsByIds(itemIds, 'AlbumId,AlbumPrimaryImageTag,UserData,MediaStreams,MediaSources')
      if (!items.length) return
      // Jellyfin returns items in its own order, so re-sort to what was sent.
      const byId = new Map(items.map(i => [i.Id, i]))
      const ordered = itemIds.map(id => byId.get(id)).filter(Boolean)
      const tracks = ordered.length ? ordered : items

      // With nothing playing there is no "next" or "last" to be relative to, so
      // both degrade to starting playback rather than filling a queue the user
      // would then have to press play on.
      const idle = !queue.length || queueIndex < 0
      const label = tracks.length === 1 ? `"${tracks[0].Name}"` : `${tracks.length} tracks`

      if (playCommand === 'PlayNext' && !idle) { playNextTracks(tracks, label); return }
      if (playCommand === 'PlayLast' && !idle) { enqueueTracks(tracks, label); return }
      playItems(tracks, startIndex)
    },
    playPause()     { if (audio.paused) playOrResume(); else audio.pause() },
    pause()         { audio.pause() },
    unpause()       { playOrResume() },
    stop()          { stopPlayback() },
    nextTrack()     { document.getElementById('btn-next').click() },
    previousTrack() { document.getElementById('btn-prev').click() },
    seek(ticks)     { seekTo(ticks / 10_000_000) },
    setVolume(pct)  { applyRemoteVolume(pct / 100) },
    volumeUp()      { applyRemoteVolume(volume + 0.1) },
    volumeDown()    { applyRemoteVolume(volume - 0.1) },
    toggleMute()    { applyRemoteMute(!_muted) },
    setMute(muted)  { applyRemoteMute(muted) },
    showMessage(message) { showServerMessage(message) },
  }, playbackIsLocallyOwned)

  // Not fatal - playback works fine without it - but it must be visible.
  // Silently swallowing this hid a malformed capabilities payload that left
  // Cascade invisible as a cast target with no symptom to chase.
  _remote.start().catch(err => {
    console.warn('[cascade] remote control unavailable:', err?.message || err)
  })
}

// Both remote volume entry points funnel through here rather than straight to
// setVolumeRatio/setDeckMuted, so "personal, per-device, never room-driven" is
// enforced once, at the layer where a remote command actually reaches the
// element - not by trusting the RemoteControl gate upstream to always cover
// it. See CascadeCore.acceptsRemoteVolumeCommand for why this is its own
// check rather than a reuse of playbackIsLocallyOwned.
function remoteVolumeAllowed() {
  return CascadeCore.acceptsRemoteVolumeCommand(ownershipState())
}

// Mirrors what the volume slider does, so a remote change looks identical.
function applyRemoteVolume(next) {
  if (!remoteVolumeAllowed()) return
  setVolumeRatio(next)
}

function applyRemoteMute(muted) {
  if (!remoteVolumeAllowed()) return
  setDeckMuted(muted)
}

// ── Device picker (drive OTHER Jellyfin sessions) ────────────────────────────
// The other half of remote control: RemoteControl above makes Cascade a cast
// TARGET; this makes Cascade a controller, same as Jellyfin's own web UI.
// Session filtering and request shapes are pure and live in
// src/core/session-control.ts; everything here is the HTTP calls, polling
// and DOM that file's comment says stay out of it.

let _dpSessions = []      // last poll's controllable sessions
let _dpSelectedId = null  // session Id being driven, or null
let _dpPollTimer = null
let _dpLastPolledAt = 0
let _dpSeekDragging = false  // suppress the poll's write to the bar mid-drag
let _dpVolDragging = false

const devicesPanel = document.getElementById('devices-panel')

function dpIsOpen() { return devicesPanel.classList.contains('open') }

async function openDevicesPanel() {
  devicesPanel.classList.add('open')
  const btn = document.getElementById('btn-devices-open')
  const r = btn.getBoundingClientRect()
  const pr = devicesPanel.getBoundingClientRect()
  // Anchored above the button, right-aligned, clamped on screen - same
  // measure-after-open-then-clamp recipe as showCtxMenu.
  const { left, top } = CascadeCore.clampMenuPosition(
    r.right - pr.width, r.top - pr.height - 8, pr.width, pr.height, window.innerWidth, window.innerHeight)
  devicesPanel.style.left = `${left}px`
  devicesPanel.style.top = `${top}px`
  await _dpPoll()
  _dpSchedulePoll()
}

function closeDevicesPanel() {
  devicesPanel.classList.remove('open')
  if (_dpPollTimer) { clearTimeout(_dpPollTimer); _dpPollTimer = null }
}

document.getElementById('btn-devices-open').addEventListener('click', (e) => {
  e.stopPropagation()
  if (dpIsOpen()) closeDevicesPanel(); else openDevicesPanel()
})
document.getElementById('dp-close').addEventListener('click', () => closeDevicesPanel())
document.addEventListener('mousedown', (e) => {
  if (dpIsOpen() && !devicesPanel.contains(e.target) && e.target.id !== 'btn-devices-open') closeDevicesPanel()
})

/** Poll only while the panel is open - a background poll nobody can see
 *  would just be load on the server for no benefit. */
async function _dpPoll() {
  try {
    const sessions = await jfGet('/Sessions', { controllableByUserId: jf.userId })
    _dpSessions = CascadeCore.filterControllableSessions(Array.isArray(sessions) ? sessions : [], deviceId)
  } catch {
    _dpSessions = []
  }
  _dpLastPolledAt = Date.now()
  _dpRenderList()
  if (_dpSelectedId) _dpRenderNowPlaying()
}

function _dpSchedulePoll() {
  if (_dpPollTimer) clearTimeout(_dpPollTimer)
  if (!dpIsOpen()) return
  _dpPollTimer = setTimeout(async () => { await _dpPoll(); _dpSchedulePoll() }, 3000)
}

function _dpRenderList() {
  const list = document.getElementById('dp-list')
  const empty = document.getElementById('dp-empty')
  if (!_dpSessions.length) {
    list.classList.add('hidden')
    empty.classList.remove('hidden')
    list.innerHTML = ''
  } else {
    empty.classList.add('hidden')
    list.classList.remove('hidden')
    list.innerHTML = _dpSessions.map(s => `
      <button class="dp-device${s.Id === _dpSelectedId ? ' active' : ''}" data-session-id="${esc(s.Id)}">
        <svg class="dp-device-icon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="4" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="18" x2="12" y2="21"/></svg>
        <span class="dp-device-info">
          <span class="dp-device-name">${esc(s.DeviceName || s.Client || 'Device')}</span>
          <span class="dp-device-sub">${esc(s.NowPlayingItem?.Name || s.Client || '')}</span>
        </span>
      </button>`).join('')
    list.querySelectorAll('.dp-device').forEach(btn => {
      btn.addEventListener('click', () => _dpSelect(btn.dataset.sessionId))
    })
  }
  // A device that vanished from the list (closed socket, signed out) cannot
  // stay selected - its now-playing panel would be driving a dead session.
  if (_dpSelectedId && !_dpSessions.some(s => s.Id === _dpSelectedId)) {
    _dpSelectedId = null
    document.getElementById('dp-now').classList.add('hidden')
    _dpUpdateCtxVisibility()
  }
}

function _dpSelect(sessionId) {
  // Clicking the already-selected device disconnects, same as clicking an
  // active output in most casting UIs.
  _dpSelectedId = (_dpSelectedId === sessionId) ? null : sessionId
  _dpRenderList()
  document.getElementById('dp-now').classList.toggle('hidden', !_dpSelectedId)
  if (_dpSelectedId) _dpRenderNowPlaying()
  _dpUpdateCtxVisibility()
}

function _dpCurrentSession() {
  return _dpSessions.find(s => s.Id === _dpSelectedId) || null
}

function _dpRenderNowPlaying() {
  const s = _dpCurrentSession()
  if (!s) return
  document.getElementById('dp-now-name').textContent = s.DeviceName || s.Client || 'Device'
  const item = s.NowPlayingItem
  const ps = s.PlayState || {}
  document.getElementById('dp-now-track').textContent = item
    ? `${item.Name}${item.AlbumArtist ? ' — ' + item.AlbumArtist : ''}`
    : 'Nothing playing'
  document.getElementById('dp-icon-play').style.display  = ps.IsPaused === false ? 'none' : ''
  document.getElementById('dp-icon-pause').style.display = ps.IsPaused === false ? '' : 'none'

  const durTicks = item?.RunTimeTicks || 0
  if (!_dpSeekDragging) {
    const posTicks = CascadeCore.interpolatedPositionTicks(ps, _dpLastPolledAt, Date.now())
    const seek = document.getElementById('dp-seek')
    const durSec = Math.max(1, Math.round(durTicks / 10_000_000))
    seek.max = String(durSec)
    seek.value = String(Math.min(durSec, Math.round(posTicks / 10_000_000)))
    document.getElementById('dp-time-cur').textContent = fmtTime(posTicks / 10_000_000)
    document.getElementById('dp-time-dur').textContent = fmtTime(durTicks / 10_000_000)
  }
  if (!_dpVolDragging && typeof ps.VolumeLevel === 'number') {
    document.getElementById('dp-vol').value = String(ps.VolumeLevel)
  }
}

/** `command` is a PlaystateCommand (PlayPause, Seek, NextTrack, ...) - see
 *  the PlaystateCommand enum in the server's own OpenAPI spec. No body: this
 *  route takes seekPositionTicks and controllingUserId as query params only. */
async function _dpSendPlaystate(command, params = {}) {
  const s = _dpCurrentSession()
  if (!s) return
  try {
    await jfClient.post(`/Sessions/${s.Id}/Playing/${command}`, null, params)
  } catch (err) {
    console.warn('[cascade] device command failed:', err?.message || err)
  }
  // The target's own state (paused/position/volume) only changes once it has
  // actually acted on the command - re-poll shortly after rather than
  // optimistically flipping the UI and risking it disagreeing with reality.
  setTimeout(_dpPoll, 500)
}

/** `body` is a GeneralCommand ({Name, Arguments}) - the full route, since the
 *  path-only /Command/{command} route has nowhere to carry a value. */
async function _dpSendGeneralCommand(body) {
  const s = _dpCurrentSession()
  if (!s) return
  try {
    await jfClient.post(`/Sessions/${s.Id}/Command`, body)
  } catch (err) {
    console.warn('[cascade] device command failed:', err?.message || err)
  }
  setTimeout(_dpPoll, 500)
}

/** "Play this on <device>" - the one guard `playItems()` needs for a remote
 *  target, added here rather than threading a device check through every
 *  play entry point (context menus, album/artist pages, playlists all
 *  already funnel into playItems() or here directly). */
async function _dpPlayItemsOnDevice(items, startIndex = 0) {
  const s = _dpCurrentSession()
  if (!s) return
  const params = CascadeCore.buildPlayOnDeviceParams((items || []).map(i => i.Id), 'PlayNow', startIndex)
  if (!params) return
  const label = s.DeviceName || s.Client || 'device'
  try {
    await jfClient.post(`/Sessions/${s.Id}/Playing`, null, params)
    showToast(`Playing on ${label}`)
  } catch (err) {
    console.warn('[cascade] play on device failed:', err?.message || err)
    showToast('Could not start playback on that device')
  }
  setTimeout(_dpPoll, 500)
}

function _dpUpdateCtxVisibility() {
  const row = document.getElementById('tctx-play-on-device')
  if (!row) return
  const s = _dpCurrentSession()
  row.classList.toggle('hidden', !s)
  if (s) document.getElementById('tctx-play-on-device-label').textContent = `Play on ${s.DeviceName || s.Client || 'device'}`
}

document.getElementById('dp-playpause').addEventListener('click', () => _dpSendPlaystate('PlayPause'))
document.getElementById('dp-prev').addEventListener('click', () => _dpSendPlaystate('PreviousTrack'))
document.getElementById('dp-next').addEventListener('click', () => _dpSendPlaystate('NextTrack'))
document.getElementById('dp-send-queue-btn').addEventListener('click', () => {
  if (queue.length) _dpPlayItemsOnDevice(queue, Math.max(0, queueIndex))
})

const dpSeekInput = document.getElementById('dp-seek')
dpSeekInput.addEventListener('input', () => { _dpSeekDragging = true })
dpSeekInput.addEventListener('change', () => {
  _dpSeekDragging = false
  _dpSendPlaystate('Seek', { seekPositionTicks: CascadeCore.secondsToTicks(Number(dpSeekInput.value)) })
})

// Live while dragging: each input would be a request to the server and a hop
// to the device, so at most one goes out per 150 ms, carrying wherever the
// thumb is by then, and the release sends the exact final level.
const dpVolInput = document.getElementById('dp-vol')
let _dpVolTimer = null
dpVolInput.addEventListener('input', () => {
  _dpVolDragging = true
  if (_dpVolTimer) return
  _dpVolTimer = setTimeout(() => {
    _dpVolTimer = null
    _dpSendGeneralCommand(CascadeCore.buildSetVolumeCommand(Number(dpVolInput.value)))
  }, 150)
})
dpVolInput.addEventListener('change', () => {
  clearTimeout(_dpVolTimer)
  _dpVolTimer = null
  _dpVolDragging = false
  _dpSendGeneralCommand(CascadeCore.buildSetVolumeCommand(Number(dpVolInput.value)))
})

// The library selection may have changed - force every lazy view to refetch.
// allSongs must be cleared too: shuffleAllSongs() short-circuits when it is
// non-empty and would keep queueing tracks from deselected libraries.
function invalidateLibraryViews() {
  allSongs = []
  _songsFetch = null
  for (const id of ['albums-grid', 'artists-grid', 'songs-rows', 'playlists-grid', 'genres-grid'])
    delete document.getElementById(id).dataset.loaded
}

/** Same, for the video grids. Separate because the two selections are separate:
 *  changing music libraries must not throw away a loaded movie grid. */
function invalidateVideoViews() {
  for (const id of ['movies-grid', 'shows-grid'])
    delete document.getElementById(id).dataset.loaded
}

/** Greys out the server library scan button when the account is not an admin,
 *  using the same disabled+data-tip pattern as the Cascade Server plugin gating below.
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
  // anything. All admin-only. These say why inline rather than with a
  // [data-tip]: a context menu item is a row in a list, and a tip floating
  // over the row below it would cover the next thing you were about to read.
  for (const id of ['ctx-refresh-meta', 'tctx-refresh-meta', 'ictx-refresh-meta', 'ctx-edit-meta', 'ctx-edit-images', 'tctx-edit-meta', 'tctx-edit-images', 'ictx-edit-meta']) {
    const item = document.getElementById(id)
    if (item) item.classList.toggle('needs-admin', !jf.isAdmin)
    const note = document.getElementById(id + '-note')
    if (note) note.hidden = !!jf.isAdmin
  }
  // Delete media (now-playing and track rows) and delete playlist (playlist
  // card menu) are all gated on the actual deletion right (see
  // canDeleteMedia), not admin - an admin always has it, but a non-admin can
  // be granted it too, and gating on isAdmin would hide the feature from
  // someone who has it.
  for (const id of ['ctx-delete', 'tctx-delete', 'ictx-delete']) {
    const item = document.getElementById(id)
    if (item) item.classList.toggle('needs-admin', !jf.canDelete)
    const note = document.getElementById(id + '-note')
    if (note) note.hidden = !!jf.canDelete
  }
}

// Greys out "Approve a device" (Settings > Account) when the server itself has
// Quick Connect switched off - same disabled+data-tip pattern as the admin
// gating above, but a server feature check rather than a permission check, so
// it is its own function rather than folded into _applyAdminGating(). Not
// admin-only: any signed-in account can approve its own Quick Connect codes.
let _qcApproveEnabled = false   // read by the click handler too, not just the button's look
async function _applyQuickConnectGating() {
  // No server to ask, and its row is hidden.
  if (isLocalMode()) return
  const enabled = await CascadeCore.quickConnectEnabled(jf.url)
  _qcApproveEnabled = enabled
  const btn = document.getElementById('qc-approve-btn')
  const code = document.getElementById('qc-approve-code')
  const host = document.getElementById('qc-approve-tip')
  if (btn) btn.disabled = !enabled
  if (code) code.disabled = !enabled
  if (host) {
    if (!enabled) host.setAttribute('data-tip', 'Quick Connect is turned off on this server')
    else host.removeAttribute('data-tip')
  }
}

function _showQcApproveStatus(message, isError) {
  const row = document.getElementById('qc-approve-status-row')
  const span = document.getElementById('qc-approve-status')
  row.style.display = ''
  span.textContent = message
  span.style.color = isError ? 'var(--red)' : 'var(--text3)'
}

document.getElementById('qc-approve-btn').addEventListener('click', async () => {
  // Guarded here too, not just via the disabled button - a disabled-looking
  // control can still be triggered programmatically (CODEMAP house rule).
  if (!_qcApproveEnabled) return
  const input = document.getElementById('qc-approve-code')
  const code = input.value.trim()
  if (!code) { _showQcApproveStatus('Enter the code shown on the other device.', true); return }
  const btn = document.getElementById('qc-approve-btn')
  btn.disabled = true
  try {
    const ok = await CascadeCore.quickConnectAuthorize(jf, code)
    if (ok) {
      _showQcApproveStatus('Device approved.', false)
      input.value = ''
    } else {
      // The server answered the request but the code itself did not check out -
      // most likely already used, or typed with a slip.
      _showQcApproveStatus('That code was not accepted. Check it and try again.', true)
    }
  } catch (e) {
    // A genuinely failed request (unknown/expired code returns 404 on this
    // server - checked directly) - show the server's own short message rather
    // than inventing one.
    _showQcApproveStatus(e.message || 'Could not reach the server.', true)
  }
  btn.disabled = !_qcApproveEnabled
})

document.getElementById('s-refresh-server').addEventListener('click', async () => {
  // The button is disabled for a non-admin, but a disabled button can still
  // be clicked programmatically - don't trust the DOM state alone against a
  // server call that would just 403 anyway.
  if (!jf.isAdmin) return
  try {
    const res = await jfFetch(`${jf.url}/Library/Refresh`, { method: 'POST', headers: CascadeCore.authHeaders(jf) })
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
let radioEnabled = false       // user has confirmed their Live TV channels are radio stations

/** `prefetched` is the in-flight /Views request connect() started in parallel
 *  with the token ping. It resolves to null if that request failed, in which
 *  case this fetches it the old way - a retry is worth more here than saving a
 *  round trip, because empty _musicLibs is indistinguishable from a music-only
 *  server and takes Movies and TV down with it. */
async function populateLibraryPicker(prefetched = null) {
  try {
    const data = (prefetched && await prefetched) || await jfGet(`/UserViews`)
    _musicLibs = (data.Items || []).filter(i =>
      i.CollectionType === 'music' || i.CollectionType === 'musicvideos'
    )
    _movieLibs = (data.Items || []).filter(i => i.CollectionType === 'movies')
    _showLibs  = (data.Items || []).filter(i => i.CollectionType === 'tvshows')
    // Local mode: a library per folder, the music ones merged or one at a
    // time as with a server, but saved under their own keys (libKey), so
    // switching back finds the Jellyfin choices as they were. Every movie
    // and show library is shown.
    if (isLocalMode()) {
      await loadCollapsedLibs()
      let savedIds = []
      try { savedIds = JSON.parse(await window.cascade.store.get(libKey('libraryIds')) || '[]') } catch {}
      singleLibraryMode = (await window.cascade.store.get(libKey('singleLibraryMode'))) === true
      savedIds = (Array.isArray(savedIds) ? savedIds : []).filter(id => _musicLibs.some(l => l.Id === id))
      if (!savedIds.length) savedIds = _musicLibs.map(l => l.Id)
      jf.libraryIds = singleLibraryMode ? savedIds.slice(0, 1) : savedIds
      jf.movieLibraryIds = _movieLibs.map(l => l.Id)
      jf.showLibraryIds = _showLibs.map(l => l.Id)
      renderLibraryPicker()
      renderVideoLibraryPicker()
      applyVideoNavVisibility()
      return
    }
    // Offline, the views are only the libraries holding downloads. The saved
    // choice is used as it is and nothing is written: trimming it to what is
    // downloaded and saving that would quietly lose the person's selection.
    const offline = jfClient.offline
    if (!offline) await migrateVideoLibraryIds()
    await loadVideoLibrarySelection()
    await loadCollapsedLibs()
    const savedRaw = await window.cascade.store.get('libraryIds')
    let savedIds = []
    try { savedIds = savedRaw ? JSON.parse(savedRaw) : [] } catch {}
    singleLibraryMode = (await window.cascade.store.get('singleLibraryMode')) === true
    if (offline) {
      jf.libraryIds = savedIds.length ? savedIds : _musicLibs.map(l => l.Id)
      renderLibraryPicker()
      return
    }

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

/** The store key for a music library choice: Local mode keeps its own, so
 *  the folders' libraries and a server's never overwrite each other. */
const libKey = (key) => isLocalMode() ? `local${key[0].toUpperCase()}${key.slice(1)}` : key

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
  await window.cascade.store.set(libKey('libraryIds'), JSON.stringify(ids))
  renderLibraryPicker()
  invalidateLibraryViews()
  showToast(ids.length === 1
    ? `Now playing from ${_musicLibs.find(l => l.Id === ids[0])?.Name || 'library'}`
    : `Merging ${ids.length} libraries`, { level: 'advanced' })
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

// ── Radio (Live TV channels shown as stations) ───────────────────────────────
// Jellyfin has no reliable per-channel way to tell an internet-radio channel
// apart from a real TV one: an M3U tuner's channels always come back
// ChannelType=TV (verified against a real 10.11 server and its own
// M3uParser.cs, which never touches that field), and the server's own
// `type=Radio` filter on /LiveTv/Channels is a no-op regardless of value
// (verified: an invalid type still returns everything, unfiltered). So this
// is opt-in rather than auto-detected - see the Settings toggle above.

/** Same no-dead-nav-row rule as applyVideoNavVisibility, for the same reason:
 *  a user who has not confirmed their Live TV is radio, or whose account
 *  cannot see Live TV at all, must never see a Radio tab that leads nowhere
 *  or 403s. */
function applyRadioNavVisibility() {
  const show = radioEnabled && !!jf.hasLiveTv
  document.body.classList.toggle('has-radio', show)
  if (!show && _currentView === 'radio') showView('home')
}

async function loadRadio() {
  const grid = document.getElementById('radio-grid')
  const empty = document.getElementById('radio-empty')
  grid.dataset.loaded = '1'
  let channels = []
  try {
    const res = await jfGet('/LiveTv/Channels', { userId: jf.userId })
    channels = res.Items || []
  } catch (e) {
    console.error('[cascade] could not load radio channels:', e)
  }
  grid.style.display = channels.length ? '' : 'none'
  empty.style.display = channels.length ? 'none' : ''
  if (!channels.length) { grid.innerHTML = ''; return }
  // albumCard()/wireAlbumCards() are the exact right shape already: a name,
  // an image and a click handler matched back to the item by id - no reason
  // to invent a second card renderer for what is, visually, the same card.
  grid.innerHTML = channels.map(ch => albumCard(ch)).join('')
  wireAlbumCards(grid, channels, ch => playRadioStation(ch))
}

/** The server-side tuner/ffmpeg session behind whichever station is
 *  currently open, if any - closed before switching stations or leaving
 *  Radio so it never lingers past the point anyone is listening to it. */
let _radioLiveStreamId = null

async function _closeRadioStreamIfAny() {
  if (!_radioLiveStreamId) return
  const id = _radioLiveStreamId
  _radioLiveStreamId = null
  await CascadeCore.closeRadioStream(jfClient, id)
}

/**
 * Plays a Live TV channel as a radio station.
 *
 * Deliberately its own function rather than routing through
 * playCurrentTrack(): that function's prefetch, resume-position and
 * crossfade-handoff logic all assume an ordinary finite Audio/Video item, and
 * bending it around a channel's shape (no RunTimeTicks, no MediaSources until
 * PlaybackInfo actually opens the tuner, a LiveStreamId to close afterwards)
 * risked breaking the finite-item path it already handles correctly for
 * everyone else - see CascadeCore.resolveRadioStream's own comment for why
 * the resolve step needed to differ too.
 *
 * The shared choke points a continuous stream would otherwise trip -
 * crossfade, prefetch, lyrics lookup, the progress bar, session progress
 * reporting - are guarded at their own sites (search this file for
 * CascadeCore.isRadioItem and audio.duration/isFinite) rather than
 * duplicated here.
 */
async function playRadioStation(channel) {
  if (blocksLocalPlayback()) return
  cancelCrossfade()
  abandonCurrentEncoding()
  await _closeRadioStreamIfAny()
  queue = [channel]
  queueIndex = 0
  queueSource = 'Radio'
  applyVideoMode(false)

  let resolved
  try {
    resolved = await CascadeCore.resolveRadioStream(
      jfClient, jf, channel.Id, currentDeviceProfile(), maxStreamingBitrate)
  } catch (e) {
    console.error('[cascade] could not resolve radio stream:', e)
    showToast('Could not play that station')
    return
  }
  // The user could have navigated to a different station (or away from
  // Radio entirely) while PlaybackInfo was in flight.
  if (queue[queueIndex]?.Id !== channel.Id) {
    CascadeCore.closeRadioStream(jfClient, resolved.liveStreamId)
    return
  }
  _radioLiveStreamId = resolved.liveStreamId
  audio.src = resolved.url
  audio.play().catch(() => {})
  updateNowPlaying(channel)
  highlightPlayingRow()
  if (overlayOpen) renderQueuePanel()
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
// Search covers music and video either way; this just names what you are
// browsing.
function setSearchPlaceholder(mode) {
  const what = mode === 'video' ? 'movies and shows' : 'songs, albums, artists'
  const key = window.cascade.platform === 'darwin' ? '⌘K' : 'Ctrl+K'
  document.getElementById('search-input').placeholder = `Search ${what}… (${key})`
}

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
  setSearchPlaceholder(mode)
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
// setAlbumArtAccent, setLyricsTranslationEnabled) - there is nothing here that
// persists a setting on its own.

// 1: the original first-run-only wizard (b6).
// 2: re-shown to everyone upgrading, for video libraries, crossfade, the
//    streaming cap and album art accent - none of which an existing user had
//    ever been walked through.
// 3: lyric translation, whose models download from the internet on first use.
//    That is disclosed here before it can happen, not left to Settings.
// 4: Smooth skips, on the crossfade step, since some people want a skip to cut.
// 5 (not yet): opt-in telemetry. Its step stays filtered out while
//    CascadeCore.telemetryAvailable() is false; bump to 5 when switching it on.
const WIZARD_REVISION = 4

const FIRSTRUN_STEPS = ['libraries', 'crossfade', 'quality', 'theme', 'translation', 'telemetry']

// The revision each step arrived in. A fresh install walks every step; someone
// updating is shown only what is new since the revision they last finished, not
// four screens they have already been through for the sake of one new one.
const FIRSTRUN_STEP_REVISION = { libraries: 1, crossfade: 4, quality: 2, theme: 2, translation: 3, telemetry: 5 }
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

  _firstRunSteps = FIRSTRUN_STEPS.filter(s =>
    (s !== 'libraries' || _firstRunNeedsLibraryStep()) &&
    // Nothing streams in Local mode, so there is no bitrate to cap.
    (s !== 'quality' || !isLocalMode()) &&
    (s !== 'telemetry' || CascadeCore.telemetryAvailable()) &&
    (_wizardIsFirstRun || FIRSTRUN_STEP_REVISION[s] > seen))
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
    const skipToggle = /** @type {HTMLInputElement} */ (document.getElementById('fr-skip-transitions-toggle'))
    skipToggle.checked = displayPrefs.skipTransitions
  } else if (step === 'quality') {
    const i = Math.max(0, MAX_BITRATE_STEPS.findIndex(s => s.value === maxStreamingBitrate))
    document.getElementById('fr-max-bitrate').value = String(i)
    document.getElementById('fr-max-bitrate-value').textContent = MAX_BITRATE_STEPS[i].label
  } else if (step === 'theme') {
    const light = document.documentElement.getAttribute('data-theme') === 'light'
    document.getElementById('fr-seg-dark').classList.toggle('active', !light)
    document.getElementById('fr-seg-light').classList.toggle('active', light)
    document.getElementById('fr-toggle-album-art').checked = themeAlbumArt
  } else if (step === 'translation') {
    // Seeded from the live value only. Never write a default on entry: this
    // step is re-shown on update, and skipping it must change nothing.
    document.getElementById('fr-lyrics-translation-toggle').checked = lyricsTranslationEnabled
    document.getElementById('fr-apple-translation-note').style.display = _appleTranslationSupported ? '' : 'none'
  } else if (step === 'telemetry') {
    // Seeded from the live value: absent is off, and skipping leaves it off.
    document.getElementById('fr-telemetry-toggle').checked = telemetryOptIn
  }
}

/** `tour` is true only from Done: Skip means skip, tips included. */
async function _finishSetupWizard(tour) {
  await window.cascade.store.set('wizardSeenRevision', WIZARD_REVISION)
  // Kept in step so a downgrade to a build that only knows the boolean does not
  // greet an existing user with the wizard again.
  await window.cascade.store.set('firstRunWizardSeen', true)
  document.getElementById('firstrun-overlay').classList.add('hidden')
  if (tour === true && _wizardIsFirstRun) setTimeout(_startTipTour, 500)
}

document.getElementById('fr-next').addEventListener('click', () => {
  if (_firstRunIdx < _firstRunSteps.length - 1) { _firstRunIdx++; _renderSetupStep() }
  else _finishSetupWizard(true)
})
// Skippable at any point, not just from the last step - whatever was already
// changed on an earlier step already went through its real setter above and
// stays changed; whatever step was never reached just keeps today's default.
document.getElementById('fr-skip').addEventListener('click', _finishSetupWizard)

// Through Settings' own setter, as every step's controls are.
document.getElementById('fr-skip-transitions-toggle').addEventListener('change', e => setDisplayPref('skipTransitions', /** @type {HTMLInputElement} */ (e.target).checked))
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
document.getElementById('fr-lyrics-translation-toggle').addEventListener('change', e => setLyricsTranslationEnabled(e.target.checked))

// ── Telemetry ─────────────────────────────────────────────────────────────────
// Opt-in, off until the user says yes, and dormant in the build until
// CascadeCore.TELEMETRY_URL is set (src/core/telemetry.ts has the checklist).
// While dormant nothing here counts, stores or sends, and neither the wizard
// step nor the Settings row shows. The install id is its own random UUID,
// never deviceId, which the Jellyfin server already knows.

let telemetryOptIn = false

async function loadTelemetry() {
  telemetryOptIn = CascadeCore.telemetryAvailable() && (await window.cascade.store.get('telemetryOptIn')) === true
}

async function setTelemetryOptIn(on) {
  telemetryOptIn = on
  document.getElementById('fr-telemetry-toggle').checked = on
  document.getElementById('s-telemetry-toggle').checked = on
  await window.cascade.store.set('telemetryOptIn', on)
  if (on) {
    if (!await window.cascade.store.get('telemetryInstallId')) await window.cascade.store.set('telemetryInstallId', crypto.randomUUID())
    maybeSendTelemetry()
  } else {
    // Opting out forgets the install: opting back in later is a new one.
    for (const k of ['telemetryInstallId', 'telemetrySongs', 'telemetryLastSent']) await window.cascade.store.delete(k)
  }
}

async function countTelemetrySong() {
  if (!telemetryOptIn) return
  await window.cascade.store.set('telemetrySongs', (Number(await window.cascade.store.get('telemetrySongs')) || 0) + 1)
}

let _telemetrySending = false
async function maybeSendTelemetry() {
  if (!telemetryOptIn || _telemetrySending) return
  if (!CascadeCore.telemetryDue(await window.cascade.store.get('telemetryLastSent'), Date.now())) return
  const installId = await window.cascade.store.get('telemetryInstallId')
  if (typeof installId !== 'string') return
  _telemetrySending = true
  try {
    const ident = CascadeCore.clientIdentity()
    const ping = CascadeCore.telemetryPing(installId, appVersion, ident.client, ident.device, await window.cascade.store.get('telemetrySongs'))
    const res = await webFetch(CascadeCore.TELEMETRY_URL, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(ping),
    })
    if (!res.ok || !telemetryOptIn) return
    // Only what was sent comes off: songs that started mid-request stay counted.
    const left = (Number(await window.cascade.store.get('telemetrySongs')) || 0) - ping.songs
    await window.cascade.store.set('telemetrySongs', Math.max(0, left))
    await window.cascade.store.set('telemetryLastSent', Date.now())
  } catch {
    // Unreachable: tried again on the next song.
  } finally {
    _telemetrySending = false
  }
}

document.getElementById('fr-telemetry-toggle').addEventListener('change', e => setTelemetryOptIn(e.target.checked))
document.getElementById('s-telemetry-toggle').addEventListener('change', e => setTelemetryOptIn(e.target.checked))

/** `category` is 'movie' or 'show' - the two hardcoded video categories. */
async function applyVideoLibrarySelection(category, ids) {
  const key = category === 'movie' ? 'movieLibraryIds' : 'showLibraryIds'
  jf[key] = ids
  await window.cascade.store.set(key, JSON.stringify(ids))
  invalidateVideoViews()
  applyVideoNavVisibility()
  renderVideoLibraryPicker()
  loadContinueWatching()
}

document.getElementById('s-single-lib-toggle').addEventListener('change', async e => {
  singleLibraryMode = e.target.checked
  await window.cascade.store.set(libKey('singleLibraryMode'), singleLibraryMode)
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
// Keyboard: tabbing into the sidebar opens it so the labels are visible, and
// tabbing out closes it. :focus-visible keeps a mouse click (which also
// focuses the item) from re-expanding what showView() just collapsed.
sidenav.addEventListener('focusin', e => {
  if (!e.target.matches(':focus-visible')) return
  sidenav.classList.add('expanded')
  backdrop.classList.add('dim')
})
sidenav.addEventListener('focusout', e => {
  if (sidenav.contains(e.relatedTarget)) return
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
  // Both are position:fixed, so left open they'd float over whatever view
  // comes next instead of disappearing with the one that opened them -
  // found by screenshotting a navigation away from an open filter panel.
  libSortDropdown.classList.remove('open')
  libFilterDropdown.classList.remove('open')
  _currentView = name
  syncSearchPlacement()

  if (name === 'albums' && !document.getElementById('albums-grid').dataset.loaded) loadAlbums()
  if (name === 'artists' && !document.getElementById('artists-grid').dataset.loaded) loadArtists()
  if (name === 'songs' && !document.getElementById('songs-rows').dataset.loaded) loadSongs()
  if (name === 'playlists' && !document.getElementById('playlists-grid').dataset.loaded) loadPlaylists()
  if (name === 'genres' && !document.getElementById('genres-grid').dataset.loaded) loadGenres()
  // No dataset.loaded gate: history must reflect whatever was just played, so
  // it reloads every time it's shown rather than caching a stale fetch.
  if (name === 'history') loadHistory()
  if (name === 'downloads') renderDownloadsView()
  if (name === 'movies' && !document.getElementById('movies-grid').dataset.loaded) loadMovies()
  if (name === 'shows' && !document.getElementById('shows-grid').dataset.loaded) loadShows()
  if (name === 'radio' && !document.getElementById('radio-grid').dataset.loaded) loadRadio()
  if (name === 'settings') { loadSettingsFields(); _syncStyleEntries() }
}

// ── Settings categories ──────────────────────────────────────────────────────
// The bar across the top of Settings. Switching slides the panes by where the
// new category sits relative to the old: moving right, the old pane leaves to
// the left and the new one comes in from the right; moving left, the reverse.
// Click to switch. As a tablist, a focused tab also takes the arrow keys.
const _settingsTabs = [...document.querySelectorAll('#view-settings .sn-item')]
const _settingsPill = document.querySelector('#view-settings .sn-pill')
let _settingsTab = 0

function placeSettingsPill(animate) {
  const t = _settingsTabs[_settingsTab]
  if (!t.offsetWidth) return   // view hidden; the observer below places it on show
  if (!animate) _settingsPill.style.transition = 'none'
  _settingsPill.style.width = `${t.offsetWidth}px`
  _settingsPill.style.transform = `translateX(${t.offsetLeft}px)`
  if (!animate) { _settingsPill.offsetWidth; _settingsPill.style.transition = '' }
}

function showSettingsTab(i) {
  if (i < 0 || i >= _settingsTabs.length || i === _settingsTab) return
  const dir = i > _settingsTab ? 1 : -1
  const pane = n => document.getElementById(`section-${_settingsTabs[n].dataset.section}`)
  const from = pane(_settingsTab), to = pane(i)
  _settingsTabs.forEach((t, n) => {
    t.classList.toggle('active', n === i)
    t.setAttribute('aria-selected', String(n === i))
    t.tabIndex = n === i ? 0 : -1
  })
  _settingsTab = i
  placeSettingsPill(true)
  document.querySelector('#view-settings .settings-view').scrollTop = 0

  // A switch mid-slide snaps the running one to its end first.
  for (const el of [from, to]) el.getAnimations().forEach(a => a.finish())
  from.classList.remove('active')
  to.classList.add('active')
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return

  const timing = { duration: 320, easing: 'cubic-bezier(0.2, 0.8, 0.2, 1)' }
  from.classList.add('leaving')
  const out = from.animate([
    { transform: 'translateX(0)', opacity: 1 },
    { transform: `translateX(${-dir * 100}%)`, opacity: 0 },
  ], timing)
  out.onfinish = out.oncancel = () => from.classList.remove('leaving')
  to.animate([
    { transform: `translateX(${dir * 100}%)`, opacity: 0 },
    { transform: 'translateX(0)', opacity: 1 },
  ], timing)
}

_settingsTabs.forEach((t, i) => t.addEventListener('click', () => showSettingsTab(i)))
document.querySelector('#view-settings .sn-tabs').addEventListener('keydown', e => {
  const step = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0
  if (!step) return
  e.preventDefault()
  showSettingsTab(_settingsTab + step)
  _settingsTabs[_settingsTab].focus()
})
// Tab widths change when the view is first shown, the window resizes, or the
// font setting changes; the observer catches all three.
new ResizeObserver(() => placeSettingsPill(false)).observe(document.querySelector('#view-settings .sn-tabs'))

// Categories with an index/detail split - clicking the sidebar item again while
// already on that category clicks its own back button, which returns to the
// index. The back buttons are already idempotent (they just re-set the same
// display styles), so this is a no-op if you're already on the index.
const CATEGORY_BACK_BTN = {
  albums: 'album-back-btn',
  artists: 'artist-back-btn',
  playlists: 'pl-back-btn',
  genres: 'genre-back-btn',
  movies: 'movie-back-btn',
  shows: 'show-back-btn'
}

document.querySelectorAll('.nav-item[data-view]').forEach(el => {
  // The items are divs (their markup nests block children), so they get the
  // button semantics here rather than by changing the element.
  el.tabIndex = 0
  el.setAttribute('role', 'button')
  el.addEventListener('keydown', e => {
    if (e.key !== 'Enter' && e.key !== ' ') return
    e.preventDefault()
    el.click()
  })
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
  takeHistorySnapshot()
}

async function loadRecentlyPlayed() {
  const grid = document.getElementById('rp-grid')
  try {
    const data = await jfGetMerged(`/Items`, {
      SortBy: 'DatePlayed',
      SortOrder: 'Descending',
      IncludeItemTypes: 'Audio',
      Filters: 'IsPlayed',
      Limit: 24,
      Recursive: true,
      Fields: 'AlbumId,AlbumPrimaryImageTag,UserData'
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
      el.addEventListener('click', () => playItems(items, i, 'Recently played'))
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
    const data = await jfGetMerged(`/Items`, {
      SortBy: 'DateCreated',
      SortOrder: 'Descending',
      IncludeItemTypes: 'MusicAlbum',
      Limit: 24,
      Recursive: true
    })
    // Fetched wider than any row could show and clipped by CSS (.album-grid on
    // #home-recent-albums), so the row is always full at any window width.
    if (!data.Items?.length) { grid.innerHTML = '<div class="empty-state" style="grid-column:1/-1">No albums yet</div>'; return }
    grid.innerHTML = data.Items.map(item => albumCard(item)).join('')
    wireAlbumCards(grid, data.Items, item => { showView('albums'); openAlbum(item.Id) })
  } catch (e) {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">Could not load albums</div>`
  }
}

// ── Albums ────────────────────────────────────────────────────────────────────

// Fetch items across all selected libraries and merge, deduplicating by Id.
// `getAllPaged` is the same thing but keeps paging past params.Limit.
const jfGetMerged   = (path, params = {}) => jfClient.getMerged(path, params)
const jfGetAllPaged = (path, params = {}) => jfClient.getAllPaged(path, params)
const bySortName = (a, b) => (a.SortName || a.Name || '').localeCompare(b.SortName || b.Name || '')

// ── Library sort & filter (Albums, Artists, Playlists, Movies, TV Shows) ─────
//
// Songs already has its own sort control (loadSongsSortPrefs/updateSongsSortUI
// below); this is the same idea generalized to every other grid, sharing ONE
// dropdown pair instead of one per view. Only one of these grids is ever
// visible at a time (showView hides the rest), and .ov-dropdown already
// repositions itself from the clicked button's rect on every open, so nothing
// about the shared elements needs to be view-specific - just their contents,
// rebuilt from whichever view's button was last clicked.
//
// Each view calls setLibItems() with its raw fetch (already sorted server-side
// A-Z, same as before) whenever it loads or the library selection changes;
// sort/filter changes then only ever re-render that cached fetch, never
// refetch - the whole point, per the brief, is that the full list is already
// in memory.
const libSortDropdown   = document.getElementById('lib-sort-dropdown')
const libFilterDropdown = document.getElementById('lib-filter-dropdown')
let _libDropdownView = null   // which view's button opened whichever dropdown is currently open

const LIB_VIEWS = {}

/** `fields`: field -> menu label, in menu order. `hasGenre`/`hasDecade`/
 *  `hasPlayed` pick which filter rows the view offers - a playlist has no
 *  genre or year, a song library has no played/unplayed. `render(items,
 *  prefs)` gets the RAW fetch (flat array, or for a grouped video grid the
 *  raw {grouped, groups} shape) plus the current prefs, and is responsible
 *  for filtering/sorting and drawing - kept in the view's own code since a
 *  grouped grid must filter/sort each library's group separately rather than
 *  as one merged list. */
function registerLibView(name, opts) {
  LIB_VIEWS[name] = { rawItems: [], prefs: null, ...opts }
}

async function loadLibPrefs(name) {
  const v = LIB_VIEWS[name]
  const raw = await window.cascade.store.get(`${name}Prefs`)
  v.prefs = CascadeCore.normalizeLibraryPrefs(raw, Object.keys(v.fields))
}

function saveLibPrefs(name) {
  window.cascade.store.set(`${name}Prefs`, JSON.stringify(LIB_VIEWS[name].prefs))
}

/** The one path a fresh fetch and a library-selection change both go through. */
function setLibItems(name, items) {
  LIB_VIEWS[name].rawItems = items
  rerenderLibView(name)
}

function rerenderLibView(name) {
  const v = LIB_VIEWS[name]
  if (!v.prefs) return   // prefs load in flight; setLibItems runs again once loadLibPrefs resolves
  v.render(v.rawItems, v.prefs)
  updateLibButtons(name)
}

function updateLibButtons(name) {
  const v = LIB_VIEWS[name]
  const sortBtn = document.querySelector(`.lib-sort-btn[data-lib-view="${name}"] .lib-sort-label`)
  if (sortBtn) sortBtn.textContent = v.fields[v.prefs.field]
  const active = v.prefs.favorite || !!v.prefs.genre || v.prefs.decade != null || !!v.prefs.played
  document.querySelector(`.lib-filter-btn[data-lib-view="${name}"]`)?.classList.toggle('active', active)
}

/** Positions any .ov-dropdown just under `btn`, clamped to the viewport - the
 *  same math #songs-sort-dropdown uses inline, pulled out here because six
 *  more buttons across five views now share it. */
function positionOvDropdown(dropdown, btn) {
  const r = btn.getBoundingClientRect()
  dropdown.style.left = `${r.left}px`
  dropdown.style.top = `${r.bottom + 6}px`
  const dr = dropdown.getBoundingClientRect()
  if (dr.right > window.innerWidth - 8) dropdown.style.left = `${window.innerWidth - dropdown.offsetWidth - 8}px`
  if (dr.bottom > window.innerHeight - 8) dropdown.style.top = `${r.top - dropdown.offsetHeight - 6}px`
}

function openLibSortDropdown(name, btn) {
  const v = LIB_VIEWS[name]
  _libDropdownView = name
  libSortDropdown.innerHTML = Object.entries(v.fields).map(([field, label]) =>
    `<button class="ov-dd-item${field === v.prefs.field ? ' active' : ''}" data-lib-sort-field="${field}"><span class="dd-check"></span>${esc(label)}</button>`
  ).join('') + `<div class="ov-dd-sep"></div>
    <button class="ov-dd-item" data-lib-sort-dir-toggle>
      <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="transform:${v.prefs.dir === 'desc' ? 'rotate(180deg)' : ''}"><path d="M12 19V5M5 12l7-7 7 7"/></svg>
      <span>${v.prefs.dir === 'desc' ? 'Descending' : 'Ascending'}</span>
    </button>`
  positionOvDropdown(libSortDropdown, btn)
  libSortDropdown.classList.add('open')
}

function libOptionHtml(value, label, selected) {
  return `<option value="${esc(String(value))}"${selected ? ' selected' : ''}>${esc(label)}</option>`
}

function openLibFilterDropdown(name, btn) {
  const v = LIB_VIEWS[name]
  _libDropdownView = name
  const opts = CascadeCore.libraryFilterOptions(v.rawItems.groups
    ? v.rawItems.groups.flatMap(g => g.items) : v.rawItems)
  // An active genre/decade must survive even if the currently loaded items no
  // longer include it (the library selection just changed) - otherwise there
  // would be no way to clear it back out of the dropdown.
  const genres  = v.prefs.genre && !opts.genres.includes(v.prefs.genre) ? [v.prefs.genre, ...opts.genres] : opts.genres
  const decades = v.prefs.decade != null && !opts.decades.includes(v.prefs.decade) ? [v.prefs.decade, ...opts.decades] : opts.decades

  const rows = [`<div class="lib-check-row">
    <span class="lib-check-label">Favorites only</span>
    <label class="toggle"><input type="checkbox" id="lib-filter-favorite"${v.prefs.favorite ? ' checked' : ''}><span class="toggle-track"></span></label>
  </div>`]
  if (v.hasGenre) rows.push(`<div class="lib-filter-label">Genre</div>
    <select class="setting-input" id="lib-filter-genre" style="width:100%">
      ${libOptionHtml('', 'All genres', !v.prefs.genre)}
      ${genres.map(g => libOptionHtml(g, g, g === v.prefs.genre)).join('')}
    </select>`)
  if (v.hasDecade) rows.push(`<div class="lib-filter-label">Decade</div>
    <select class="setting-input" id="lib-filter-decade" style="width:100%">
      ${libOptionHtml('', 'All years', v.prefs.decade == null)}
      ${decades.map(d => libOptionHtml(d, `${d}s`, d === v.prefs.decade)).join('')}
    </select>`)
  if (v.hasPlayed) rows.push(`<div class="lib-filter-label">Played</div>
    <select class="setting-input" id="lib-filter-played" style="width:100%">
      ${libOptionHtml('', 'Any', !v.prefs.played)}
      ${libOptionHtml('unplayed', 'Unplayed', v.prefs.played === 'unplayed')}
      ${libOptionHtml('played', 'Played', v.prefs.played === 'played')}
    </select>`)
  rows.push(`<div class="ov-dd-sep"></div><button class="ov-dd-item" id="lib-filter-clear">Clear filters</button>`)
  libFilterDropdown.innerHTML = `<div class="lib-filter-panel">${rows.join('')}</div>`

  document.getElementById('lib-filter-favorite').addEventListener('change', e => {
    v.prefs.favorite = e.target.checked
    saveLibPrefs(name); rerenderLibView(name)
  })
  document.getElementById('lib-filter-genre')?.addEventListener('change', e => {
    v.prefs.genre = e.target.value || null
    saveLibPrefs(name); rerenderLibView(name)
  })
  document.getElementById('lib-filter-decade')?.addEventListener('change', e => {
    const n = Number(e.target.value)
    v.prefs.decade = e.target.value !== '' && Number.isFinite(n) ? n : null
    saveLibPrefs(name); rerenderLibView(name)
  })
  document.getElementById('lib-filter-played')?.addEventListener('change', e => {
    v.prefs.played = e.target.value || null
    saveLibPrefs(name); rerenderLibView(name)
  })
  document.getElementById('lib-filter-clear').addEventListener('click', () => {
    Object.assign(v.prefs, { favorite: false, genre: null, decade: null, played: null })
    saveLibPrefs(name); rerenderLibView(name)
    openLibFilterDropdown(name, btn)   // rebuild with the cleared state, stays open
  })

  positionOvDropdown(libFilterDropdown, btn)
  libFilterDropdown.classList.add('open')
}

document.querySelectorAll('.lib-sort-btn').forEach(btn => {
  btn.addEventListener('click', (e) => {
    e.stopPropagation()
    const name = btn.dataset.libView
    const wasOpen = libSortDropdown.classList.contains('open') && _libDropdownView === name
    libFilterDropdown.classList.remove('open')
    libSortDropdown.classList.toggle('open', !wasOpen)
    if (!wasOpen) openLibSortDropdown(name, btn)
  })
})

document.querySelectorAll('.lib-filter-btn').forEach(btn => {
  btn.addEventListener('click', (e) => {
    e.stopPropagation()
    const name = btn.dataset.libView
    const wasOpen = libFilterDropdown.classList.contains('open') && _libDropdownView === name
    libSortDropdown.classList.remove('open')
    libFilterDropdown.classList.toggle('open', !wasOpen)
    if (!wasOpen) openLibFilterDropdown(name, btn)
  })
})

libSortDropdown.addEventListener('click', (e) => {
  e.stopPropagation()
  const name = _libDropdownView
  if (!name) return
  const v = LIB_VIEWS[name]
  const btn = document.querySelector(`.lib-sort-btn[data-lib-view="${name}"]`)
  const fieldBtn = e.target.closest('[data-lib-sort-field]')
  if (fieldBtn) {
    v.prefs.field = fieldBtn.dataset.libSortField
    saveLibPrefs(name); rerenderLibView(name)
    openLibSortDropdown(name, btn)
    return
  }
  if (e.target.closest('[data-lib-sort-dir-toggle]')) {
    v.prefs.dir = v.prefs.dir === 'desc' ? 'asc' : 'desc'
    saveLibPrefs(name); rerenderLibView(name)
    openLibSortDropdown(name, btn)
  }
})

document.addEventListener('mousedown', (e) => {
  if (!libSortDropdown.contains(e.target) && !e.target.closest('.lib-sort-btn')) libSortDropdown.classList.remove('open')
  if (!libFilterDropdown.contains(e.target) && !e.target.closest('.lib-filter-btn')) libFilterDropdown.classList.remove('open')
})

// No "Recently played" here: checked against the test server, and a
// MusicAlbum's own UserData.LastPlayedDate never gets set even after its
// tracks are marked played (Played stays false, PlayCount stays 0 - Jellyfin
// does not roll play state up from tracks to the album). Offering that sort
// would silently do nothing (every album ties at 0, falling back to the name
// tiebreak), so it's left out rather than shipped as a dead menu item.
registerLibView('albums', {
  fields: { name: 'Name', artist: 'Artist', year: 'Year', added: 'Date added', random: 'Random' },
  hasGenre: true, hasDecade: true, hasPlayed: false,
  render(items, prefs) {
    const grid = document.getElementById('albums-grid')
    if (!items.length) { grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">No albums found</div>`; return }
    const shown = CascadeCore.sortLibraryItems(CascadeCore.filterLibraryItems(items, prefs), prefs.field, prefs.dir)
    if (!shown.length) { grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">No albums match these filters</div>`; return }
    grid.innerHTML = shown.map(item => albumCard(item)).join('')
    wireAlbumCards(grid, shown, item => { showView('albums'); openAlbum(item.Id) })
  }
})

async function loadAlbums() {
  const grid = document.getElementById('albums-grid')
  grid.dataset.loaded = '1'
  await loadLibPrefs('albums')
  try {
    const params = { SortBy: 'SortName', SortOrder: 'Ascending', IncludeItemTypes: 'MusicAlbum', Recursive: true, Fields: 'SortName,Genres,ProductionYear,UserData', Limit: 500 }
    const data = await jfGetAllPaged(`/Items`, params)
    data.Items.sort(bySortName)   // the merge only kept SortBy within each library
    setLibItems('albums', data.Items)
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

/** Wires an .album-card grid's click and right-click, matching each card back
 *  to `items` by id (data-id or, from search, data-search-album) - same
 *  by-id-map shape as wirePosterCards below, needed since a grid can be
 *  rebuilt with a different item list between calls. */
function wireAlbumCards(container, items, onPick) {
  const byId = new Map(items.map(i => [i.Id, i]))
  container.querySelectorAll('.album-card').forEach(el => {
    const item = byId.get(el.dataset.id || el.dataset.searchAlbum)
    if (!item) return
    el.addEventListener('click', () => onPick(item))
    el.addEventListener('contextmenu', e => { e.preventDefault(); showItemCtxMenu('album', item, el, e.clientX, e.clientY) })
  })
}

/** Same for .artist-card grids. */
function wireArtistCards(container, items, onPick) {
  const byId = new Map(items.map(i => [i.Id, i]))
  container.querySelectorAll('.artist-card').forEach(el => {
    const item = byId.get(el.dataset.id || el.dataset.searchArtist)
    if (!item) return
    el.addEventListener('click', () => onPick(item))
    el.addEventListener('contextmenu', e => { e.preventDefault(); showItemCtxMenu('artist', item, el, e.clientX, e.clientY, onPick) })
  })
}

let currentAlbumTracks = []
let _openAlbumItem = null   // the album page's own item, for its Download button

/** Track query shared by the album detail view and the album context menu's
 *  Play/Play next/Play last/Shuffle/Add to playlist actions. */
async function fetchAlbumTracks(albumId) {
  const data = await jfGet(`/Items`, {
    ParentId: albumId,
    SortBy: 'ParentIndexNumber,IndexNumber,SortName',
    IncludeItemTypes: 'Audio',
    Recursive: true,
    Fields: 'AlbumId,AlbumPrimaryImageTag'
  })
  return data.Items || []
}

async function openAlbum(albumId) {
  document.getElementById('albums-index').style.display = 'none'
  const detail = document.getElementById('album-detail')
  detail.style.display = ''
  document.getElementById('album-detail-name').textContent = ''
  document.getElementById('album-detail-meta').innerHTML = '<span class="skel skel-text" style="display:inline-block;width:120px"></span>'
  document.getElementById('album-detail-rows').innerHTML = skeletonHTML('track', 6)
  document.getElementById('album-detail-art').innerHTML = '♪'

  try {
    const [album, tracks] = await Promise.all([
      jfGet(`/Items/${albumId}`),
      fetchAlbumTracks(albumId)
    ])
    currentAlbumTracks = tracks
    _openAlbumItem = album
    renderOfflineButtons()

    document.getElementById('album-detail-name').textContent = album.Name || ''
    const artistHtml = album.AlbumArtist
      ? `<span class="row-link" data-artist-link="${esc(album.AlbumArtist)}" tabindex="0">${esc(album.AlbumArtist)}</span>`
      : ''
    const meta = [artistHtml, album.ProductionYear, `${tracks.length} song${tracks.length !== 1 ? 's' : ''}`].filter(Boolean)
    document.getElementById('album-detail-meta').innerHTML = meta.join(' · ')

    const art = artUrl(album.Id, album.ImageTags?.Primary)
    document.getElementById('album-detail-art').innerHTML = art ? `<img src="${art}" alt="" onerror="this.innerHTML='♪'">` : '♪'

    // albumArtist: drop the per-row thumbnail and Album cell and show an artist
    // only when it differs from the album's (features, compilations).
    const rowOpts = { albumArtist: album.AlbumArtist || '' }
    document.getElementById('album-detail-rows').innerHTML = tracks.map((item, i) => trackRowHtml(item, i, rowOpts)).join('')
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
document.getElementById('btn-shuffle-album').addEventListener('click', () => {
  shuffleAndPlay(currentAlbumTracks, document.getElementById('album-detail-name').textContent)
})

// ── Artists ───────────────────────────────────────────────────────────────────

// No genre/year fields here: Jellyfin doesn't populate those on the artist
// item itself (they live on the album/track), so offering that filter would
// just show an empty list. Favorites still works - IsFavorite is a real
// per-artist UserData flag.
registerLibView('artists', {
  fields: { name: 'Name', added: 'Date added', random: 'Random' },
  hasGenre: false, hasDecade: false, hasPlayed: false,
  render(items, prefs) {
    const grid = document.getElementById('artists-grid')
    if (!items.length) { grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">No artists found</div>`; return }
    const shown = CascadeCore.sortLibraryItems(CascadeCore.filterLibraryItems(items, prefs), prefs.field, prefs.dir)
    if (!shown.length) { grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">No artists match these filters</div>`; return }
    grid.innerHTML = shown.map(item => artistCardHtml(item)).join('')
    wireArtistCards(grid, shown, item => openArtist(item.Id, item.Name))
  }
})

async function loadArtists() {
  const grid = document.getElementById('artists-grid')
  grid.dataset.loaded = '1'
  await loadLibPrefs('artists')
  try {
    const params = { UserId: jf.userId, SortBy: 'SortName', SortOrder: 'Ascending', Fields: 'SortName,DateCreated,UserData', Limit: 500 }
    const data = await jfGetAllPaged(`/Artists`, params)
    data.Items.sort(bySortName)   // the merge only kept SortBy within each library
    setLibItems('artists', data.Items)
  } catch (e) {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">Could not load artists</div>`
  }
}

/** Songs query shared by the artist detail view and the artist context menu's
 *  Play all/Shuffle all actions. */
// The artist page and "play artist" go through the library-aware merge like
// every other view: a plain get ignored the library selection and listed an
// album or song once per library that held it.
async function fetchArtistSongs(artistId) {
  const data = await jfGetMerged(`/Items`, {
    ArtistIds: artistId, IncludeItemTypes: 'Audio', Recursive: true,
    SortBy: 'Album,ParentIndexNumber,IndexNumber',
    Fields: 'AlbumId,AlbumPrimaryImageTag'
  })
  // Merged results arrive library by library; SortBy only held within each.
  return (data.Items || []).sort((a, b) =>
    (a.Album || '').localeCompare(b.Album || '') ||
    (a.ParentIndexNumber ?? 0) - (b.ParentIndexNumber ?? 0) ||
    (a.IndexNumber ?? 0) - (b.IndexNumber ?? 0))
}

/** Overview is empty for most fake/untagged artists and for any artist
 *  Jellyfin hasn't matched against MusicBrainz/TheAudioDB (needs the server
 *  online). Hides the whole section rather than showing an empty card - an
 *  artist with no bio should look like it simply has no bio section, not like
 *  a broken box. */
function renderArtistBio(overview) {
  const section = document.getElementById('artist-bio-section')
  const text = document.getElementById('artist-bio-text')
  const more = document.getElementById('artist-bio-more')
  const trimmed = (overview || '').trim()
  if (!trimmed) { section.style.display = 'none'; return }
  section.style.display = ''
  text.textContent = trimmed
  text.classList.remove('expanded')
  // scrollHeight > clientHeight only once the clamp has actually cut something -
  // checked after the text is in the DOM so the clamped height is real, not the
  // pre-layout 0 a synchronous check right after assignment would read.
  requestAnimationFrame(() => {
    more.style.display = text.scrollHeight > text.clientHeight + 1 ? '' : 'none'
  })
  more.textContent = 'More'
  more.onclick = () => {
    const expanded = text.classList.toggle('expanded')
    more.textContent = expanded ? 'Less' : 'More'
  }
}

/** Scoped to the user's libraries the same way every other artist/album query
 *  here is: passing UserId is what makes Jellyfin filter results (and attach
 *  UserData) to what that user can actually see. Hidden entirely when there is
 *  nothing similar, rather than an empty "Similar Artists" heading over nothing. */
async function fetchSimilarArtists(artistId) {
  try {
    const [data, libArtists] = await Promise.all([
      jfGet(`/Artists/${artistId}/Similar`, { UserId: jf.userId, Limit: 24 }),
      // /Artists/{id}/Similar has no library-scoping parameter of its own
      // (checked the OpenAPI spec: UserId there only applies server-side
      // permissions, not Cascade's own library selection). The same merged
      // /Artists call loadArtists uses is what actually knows which artists
      // are in the libraries this user picked in Cascade, so intersecting
      // with it is what "scoped to the user's libraries" has to mean here.
      jfGetAllPaged(`/Artists`, { UserId: jf.userId, Limit: 500 })
    ])
    const libIds = new Set((libArtists.Items || []).map(a => a.Id))
    return (data.Items || []).filter(a => libIds.has(a.Id)).slice(0, 12)
  } catch (e) {
    return []
  }
}

function renderSimilarArtists(items) {
  const section = document.getElementById('artist-similar-section')
  const grid = document.getElementById('artist-similar-grid')
  if (!items.length) { section.style.display = 'none'; grid.innerHTML = ''; return }
  section.style.display = ''
  grid.innerHTML = items.map(item => artistCardHtml(item)).join('')
  wireArtistCards(grid, items, item => openArtist(item.Id, item.Name))
}

async function openArtist(artistId, name) {
  // A similar-artist click from further down the page must not leave the new
  // artist's page scrolled to wherever the old one was.
  document.getElementById('view-artists').scrollTop = 0
  document.getElementById('artist-index').style.display = 'none'
  const detail = document.getElementById('artist-detail')
  detail.style.display = ''
  document.getElementById('artist-detail-name').textContent = name
  document.getElementById('artist-detail-meta').innerHTML = '<span class="skel skel-text" style="display:inline-block;width:120px"></span>'
  document.getElementById('artist-bio-section').style.display = 'none'
  document.getElementById('artist-top-songs-section').style.display = 'none'
  document.getElementById('artist-similar-section').style.display = 'none'
  document.getElementById('artist-albums-grid').innerHTML = skeletonHTML('album', 6)
  document.getElementById('artist-songs-rows').innerHTML = skeletonHTML('track', 6)

  const art = artistArtUrl(artistId)
  // Falls back to the note glyph on a 404 - onerror fires on the <img> itself,
  // which has no children, so the glyph has to replace it via the parent.
  document.getElementById('artist-detail-art').innerHTML = `<img src="${art}" alt="" onerror="this.parentNode.innerHTML='♪'" style="width:100%;height:100%;object-fit:cover;border-radius:50%">`

  try {
    const [artistItem, albumsData, songs, similar] = await Promise.all([
      jfGet(`/Items/${artistId}`, { Fields: 'Overview' }).catch(() => null),
      jfGetMerged(`/Items`, {
        ArtistIds: artistId, IncludeItemTypes: 'MusicAlbum', Recursive: true,
        SortBy: 'ProductionYear,SortName', SortOrder: 'Descending'
      }),
      fetchArtistSongs(artistId),
      fetchSimilarArtists(artistId)
    ])

    renderArtistBio(artistItem?.Overview)

    // Newest first, as SortBy asked; the merge only kept that within each library.
    const albums = (albumsData.Items || []).sort((a, b) =>
      (b.ProductionYear ?? 0) - (a.ProductionYear ?? 0) || (a.SortName || a.Name || '').localeCompare(b.SortName || b.Name || ''))

    document.getElementById('artist-detail-meta').textContent =
      `${albums.length} album${albums.length !== 1 ? 's' : ''} · ${songs.length} song${songs.length !== 1 ? 's' : ''}`

    // Albums grid
    document.getElementById('artist-albums-grid').innerHTML = albums.map(item => albumCard(item)).join('')
    wireAlbumCards(document.getElementById('artist-albums-grid'), albums, item => { showView('albums'); openAlbum(item.Id) })

    // Play all button
    document.getElementById('btn-play-artist-discography').onclick = () => {
      if (songs.length) playItems(songs, 0, document.getElementById('artist-detail-name').textContent)
    }

    // Top songs shelf - a ranked subset of the same songs, not a separate fetch.
    const topSongs = CascadeCore.topSongsOf(songs)
    const topSection = document.getElementById('artist-top-songs-section')
    if (topSongs.length) {
      topSection.style.display = ''
      const topRows = document.getElementById('artist-top-songs-rows')
      topRows.innerHTML = topSongs.map((item, i) => trackRowHtml(item, i)).join('')
      highlightPlayingRow()
      topRows.querySelectorAll('.track-row').forEach(el => {
        const idx = parseInt(el.dataset.idx)
        wireTrackRow(el, topSongs[idx], topSongs, idx, { source: document.getElementById('artist-detail-name').textContent })
      })
    } else {
      topSection.style.display = 'none'
    }

    renderSimilarArtists(similar)

    // Songs list
    document.getElementById('artist-songs-rows').innerHTML = songs.map((item, i) => trackRowHtml(item, i)).join('')
    highlightPlayingRow()

    document.getElementById('artist-songs-rows').querySelectorAll('.track-row').forEach(el => {
      const idx = parseInt(el.dataset.idx)
      wireTrackRow(el, songs[idx], songs, idx, { source: document.getElementById('artist-detail-name').textContent })
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
  return `<div class="track-thumb">${img}<span class="track-eq">${'<i></i>'.repeat(CascadeCore.EQ_BARS)}</span></div>`
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
  const onAlbumPage  = opts.albumArtist != null
  // Album page: only a differing artist is shown, as plain text (the link
  // opens the album artist, which would not be the name on screen).
  const featured     = (item.Artists || []).join(', ')
  const artistName  = onAlbumPage ? (featured && featured !== opts.albumArtist ? featured : '') : (item.AlbumArtist || item.Artists?.[0] || '')
  const artistCls    = artistName && !onAlbumPage ? ' row-link' : ''
  const artistAttrs  = artistName && !onAlbumPage ? ' data-artist-link tabindex="0"' : ''
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
    ${trackThumbHtml(onAlbumPage ? '' : art)}
    <div style="min-width:0">
      <div class="track-title">${esc(item.Name)}${explicitBadgeHtml(item.Id)}</div>
      ${onAlbumPage && !artistName ? '' : `<div class="track-artist${artistCls}"${artistAttrs}>${esc(artistName)}</div>`}
    </div>
    ${onAlbumPage ? '' : `<div class="track-album-name${albumCls}"${albumAttrs}>${esc(item.Album || '')}</div>`}
    ${extraHtml}
    <div class="track-dur">${fmtTime((item.RunTimeTicks || 0) / 10000000)}</div>
  </div>`
}

// ── Songs ─────────────────────────────────────────────────────────────────────

let allSongs = []
let _songsFetch = null

// The one fetch behind both the Songs table and Shuffle All. They used to fetch
// separately and race: Shuffle All's copy had no DateCreated and was never
// sorted, so clicking it before the table loaded could leave the table in
// server (title) order under a "Date Added" label. A second caller now waits
// on the fetch already in flight instead of starting its own.
function fetchAllSongs() {
  if (_songsFetch) return _songsFetch
  const p = _songsFetch = (async () => {
    await loadSongsSortPrefs()
    // jfGetAllPaged instead of jfGetMerged so libraries over 500 tracks aren't
    // silently truncated.
    const params = { SortBy: 'SortName', SortOrder: 'Ascending', IncludeItemTypes: 'Audio', Recursive: true, Fields: 'AlbumId,AlbumPrimaryImageTag,UserData,DateCreated', Limit: 500 }
    const data = await jfGetAllPaged(`/Items`, params)
    // The library selection changed mid-fetch: these are the old libraries' songs.
    if (_songsFetch !== p) return
    allSongs = data.Items || []
    sortAllSongs()
  })()
  p.catch(() => { if (_songsFetch === p) _songsFetch = null })   // let the next call retry
  return p
}

async function loadSongs() {
  const rows = document.getElementById('songs-rows')
  rows.dataset.loaded = '1'
  await loadSongsSortPrefs()
  updateSongsSortUI()
  try {
    await fetchAllSongs()
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
        playItems(allSongs, idx, 'Songs')
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
      playItems(allSongs, parseInt(el.dataset.idx), 'Songs')
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

function playlistCardHtml(item) {
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
}

// Sort/filter only - the playlist views themselves (rule builder, editing)
// are the artists agent's item, per the overnight brief's ownership table.
// Smart cards (Favorites, Most Played) always stay pinned first: they are
// generated, not part of the sorted/filtered set.
// The generated cards (built-ins, then the user's own rule-based ones) always
// lead the grid and sit outside the sort/filter, which only applies to real
// playlists.
const allSmartPlaylistCardsHtml = () =>
  smartPlaylistCardHtml('favorites') + smartPlaylistCardHtml('most-played') +
  userSmartPlaylists.map(userSmartPlaylistCardHtml).join('')

registerLibView('playlists', {
  fields: { name: 'Name', added: 'Date added', count: 'Song count' },
  hasGenre: false, hasDecade: false, hasPlayed: false,
  render(items, prefs) {
    const grid = document.getElementById('playlists-grid')
    const smartHtml = allSmartPlaylistCardsHtml()
    const shown = CascadeCore.sortLibraryItems(CascadeCore.filterLibraryItems(items, prefs), prefs.field, prefs.dir)
    const emptyHtml = !shown.length && items.length
      ? `<div class="empty-state" style="grid-column:1/-1">No playlists match these filters</div>` : ''
    grid.innerHTML = smartHtml + shown.map(playlistCardHtml).join('') + emptyHtml
    wirePlaylistCards(grid)
    wireSmartPlaylistCards(grid)
  }
})

async function loadPlaylists() {
  const grid = document.getElementById('playlists-grid')
  grid.dataset.loaded = '1'
  await Promise.all([loadUserSmartPlaylists(), loadLibPrefs('playlists')])
  try {
    const data = await jfGet(`/Items`, {
      SortBy: 'SortName',
      SortOrder: 'Ascending',
      IncludeItemTypes: 'Playlist',
      Recursive: true,
      Fields: 'ChildCount,DateCreated,UserData'
    })
    setLibItems('playlists', data.Items || [])
  } catch (e) {
    const smartHtml = allSmartPlaylistCardsHtml()
    grid.innerHTML = smartHtml + `<div class="empty-state" style="grid-column:1/-1">Could not load playlists</div>`
    wireSmartPlaylistCards(grid)
  }
}

/** Real (non-smart) playlist cards: click opens it, right-click offers
 *  Play/Shuffle/Rename/Delete via the shared item context menu. */
function wirePlaylistCards(grid) {
  grid.querySelectorAll('.playlist-card[data-id]').forEach(el => {
    const item = { Id: el.dataset.id, Name: el.dataset.name }
    el.addEventListener('click', () => openPlaylist(item.Id, item.Name))
    el.addEventListener('contextmenu', e => { e.preventDefault(); showItemCtxMenu('playlist', item, el, e.clientX, e.clientY) })
  })
}

/** Favorites/Most Played/user smart playlists: click opens it, right-click
 *  offers Play/Shuffle (built-ins) or Play/Shuffle/Edit rules/Delete (a user
 *  definition - it's only ever local storage, so there is always something to
 *  edit or delete, unlike a real playlist's ownership-gated delete). */
function wireSmartPlaylistCards(grid) {
  grid.querySelectorAll('[data-smart]').forEach(el => {
    el.addEventListener('click', () => openSmartPlaylist(el.dataset.smart))
    el.addEventListener('contextmenu', e => {
      e.preventDefault()
      const sp = smartPlaylistEntry(el.dataset.smart)
      if (!sp) return
      const kind = sp.isUser ? 'user-smart-playlist' : 'smart-playlist'
      showItemCtxMenu(kind, { smartKind: el.dataset.smart, Name: sp.name }, el, e.clientX, e.clientY)
    })
  })
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

/** Items query shared by the playlist detail view, its refresh, and the
 *  playlist context menu's Play/Shuffle actions. */
async function fetchPlaylistTracks(playlistId) {
  const data = await jfGet(`/Playlists/${playlistId}/Items`, {
    UserId: jf.userId,
    Fields: 'AlbumId,AlbumPrimaryImageTag,DateCreated'
  })
  return data.Items || []
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
      const sp = smartPlaylistEntry(currentSmartKind)
      renderPlaylistDetailItems(sp ? await sp.fetch() : [], false)
    } else {
      renderPlaylistDetailItems(await fetchPlaylistTracks(currentPlaylistId), true)
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
  stopPlaylistDetailsEdit()
  if (!silent && wasActive) renderPlaylistDetailItems(currentPlaylistItems, !!currentPlaylistId)
}

document.getElementById('btn-edit-playlist').addEventListener('click', async () => {
  if (plEditMode) { exitPlEditMode(); return }
  // A user smart playlist repurposes this same button for its rule editor -
  // guarded here too, not just by the button's visibility, since a disabled-
  // looking element can still be triggered programmatically.
  if (currentSmartKind) {
    const sp = smartPlaylistEntry(currentSmartKind)
    if (sp?.isUser) openSmartPlaylistEditor(sp.def)
    return
  }
  if (!currentPlaylistId) return // built-in smart playlists hide this button; nothing to edit
  // Ownership: Jellyfin has no dedicated "do you own this playlist" field, but
  // item DTOs carry CanDelete - the same permission Jellyfin itself uses to
  // gate deleting/managing an item, computed server-side for the current user.
  // An explicit false is trusted and blocks entry. Anything else (true, or
  // missing on an older server) offers Edit mode anyway; a write it isn't
  // allowed to make then fails loudly via the catch blocks below, same as
  // remove-from-playlist and drag-reorder already do for every playlist today.
  try {
    const it = await jfGet(`/Items/${currentPlaylistId}`, { Fields: 'Overview' })
    if (it.CanDelete === false) {
      showNotice(isLocalMode() ? LOCAL_M3U_READ_ONLY : 'You do not have permission to edit this playlist.', 'Playlist')
      return
    }
    plCurrentIsPublic = !!it.IsPublic
    enterPlEditMode()
    startPlaylistDetailsEdit(it)
  } catch (e) {
    plCurrentIsPublic = false
    enterPlEditMode()
    startPlaylistDetailsEdit(null)
  }
})

document.getElementById('pl-select-all').addEventListener('change', (e) => {
  if (e.target.checked) currentPlaylistItems.forEach(i => plEditSelected.add(entryIdOf(i)))
  else plEditSelected.clear()
  renderPlaylistDetailItems(currentPlaylistItems, true)
  updatePlEditToolbar()
})

// Every write to a playlist waits here first, so Jellyfin's background
// playlist.xml saver cannot undo it (see createPlaylistWriteGate).
const waitForPlaylistWrite = CascadeCore.createPlaylistWriteGate()

// Rewrites Ids wholesale (one atomic request) rather than firing per-row
// Move/DELETE calls. Built from currentPlaylistItems after applying the change
// locally, then playlistMutated() re-reads from the server so the view and
// currentPlaylistItems never disagree with what actually saved.
async function savePlaylistIds(newItems, successMsg) {
  try {
    await waitForPlaylistWrite(currentPlaylistId)
    const res = await jfFetch(`${jf.url}/Playlists/${currentPlaylistId}`, {
      method: 'POST',
      headers: CascadeCore.authHeaders(jf, { 'Content-Type': 'application/json' }),
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

// ── Playlist details, edited in place ───────────────────────────────────────
// In Edit mode the header is the editor: the name is a text field, a
// description field shows under it, the cover offers Change and Remove
// picture on hover, and a Public switch sits in the edit toolbar. Each saves
// on its own as soon as it is changed (the name and description when you
// leave them). Name and public go through Jellyfin's own POST /Playlists/{id},
// which the owner may use. Picture and description cannot: Jellyfin requires
// an admin for both (POST /Items/{id}/Images/Primary and POST /Items/{id}), so
// they go through Cascade Server's playlist-edit routes when it offers them,
// which let the owner do it, and Jellyfin's routes for an admin otherwise.
// With neither, those two stay out of the editor and the cover says why. See
// CascadeCore.playlistDetailsRoute and docs/cascade-server-plugin-tasks.md.

let _plEdit = null   // { id, route, name, isPublic, overview, hasArt, busy } while Edit mode is on
const _plArtBust = new Map()   // playlist id -> cache-buster after a picture change

/** The detail header's art URL. It carries no image tag, so after a change
 *  the old picture would be served from cache without the buster. */
function playlistArtUrl(playlistId) {
  // Local mode has no picture for a playlist, and no server to ask.
  if (isLocalMode()) return ''
  const bust = _plArtBust.get(playlistId)
  return `${jf.url}/Items/${playlistId}/Images/Primary?fillHeight=160&fillWidth=160&quality=80&ApiKey=${jf.token}${bust ? `&v=${bust}` : ''}`
}

/** One write, checked (CODEMAP rule 1). Resolves to an error message or null. */
async function _plDetailsWrite(path, init) {
  try {
    // Spaced like every other playlist write (createPlaylistWriteGate); the
    // name, description and picture of one playlist share one gate.
    const id = path.match(/[0-9a-f]{32}/i)?.[0]
    if (id) await waitForPlaylistWrite(id)
    const res = await jfFetch(`${jf.url}${path}`, init)
    return res.ok ? null : await CascadeCore.readErrorMessage(res)
  } catch (e) {
    return e.message
  }
}

async function _savePlaylistOverview(d, overview) {
  if (d.route === 'plugin') {
    return _plDetailsWrite(`/CascadeServer/Playlists/${d.id}/Details`, {
      method: 'PUT',
      headers: CascadeCore.authHeaders(jf, { 'Content-Type': 'application/json' }),
      body: JSON.stringify({ overview }),
    })
  }
  // Jellyfin's item update replaces the whole item, so it takes the full
  // fetched DTO with one field changed, never a partial body (the metadata
  // editor's rule too).
  try {
    const res = await jfFetch(`${jf.url}/Items/${d.id}`, { headers: CascadeCore.authHeaders(jf) })
    if (!res.ok) return await CascadeCore.readErrorMessage(res)
    const full = await res.json()
    return _plDetailsWrite(`/Items/${d.id}`, {
      method: 'POST',
      headers: CascadeCore.authHeaders(jf, { 'Content-Type': 'application/json' }),
      body: JSON.stringify({ ...full, Overview: overview }),
    })
  } catch (e) {
    return e.message
  }
}

async function _savePlaylistArt(d) {
  const plugin = d.route === 'plugin'
  const path = plugin ? `/CascadeServer/Playlists/${d.id}/Image` : `/Items/${d.id}/Images/Primary`
  if (d.art === 'remove') return _plDetailsWrite(path, { method: 'DELETE', headers: CascadeCore.authHeaders(jf) })
  // The plugin takes the raw bytes; Jellyfin's own route reads its body as
  // base64 text with the image's type as Content-Type.
  return _plDetailsWrite(path, {
    method: 'POST',
    headers: CascadeCore.authHeaders(jf, { 'Content-Type': d.art.type }),
    body: plugin ? d.art.bytes : CascadeCore.bytesToBase64(d.art.bytes),
  })
}

/** Fills the editor from the playlist as the server has it, when Edit mode opens. */
function startPlaylistDetailsEdit(it) {
  const route = CascadeCore.playlistDetailsRoute(_cascadePluginCaps, !_cascadePluginAbsent, !!jf.isAdmin)
  _plEdit = {
    id: currentPlaylistId,
    route,
    name: it?.Name || document.getElementById('pl-detail-name').textContent,
    isPublic: !!it?.IsPublic,
    overview: typeof it?.Overview === 'string' ? it.Overview : '',
    hasArt: !!it?.ImageTags?.Primary,
    busy: false,
    chain: Promise.resolve(),
  }
  const name = document.getElementById('pl-detail-name')
  name.textContent = _plEdit.name
  name.contentEditable = 'plaintext-only'
  name.setAttribute('role', 'textbox')
  name.setAttribute('aria-label', 'Playlist name')
  const overview = document.getElementById('pl-detail-overview-input')
  overview.value = _plEdit.overview
  overview.hidden = !route
  _sizeOverviewInput()
  document.getElementById('pl-edit-public').checked = _plEdit.isPublic
  const wrap = document.getElementById('pl-art-wrap')
  wrap.classList.toggle('can-edit', !!route)
  wrap.classList.toggle('has-art', _plEdit.hasArt)
  wrap.title = route ? '' : 'Changing the picture and description needs Cascade Server on this server, or an admin account.'
}

/** Back to a plain header when Edit mode closes. */
function stopPlaylistDetailsEdit() {
  const name = document.getElementById('pl-detail-name')
  name.removeAttribute('contenteditable')
  name.removeAttribute('role')
  name.removeAttribute('aria-label')
  document.getElementById('pl-detail-overview-input').hidden = true
  const wrap = document.getElementById('pl-art-wrap')
  wrap.classList.remove('can-edit', 'has-art')
  wrap.title = ''
  _plEdit = null
}

function _sizeOverviewInput() {
  const el = document.getElementById('pl-detail-overview-input')
  el.style.height = 'auto'
  el.style.height = `${el.scrollHeight + 2}px`
}

/**
 * Runs the editor's writes one after another, each reading the playlist as the
 * last one left it. Writes are spaced (waitForPlaylistWrite), so a rename can
 * still be on its way when Public is flipped, and Public then sent the old name
 * and undid the rename.
 */
function _plEditInTurn(d, job) {
  const run = d.chain.then(job)
  d.chain = run.catch(() => {})
  return run
}

async function _savePlaylistNameAndPublic(d, name, isPublic) {
  const err = await _plDetailsWrite(`/Playlists/${d.id}`, {
    method: 'POST',
    headers: CascadeCore.authHeaders(jf, { 'Content-Type': 'application/json' }),
    body: JSON.stringify({ Name: name, IsPublic: isPublic }),
  })
  if (err) return err
  d.name = name
  d.isPublic = isPublic
  plCurrentIsPublic = isPublic
  // The index shows names, and re-fetches them next time it is drawn.
  delete document.getElementById('playlists-grid').dataset.loaded
  return null
}

const _plNameEl = document.getElementById('pl-detail-name')
_plNameEl.addEventListener('keydown', (e) => {
  if (!_plEdit) return
  if (e.key === 'Enter') { e.preventDefault(); _plNameEl.blur() }
  if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); _plNameEl.textContent = _plEdit.name; _plNameEl.blur() }
})
_plNameEl.addEventListener('blur', async () => {
  const d = _plEdit
  if (!d) return
  const name = _plNameEl.textContent.replace(/\s+/g, ' ').trim().slice(0, 100)
  if (!name) { _plNameEl.textContent = d.name; showToast('A playlist needs a name'); return }
  _plNameEl.textContent = name
  if (name === d.name) return
  const err = await _plEditInTurn(d, () => _savePlaylistNameAndPublic(d, name, d.isPublic))
  if (err) { _plNameEl.textContent = d.name; showNotice(`Could not rename the playlist.\n\n${err}`, 'Playlist') }
  else showToast('Playlist renamed')
})

const _plOverviewEl = document.getElementById('pl-detail-overview-input')
_plOverviewEl.addEventListener('input', _sizeOverviewInput)
_plOverviewEl.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && _plEdit) { e.stopPropagation(); _plOverviewEl.value = _plEdit.overview; _plOverviewEl.blur() }
})
_plOverviewEl.addEventListener('blur', async () => {
  const d = _plEdit
  if (!d?.route) return
  const overview = _plOverviewEl.value.trim().slice(0, CascadeCore.PLAYLIST_OVERVIEW_MAX)
  if (overview === d.overview) return
  const err = await _plEditInTurn(d, () => _savePlaylistOverview(d, overview))
  if (err) { showNotice(`Could not save the description.\n\n${err}`, 'Playlist'); return }
  d.overview = overview
  showPlaylistOverview(overview)
  showToast(overview ? 'Description saved' : 'Description removed')
})

document.getElementById('pl-edit-public').addEventListener('change', async (e) => {
  const d = _plEdit
  if (!d) return
  const want = e.target.checked
  const err = await _plEditInTurn(d, () => _savePlaylistNameAndPublic(d, d.name, want))
  if (err) { e.target.checked = d.isPublic; showNotice(`Could not change who can see the playlist.\n\n${err}`, 'Playlist') }
  else showToast(want ? 'Playlist is public' : 'Playlist is private')
})

/** Shows the cover as the server has it, past the cache (its URL carries no image tag). */
function _showPlaylistArt(d) {
  _plArtBust.set(d.id, Date.now())
  document.getElementById('pl-detail-art').innerHTML = d.hasArt
    ? `<img src="${playlistArtUrl(d.id)}" alt="" onerror="this.parentElement.textContent='♪'">` : '♪'
  document.getElementById('pl-art-wrap').classList.toggle('has-art', d.hasArt)
}

document.getElementById('pl-art-change').addEventListener('click', () => {
  if (_plEdit?.route && !_plEdit.busy) document.getElementById('pl-edit-art-file').click()
})

document.getElementById('pl-edit-art-file').addEventListener('change', async (e) => {
  const file = e.target.files?.[0]
  e.target.value = ''
  const d = _plEdit
  if (!file || !d?.route || d.busy) return
  if (file.size > CascadeCore.PLAYLIST_IMAGE_MAX_BYTES) { showNotice('That picture is too large. Use one under 10 MB.', 'Playlist'); return }
  const bytes = new Uint8Array(await file.arrayBuffer())
  const type = CascadeCore.sniffImageType(bytes)
  if (!type) { showNotice('Use a JPEG, PNG or WebP picture.', 'Playlist'); return }
  // Shown at once, saved behind it, and put back if the save fails.
  const preview = URL.createObjectURL(new Blob([bytes], { type }))
  document.getElementById('pl-detail-art').innerHTML = `<img src="${preview}" alt="">`
  d.busy = true
  const err = await _plEditInTurn(d, () => _savePlaylistArt({ ...d, art: { bytes, type } }))
  d.busy = false
  URL.revokeObjectURL(preview)
  if (err) { _showPlaylistArt(d); showNotice(`Could not change the picture.\n\n${err}`, 'Playlist'); return }
  d.hasArt = true
  _showPlaylistArt(d)
  delete document.getElementById('playlists-grid').dataset.loaded
  showToast('Picture changed')
})

document.getElementById('pl-art-remove').addEventListener('click', async () => {
  const d = _plEdit
  if (!d?.route || d.busy || !d.hasArt) return
  d.busy = true
  const err = await _plEditInTurn(d, () => _savePlaylistArt({ ...d, art: 'remove' }))
  d.busy = false
  if (err) { showNotice(`Could not remove the picture.\n\n${err}`, 'Playlist'); return }
  d.hasArt = false
  _showPlaylistArt(d)
  delete document.getElementById('playlists-grid').dataset.loaded
  showToast('Picture removed')
})

/** The description under the playlist's name in its detail header. */
function showPlaylistOverview(text) {
  const el = document.getElementById('pl-detail-overview')
  el.textContent = text || ''
  el.hidden = !text
}

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
    wireTrackRow(el, items[idx], items, idx, { inPlaylist: entryIds, source: document.getElementById('pl-detail-name').textContent })
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
      markTipSeen('playlist-drag')
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
        await waitForPlaylistWrite(currentPlaylistId)
        const res = await jfFetch(`${jf.url}/Playlists/${currentPlaylistId}/Items/${entryId}/Move/${to}`, {
          method: 'POST', headers: CascadeCore.authHeaders(jf)
        })
        if (!res.ok) throw new Error(res.status)
      } catch (err) {
        // An .m3u in Local mode is never written: put its own order back.
        if (isLocalMode() && err?.message === '403') { showNotice(LOCAL_M3U_READ_ONLY, 'Playlist'); refreshPlaylistDetail(); return }
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
  artEl.innerHTML = `<img src="${playlistArtUrl(playlistId)}" alt="" onerror="this.parentElement.textContent='♪'">`
  // The description is not in the track list's response, so it comes from the
  // item itself, without holding up the tracks.
  showPlaylistOverview('')
  jfGet(`/Items/${playlistId}`, { Fields: 'Overview' })
    .then(it => { if (currentPlaylistId === playlistId) showPlaylistOverview(typeof it?.Overview === 'string' ? it.Overview : '') })
    .catch(() => {})

  try {
    renderOfflineButtons()
    renderPlaylistDetailItems(await fetchPlaylistTracks(playlistId), true)
  } catch (e) {
    document.getElementById('pl-detail-rows').innerHTML = `<div class="empty-state">Could not load playlist</div>`
  }
}

// ── Smart playlists ─────────────────────────────────────────────────────────────
// Auto-updating, synthesized from Jellyfin queries rather than real playlist entities.
// Each one's query is load(), not fetch(): the offline guard's sweep (63089c5)
// renamed a method called fetch() to jfFetch() while smartPlaylistEntry() kept
// reading .fetch, so Favorites and Most Played threw on open and showed "Could
// not load" from 2026-10-14 to 2026-10-20.

const SMART_PLAYLISTS = {
  favorites: {
    name: 'Favorites',
    icon: '<svg width="32" height="32" viewBox="0 0 24 24" fill="currentColor" stroke="none"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/></svg>',
    gradient: 'linear-gradient(135deg,#f472b6,#dc2626)',
    async load() {
      const data = await jfGetMerged(`/Items`, {
        IncludeItemTypes: 'Audio', Recursive: true, Filters: 'IsFavorite',
        SortBy: 'SortName', SortOrder: 'Ascending',
        Fields: 'AlbumId,AlbumPrimaryImageTag'
      })
      return data.Items || []
    }
  },
  'most-played': {
    name: 'Most Played',
    icon: '<svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="23 6 13.5 15.5 8.5 10.5 1 18"/><polyline points="17 6 23 6 23 12"/></svg>',
    gradient: 'linear-gradient(135deg,#60a5fa,#059669)',
    async load() {
      // Ask each library for its own top 200 by play count (server-side sorted),
      // then merge and re-sort/slice client-side - a per-library cap could otherwise
      // leave the true top 100 overall incomplete once multiple libraries are merged.
      const data = await jfGetMerged(`/Items`, {
        IncludeItemTypes: 'Audio', Recursive: true,
        SortBy: 'PlayCount', SortOrder: 'Descending', Limit: 200,
        Fields: 'AlbumId,AlbumPrimaryImageTag'
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

// ── User smart playlists ─────────────────────────────────────────────────────
// Jellyfin has no concept of these, so the definitions live only in Cascade's
// local store (parsed/clamped on every read - see CascadeCore.parseSmartPlaylists,
// CODEMAP rule "stored values are untrusted"). currentSmartKind holds a def's id
// (`user:<uuid>`) exactly the way it already holds 'favorites'/'most-played',
// so every place that dispatches on it goes through smartPlaylistEntry() below
// instead of caring which kind of smart playlist it is.

let userSmartPlaylists = []   // SmartPlaylistDef[], reloaded each time Playlists is shown

async function loadUserSmartPlaylists() {
  userSmartPlaylists = CascadeCore.parseSmartPlaylists(await window.cascade.store.get('smartPlaylists'))
}

async function saveUserSmartPlaylists() {
  await window.cascade.store.set('smartPlaylists', CascadeCore.serializeSmartPlaylists(userSmartPlaylists))
}

const USER_SMART_GRADIENT = 'linear-gradient(135deg,#a78bfa,#7c3aed)'
const USER_SMART_ICON = '<svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3"/></svg>'

function userSmartPlaylistCardHtml(def) {
  return `<div class="playlist-card" data-smart="${def.id}">
    <div class="playlist-art" style="background:${USER_SMART_GRADIENT};color:#fff;">${USER_SMART_ICON}</div>
    <div class="playlist-body">
      <div class="playlist-name">${esc(def.name)}</div>
      <div class="playlist-count">Smart playlist</div>
    </div>
  </div>`
}

/** Runs a user def's query (best-effort prefilter - see toItemsQuery's own
 *  comment) then re-applies the full rule set client-side, which is what
 *  actually decides membership, sort and limit. */
async function fetchUserSmartPlaylist(def) {
  const query = CascadeCore.toItemsQuery(def)
  const data = await jfGetAllPaged(`/Items`, {
    IncludeItemTypes: 'Audio', Recursive: true,
    Fields: 'AlbumId,AlbumPrimaryImageTag,Genres,DateCreated',
    ...query
  })
  return CascadeCore.applySmartPlaylistRules(data.Items || [], def, Date.now())
}

/** The one lookup every card, the context menu and the refresh/fetch paths go
 *  through, so none of them need to know whether a `smart` kind is one of the
 *  two built-ins or a user definition. Returns null for a user playlist that
 *  was deleted out from under something still pointing at its id (a stale
 *  currentSmartKind, e.g.) rather than throwing. */
function smartPlaylistEntry(kind) {
  const builtin = SMART_PLAYLISTS[kind]
  if (builtin) return { name: builtin.name, icon: builtin.icon, gradient: builtin.gradient, fetch: builtin.load, isUser: false, def: null }
  const def = userSmartPlaylists.find(d => d.id === kind)
  if (!def) return null
  return { name: def.name, icon: USER_SMART_ICON, gradient: USER_SMART_GRADIENT, fetch: () => fetchUserSmartPlaylist(def), isUser: true, def }
}

async function openSmartPlaylist(kind) {
  const sp = smartPlaylistEntry(kind)
  if (!sp) return
  currentPlaylistId = null
  currentSmartKind = kind
  showPlaylistDetailShell(sp.name)
  // Not a real Jellyfin playlist - nothing for Edit mode (built-ins) to write
  // to. A user definition repurposes the same button to open the rule editor
  // instead (see btn-edit-playlist's handler below).
  document.getElementById('btn-edit-playlist').style.display = sp.isUser ? '' : 'none'
  document.getElementById('btn-edit-playlist').textContent = sp.isUser ? 'Edit Rules' : 'Edit'
  document.getElementById('btn-save-as-playlist').style.display = sp.isUser ? '' : 'none'
  renderOfflineButtons()   // no id: a smart playlist has nothing on the server to download
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
  if (currentPlaylistItems.length) playItems(currentPlaylistItems, 0, document.getElementById('pl-detail-name').textContent)
})

document.getElementById('btn-shuffle-playlist').addEventListener('click', () => shuffleAndPlay(currentPlaylistItems, document.getElementById('pl-detail-name').textContent))

// Snapshots whatever is currently showing into a real Jellyfin playlist - a
// smart playlist has nothing on the server to point at, so "save" here means
// "create one with today's matching tracks", not "keep this in sync".
document.getElementById('btn-save-as-playlist').addEventListener('click', async () => {
  if (!currentSmartKind || !currentPlaylistItems.length) return
  const sp = smartPlaylistEntry(currentSmartKind)
  if (!sp?.isUser) return   // guard the handler too, not just the button's visibility
  const name = sp.name
  try {
    const ids = currentPlaylistItems.map(i => encodeURIComponent(i.Id)).join(',')
    const res = await jfFetch(`${jf.url}/Playlists?Name=${encodeURIComponent(name)}&Ids=${ids}&UserId=${encodeURIComponent(jf.userId)}&MediaType=Audio`, {
      method: 'POST',
      headers: CascadeCore.authHeaders(jf)
    })
    if (!res.ok) throw new Error(await CascadeCore.readErrorMessage(res))
    showToast(`Saved as playlist "${name}"`)
    delete document.getElementById('playlists-grid').dataset.loaded
  } catch (e) {
    showNotice(`Could not save this as a playlist.\n\n${e.message}`, 'Playlist')
  }
})

// ── Smart playlist rule builder ──────────────────────────────────────────────

/** One entry per rule field: the label for the field picker, and how to read/
 *  write that field's value controls. Kept as a table rather than a switch
 *  spread across render/serialize so adding a field only ever touches one
 *  place. */
const SMART_RULE_FIELDS = {
  genre: {
    label: 'Genre',
    render: (r) => `
      <select class="spl-op">
        <option value="is"${r?.op !== 'isNot' ? ' selected' : ''}>is</option>
        <option value="isNot"${r?.op === 'isNot' ? ' selected' : ''}>is not</option>
      </select>
      <input type="text" class="spl-val" placeholder="Genre name" value="${esc(r?.value || '')}">`,
    read: (row) => ({ field: 'genre', op: row.querySelector('.spl-op').value, value: row.querySelector('.spl-val').value.trim() })
  },
  artist: {
    label: 'Artist',
    render: (r) => `<span>is</span><input type="text" class="spl-val" placeholder="Artist name" value="${esc(r?.value || '')}">`,
    read: (row) => ({ field: 'artist', op: 'is', value: row.querySelector('.spl-val').value.trim() })
  },
  year: {
    label: 'Year',
    render: (r) => `<span>between</span>
      <input type="number" class="spl-min" value="${r?.min ?? 1970}">
      <span>and</span>
      <input type="number" class="spl-max" value="${r?.max ?? 1979}">`,
    read: (row) => ({ field: 'year', op: 'between', min: parseInt(row.querySelector('.spl-min').value, 10), max: parseInt(row.querySelector('.spl-max').value, 10) })
  },
  addedWithinDays: {
    label: 'Added',
    render: (r) => `<span>within the last</span><input type="number" class="spl-days" value="${r?.days ?? 30}"><span>days</span>`,
    read: (row) => ({ field: 'addedWithinDays', op: 'lte', days: parseInt(row.querySelector('.spl-days').value, 10) })
  },
  played: {
    label: 'Played',
    render: (r) => `<select class="spl-val">
      <option value="true"${r?.value !== false ? ' selected' : ''}>Played</option>
      <option value="false"${r?.value === false ? ' selected' : ''}>Never played</option>
    </select>`,
    read: (row) => ({ field: 'played', op: 'is', value: row.querySelector('.spl-val').value === 'true' })
  },
  playCount: {
    label: 'Play count',
    render: (r) => `<span>at least</span><input type="number" class="spl-val" min="0" value="${r?.value ?? 1}">`,
    read: (row) => ({ field: 'playCount', op: 'gte', value: parseInt(row.querySelector('.spl-val').value, 10) })
  },
  favorite: {
    label: 'Favorite',
    render: (r) => `<select class="spl-val">
      <option value="true"${r?.value !== false ? ' selected' : ''}>Is a favorite</option>
      <option value="false"${r?.value === false ? ' selected' : ''}>Not a favorite</option>
    </select>`,
    read: (row) => ({ field: 'favorite', op: 'is', value: row.querySelector('.spl-val').value === 'true' })
  }
}

function smartRuleRowHtml(rule) {
  const field = rule?.field && SMART_RULE_FIELDS[rule.field] ? rule.field : 'genre'
  const options = Object.entries(SMART_RULE_FIELDS).map(([k, f]) => `<option value="${k}"${k === field ? ' selected' : ''}>${f.label}</option>`).join('')
  return `<div class="smart-pl-rule">
    <div class="smart-pl-rule-top">
      <select class="spl-field">${options}</select>
      <button type="button" class="smart-pl-rule-remove" title="Remove rule">×</button>
    </div>
    <div class="smart-pl-rule-value">${SMART_RULE_FIELDS[field].render(rule)}</div>
  </div>`
}

function wireSmartRuleRow(row, rule) {
  row.querySelector('.spl-field').addEventListener('change', (e) => {
    const field = e.target.value
    row.querySelector('.smart-pl-rule-value').innerHTML = SMART_RULE_FIELDS[field].render(null)
  })
  row.querySelector('.smart-pl-rule-remove').addEventListener('click', () => row.remove())
}

function addSmartRuleRow(rule) {
  const container = document.getElementById('smart-pl-rules')
  const wrap = document.createElement('div')
  wrap.innerHTML = smartRuleRowHtml(rule)
  const row = wrap.firstElementChild
  container.appendChild(row)
  wireSmartRuleRow(row, rule)
}

document.getElementById('smart-pl-add-rule').addEventListener('click', () => addSmartRuleRow(null))

let _smartPlEditingId = null   // set while the modal edits an existing def, null while creating one
// Which kind the shared modal is making: 'normal' (a real Jellyfin playlist)
// or 'smart' (a local rule-based definition). Only "New Playlist" offers the
// choice; editing a smart playlist is always 'smart'.
let _newPlMode = 'smart'

function setNewPlaylistMode(mode) {
  _newPlMode = mode === 'normal' && !_smartPlEditingId ? 'normal' : 'smart'
  const normal = _newPlMode === 'normal'
  const normalBtn = document.getElementById('new-pl-mode-normal')
  const smartBtn = document.getElementById('new-pl-mode-smart')
  normalBtn.classList.toggle('active', normal)
  smartBtn.classList.toggle('active', !normal)
  normalBtn.setAttribute('aria-pressed', String(normal))
  smartBtn.setAttribute('aria-pressed', String(!normal))
  document.getElementById('new-pl-normal-fields').hidden = !normal
  document.getElementById('new-pl-smart-fields').hidden = normal
  document.getElementById('smart-pl-modal-title').textContent =
    _smartPlEditingId ? 'Edit smart playlist' : normal ? 'New playlist' : 'New smart playlist'
}

function openSmartPlaylistEditor(def) {
  _smartPlEditingId = def ? def.id : null
  // .seg-control sets display itself, so the hidden attribute would lose to it.
  document.getElementById('new-pl-mode').style.display = def ? 'none' : ''
  setNewPlaylistMode('smart')
  document.getElementById('smart-pl-name').value = def?.name || ''
  document.getElementById('smart-pl-match').value = def?.match || 'all'
  document.getElementById('smart-pl-sort-by').value = def?.sortBy || 'name'
  document.getElementById('smart-pl-sort-dir').value = def?.sortDir || 'asc'
  document.getElementById('smart-pl-limit').value = String(def?.limit ?? 100)
  const rulesEl = document.getElementById('smart-pl-rules')
  rulesEl.innerHTML = ''
  const rules = def?.rules?.length ? def.rules : [null]
  rules.forEach(r => addSmartRuleRow(r))
  document.getElementById('smart-pl-modal').classList.remove('hidden')
}

/** "New Playlist": the same modal with the Normal / Smart switch showing,
 *  starting on Normal since a plain playlist is the common case. */
function openNewPlaylistModal() {
  openSmartPlaylistEditor(null)
  document.getElementById('new-pl-public').checked = false
  setNewPlaylistMode('normal')
  document.getElementById('smart-pl-name').focus()
}

document.getElementById('btn-new-playlist').addEventListener('click', openNewPlaylistModal)
document.getElementById('new-pl-mode-normal').addEventListener('click', () => setNewPlaylistMode('normal'))
document.getElementById('new-pl-mode-smart').addEventListener('click', () => setNewPlaylistMode('smart'))

// The Playlists index only re-fetches when shown with its loaded flag cleared,
// and a playlist made from its own header leaves it showing - so redraw it
// now rather than leaving the new card missing until the next visit.
function reloadPlaylistIndexIfShown() {
  delete document.getElementById('playlists-grid').dataset.loaded
  const index = document.getElementById('playlist-index')
  if (document.getElementById('view-playlists').classList.contains('active') && index.style.display !== 'none') loadPlaylists()
}

/** A real, empty Jellyfin playlist. Name, owner and media type go in the query
 *  like every other create call here; IsPublic only exists on the JSON body
 *  (CreatePlaylistDto). Returns the new id, or null after telling the user. */
async function createEmptyPlaylist(name, isPublic) {
  try {
    const res = await jfFetch(`${jf.url}/Playlists?Name=${encodeURIComponent(name)}&UserId=${encodeURIComponent(jf.userId)}&MediaType=Audio`, {
      method: 'POST',
      headers: CascadeCore.authHeaders(jf, { 'Content-Type': 'application/json' }),
      body: JSON.stringify({ Name: name, Ids: [], UserId: jf.userId, MediaType: 'Audio', IsPublic: isPublic })
    })
    if (!res.ok) throw new Error(await CascadeCore.readErrorMessage(res))
    const data = await res.json().catch(() => null)
    return typeof data?.Id === 'string' && data.Id ? data.Id : ''
  } catch (e) {
    showNotice(`Could not create the playlist.\n\n${e.message}`, 'Playlist')
    return null
  }
}

document.getElementById('smart-pl-cancel').addEventListener('click', () => {
  document.getElementById('smart-pl-modal').classList.add('hidden')
})

let _newPlSaving = false

document.getElementById('smart-pl-save').addEventListener('click', async () => {
  const name = document.getElementById('smart-pl-name').value.trim()
  if (_newPlMode === 'normal' && !_smartPlEditingId) {
    if (!name) { showNotice('Give this playlist a name.', 'Playlist'); return }
    // Guarded here, not only by disabling the button: a second press while
    // the first request is in flight would create the playlist twice.
    if (_newPlSaving) return
    _newPlSaving = true
    const saveBtn = document.getElementById('smart-pl-save')
    saveBtn.disabled = true
    try {
      const id = await createEmptyPlaylist(name, document.getElementById('new-pl-public').checked)
      if (id == null) return
      document.getElementById('smart-pl-modal').classList.add('hidden')
      showToast(`Playlist "${name}" created`)
      reloadPlaylistIndexIfShown()
      // The server answers with the new id; an older one that does not still
      // made the playlist, which the reloaded index now shows.
      if (id) openPlaylist(id, name)
    } finally {
      _newPlSaving = false
      saveBtn.disabled = false
    }
    return
  }
  if (!name) { showNotice('Give this smart playlist a name.', 'Smart Playlist'); return }
  const rules = [...document.querySelectorAll('#smart-pl-rules .smart-pl-rule')].map(row => {
    const field = row.querySelector('.spl-field').value
    return SMART_RULE_FIELDS[field].read(row)
  })
  const raw = {
    id: _smartPlEditingId || `user:${crypto.randomUUID()}`,
    name,
    match: document.getElementById('smart-pl-match').value,
    rules,
    sortBy: document.getElementById('smart-pl-sort-by').value,
    sortDir: document.getElementById('smart-pl-sort-dir').value,
    limit: parseInt(document.getElementById('smart-pl-limit').value, 10)
  }
  // Round-tripped through the same parse/validate/clamp used on every load
  // from the store, rather than trusting the form's own values - it is one
  // code path either way, and this is the untrusted-input boundary just as
  // much as reading a stale store value back is.
  const others = userSmartPlaylists.filter(d => d.id !== raw.id)
  const merged = CascadeCore.parseSmartPlaylists(JSON.stringify([...others, raw]))
  userSmartPlaylists = merged
  await saveUserSmartPlaylists()
  document.getElementById('smart-pl-modal').classList.add('hidden')
  reloadPlaylistIndexIfShown()
  showToast(_smartPlEditingId ? 'Smart playlist updated' : 'Smart playlist created')
  if (currentSmartKind === raw.id) await refreshPlaylistDetail()
})


// ── Genres ────────────────────────────────────────────────────────────────────

function genreCardHtml(item) {
  const art = artUrl(item.Id, item.ImageTags?.Primary)
  const initial = (item.Name || '?').trim().charAt(0).toUpperCase() || '?'
  // The tile (initial letter) is the base, drawn whether or not there's real
  // art - Jellyfin usually generates a genre collage, but onerror still needs
  // something sane to fall back to for a genre that has none. See
  // .genre-tile in library.css.
  return `<div class="album-card" data-id="${item.Id}">
    <div class="album-art genre-tile"><span class="genre-tile-letter">${esc(initial)}</span>${art ? `<img src="${art}" alt="" loading="lazy" onerror="this.style.display='none'">` : ''}</div>
    <div class="album-body">
      <div class="album-name">${esc(item.Name)}</div>
    </div>
  </div>`
}

// A plain A-Z grid, no sort/filter header - there's only a name to sort by
// and nothing on a genre itself worth filtering on, so this skips the
// registerLibView machinery the other grids use.
async function loadGenres() {
  const grid = document.getElementById('genres-grid')
  grid.dataset.loaded = '1'
  try {
    // getMerged narrows to the selected music libraries via ParentId, same as
    // every other music fetch - a genre's albums/songs are scoped the same
    // way once you're inside it (fetchGenreAlbums/fetchGenreSongs below).
    const data = await jfGetMerged('/MusicGenres', { UserId: jf.userId })
    const items = (data.Items || []).sort(bySortName)
    if (!items.length) { grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">No genres found</div>`; return }
    grid.innerHTML = items.map(genreCardHtml).join('')
    const byId = new Map(items.map(i => [i.Id, i]))
    grid.querySelectorAll('.album-card').forEach(el => {
      const item = byId.get(el.dataset.id)
      if (item) el.addEventListener('click', () => openGenre(item.Id, item.Name))
    })
  } catch (e) {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">Could not load genres</div>`
  }
}

async function fetchGenreAlbums(genreId) {
  const data = await jfGetAllPaged(`/Items`, {
    // GenreIds, not Genres (a name) - a genre name containing '|' would break
    // the pipe-delimited Genres filter.
    GenreIds: genreId, IncludeItemTypes: 'MusicAlbum', Recursive: true,
    Fields: 'SortName,ProductionYear,UserData', SortBy: 'SortName', SortOrder: 'Ascending', Limit: 500,
  })
  data.Items.sort(bySortName)   // the merge only kept SortBy within each library
  return data.Items
}

async function fetchGenreSongs(genreId) {
  const data = await jfGetAllPaged(`/Items`, {
    GenreIds: genreId, IncludeItemTypes: 'Audio', Recursive: true,
    Fields: 'AlbumId,AlbumPrimaryImageTag,UserData,DateCreated,SortName', SortBy: 'SortName', SortOrder: 'Ascending', Limit: 500,
  })
  data.Items.sort(bySortName)
  return data.Items
}

let currentGenreSongs = []
let _genreSongsShown = 0
const GENRE_SONGS_PAGE = 300   // rows aren't virtualized here; a genre this wide is rare, so paint in chunks instead

function renderGenreSongRows() {
  const rows = document.getElementById('genre-songs-rows')
  if (!currentGenreSongs.length) { rows.innerHTML = `<div class="empty-state">No songs</div>`; return }
  _genreSongsShown = Math.min(currentGenreSongs.length, _genreSongsShown + GENRE_SONGS_PAGE)
  rows.innerHTML = currentGenreSongs.slice(0, _genreSongsShown).map((item, i) => trackRowHtml(item, i)).join('')
  highlightPlayingRow()
  rows.querySelectorAll('.track-row').forEach(el => {
    const idx = parseInt(el.dataset.idx)
    wireTrackRow(el, currentGenreSongs[idx], currentGenreSongs, idx)
  })
  document.getElementById('btn-genre-show-more').style.display = _genreSongsShown < currentGenreSongs.length ? '' : 'none'
}

async function openGenre(genreId, name) {
  document.getElementById('genres-index').style.display = 'none'
  const detail = document.getElementById('genre-detail')
  detail.style.display = ''
  document.getElementById('genre-detail-name').textContent = name
  document.getElementById('genre-detail-letter').textContent = (name || '?').trim().charAt(0).toUpperCase() || '?'
  document.getElementById('genre-detail-art').querySelector('img')?.remove()
  document.getElementById('genre-detail-meta').innerHTML = '<span class="skel skel-text" style="display:inline-block;width:120px"></span>'
  document.getElementById('genre-albums-grid').innerHTML = skeletonHTML('album', 6)
  document.getElementById('genre-songs-rows').innerHTML = skeletonHTML('track', 6)
  document.getElementById('btn-genre-show-more').style.display = 'none'
  currentGenreSongs = []
  _genreSongsShown = 0

  try {
    const [genre, albums, songs] = await Promise.all([
      jfGet(`/Items/${genreId}`).catch(() => null),
      fetchGenreAlbums(genreId),
      fetchGenreSongs(genreId),
    ])
    currentGenreSongs = songs

    const art = artUrl(genreId, genre?.ImageTags?.Primary)
    if (art) document.getElementById('genre-detail-art').insertAdjacentHTML('beforeend', `<img src="${art}" alt="" onerror="this.remove()">`)
    document.getElementById('genre-detail-meta').textContent =
      `${albums.length} album${albums.length !== 1 ? 's' : ''} · ${songs.length} song${songs.length !== 1 ? 's' : ''}`

    document.getElementById('genre-albums-grid').innerHTML = albums.length
      ? albums.map(item => albumCard(item)).join('')
      : `<div class="empty-state" style="grid-column:1/-1">No albums</div>`
    wireAlbumCards(document.getElementById('genre-albums-grid'), albums, item => { showView('albums'); openAlbum(item.Id) })

    renderGenreSongRows()
  } catch (e) {
    document.getElementById('genre-detail-meta').textContent = 'Could not load genre'
  }
}

document.getElementById('btn-genre-show-more').addEventListener('click', renderGenreSongRows)

document.getElementById('genre-back-btn').addEventListener('click', () => {
  document.getElementById('genre-detail').style.display = 'none'
  document.getElementById('genres-index').style.display = ''
})

document.getElementById('btn-play-genre').addEventListener('click', () => {
  if (currentGenreSongs.length) playItems(currentGenreSongs, 0, document.getElementById('genre-detail-name').textContent)
})

document.getElementById('btn-shuffle-genre').addEventListener('click', () => shuffleAndPlay(currentGenreSongs, document.getElementById('genre-detail-name').textContent))

// ── History ───────────────────────────────────────────────────────────────────
//
// Jellyfin keeps one LastPlayedDate per item (UserData), not a log of every
// play - a track played three times today still just has one date. This view
// is therefore "which tracks have I played and when most recently", grouped
// by day, not a true per-play log. A true log needs the Playback Reporting
// plugin's own (non-standard) API; this server doesn't have it (checked
// /Plugins), so nothing here depends on it.
let currentHistoryItems = []

async function loadHistory() {
  takeHistorySnapshot()
  const rows = document.getElementById('history-rows')
  rows.innerHTML = skeletonHTML('track', 6)
  try {
    // getAllPaged pages each library to the end, but StartIndex paging within
    // a library is only meaningful sorted by that library's own order - with
    // more than one library merged, only a client-side re-sort by
    // LastPlayedDate afterward gives a correct global newest-first order.
    const data = await jfGetAllPaged(`/Items`, {
      SortBy: 'DatePlayed', SortOrder: 'Descending',
      IncludeItemTypes: 'Audio', Filters: 'IsPlayed', Recursive: true,
      Fields: 'AlbumId,AlbumPrimaryImageTag,UserData,SortName', Limit: 500,
    })
    const items = (data.Items || []).sort((a, b) =>
      new Date(b.UserData?.LastPlayedDate || 0) - new Date(a.UserData?.LastPlayedDate || 0))
    currentHistoryItems = items
    if (!items.length) { rows.innerHTML = `<div class="empty-state">No play history yet</div>`; return }

    const groups = CascadeCore.groupByDay(items)
    let idx = 0
    rows.innerHTML = groups.map(g => {
      const dayRows = g.items.map(item => {
        // data-idx must index the flat list, not the position within a day,
        // so clicking a row plays onward through the rest of history rather
        // than restarting the count at zero for every day.
        const html = trackRowHtml(item, idx)
        idx++
        return html
      }).join('')
      return `<div class="history-day-header">${esc(g.label)}</div>${dayRows}`
    }).join('')
    highlightPlayingRow()
    rows.querySelectorAll('.track-row').forEach(el => {
      const i = parseInt(el.dataset.idx)
      wireTrackRow(el, items[i], items, i)
    })
  } catch (e) {
    rows.innerHTML = `<div class="empty-state">Could not load history</div>`
  }
}

// ── Universal track context menu ───────────────────────────────────────────────

const trackCtxMenu = document.getElementById('track-ctx-menu')
let _ctxItem = null   // Jellyfin item object for the right-clicked row
let _ctxEl   = null   // DOM element of the right-clicked row
let _ctxInPl = false  // whether we're inside a playlist (shows Remove option)

function showTrackCtxMenu(item, el, x, y, inPlaylist = false) {
  markTipSeen('track-menu')
  _ctxItem = item; _ctxEl = el; _ctxInPl = inPlaylist
  // Show/hide playlist-only items
  trackCtxMenu.querySelectorAll('.tctx-pl-only').forEach(n => n.classList.toggle('hidden', !inPlaylist))
  const favLabel = document.getElementById('tctx-favorite-label')
  if (favLabel) favLabel.textContent = item?.UserData?.IsFavorite ? 'Unfavorite' : 'Favorite'
  trackCtxMenu.style.left = `${x}px`
  trackCtxMenu.style.top  = `${y}px`
  trackCtxMenu.classList.add('open')
  const r = trackCtxMenu.getBoundingClientRect()
  const { left, top } = CascadeCore.clampMenuPosition(x, y, r.width, r.height, window.innerWidth, window.innerHeight)
  trackCtxMenu.style.left = `${left}px`
  trackCtxMenu.style.top  = `${top}px`
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
      playItems(items, idx, opts.source)
    })
  }
  // Single click on rest of row - select (or play immediately in transient
  // contexts like the search dropdown, where "select" has nothing to select for)
  el.addEventListener('click', e => {
    if (e.target.closest('.track-thumb')) return  // handled above
    if (e.target.closest('[data-album-link]')) { e.stopPropagation(); openAlbumFromTrack(item); return }
    if (e.target.closest('[data-artist-link]')) { e.stopPropagation(); openArtistFromTrack(item); return }
    if (opts.clickToPlay) { playItems(items, idx, opts.source); return }
    document.querySelectorAll('.track-row.selected').forEach(r => r.classList.remove('selected'))
    el.classList.add('selected')
  })
  // Double click anywhere - play, except on the album/artist links themselves
  el.addEventListener('dblclick', e => {
    if (e.target.closest('.row-link')) return
    playItems(items, idx, opts.source)
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
  // Every row plays on dblclick except a queue row, which only ever listens
  // for a plain click (see _drawQueueRows) - a dblclick here would do nothing.
  const evt = _ctxEl.classList.contains('queue-row') ? 'click' : 'dblclick'
  _ctxEl.dispatchEvent(new MouseEvent(evt, { bubbles: true }))
})

document.getElementById('tctx-play-next').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  // Guests append only - letting them jump the line would let the last clicker
  // always win the next slot.
  playNextTracks([_ctxItem], `"${_ctxItem.Name}"`)
})

// "Play last" - appends to the end, which is what the old single "Add to
// queue" action already did. Kept as enqueueTracks() rather than duplicating
// its ownership handling (local/propose/blocked) here.
document.getElementById('tctx-add-queue').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  enqueueTracks([_ctxItem], `"${_ctxItem.Name}"`)
})

// Row is hidden unless a device is selected in the Devices panel - see
// _dpUpdateCtxVisibility(). No visibility check needed here beyond _ctxItem:
// a hidden row cannot be clicked.
document.getElementById('tctx-play-on-device').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  _dpPlayItemsOnDevice([_ctxItem])
})

/** InstantMix seeded from any item that supports it (track, artist, ...) -
 *  shared by the track context menu and the artist context menu, so a second
 *  copy of this fetch+play+toast never had to exist. */
async function instantMixAndPlay(itemId, label) {
  try {
    const data = await jfGet(`/Items/${itemId}/InstantMix`, { UserId: jf.userId, Limit: 50, Fields: 'AlbumId,AlbumPrimaryImageTag' })
    if (!data.Items?.length) { showNotice('Jellyfin did not return an instant mix for this.', 'Instant mix'); return }
    playItems(data.Items, 0, 'Instant mix')
    showToast(`Instant mix from "${label}"`)
  } catch (e) { showNotice('Could not build an instant mix.', 'Instant mix') }
}

document.getElementById('tctx-instant-mix').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  instantMixAndPlay(_ctxItem.Id, _ctxItem.Name)
})

document.getElementById('tctx-favorite').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  toggleLike(_ctxItem)
})

document.getElementById('tctx-add-playlist').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  // Reuse existing add-to-playlist modal - store item for it
  _atpTargetItem = _ctxItem
  openAtpModal()
})

// Media info - openMediaInfoFor() defined with the now-playing context menu above.
document.getElementById('tctx-media-info').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  openMediaInfoFor(_ctxItem)
})

document.getElementById('tctx-download').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  const url = `${jf.url}/Items/${_ctxItem.Id}/Download?ApiKey=${jf.token}`
  const a = document.createElement('a'); a.href = url; a.download = _ctxItem.Name || 'track'; a.click()
})

document.getElementById('tctx-copy-url').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  const url = `${jf.url}/Audio/${_ctxItem.Id}/universal?UserId=${jf.userId}&ApiKey=${jf.token}&Container=mp3,aac,ogg,flac`
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

/** POST /Items/{id}/Refresh - RequiresElevation, same as the library scan.
 *  Shared by the track, now-playing and album context menus so a refresh
 *  request only has one shape to keep in sync. The response was never read
 *  before this existed, so a 403 from a non-admin account reported "queued"
 *  for a refresh the server had refused outright - fixed once, here. */
async function refreshItemMetadata(item) {
  if (!item || !jf.isAdmin) return
  try {
    const res = await jfFetch(`${jf.url}/Items/${item.Id}/Refresh?MetadataRefreshMode=FullRefresh&ImageRefreshMode=FullRefresh&ReplaceAllMetadata=false&ReplaceAllImages=false`, {
      method: 'POST', headers: CascadeCore.authHeaders(jf)
    })
    if (!res.ok) throw new Error(String(res.status))
    showToast('Metadata refresh queued')
  } catch { showNotice('Could not queue a metadata refresh on the server.', 'Refresh failed') }
}

document.getElementById('tctx-refresh-meta').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  refreshItemMetadata(_ctxItem)
})

document.getElementById('tctx-edit-meta').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  openMetadataEditorFor(_ctxItem)
})

// openInJellyfinWeb() and openLyricsEditorFor() are defined with the
// now-playing context menu / lyrics editor below - same functions, no second
// copy hardwired to queue[queueIndex].
document.getElementById('tctx-edit-images').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  openInJellyfinWeb(_ctxItem)
})

document.getElementById('tctx-edit-lyrics').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  openLyricsEditorFor(_ctxItem)
})

document.getElementById('tctx-pl-remove').addEventListener('click', async () => {
  if (!_ctxEl || !currentPlaylistId) return
  closeTrackCtxMenu()
  const entryId = _ctxEl.dataset.entryId
  if (!entryId) { showNotice('This row is missing its playlist entry ID, so it cannot be removed.', 'Playlist'); return }
  try {
    await waitForPlaylistWrite(currentPlaylistId)
    const res = await jfFetch(`${jf.url}/Playlists/${currentPlaylistId}/Items?EntryIds=${encodeURIComponent(entryId)}`, {
      method: 'DELETE', headers: CascadeCore.authHeaders(jf)
    })
    if (!res.ok) throw new Error(res.status)
    showToast('Removed from playlist')
    // Re-fetch rather than patch the DOM in place - a manual patch left currentPlaylistItems
    // (what Play/Shuffle use) still holding the removed track.
    await playlistMutated(currentPlaylistId)
  } catch (e) { showNotice(`Could not remove this track from the playlist.\n\n${e.message}`, 'Playlist') }
})

// Delete media - deleteItemFromServer() is defined with the now-playing
// context menu below (shared with "Delete media" there and "Delete playlist"
// on the item context menu), made to take an item instead of always reading
// queue[queueIndex]. Unlike Remove from playlist above, this deletes the file
// from the server, so it can turn up in Songs, an album, an artist or search -
// invalidating the lazy caches and reloading whatever's on screen is the same
// "re-fetch, don't hand-patch" reasoning as playlistMutated's comment above.
document.getElementById('tctx-delete').addEventListener('click', () => {
  if (!_ctxItem) return
  const item = _ctxItem
  closeTrackCtxMenu()
  deleteItemFromServer(item, {
    confirmMsg: `Delete "${item.Name}" from your server? This cannot be undone.`,
    onDeleted: () => {
      invalidateLibraryViews()
      showView(_currentView)
      const qIdx = queue.findIndex(q => q.Id === item.Id)
      if (qIdx !== -1) {
        const wasCurrent = qIdx === queueIndex
        if (wasCurrent) { audio.pause(); _detachDeck(audio) }
        queue.splice(qIdx, 1)
        if (qIdx < queueIndex) queueIndex--
        else if (wasCurrent) queueIndex = Math.min(queueIndex, queue.length - 1)
        // Same cleanup the queue panel's own remove button does - without it
        // every row after this one keeps the data-qi it had before the splice,
        // so the next click on one of them plays the wrong track, and a
        // deleted "next" track stays prefetched.
        _reprefetch()
        renderQueuePanel()
        if (wasCurrent) { if (queue.length) playCurrentTrack(); else _clearStreamPrefetch() }
      }
      showToast('Deleted from server')
    }
  })
})

// ── Movies & TV ───────────────────────────────────────────────────────────────
//
// Browsing only. Playback is the same code path music uses: these views build a
// queue and hand it to playItems(), which is what makes next-episode autoplay
// fall out for free rather than needing a second player.

/** Runtime as "1h 47m" / "47m". Distinct from fmtTime, which is for a scrubber. */
function fmtRuntime(ticks) {
  if (!ticks) return ''
  const mins = Math.round(ticks / 600_000_000)
  const h = Math.floor(mins / 60)
  return h ? `${h}h ${mins % 60}m` : `${mins}m`
}

// `opts` lets a caller show a different item's art/name than the one the card
// is `data-id`'d and clicked on - used to show a Continue watching episode as
// its series' poster and name (see onePerSeries) without changing
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
 *  than one group of cards, each with its own item list.
 *
 *  `kind` is optional - pass 'video' or 'series' (or a function(item) that
 *  returns one, for a shelf that mixes movies and episodes) to also wire a
 *  right-click menu. Its "Go to details" row reuses `onPick` itself, since
 *  every poster card's click already IS "go to this thing's detail view" -
 *  there is no second navigation function to write. */
function wirePosterCards(container, items, onPick, kind) {
  const byId = new Map(items.map(i => [i.Id, i]))
  container.querySelectorAll('.poster-card').forEach(el => {
    const item = byId.get(el.dataset.id)
    if (!item) return
    el.addEventListener('click', () => onPick(item))
    if (kind) {
      const k = typeof kind === 'function' ? kind(item) : kind
      el.addEventListener('contextmenu', e => { e.preventDefault(); showItemCtxMenu(k, item, el, e.clientX, e.clientY, onPick) })
    }
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
// under each title. `libs`/`ids` are that category's known libraries and its
// currently selected ids (in fetch order), so each grid only ever fans out
// across its own category's libraries, paging each to the end -
// with more than one selected, the grid renders one collapsible group per
// library instead of a single merged pile.
/** Draws either the grouped-by-library layout or a single flat grid from
 *  `raw` (the {grouped, groups|items} shape loadPosterGrid fetched), applying
 *  the current sort/filter prefs. Shared by the initial load and every
 *  sort/filter re-render, which is why the network fetch itself lives only in
 *  loadPosterGrid - this never refetches. A grouped grid filters/sorts each
 *  library's own items separately rather than as one merged list, so
 *  changing sort/filter on a two-library grid re-sorts each shelf on its own. */
function renderPosterGridView(gridId, sub, onPick, kind, libs, raw, prefs) {
  const grid = document.getElementById(gridId)
  const filterSort = arr => CascadeCore.sortLibraryItems(CascadeCore.filterLibraryItems(arr, prefs), prefs.field, prefs.dir)
  if (raw.grouped) {
    if (!raw.groups.some(g => g.items.length)) {
      grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">Nothing here yet</div>`
      return
    }
    const groups = raw.groups.map(g => ({ ...g, items: filterSort(g.items) }))
    // The container is itself a .poster-grid, so without this its groups
    // become grid cells rather than stacked sections. See .lib-grouped.
    grid.classList.add('lib-grouped')
    grid.innerHTML = groups.map(g => {
      const lib = libs.find(l => l.Id === g.libraryId)
      return posterGroupHTML(g.libraryId, lib ? lib.Name : g.libraryId, g.items, sub)
    }).join('')
    grid.querySelectorAll('.lib-group').forEach((section, i) => {
      wirePosterCards(section, groups[i].items, onPick, kind)
    })
    wireLibGroupHeaders(grid)
    wireHShelf(grid)
  } else {
    // Single library: the container goes back to being a real poster grid.
    grid.classList.remove('lib-grouped')
    if (!raw.items.length) {
      grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">Nothing here yet</div>`
      return
    }
    const shown = filterSort(raw.items)
    if (!shown.length) {
      grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">Nothing matches these filters</div>`
      return
    }
    grid.innerHTML = shown.map(i => posterCard(i, sub(i))).join('')
    wirePosterCards(grid, shown, onPick, kind)
  }
}

async function loadPosterGrid(name, gridId, itemType, sub, onPick, libs, ids) {
  const grid = document.getElementById(gridId)
  grid.dataset.loaded = '1'
  // A movie has its own playable media; a series is a container of episodes
  // and has no direct "Play" - see menuItemsForKind in src/core/context-menu.ts.
  const kind = itemType === 'Movie' ? 'video' : 'series'
  // Cleared before the skeleton, not after the fetch: left over from a previous
  // grouped load it makes the container display:block, and eight poster
  // skeletons stack into a full-width column instead of a grid.
  grid.classList.remove('lib-grouped')
  grid.innerHTML = skeletonHTML('poster', 8)
  registerLibView(name, {
    fields: { name: 'Name', year: 'Year', added: 'Date added', random: 'Random' },
    hasGenre: true, hasDecade: true, hasPlayed: true,
    render: (raw, prefs) => renderPosterGridView(gridId, sub, onPick, kind, libs, raw, prefs),
  })
  await loadLibPrefs(name)
  const path = `/Items`
  const params = {
    SortBy: 'SortName', SortOrder: 'Ascending',
    IncludeItemTypes: itemType, Recursive: true,
    Fields: 'UserData,ProductionYear,Genres',
    Limit: 500,
  }
  try {
    if ((ids || []).length > 1) {
      const groups = await jfClient.getAllGrouped(path, params, ids)
      setLibItems(name, { grouped: true, groups })
    } else {
      const data = await jfClient.getAllPaged(path, params, ids)
      setLibItems(name, { grouped: false, items: data.Items || [] })
    }
  } catch {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">Could not load this library</div>`
  }
}

const loadMovies = () => loadPosterGrid(
  'movies', 'movies-grid', 'Movie',
  m => m.ProductionYear || '',
  m => openMovie(m.Id), _movieLibs, jf.movieLibraryIds || [])

const loadShows = () => loadPosterGrid(
  'shows', 'shows-grid', 'Series',
  s => s.ProductionYear || '',
  s => openSeries(s.Id), _showLibs, jf.showLibraryIds || [])

// ── Continue watching (Home) ──
//
// The one video shelf on Home: what is partway through, then the next
// episode of each show being followed (Jellyfin's Next Up). It replaced a
// separate "Recently watched" shelf that mostly repeated this one.
// Horizontal, matching Jellyfin's own webui, via the shared hshelf component;
// hidden when empty, so a music-only user never sees it.
async function loadContinueWatching() {
  const section = document.getElementById('home-resume-section')
  const movieIds = jf.movieLibraryIds || [], showIds = jf.showLibraryIds || []
  if (!movieIds.length && !showIds.length) { section.style.display = 'none'; return }
  const Fields = 'UserData,ProductionYear,SeriesPrimaryImageTag'
  try {
    const [resume, nextUp] = await Promise.all([
      jfClient.getMerged(`/Items`, {
        SortBy: 'DatePlayed', SortOrder: 'Descending',
        IncludeItemTypes: 'Movie,Episode', Filters: 'IsResumable',
        Recursive: true, Fields, Limit: 24,
      }, [...movieIds, ...showIds]),
      // Best effort: a failed Next Up still leaves the resume list.
      showIds.length
        ? jfClient.getMerged('/Shows/NextUp', { UserId: jf.userId, Fields, Limit: 24, EnableResumable: false }, showIds)
            .catch(() => ({ Items: [] }))
        : { Items: [] },
    ])
    // getMerged concatenates per-library results, so the server's DatePlayed
    // order only holds within one library - re-sort across the merge before
    // onePerSeries picks each show's card.
    const partway = (resume.Items || [])
      .sort((a, b) => new Date(b.UserData?.LastPlayedDate || 0) - new Date(a.UserData?.LastPlayedDate || 0))
    const items = onePerSeries([...partway, ...(nextUp.Items || [])]).slice(0, 24)
    if (!items.length) { section.style.display = 'none'; return }
    section.style.display = ''
    const grid = document.getElementById('home-resume-grid')
    // An episode shows its series' poster and name with "S2E6" underneath: an
    // episode still is widescreen and cropped badly into a poster card. One
    // with no SeriesId has no series art to borrow, so it keeps its own.
    grid.innerHTML = hshelfHTML(items.map(item =>
      item.Type === 'Episode' && item.SeriesId
        ? posterCard(item, episodeCode(item), { artId: item.SeriesId, artTag: item.SeriesPrimaryImageTag, title: item.SeriesName || item.Name })
        : posterCard(item, recentVideoSub(item))
    ).join(''))
    wireHShelf(grid)
    // The card is the real Movie or Episode underneath (its own UserData and
    // resume position), so 'video' is the right menu kind even for a card
    // wearing its series' poster. There is no per-episode detail view, so an
    // episode lands on its series.
    wirePosterCards(grid, items, item => {
      if (item.Type === 'Movie') { showView('movies'); openMovie(item.Id) }
      else { showView('shows'); openSeries(item.SeriesId) }
    }, 'video')
  } catch {
    section.style.display = 'none'
  }
}

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

// ── Movie detail ──

/** The movie whose page is open, for its Download button. */
let _openMovie = null

async function openMovie(movieId) {
  _openMovie = null
  document.getElementById('movies-index').style.display = 'none'
  const detail = document.getElementById('movie-detail')
  detail.style.display = ''
  const body = document.getElementById('movie-detail-body')
  body.innerHTML = skeletonHTML('track', 3)

  try {
    // MediaStreams is what applySubtitles() reads, and MediaSources is needed to
    // build a subtitle URL - neither comes back on the grid query, so the detail
    // fetch is where the item becomes playable.
    const movie = await jfGet(`/Items/${movieId}`,
      { Fields: 'Overview,MediaStreams,MediaSources,Genres' })

    const art = artUrl(movie.Id, movie.ImageTags?.Primary)
    const meta = [movie.ProductionYear, fmtRuntime(movie.RunTimeTicks), (movie.Genres || []).slice(0, 3).join(', ')]
      .filter(Boolean).join('  ·  ')
    const resume = resumeTicks(movie)
    // Picture subtitles can only be burned into a download (a re-encode).
    const pictureSubs = (movie.MediaStreams || []).filter(s => s.Type === 'Subtitle' && s.IsTextSubtitleStream === false)

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
            <button class="shuffle-all-btn" id="movie-download" style="display:none"></button>
            ${pictureSubs.length ? `<select class="vd-dl-note" id="movie-burnin" title="Picture subtitles can only be burned into a download, which the server converts">
              <option value="">No burned-in subtitles</option>
              ${pictureSubs.map(s => `<option value="${s.Index}">Burn in ${esc(s.DisplayTitle || s.Language || `track ${s.Index}`)}</option>`).join('')}
            </select>` : ''}
          </div>
        </div>
      </div>`

    // startTicks 0 on "Play from start" is what stops playCurrentTrack falling
    // back to the stored resume position.
    document.getElementById('movie-play').onclick = () => playVideo([movie], 0, 0)
    document.getElementById('movie-resume')?.addEventListener('click',
      () => playVideo([movie], 0, resume))
    _openMovie = movie
    document.getElementById('movie-download').onclick = () => {
      const burn = /** @type {HTMLSelectElement | null} */ (document.getElementById('movie-burnin'))?.value
      toggleVideoDownload('movie', movie, { burnIn: burn ? Number(burn) : null })
    }
    renderVideoDownloadButtons()
  } catch {
    body.innerHTML = `<div class="empty-state">Could not load this movie</div>`
  }
}

// ── Series detail ──

let _currentSeries = null
/** The season whose episodes are showing, for its Download button. */
let _currentSeason = null

async function openSeries(seriesId) {
  document.getElementById('shows-index').style.display = 'none'
  const detail = document.getElementById('show-detail')
  detail.style.display = ''
  const body = document.getElementById('show-detail-body')
  body.innerHTML = skeletonHTML('track', 4)

  try {
    const [series, seasonsData, allEpisodes] = await Promise.all([
      jfGet(`/Items/${seriesId}`, { Fields: 'Overview,Genres' }),
      jfGet(`/Shows/${seriesId}/Seasons`, { UserId: jf.userId, Fields: 'UserData' }),
      // Every episode with its watch state, light, for the Continue button.
      jfGet(`/Shows/${seriesId}/Episodes`, { UserId: jf.userId, EnableImages: false }).catch(() => null),
    ])
    _currentSeries = series
    const seasons = seasonsData.Items || []
    // Where you left off: the episode watched last, resumed, or the one after it.
    const episodes = allEpisodes?.Items || []
    const cont = CascadeCore.continueEpisode(episodes)
    const contEp = cont && episodes[cont.index]
    const contLabel = contEp && (() => {
      const code = `S${contEp.ParentIndexNumber ?? '?'}:E${contEp.IndexNumber ?? '?'}`
      return cont.startTicks ? `Resume ${code} at ${fmtTime(cont.startTicks / 10_000_000)}` : `Continue with ${code}`
    })()
    // Open on that episode's season rather than the first.
    const startSeason = Math.max(0, contEp ? seasons.findIndex(s => s.Id === contEp.SeasonId) : 0)

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
          <div class="vd-actions">
            ${contLabel ? `<button class="shuffle-all-btn" id="series-continue" title="${esc(contEp.Name || '')}">${esc(contLabel)}</button>` : ''}
            <button class="shuffle-all-btn" id="series-download" data-label="Download show" style="display:none"></button>
          </div>
          <label class="dl-follow"><input type="checkbox" id="series-follow"> Download new episodes as they arrive</label>
        </div>
      </div>
      <div class="season-tabs" id="season-tabs">${
        seasons.map((s, i) =>
          `<button class="season-tab${i === startSeason ? ' active' : ''}">${esc(s.Name)}</button>`
        ).join('')
      }<button class="shuffle-all-btn" id="season-download" data-label="Download season" style="display:none"></button></div>
      <div id="episode-list"></div>`

    // Closes over `seasons` by index rather than reading an id back out of a
    // data attribute - the array is right here.
    document.querySelectorAll('#season-tabs .season-tab').forEach((tab, i) => {
      tab.addEventListener('click', () => {
        document.querySelectorAll('#season-tabs .season-tab').forEach(t => t.classList.remove('active'))
        tab.classList.add('active')
        _currentSeason = seasons[i]
        loadEpisodes(seriesId, seasons[i].Id)
      })
    })
    document.getElementById('series-download').onclick = () => toggleVideoDownload('series', series,
      { follow: /** @type {HTMLInputElement} */ (document.getElementById('series-follow')).checked })
    // Before the show is downloaded the box is the choice made with it; after,
    // it changes the download (the download manager has the same switch).
    document.getElementById('series-follow').addEventListener('change', (e) => {
      if (offlineCollection(series.Id)) window.cascade.offline.follow(series.Id, /** @type {HTMLInputElement} */ (e.target).checked).then(refreshOffline)
    })
    document.getElementById('season-download').onclick = () => {
      if (_currentSeason) toggleVideoDownload('season', { ...(_currentSeason), SeriesId: series.Id, SeriesName: series.Name })
    }

    // Its whole season becomes the queue, as a click on the episode does, so it rolls on to the next.
    document.getElementById('series-continue')?.addEventListener('click', async () => {
      try {
        const data = await jfGet(`/Shows/${seriesId}/Episodes`, {
          SeasonId: contEp.SeasonId, UserId: jf.userId, Fields: 'Overview,MediaStreams,MediaSources,UserData',
        })
        const eps = data.Items || []
        const i = eps.findIndex(e => e.Id === contEp.Id)
        if (i >= 0) playVideo(eps, i, cont.startTicks)
      } catch {
        showToast('Could not load that episode')
      }
    })

    _currentSeason = seasons[startSeason] || null
    renderVideoDownloadButtons()
    if (seasons.length) loadEpisodes(seriesId, seasons[startSeason].Id)
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
        <div class="ep-time">${ep.UserData?.Played ? '<span class="ep-watched">✓</span> ' : ''}${fmtRuntime(ep.RunTimeTicks)}<button class="ep-dl" data-id="${esc(ep.Id)}" type="button" aria-label="Download">${DL_ICON}</button></div>
      </div>`
    }).join('')
    list.querySelectorAll('.ep-dl').forEach((b, i) => b.addEventListener('click', (e) => {
      e.stopPropagation()
      const ep = eps[i]
      if (!offlineCollection(ep.Id) && isVideoHeld(ep.Id)) { showNotice('This episode is downloaded with its season or show. Remove that in Downloads.', 'Downloads'); return }
      toggleVideoDownload('episode', ep)
    }))
    renderVideoDownloadButtons()

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
  // A fresh Play click is a new session boundary - unlike the queue simply
  // advancing to the next track, this is where a stale manual audio-track
  // pick from whatever was playing before should stop applying.
  _audioStreamIndexIsExplicit = false
  queue = [...items]
  queueIndex = startIndex
  queueSource = null
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

/** Start a new queue. `source` names it in the queue panel ("From Favorite
 *  Songs"); without one, a single album's tracks are labelled with the album. */
// ── Last queue ───────────────────────────────────────────────────────────────
// The queue, the current track and where it was are kept across restarts
// (CascadeCore.savedQueueOf / restoreQueue): saved every few seconds when it
// changed, and restored after sign-in, shown but not loaded. Nothing plays and
// nothing is reported to the server until play is pressed, which then starts
// that track where it was left (playOrResume). A Waterfall guest neither saves
// nor restores: its queue is the host's.
let _lastSavedQueue = undefined

function _saveQueueState() {
  if (blocksLocalPlayback()) return
  const state = CascadeCore.savedQueueOf(queue, queueIndex, mediaPosition(), _unshuffledQueue)
  // Nothing has played this session (the restore card may still be up, or
  // was ignored): last session's queue stays saved for the next launch.
  if (!state && _lastSavedQueue === undefined) return
  const text = JSON.stringify(state)
  if (text === _lastSavedQueue) return
  _lastSavedQueue = text
  window.cascade.store.set(lastQueueKey(), text)
}

/** Local mode keeps its own: a folder's ids mean nothing to a server, and
 *  the reverse. */
function lastQueueKey() {
  return isLocalMode() ? 'localLastQueue' : 'lastQueue'
}
setInterval(_saveQueueState, 5000)
window.addEventListener('beforeunload', _saveQueueState)

async function restoreLastQueue() {
  if (queue.length || blocksLocalPlayback()) return
  let saved = null
  try { saved = JSON.parse(await window.cascade.store.get(lastQueueKey()) || 'null') } catch {}
  const ids = CascadeCore.savedQueueIds(saved)
  if (!ids.length) return
  const items = await jfItemsByIds(ids, 'AlbumId,AlbumPrimaryImageTag,UserData,MediaStreams,MediaSources')
  if (queue.length || blocksLocalPlayback()) return   // something started meanwhile
  const restored = CascadeCore.restoreQueue(saved, items)
  if (!restored) return
  // Offered, not put back unasked: a card in the corner for 20 s. Ignoring it
  // keeps the saved queue (nothing overwrites it while nothing plays), so the
  // next launch asks again.
  offerQueueRestore(restored, () => applyRestoredQueue(restored))
}

function applyRestoredQueue(restored) {
  if (queue.length || blocksLocalPlayback()) return   // something started while the card was up
  queue = restored.queue
  queueIndex = restored.index
  _unshuffledQueue = shuffle ? (restored.unshuffled.length ? restored.unshuffled : [...queue]) : []
  queueSource = CascadeCore.queueSourceFallback(queue)
  _restoredResume = { sec: restored.positionSec }
  _lastSavedQueue = JSON.stringify(CascadeCore.savedQueueOf(queue, queueIndex, restored.positionSec, _unshuffledQueue))
  updateNowPlaying(queue[queueIndex])
  syncProgressUI()
  renderQueuePanel()
}

// The "Pick up where you left off?" card (index.html #restore-card): the song,
// its artist and the queue's length, with a bar that runs out after 20 s and
// closes the card. Restore runs `apply`; closing or running out does nothing.
const RESTORE_OFFER_SECONDS = 20
let _restoreOfferTimer = null

function offerQueueRestore(restored, apply) {
  const card = document.getElementById('restore-card')
  if (!card) return
  const item = restored.queue[restored.index] || restored.queue[0]
  const count = restored.queue.length
  const artist = item?.AlbumArtist || item?.Artists?.[0] || ''
  document.getElementById('restore-card-sub').textContent =
    [item?.Name, artist].filter(Boolean).join(' - ') + ` \u00B7 ${count === 1 ? '1 song' : `${count} songs`}`
  const art = item ? artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary) : null
  document.getElementById('restore-card-art').style.backgroundImage = art ? `url("${art}")` : ''
  const timer = document.getElementById('restore-card-timer')
  timer.classList.remove('running')
  card.style.setProperty('--restore-seconds', `${RESTORE_OFFER_SECONDS}s`)
  card.classList.remove('hidden')
  // Restart the bar's transition from full.
  void timer.offsetWidth
  timer.classList.add('running')
  const close = () => {
    clearTimeout(_restoreOfferTimer)
    card.classList.add('hidden')
    document.getElementById('restore-card-yes').onclick = null
    document.getElementById('restore-card-no').onclick = null
  }
  document.getElementById('restore-card-yes').onclick = () => { close(); apply() }
  document.getElementById('restore-card-no').onclick = close
  clearTimeout(_restoreOfferTimer)
  _restoreOfferTimer = setTimeout(close, RESTORE_OFFER_SECONDS * 1000)
}

// Play, or for a restored queue, start its track where it was left.
function playOrResume() {
  if (_restoredResume && queue[queueIndex]) {
    playCurrentTrack({ startTicks: Math.round(_restoredResume.sec * 10_000_000) })
    return
  }
  audio.play().catch(() => {})
}

function playItems(items, startIndex, source) {
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
  queueSource = source || CascadeCore.queueSourceFallback(items)
  playCurrentTrack()
}

// ── Video mode ────────────────────────────────────────────────────────────────

// Flip the overlay between the music layout (art + lyrics/queue columns) and the
// single-column video layout. Purely a class toggle: the CSS in index.html owns
// what actually shows, so there is one place to change if the layout moves.
/** Playback speed for video, set with < and >. Kept across videos for the
 *  session, like YouTube's, and never applied to music - applyVideoMode()
 *  puts both decks back to 1x for a song. */
let _videoRate = 1

function applyVideoMode(on) {
  // Music and video keep separate saved EQ curves - this is the one place
  // playback knows which is active, so it is also where the live graph
  // switches which profile it is wired to.
  eqActiveMode = on ? 'video' : 'music'
  _applyEqToGraph()
  const ov = document.getElementById('np-overlay')
  // Video Now Playing has no editor (the spec's scope): close it first.
  if (on) closeEditor({ instant: true })
  ov.classList.toggle('video', !!on)
  // Only the current deck may show a picture - the other is mid-crossfade or idle.
  DECKS.forEach(d => d.classList.toggle('deck-hidden', d !== audio))
  // A film keeps the session's speed (< and >); a song is always 1x.
  DECKS.forEach(d => { d.playbackRate = d.defaultPlaybackRate = on ? _videoRate : 1 })
  // A film opened on its own is a queue of one, so prev and next have nowhere
  // to go. A season is not - that queue is the whole point of next-episode.
  ov.classList.toggle('single', !!on && queue.length <= 1)
  // The bottom bar gets the same treatment: shuffle, repeat, lyrics and the
  // miniplayer are song controls, and prev/next only apply to a season.
  const bar = document.querySelector('.statusbar')
  bar.classList.toggle('video', !!on)
  bar.classList.toggle('single', !!on && queue.length <= 1)
  loadChapters(on ? queue[queueIndex] : null)
  loadSegments(on ? queue[queueIndex] : null)
  // A movie playing behind the library grid with no picture is confusing, so
  // opening the overlay is part of starting video, not a separate step.
  if (on) openOverlay()
}

// ── Chapters ──
//
// Fetched once when a video starts rather than added to every query that can
// put one in the queue (grids, Home, episodes) - one small request per film.

/** The current video's chapters, from CascadeCore.chapterList(). */
let _chapters = []

async function loadChapters(item) {
  _chapters = []
  renderChapterMarks()
  if (!item || !isVideoItem(item)) return
  try {
    const full = await jfGet(`/Items/${item.Id}`, { Fields: 'Chapters' })
    // Skipped past it while the request was out: these are someone else's.
    if (queue[queueIndex]?.Id !== item.Id) return
    _chapters = CascadeCore.chapterList(full.Chapters, item.RunTimeTicks)
  } catch { /* no chapters is the same as none */ }
  renderChapterMarks()
}

/** Ticks on the scrubber at each chapter start, and the Chapters button only
 *  when there is something to pick from. */
function renderChapterMarks() {
  const bar = document.getElementById('ov-prog-bar')
  bar.querySelectorAll('.ov-chapter-mark').forEach(m => m.remove())
  document.getElementById('ov-chapters').style.display = _chapters.length ? '' : 'none'
  const dur = mediaDuration()
  if (!dur) return
  for (const c of _chapters) {
    if (c.sec <= 0) continue
    const mark = document.createElement('span')
    mark.className = 'ov-chapter-mark'
    mark.style.left = `${(c.sec / dur) * 100}%`
    bar.appendChild(mark)
  }
}

// ── Skip intro and outro ──
//
// Jellyfin 10.10+ Media Segments, fetched once per video next to the chapters.
// An older server (404) or one with no provider (empty list) shows nothing.
// Pure parsing and "which segment is playing" live in src/core/media-segments.ts.

/** The current video's segments, from CascadeCore.parseMediaSegments(). */
let _segments = []
/** The segment the button is showing for, or null. */
let _activeSegment = null
/** Settings > Playback: skip an intro or outro the moment it starts. */
let autoSkipSegments = false
/** Segments auto-skip has already fired for, so seeking back is not fought. */
const _autoSkipped = new Set()

async function loadSegments(item) {
  _segments = []
  _autoSkipped.clear()
  _syncSkipButton()
  if (!item || !isVideoItem(item)) return
  try {
    const data = await jfGet(`/MediaSegments/${item.Id}`)
    // Skipped past it while the request was out: these are someone else's.
    if (queue[queueIndex]?.Id !== item.Id) return
    _segments = CascadeCore.parseMediaSegments(data)
  } catch { /* no segments is the same as none */ }
  _syncSkipButton()
}

/** Show, relabel or hide the button for the segment at the playhead, and fire
 *  auto-skip. Runs on every timeupdate while a video has segments. */
function _syncSkipButton() {
  const btn = document.getElementById('ov-skip-segment')
  const seg = _segments.length && playingVideo() ? CascadeCore.activeSegment(_segments, mediaPosition()) : null
  _activeSegment = seg
  btn.classList.toggle('show', !!seg)
  if (!seg) return
  const label = CascadeCore.skipLabel(seg)
  if (btn.textContent !== label) btn.textContent = label
  const key = CascadeCore.segmentKey(queue[queueIndex].Id, seg)
  if (autoSkipSegments && !audio.paused && !_autoSkipped.has(key)) {
    _autoSkipped.add(key)
    skipActiveSegment()
  }
}

/** Skip what the button offers: seek past it, or for an outro that runs to the
 *  end, on to the next episode (or the end, when there is none). */
function skipActiveSegment() {
  const seg = _activeSegment
  if (!seg || !playingVideo()) return
  const action = CascadeCore.skipAction(seg, mediaDuration())
  if (action.kind === 'next') {
    if (queueIndex < queue.length - 1 && !blocksLocalPlayback()) document.getElementById('btn-next').click()
    else seekTo(mediaDuration())
  } else {
    seekTo(action.sec)
  }
  videoOsd(CascadeCore.skipLabel(seg).replace('Skip', 'Skipped'))
}

document.getElementById('ov-skip-segment').addEventListener('click', (e) => {
  e.stopPropagation()
  skipActiveSegment()
})
onDeck('timeupdate', () => { if (_segments.length) _syncSkipButton() })

// Attach text subtitles as native <track> elements.
//
// Only text subtitles appear here. Bitmap ones (PGS, VOBSUB) cannot be drawn by
// a <track>, so ELECTRON_PROFILE deliberately omits them and the server burns
// them into the video instead - which means they arrive as picture and need
// nothing from this function.
function applySubtitles(item, resolved) {
  audio.querySelectorAll('track').forEach(t => t.remove())
  if (!isVideoItem(item)) return

  // A download plays its own WebVTT files, saved beside it.
  if (resolved?.local) {
    for (const s of _offline.subs?.[item.Id] || []) {
      const track = document.createElement('track')
      track.kind = 'subtitles'
      track.label = s.title || s.language || `Track ${s.index}`
      if (s.language) track.srclang = s.language
      track.src = s.url
      audio.appendChild(track)
      track.track.mode = (s.isDefault || s.isForced) ? 'showing' : 'disabled'
    }
    return
  }

  const sourceId = resolved?.mediaSourceId
  if (!sourceId) return

  const subs = (item.MediaStreams || []).filter(s =>
    s.Type === 'Subtitle' && s.IsTextSubtitleStream)

  for (const s of subs) {
    const track = document.createElement('track')
    track.kind = 'subtitles'
    track.label = s.DisplayTitle || s.Language || `Track ${s.Index}`
    if (s.Language) track.srclang = s.Language
    track.src = `${jf.url}/Videos/${item.Id}/${sourceId}/Subtitles/${s.Index}/Stream.vtt?ApiKey=${jf.token}`
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
// opts.skip: { from, kind } from skipTo, for a skip's short transition.
async function playCurrentTrack(opts = {}) {
  if (blocksLocalPlayback()) return
  if (queueIndex < 0 || queueIndex >= queue.length) return
  const item = queue[queueIndex]
  _restoredResume = null

  // Every track change funnels through here, so this is the one place that
  // needs to know to abandon an in-progress crossfade - covers next/prev,
  // queue-row jumps, double-click play, instant mix, everything.
  // A cover cut still on screen sweeps off whole first, before the cover
  // under it changes again.
  trailArtSlice(_slice, item)
  cancelCrossfade()
  // Laid over the outgoing cover now, before anything below changes it.
  const skipSlice = opts.skip ? _beginSkip(opts.skip, item) : null
  // Whatever the server was encoding for the outgoing item is now waste. Runs
  // before _playSessionId is replaced by the new stream's.
  abandonCurrentEncoding()

  const video = isVideoItem(item)
  let shownEarly = false

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
    // A skip lets the old track fade out under the new one.
    if (opts.skip) _swapDeckFadingOut(prefetched.deck, audio)
    else _swapDeck(prefetched.deck, audio)
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
    // On a slow connection the resolve below can take seconds. Showing the
    // new track only after it meant a skip looked like it did nothing, so
    // people pressed again and skipped several songs once the network caught
    // up. The title and cover change now, with a wheel over the cover until
    // the deck actually plays.
    updateNowPlaying(item)
    highlightPlayingRow()
    if (skipSlice) startArtSlice(skipSlice, SKIP_TRANSITION_SECS)
    shownEarly = true
    _setTrackLoading(true)
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
    // Skipped entirely once the user has picked a track by hand - see
    // _audioStreamIndexIsExplicit above. Without this gate, the next track
    // (or _handleUndecodableAudio's own re-resolve) silently recomputed and
    // threw the user's pick away.
    // A film started from search or a card menu comes from a list fetched
    // without MediaStreams, so its audio menu said "Only one track" and the
    // decodable-track check had nothing to read. Filled in once, here, where
    // every way of starting a video ends up.
    if (video && !item.MediaStreams && !_offline.ready[item.Id]) {
      const [full] = await jfItemsByIds([item.Id], 'Overview,MediaStreams,MediaSources,UserData')
      if (queue[queueIndex]?.Id !== item.Id) return
      if (full?.MediaStreams) Object.assign(item, { MediaStreams: full.MediaStreams, MediaSources: full.MediaSources })
    }
    if (video && !_audioStreamIndexIsExplicit) {
      _audioStreamIndex = neededAudioStreamIndex(item.MediaStreams, decodableVideoAudioCodecs())
    } else if (!video) {
      _audioStreamIndex = null
      _audioStreamIndexIsExplicit = false
    }

    const resolved = await resolveTrackStream(item.Id, video ? 'Video' : 'Audio',
      { startTicks, audioStreamIndex: _audioStreamIndex })
    if (queue[queueIndex]?.Id !== item.Id) return

    // A skip loads the new track on the idle deck, so the old one fades out
    // there as this one buffers. Only once resolved: swapped any sooner,
    // `audio` would be an empty, paused deck for the round trip, and the
    // miniplayer and play button read that as a pause. Songs only, since a
    // deck draws a video's picture.
    if (opts.skip && !video && !isVideoItem(opts.skip.from) && !audio.paused && _audioCtx && _deckGain(audio)) {
      _swapDeckFadingOut(DECKS.find(d => d !== audio), audio)
    }
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

  // By now `audio` is whichever deck is actually carrying `item`, on every
  // path above (cold load, prefetched swap, or a crossfade's own handoff
  // already having pointed it here). Cached and idempotent for the prefetch
  // and crossfade cases; a fresh fetch only for a cold load with no prefetch.
  _applyNormalizationToDeck(audio, item)
  if (!shownEarly) {
    updateNowPlaying(item)
    highlightPlayingRow()
    if (skipSlice) startArtSlice(skipSlice, SKIP_TRANSITION_SECS)
  }
  reportPlaybackStart(item.Id)
}

// ── Smooth skips ─────────────────────────────────────────────────────────────
// A skip (Next, Previous, a jump in the queue) gets a short version of the
// crossfade's transition while Settings > Playback > Smooth skips is on
// (displayPrefs.skipTransitions): the cover slice sweeps straight across with
// no hold, since only one song plays; going forward, the lyrics roll on to the
// next song (_ovRollIn, compressed when it is far below); and the old track
// fades out over SKIP_FADE_SECS instead of stopping dead, under the new one
// when it is already buffered (the next one), or as it loads on the idle deck
// when it is not. The new one starts at full volume, so its
// first beat is not faded away. The colors fade
// as on any song change (fadeOverlayColors). Rapid skips need nothing extra:
// each one cuts the last one's fade (cancelCrossfade) and trails its cover off
// (trailArtSlice).
const SKIP_TRANSITION_SECS = 0.45
const SKIP_FADE_SECS = 0.3

/** Moves to queue[index] as a skip, from the controls that skip. */
function skipTo(index, kind) {
  const from = queue[queueIndex]
  queueIndex = index
  const skip = displayPrefs.skipTransitions && from && from !== queue[index] ? { from, kind } : null
  playCurrentTrack(skip ? { skip } : {})
}

/** The visual side of a skip, from playCurrentTrack before the cover changes:
 *  the lyrics roll going forward, and the slice laid over the old cover. The
 *  slice, or null when there is none to run. */
function _beginSkip({ from, kind }, to) {
  if (!from || !to || isVideoItem(from) || isVideoItem(to)) return null
  if (kind !== 'prev') _rollLyricsToNext()
  const key = it => it.AlbumId || it.Id
  // A slice still on screen (a skip a moment ago) carries this one off on its trail.
  if (key(from) === key(to) || _slice || !prepareCrossfadeSlice()) return null
  Object.assign(_slice, { under: key(to), sweepMs: SKIP_TRANSITION_SECS * 1000, slideOutMs: SKIP_TRANSITION_SECS * 1000 })
  return _slice
}

/** _swapDeck, but the outgoing deck keeps playing as its gain falls to 0 over
 *  SKIP_FADE_SECS. It is a crossfade tail (_cfTail): the prefetch waits for it
 *  to end, and the next skip cuts it short. Without the Web Audio graph there
 *  is no gain to ramp, so it is a plain swap. */
function _swapDeckFadingOut(incoming, outgoing) {
  const outGain = _audioCtx && _deckGain(outgoing)
  if (!outGain) { _swapDeck(incoming, outgoing); return }
  audio = incoming
  _mediaSrc = _deckSource(incoming)
  const now = _audioCtx.currentTime
  const inGain = _deckGain(incoming)
  if (inGain) { inGain.gain.cancelScheduledValues(now); inGain.gain.setValueAtTime(1, now) }
  outGain.gain.cancelScheduledValues(now)
  outGain.gain.setValueAtTime(outGain.gain.value, now)
  outGain.gain.linearRampToValueAtTime(0, now + SKIP_FADE_SECS)
  _cfTail = { deck: outgoing, timer: setTimeout(() => { _cutCrossfadeTail(); _schedulePrefetch() }, SKIP_TRANSITION_SECS * 1000) }
}

/** The wheel over the player bar's and Now Playing's cover (.art-loading):
 *  on from a track being picked, or the playing one stalling, until it plays. */
function _setTrackLoading(on) {
  for (const id of ['np-art', 'ov-art']) document.getElementById(id).classList.toggle('art-loading', on)
}
// Not on 'pause' or 'emptied': swapping the src fires those on the way to
// playing, and the wheel would drop while the new track still loads.
onDeck('playing', () => _setTrackLoading(false))
onDeck('error', () => _setTrackLoading(false))
// A stall mid-song (the network dropping under it) gets the same wheel.
onDeck('waiting', () => { if (!audio.paused) _setTrackLoading(true) })

let _prefetchSession = 0

/** Warms the iTunes cover cache for an upcoming track. Deduped by artist+album
 *  inside fetchItunesArt, so playing through an album costs one lookup rather
 *  than one per track. Fire and forget - the point is that the answer is
 *  already sitting in the cache by the time the track starts and the Discord
 *  presence wants it, instead of being a network round trip at exactly the
 *  moment it is needed. */
function warmItunesArt(item) {
  if (!item || isVideoItem(item)) return
  const artist = item.AlbumArtist || item.Artists?.[0] || ''
  const album  = item.Album || ''
  if (artist || album) fetchItunesArt(artist, album).catch(() => {})
}

async function _prefetchUpcoming() {
  const session = ++_prefetchSession
  const start = queueIndex + 1
  const end = Math.min(start + 5, queue.length)
  for (let i = start; i < end; i++) {
    if (session !== _prefetchSession) break        // user skipped, abandon
    const item = queue[i]
    if (!item?.Id) continue
    warmItunesArt(item)
    // Cached lyrics used to `continue` straight past the gap below, which was
    // right when they were the only request here. The cover warm-up is a
    // request too, so the spacing now applies either way.
    if (!_lyricsCache.has(item.Id)) {
      await fetchLyricsWaterfall(item).catch(() => {})
      if (session !== _prefetchSession) break
      if (i === start) _refreshLyricsPreviews()
    }
    await new Promise(r => setTimeout(r, 400))    // brief gap between API calls
  }
}

// Marquee: applyMarquee() scrolls a line too long for its box. It lives in
// marquee.js, shared with the miniplayer. Used by the statusbar and both
// fullscreen overlay lines.
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
  _syncStyleEntries()
  _ceQueueMoved()

  // Warm the cache for the current song and the next 5 in queue. Movies have no
  // lyrics, and asking LRCLIB and Kugou about one wastes two round-trips per
  // title and pollutes the cache with misses. A radio station is the same
  // problem for a different reason: its "title" is a station name, and
  // sending that to LRCLIB/Kugou on every tune-in is a lookup that can only
  // ever miss.
  // Cleared while the new song's search runs.
  _lyricsMark = null
  _applyLyricsMark()
  if (item?.Id && !video && !CascadeCore.isRadioItem(item)) {
    fetchLyricsWaterfall(item).then(r => _markLyricsFor(item, r)).catch(() => {})
    _prefetchUpcoming()
  }

  _currentHighResArtUrl = null // reset for new track

  const art = artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
  _currentHighResArtUrl = art  // Jellyfin 600px as immediate baseline
  _animatedArtItemId = null    // reset for new track
  _setArtStill(document.getElementById('np-art'), art)

  // Upgrade the still to the animated original if the library has one. Videos
  // are skipped - a poster is a poster.
  if (art && !video) {
    const artItemId = item.AlbumId || item.Id
    const animItemId = item.Id
    animatedArtUrl(artItemId).then(animUrl => {
      if (!animUrl || queue[queueIndex]?.Id !== animItemId) return  // track changed
      _animatedArtItemId = animItemId
      _currentHighResArtUrl = animUrl
      _setArtStill(document.getElementById('np-art'), animUrl)
      _setArtStill(document.getElementById('ov-art'), animUrl)
    }).catch(() => {})
    // Or a video cover from Cascade Server (cover.mp4 beside the album, or
    // TIDAL), over the still: the still stays underneath for the background
    // and the album-art accent, which read an image.
    pluginCoverVideoUrl(artItemId, () => queue[queueIndex]?.Id === animItemId).then(videoUrl => {
      if (!videoUrl || queue[queueIndex]?.Id !== animItemId) return
      const tag = `<video class="art-video" data-album="${esc(artItemId)}" src="${esc(videoUrl)}" autoplay loop muted playsinline disablepictureinpicture aria-hidden="true" onerror="this.remove()"></video>`
      for (const id of ['np-art', 'ov-art']) {
        const host = document.getElementById(id)
        host.querySelector('.art-video')?.remove()
        host.insertAdjacentHTML('beforeend', tag)
      }
    }).catch(() => {})
  }
  document.getElementById('np-info').innerHTML = `
    <span class="np-scroll-inner">
      <span class="np-title">${esc(item.Name)}${explicitBadgeHtml(item.Id)}</span>
      <span class="np-sep">-</span>
      <span class="np-artist">${esc(secondaryLine(item))}</span>
    </span>
  `
  refreshMarquees()
  // Sync like state from Jellyfin user data
  const liked = item.UserData?.IsFavorite || false
  document.getElementById('btn-like').classList.toggle('liked', liked)
  document.getElementById('ov-art-like').classList.toggle('liked', liked)

  // Update Touch Bar track label
  window.cascade.touchbarUpdate({ title: `${item.Name}  -  ${item.AlbumArtist || item.Artists?.[0] || ''}` })

  // Notify Cha0s Stream of the new track
  // Ids rather than a URL: artUrl() embeds this client's token, and a consumer
  // with its own Jellyfin session (Cha0s Stream borrows one via
  // /cascade/jellyfin) should build its own. Same fallbacks as line 1504.
  window.cascade.nowPlayingUpdate({
    title: item.Name || '',
    artist: item.AlbumArtist || item.Artists?.[0] || '',
    album: item.Album || '',
    // The track's own id, distinct from artItemId, which prefers AlbumId and so
    // identifies the artwork rather than the song. A consumer correlating what is
    // playing against a request queue needs an exact key: matching on artist and
    // title strings is guesswork, and artItemId collides across a whole album.
    trackId: item.Id || '',
    artItemId: item.AlbumId || item.Id || '',
    artImageTag: item.AlbumPrimaryImageTag || item.ImageTags?.Primary || '',
    durationMs: item.RunTimeTicks ? Math.round(item.RunTimeTicks / 10_000) : null,
    positionMs: 0,
    isPlaying: true,
  })

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
  _syncRpcClock()
  updateDiscordPresence(item)

  // Album art accent: fetch for canvas color extraction (ApiKey is in URL, no extra header needed)
  // Skipped for video - the overlay shows the film, not a recoloured backdrop.
  if (themeAlbumArt && art && !video) {
    _currentBgArtUrl = art
    themeFromArtUrl(art)
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
      if (_animatedArtItemId === itemId) return  // a moving library cover beats a still
      _currentHighResArtUrl = itunesUrl
      _currentBgArtUrl = itunesUrl
      // Update status bar art
      _setArtStill(document.getElementById('np-art'), itunesUrl)
      // Update overlay art if open
      _setArtStill(document.getElementById('ov-art'), itunesUrl)
      // Update OS Now Playing widget
      if ('mediaSession' in navigator && navigator.mediaSession.metadata) {
        navigator.mediaSession.metadata.artwork = [{ src: itunesUrl, sizes: '600x600', type: 'image/jpeg' }]
      }
      // Re-run color extraction with the higher-quality source
      if (themeAlbumArt) {
        themeFromArtUrl(itunesUrl)
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
//
// That drop keeps the renderer from duplicating window state, and it stays. But
// with no miniplayer open every push would be built, serialised and structured-
// cloned across IPC purely to be discarded - four times a second, all session.
// Bail before doing that work. _miniplayerOpen is kept by main.js's open-state
// message (declared here, above every caller, so no use can reach its TDZ).
let _miniplayerOpen = false
let _mpSheetOf = null, _mpSheetEmphasis = false, _mpSheetId = 0, _mpSheetSent = false

function pushMiniplayerState() {
  if (!_miniplayerOpen) return
  const item = queue[queueIndex]
  if (!item) { window.cascade.miniPlayer.updateState(null); return }
  const art = _currentHighResArtUrl || artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
  const track = { itemId: item.Id, title: item.Name || '', subtitle: secondaryLine(item), artUrl: art }
  // The timed lyric sheet, for the miniplayer's own karaoke: only when it
  // changed (a new lyricsData array, or the Spicy credit that decides held
  // notes) or the miniplayer asked for it again. Every tick carries the id.
  const emphasis = !!lyricsCredit
  if (lyricsData !== _mpSheetOf || emphasis !== _mpSheetEmphasis) {
    _mpSheetOf = lyricsData
    _mpSheetEmphasis = emphasis
    _mpSheetId++
    _mpSheetSent = false
  }
  const sheet = _mpSheetSent ? null : CascadeCore.miniplayerSheet(lyricsData, emphasis)
  _mpSheetSent = true
  // Up Next: what follows the current track.
  const queueStart = queueIndex + 1
  const upNext = queue.slice(queueStart, queueStart + CascadeCore.MINIPLAYER_QUEUE_MAX).map(q => ({
    title: q.Name || '',
    subtitle: secondaryLine(q),
    artUrl: artUrl(q.AlbumId || q.Id, q.AlbumPrimaryImageTag || q.ImageTags?.Primary),
  }))
  // The heart's own class, same source of truth toggleLike() reads for the
  // current track. By id, not the likeBtn const: this can run before that
  // line of the script has executed.
  const isFavorite = !!document.getElementById('btn-like')?.classList.contains('liked')
  window.cascade.miniPlayer.updateState(CascadeCore.buildMiniplayerState(track, !audio.paused, mediaPosition(), mediaDuration(), _mpSheetId,
    { isFavorite, volume, credit: lyricsCredit, sheet, queue: upNext, queueStart, shuffle, autoMix: autoMixEnabled, repeat: repeatMode,
      live: CascadeCore.isRadioItem(item) }))
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
  // Only a progressive video transcode can be re-pointed by swapping the
  // offset. Direct play and HLS seek on the element, and music never gets
  // here at all.
  _transcodeUrl = (!resolved.direct && isVideoItem(queue[queueIndex]) && !CascadeCore.isHlsUrl(resolved.url))
    ? resolved.url : null
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
  if (_restoredResume) return _restoredResume.sec
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
  if (_restoredResume && item?.RunTimeTicks) return item.RunTimeTicks / 10_000_000
  if (isVideoItem(item) && item?.RunTimeTicks) return item.RunTimeTicks / 10_000_000
  return audio.duration || 0
}

/**
 * Seek to a position in the item, in seconds.
 *
 * Direct play and HLS can move the element's own clock. A progressive
 * transcode cannot: the bytes past the encoded point do not exist yet, so the
 * only way there is to ask the server for a fresh stream starting at that
 * offset. Video transcodes are HLS now; the progressive path is kept for a
 * server that answers with one anyway.
 */
async function seekTo(sec) {
  const item = queue[queueIndex]
  const dur = mediaDuration()
  const target = Math.max(0, Math.min(dur || sec, sec))

  // Not loaded yet (a restored queue): move where play will start from.
  if (_restoredResume) { _restoredResume.sec = target; syncProgressUI(); return }
  if (_transcodeUrl) {
    await restartStreamAt(target)
    return
  }
  audio.currentTime = target
}

/** Which audio track the user picked, as a MediaStreams index. null = server's
 *  choice, which is what everything but an explicit switch uses. */
let _audioStreamIndex = null

/** True once the user has picked a track by hand via the ov-audio-track
 *  dropdown. Distinguishes their choice from neededAudioStreamIndex()'s own
 *  writes to _audioStreamIndex (playCurrentTrack, below) - without this,
 *  advancing to the next track silently recomputed and overwrote whatever
 *  the user had picked. Cleared in playVideo(): a fresh "Play" click is a new
 *  session, but the queue auto-advancing to the next track is not. */
let _audioStreamIndexIsExplicit = false

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
    isMuted: _muted,
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
  const item = queue[queueIndex]
  if (item && !isVideoItem(item) && !CascadeCore.isRadioItem(item)) countTelemetrySong()
  CascadeCore.reportStart(jfClient, playbackSnapshot(itemId)).then(ok => {
    // Jellyfin counts a play on this report, so one it never heard (offline) is
    // kept and sent later as a played-at update. Music only: a film or a radio
    // channel has no play to lose.
    // A report that landed changed the server's history: the snapshot
    // follows it, so this device's own plays never read as someone else's.
    // A start that landed means online, so it is also when the daily
    // telemetry ping goes: never at launch, before Offline Mode is restored.
    if (!ok) { if (item && !isVideoItem(item) && !CascadeCore.isRadioItem(item)) queueOfflinePlay(item.Id) }
    else { scheduleHistorySnapshot(); maybeSendTelemetry() }
  })
  startProgressReporting()
}

/** `item`: when the queue no longer holds it (stopPlayback clears it first). */
function reportPlaybackStopped(itemId, positionTicks, item) {
  _reportingActive = false
  stopProgressReporting()
  const stopped = item || queue.find(q => q?.Id === itemId)
  const ticks = positionTicks ?? Math.round(mediaPosition() * 10_000_000)
  noteOfflineWatched(stopped, ticks)
  CascadeCore.reportStopped(jfClient, playbackSnapshot(itemId, ticks)).then(ok => {
    // Where a video stopped is what the server resumes from next time: one
    // it never heard (offline) is queued with its time and sent later.
    if (ok) scheduleHistorySnapshot()
    else if (stopped && isVideoItem(stopped) && !CascadeCore.isRadioItem(stopped)) queueVideoPosition(stopped, ticks)
  })
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
  const radio = CascadeCore.isRadioItem(item)
  // Read the position before clearing src, which resets currentTime to 0.
  const positionTicks = Math.round(mediaPosition() * 10_000_000)
  abandonCurrentEncoding()
  _clearStreamPrefetch()
  if (radio) _closeRadioStreamIfAny()

  audio.pause()
  _detachDeck(audio)
  audio.querySelectorAll('track').forEach(t => t.remove())
  queue = []; queueIndex = -1; queueSource = null
  closeEditor({ instant: true })
  _syncStyleEntries()
  // Drop video mode after clearing the queue, so the class toggle sees an empty
  // queue and does not try to re-open the overlay.
  applyVideoMode(false)

  // A channel has no finite position to report and Jellyfin has nothing
  // meaningful to do with a played-state update against a TvChannel item.
  if (item && !radio) reportPlaybackStopped(item.Id, positionTicks, item)

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

// A seek moves the playback head without starting a new track, so Discord's
// bar has to be re-anchored or it keeps drawing from the old position. Scrubbing
// while paused only re-anchors: posting there would put the presence back up
// and set the bar running against a track that is not playing.
onDeck('seeked', () => {
  _syncRpcClock()
  if (!audio.paused) updateDiscordPresence(queue[queueIndex])
})

// ── Audio events ──────────────────────────────────────────────────────────────

// Both scrubbers show the same numbers, so they are filled from one place -
// they used to be two near-identical handlers reading audio.currentTime, and
// only one of them got fixed the first time the offset mattered.
// While a seek is being picked (a drag, or arrow keys before they settle), the
// seconds it is headed for: the bar shows it, the right-hand time reads it, and
// the left one keeps counting the song as it plays. Playback would otherwise
// paint over the drag on every tick and snap it back. Null otherwise.
let _scrubTarget = null

function syncProgressUI() {
  const cur = mediaPosition()
  const dur = mediaDuration()
  // A live radio stream reports audio.duration as Infinity - fmtTime would
  // render that as a literal "Infinity:00" rather than failing loudly, so it
  // needs its own label, and the bar stays at 0% rather than NaN%.
  const live = !isFinite(dur)
  const scrub = !live && dur && _scrubTarget != null
  const shown = scrub ? _scrubTarget : cur
  const durText = live ? 'LIVE' : fmtTime(scrub ? _scrubTarget : dur)
  const pct = !live && dur ? `${Math.min(100, (shown / dur) * 100)}%` : '0%'

  document.getElementById('prog-cur').textContent = fmtTime(cur)
  document.getElementById('prog-dur').textContent = durText
  document.getElementById('prog-fill').style.width = pct
  setBarAriaNow(document.getElementById('prog-bar'), shown, dur, fmtTime(shown))

  pushMiniplayerState()

  if (!overlayOpen) return
  document.getElementById('ov-cur').textContent = fmtTime(cur)
  document.getElementById('ov-dur').textContent = durText
  document.getElementById('ov-prog-fill').style.width = pct
  setBarAriaNow(document.getElementById('ov-prog-bar'), shown, dur, fmtTime(shown))
}

onDeck('timeupdate', syncProgressUI)

let _npPositionSentAt = 0
onDeck('timeupdate', () => {
  const now = Date.now()
  if (now - _npPositionSentAt < 3000) return
  _npPositionSentAt = now
  const dur = mediaDuration()
  window.cascade.nowPlayingUpdate?.({
    positionMs: Math.round(mediaPosition() * 1000),
    durationMs: dur && isFinite(dur) ? Math.round(dur * 1000) : null,
  })
})

onDeck('play', () => {
  document.getElementById('icon-play').style.display = 'none'
  document.getElementById('icon-pause').style.display = ''
  // Re-anchor on every play, not just when resuming: a track can begin partway
  // in (a video resume, or "play from here"), and time spent paused has to come
  // off the clock either way. Both used to leave Discord counting from the
  // wrong instant - invisible when it was only an elapsed number, obvious once
  // there is a bar drawn from it.
  _syncRpcClock()
  updateDiscordPresence(queue[queueIndex])
})

onDeck('pause', () => {
  document.getElementById('icon-play').style.display = ''
  document.getElementById('icon-pause').style.display = 'none'
  // A manual pause mid-crossfade abandons it rather than trying to keep the
  // two decks' pause state in sync - simplest behavior, least surprising.
  //
  // BUT the browser fires this same 'pause' event as part of reaching the end
  // of a media resource, immediately before 'ended' - and audio.ended is
  // already true by the time this handler runs (spec order: paused state set,
  // then 'pause', then 'ended'). Cancelling here on THAT pause tore down a
  // crossfade that was completing normally: it detached the deck that had
  // already faded in correctly and cleared _cfActive, so the 'ended' handler
  // firing right behind this one no longer saw the fade as active and cold-
  // restarted the next track on the deck that just naturally ended, throwing
  // away the deck that was already playing it. This is the "restarts when
  // crossfade ends" bug - reproduced over CDP by forcing a prefetch miss (a
  // slow cold resolve narrows the fade to end at almost exactly the outgoing
  // track's true duration, so the native end-of-media pause+ended pair
  // usually wins the race against the crossfade's own setTimeout handoff).
  // A genuine manual pause never has audio.ended true, so this only skips the
  // cancel for the natural-end case.
  if (!audio.ended) cancelCrossfade()

  // Discord has no paused state. Its timestamps are wall-clock, so a presence
  // left up while paused either runs the progress bar on without us or, with
  // the timestamps removed, falls back to counting elapsed since it arrived.
  // Both are a lie about where playback is, and neither can be frozen from
  // here. Dropping the presence is the only honest option; 'play' puts it
  // straight back.
  window.cascade.discord.clear()
})

onDeck('ended', () => {
  // A live stream "ending" almost always means the connection dropped, not
  // that the station finished - retry the same channel rather than reporting
  // a position built from audio.duration (Infinity for a live stream, which
  // would send a garbage tick count to the server) or running the queue
  // -advance logic below, which assumes a finite item.
  if (CascadeCore.isRadioItem(queue[queueIndex])) { audio.play().catch(() => {}); return }

  // Crossfade already handles this transition on its own timeline (driven by
  // wall-clock time, not this event) - let it finish rather than double-advance.
  if (_cfActive) return

  const item = queue[queueIndex]
  if (item) reportPlaybackStopped(item.Id, Math.round(audio.duration * 10000000))

  // A Waterfall guest waits for the host's next state instead of advancing on
  // its own clock, which would start the next track out of step with the room.
  if (blocksLocalPlayback()) return

  if (sleepAtTrackEnd) {
    sleepAtTrackEnd = false
    document.getElementById('ctx-sleep-timer').classList.remove('active')
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
    if (repeatMode === 'all') { _rollLyricsToNext(); queueIndex = 0; playCurrentTrack(); return }
    // Instant mix is a music feature. Asking Jellyfin for one "similar to" the
    // last episode of a season would either fail or queue up something random.
    if (autoMixEnabled && item && !isVideoItem(item)) continueWithAutoMix(item)
    return
  }
  _rollLyricsToNext()
  queueIndex = next
  playCurrentTrack()
})

// Fetches similar tracks to the one that just ended and appends them to the queue,
// continuing playback - only reached when the queue runs out and auto-mix is on.
async function continueWithAutoMix(lastItem) {
  try {
    const data = await jfGet(`/Items/${lastItem.Id}/InstantMix`, {
      UserId: jf.userId, Limit: 25,
      Fields: 'AlbumId,AlbumPrimaryImageTag'
    })
    const items = (data.Items || []).filter(i => i.Id !== lastItem.Id)
    if (!items.length) return
    const startIndex = queue.length
    queue.push(...items)
    queueIndex = startIndex
    playCurrentTrack()
    renderQueuePanel()
    showToast('Auto-mix added similar tracks to the queue', { level: 'advanced' })
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
let _cfActive = false      // true while a no-fade handoff runs (finishCrossfade); a real fade hands over as it starts
let _cfOtherDeck = null    // the deck fading in, while a crossfade is in progress
let _cfTail = null         // { deck, timer }: the previous track fading out after the handoff
let _cfNextResolved = null   // resolved stream of the incoming track, adopted on finish

// Mirrors the `ended` handler's "what plays next" logic, but only for the case
// where the next track is already known - skips the auto-mix case, since that
// track doesn't exist until the current one actually finishes.
function _resolveCrossfadeTarget() {
  const next = nextQueueIndex(queue.length, queueIndex, repeatMode)
  return next === null ? -1 : next
}

onDeck('timeupdate', () => {
  if (!crossfadeEnabled || !_cfArmed || _cfActive || _cfTail) return
  // The host owns track changes in a Waterfall room. A guest fading on its own
  // leaves `audio` on the outgoing deck while the incoming one is what plays,
  // so the room's drift correction would seek a deck nobody is hearing.
  if (blocksLocalPlayback()) return
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

  incoming.volume = _masterGain ? 1 : volume   // see setDeckVolume

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
  // The incoming deck carries ITS OWN track's normalization gain into the
  // fade, not whatever the outgoing deck was set to - a prefetch hit usually
  // already has this applied (see _prefetchNext), so this is a cache hit and
  // near-instant most of the time.
  _applyNormalizationToDeck(incoming, nextItem)

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
  // The new track becomes the current one the moment it starts fading in, so
  // the title, art, lyrics, queue and the server all move to it then, not
  // once the old one has faded out. The audio thread owns both ramps above.
  _handOverAtFadeStart(nextIndex, incoming, fadeSecs)
}

// The handoff for a fade that is running: everything finishCrossfade does,
// except the outgoing deck keeps playing its fade-out as the "tail" instead of
// stopping. Its events are already ignored from here on (onDeck only listens
// to `audio`), and its gain ramp needs nothing from JS. The tail is stopped
// when its fade ends, or cut short by cancelCrossfade (pause, skip, any track
// change). The incoming deck's gain is left mid-ramp, not snapped to 1 the way
// _swapDeck does.
function _handOverAtFadeStart(nextIndex, incoming, fadeSecs) {
  const outgoing = audio
  const outgoingItem = queue[queueIndex]
  const sameCover = (outgoingItem?.AlbumId || outgoingItem?.Id) === (queue[nextIndex]?.AlbumId || queue[nextIndex]?.Id)
  // Laid over the art now, before playCurrentTrack() moves it to the new
  // track, from copies of the covers on screen (already decoded): startArtSlice.
  const slicing = !sameCover && !isVideoItem(queue[nextIndex]) && prepareCrossfadeSlice()
  if (slicing) _slice.under = queue[nextIndex].AlbumId || queue[nextIndex].Id
  // The next song's lyrics roll in under the last song's (see _ovKeepGhost),
  // if they arrive while the fade runs.
  if (!isVideoItem(queue[nextIndex])) _lyricsRollUntil = performance.now() + Math.max(fadeSecs, 3) * 1000
  if (outgoingItem) reportPlaybackStopped(outgoingItem.Id, Math.round(outgoing.currentTime * 10000000))

  audio = incoming
  if (_audioCtx) _mediaSrc = _deckSource(incoming)
  _cfActive = false
  _cfOtherDeck = null
  queueIndex = nextIndex
  startEqLoop()
  _startWordLoop()
  // Its first, synchronous step is cancelCrossfade(), so the tail is set only
  // after this call; set before, the handoff would cut its own tail.
  playCurrentTrack({ alreadyPlaying: true, resolved: _cfNextResolved })
  _cfNextResolved = null
  renderQueuePanel()
  _cfTail = { deck: outgoing, timer: setTimeout(() => { _cutCrossfadeTail(); _schedulePrefetch() }, fadeSecs * 1000) }
  if (slicing) startArtSlice(_slice, fadeSecs)
  // The background's colors follow the fade too, when they arrive.
  _ovColorFadeUntil = performance.now() + fadeSecs * 1000
}

// Stop the previous track's fade-out and give the new one full gain. The
// prefetch waits for this: the deck the tail plays on is the one it loads.
function _cutCrossfadeTail() {
  if (!_cfTail) return
  endArtSlice(_slice)
  const { deck, timer } = _cfTail
  _cfTail = null
  clearTimeout(timer)
  deck.pause()
  _detachDeck(deck)
  const g = _audioCtx && _deckGain(audio)
  if (g) { g.gain.cancelScheduledValues(_audioCtx.currentTime); g.gain.setValueAtTime(1, _audioCtx.currentTime) }
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

  if (!isVideoItem(queue[nextIndex])) _rollLyricsToNext()
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
  // After the handoff the new track is already `audio`; only the old one's
  // fade-out is left to stop.
  _cutCrossfadeTail()
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
  // A crossfade claims the idle deck as its incoming track from the moment it
  // calls incoming.play() through the handoff in finishCrossfade. This used to
  // run mid-fade too - every queue mutation (add, reorder, remove, shuffle and
  // repeat toggles) calls _reprefetch() -> _prefetchNext() regardless of
  // whether a fade is in progress - and it would resolve the SAME track that
  // was already fading in and hand its src back to it, restarting the incoming
  // deck from 0 while it was mid-fade. finishCrossfade's own
  // _clearStreamPrefetch() then detached that exact deck right after swapping
  // `audio` onto it, leaving playback stuck silent at 0:00 with the queue
  // still pointed at the "now playing" track. Reproduced over CDP: firing a
  // queue mutation during an active fade left both decks at readyState 0 with
  // playback frozen. _cfOtherDeck is non-null for that whole window, so
  // bailing here is the single guard every mutation path needs.
  // Same for the previous track's fade-out: it is still playing on the idle
  // deck, and _cutCrossfadeTail() schedules the prefetch once it ends.
  if (_cfOtherDeck || _cfTail) return
  const nextIndex = _resolveCrossfadeTarget()
  const nextItem = nextIndex >= 0 ? queue[nextIndex] : null
  // A radio queue is always a single channel, but repeat-all can make
  // _resolveCrossfadeTarget() name it as its own "next" - prefetching it
  // through the ordinary track resolver would hit the same static=true
  // shortcoming resolveRadioStream() exists to avoid.
  if (!nextItem || isVideoItem(nextItem) || CascadeCore.isRadioItem(nextItem)) return
  if (_streamPrefetch?.itemId === nextItem.Id) return   // already have it

  _clearStreamPrefetch()
  const token = _prefetchToken
  const deck = DECKS.find(d => d !== audio)
  const resolved = await resolveTrackStream(nextItem.Id)
  // Invalidated (track changed, queue mutated, or a crossfade claimed the deck)
  // while the round trip was in flight - the deck we would have loaded may not
  // even be idle any more. deck === audio covers a fade that started AND
  // finished entirely during this await, which moves what "idle" means out
  // from under the captured `deck` without ever setting _cfOtherDeck again.
  if (token !== _prefetchToken || playingVideo() || deck === audio || deck === _cfOtherDeck || deck === _cfTail?.deck) {
    if (!resolved.direct) stopActiveEncoding(jfClient, jf, resolved.playSessionId)
    return
  }
  deck.preload = 'auto'
  deck.src = resolved.url
  deck.load()
  _streamPrefetch = { itemId: nextItem.Id, resolved, deck }
  // Pre-warm the gain too, so a crossfade or a prefetched advance into this
  // deck already has the right level rather than fetching it at the moment
  // it is needed.
  _applyNormalizationToDeck(deck, nextItem)
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
  if (audio.paused) playOrResume()
  else audio.pause()
})

document.getElementById('btn-prev').addEventListener('click', () => {
  // A radio queue is always a single channel - "previous" has nowhere to go
  // and a seek-to-0 makes no sense against a live stream (there is no
  // position 0 to go back to). Reconnecting the same channel is the
  // sensible reading of the same button press.
  if (CascadeCore.isRadioItem(queue[queueIndex])) { playRadioStation(queue[queueIndex]); return }
  if (mediaPosition() > 3) { seekTo(0); return }
  skipTo(Math.max(0, queueIndex - 1), 'prev')
})

document.getElementById('btn-next').addEventListener('click', () => {
  if (CascadeCore.isRadioItem(queue[queueIndex])) { playRadioStation(queue[queueIndex]); return }
  skipTo(Math.min(queue.length - 1, queueIndex + 1), 'next')
})

document.getElementById('btn-shuffle').addEventListener('click', () => {
  shuffle = !shuffle
  document.getElementById('btn-shuffle').classList.toggle('active', shuffle)
  window.cascade.store.set('shuffle', shuffle)

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
    // Restore original order, keeping the same track playing. A queue with no
    // original order on record stays as it is rather than emptying.
    if (_unshuffledQueue.length) queue = _unshuffledQueue
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
  _renderQueueMeta()   // with repeat on, the queue has no end time
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
  window.cascade.store.set('repeatMode', repeatMode)
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
    // The pointer usually ends the drag outside the bar's rect, so mouseout
    // never fires there to hide a live tooltip (see the document-level
    // mouseout listener, which skips hiding while .dragging is set). Close it
    // here instead, unless the pointer happens to still be over the bar, in
    // which case the ordinary hover state should keep it open.
    if (!bar.matches(':hover')) _hideTooltip()
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
function wireProgressBar(barId) {
  const bar = document.getElementById(barId)
  wireBar(bar, {
    // A live radio stream's duration is Infinity - never a seekable target,
    // so every callback here treats it exactly like "no duration yet" rather
    // than computing with it (ratio*Infinity is NaN or Infinity depending on
    // ratio, and audio.currentTime = Infinity is not a real seek).
    getRatio: () => { const dur = mediaDuration(); return dur && isFinite(dur) ? mediaPosition() / dur : 0 },
    step:     () => { const dur = mediaDuration(); return dur && isFinite(dur) ? 5 / dur : 0.05 },
    bigStep:  () => { const dur = mediaDuration(); return dur && isFinite(dur) ? 30 / dur : 0.1 },
    onChange: (ratio) => {
      const dur = mediaDuration()
      if (!dur || !isFinite(dur)) return
      _scrubTarget = ratio * dur
      syncProgressUI()
    },
    // Held on the target until the seek has landed, so the bar never shows the old spot in between.
    onCommit: async (ratio) => {
      const dur = mediaDuration()
      if (dur && isFinite(dur)) await seekTo(ratio * dur).catch(() => {})
      _scrubTarget = null
      syncProgressUI()
    },
  })
}

/** Wires a volume bar (statusbar or overlay) through the shared setVolumeRatio(),
 *  which is what keeps the two mirrored. */
function wireVolumeBar(barId) {
  const bar = document.getElementById(barId)
  wireBar(bar, {
    getRatio: () => volume,
    step:     () => 0.05,
    bigStep:  () => 0.2,
    onChange: (ratio) => setVolumeRatio(ratio, bar),
  })
}

wireProgressBar('prog-bar')
wireVolumeBar('vol-bar')

document.getElementById('btn-mute').addEventListener('click', () => {
  setDeckMuted(!_muted)
})

// Lyrics open button
document.getElementById('btn-lyrics-open').addEventListener('click', () => showLyrics())

// Miniplayer open button - main.js minimizes this window and creates (or
// focuses) the small always-on-top remote control window.
// Lyrics are fetched only while something shows them (see updateNowPlaying);
// an open miniplayer counts. Fetched on open too, for the song already playing.
window.cascade.miniPlayer.onOpenChange(open => {
  _miniplayerOpen = open
  if (!open) return
  if (!lyricsData.length && queue[queueIndex]) fetchLyrics()
  // The window's page has not loaded yet, and while paused nothing else would
  // push, so it would sit on "Nothing playing" until the next state change.
  pushMiniplayerState()
  setTimeout(pushMiniplayerState, 600)
})

document.getElementById('btn-miniplayer-open').addEventListener('click', () => {
  window.cascade.miniPlayer.open()
})

// Like / favourite
const likeBtn = document.getElementById('btn-like')

/** POST/DELETE /UserFavoriteItems/{id} - shared by the transport bar's heart
 *  button, the overlay's, and the Favorite/Unfavorite row every context menu
 *  that offers one (now playing, track rows, albums, artists) reuses. `item`
 *  defaults to whatever is currently playing, which is what the two heart
 *  buttons pass nothing and get.
 *
 *  NOT /Users/{userId}/FavoriteItems/{id} - checked against this server's own
 *  OpenAPI spec (10.11.11), where /UserFavoriteItems is the only favorites
 *  path, same userId-as-query-param shape as /UserPlayedItems (see
 *  setItemPlayed). The old route would have 404'd on every heart click,
 *  silently, since nothing here read the response before this function
 *  started doing that (CODEMAP rule 1).
 *
 *  For the current track, "liked" is read off the button's own class rather
 *  than item.UserData - that DOM state is already kept in sync by
 *  updateNowPlaying() and is right even when UserData never loaded. Any other
 *  item (a menu's target, not necessarily playing) has no button to read, so
 *  it falls back to item.UserData?.IsFavorite, which is what the menu that
 *  opened on it used to decide the row's own Favorite/Unfavorite label.
 *
 *  Compared by Id, not by reference: a Songs/album/artist row and
 *  queue[queueIndex] are frequently different objects for the same track
 *  (the row came from its own list fetch), so favoriting the playing song
 *  from a row still has to find and update the one the heart buttons read. */
async function toggleLike(item) {
  const current = queue[queueIndex]
  const isCurrent = !item || (!!current && item.Id === current.Id)
  item = item || current
  if (!item) return
  const isLiked = isCurrent ? likeBtn.classList.contains('liked') : !!item.UserData?.IsFavorite
  try {
    // Offline it is queued and sent when the server is back.
    if (jfClient.offline) {
      await queueOfflineChange({ itemId: item.Id, kind: 'favorite', favorite: !isLiked, was: isLiked })
    } else {
      const res = await jfFetch(`${jf.url}/UserFavoriteItems/${item.Id}?userId=${encodeURIComponent(jf.userId)}`, {
        method: isLiked ? 'DELETE' : 'POST',
        headers: CascadeCore.authHeaders(jf)
      })
      // Read the response rather than assume success - see CODEMAP rule 1.
      if (!res.ok) throw new Error(String(res.status))
    }
    if (!item.UserData) item.UserData = {}
    item.UserData.IsFavorite = !isLiked
    if (isCurrent) {
      // item may be a different object than queue[queueIndex] holding the
      // same track (see above) - patch both so a later ctx-menu/showCtxMenu
      // read of queue[queueIndex] sees the change too.
      if (current && current !== item) {
        if (!current.UserData) current.UserData = {}
        current.UserData.IsFavorite = !isLiked
      }
      // #ov-like (the overlay's own heart button) is gone - see Favorite
      // in #ctx-menu, whose label showCtxMenu() refreshes on open.
      likeBtn.classList.toggle('liked', !isLiked)
      document.getElementById('ov-art-like').classList.toggle('liked', !isLiked)
      pushMiniplayerState()
    }
  } catch (e) {
    console.error('Favorite failed', e)
    showNotice('Could not update favorite status on the server.', 'Favorite')
  }
}

likeBtn.addEventListener('click', () => toggleLike())

// ── Shuffle All ───────────────────────────────────────────────────────────────

// Turn shuffle on and play items from a random track. Shared by every "Shuffle"
// button. playItems() does the shuffling and keeps items' own order as the
// unshuffled queue; pre-shuffling here used to hand it an already random list,
// so toggling shuffle off afterwards never restored the original order.
function shuffleAndPlay(items, source) {
  if (!items.length) return
  shuffle = true
  document.getElementById('btn-shuffle').classList.add('active')
  document.getElementById('ov-shuffle').classList.add('active')

  playItems(items, Math.floor(Math.random() * items.length), source)
}

async function shuffleAllSongs() {
  if (!allSongs.length) {
    await fetchAllSongs()
    // loadSongs() renders the table itself once the shared fetch lands, so there
    // is nothing to draw here.
  }
  shuffleAndPlay(allSongs, 'Songs')
}

document.getElementById('btn-shuffle-songs').addEventListener('click', shuffleAllSongs)
document.getElementById('btn-shuffle-albums').addEventListener('click', shuffleAllSongs)
document.getElementById('btn-shuffle-artists').addEventListener('click', shuffleAllSongs)

// ── Native media session (OS media keys + lock screen / taskbar integration) ──

// Play and pause go through the play button like next and previous do, not
// straight to the element, so whatever the button enforces applies here too:
// a Waterfall guest's transport stays with the host. On Windows these are the
// media keys' only route (see the globalShortcut note in main.js).
if ('mediaSession' in navigator) {
  const playButton = () => document.getElementById('btn-play').click()
  navigator.mediaSession.setActionHandler('play',          () => { if (audio.paused) playButton() })
  navigator.mediaSession.setActionHandler('pause',         () => { if (!audio.paused) playButton() })
  navigator.mediaSession.setActionHandler('stop',          () => stopPlayback())
  navigator.mediaSession.setActionHandler('nexttrack',     () => document.getElementById('btn-next').click())
  navigator.mediaSession.setActionHandler('previoustrack', () => document.getElementById('btn-prev').click())
  navigator.mediaSession.setActionHandler('seekto', (details) => {
    if (mediaDuration() && details.seekTime != null) seekTo(details.seekTime)
  })
}

// Media keys registered as global shortcuts on macOS and Linux (see main.js)
window.cascade.onMediaKey((key) => {
  if (key === 'playpause') document.getElementById('btn-play').click()
  else if (key === 'next')  document.getElementById('btn-next').click()
  else if (key === 'prev')  document.getElementById('btn-prev').click()
})

// Keep OS media session state in sync with playback
onDeck('play',  () => {
  if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing'
  window.cascade.touchbarUpdate({ playing: true })
  window.cascade.nowPlayingUpdate({ isPlaying: true, positionMs: Math.round(mediaPosition() * 1000) })
  pushMiniplayerState()
})
onDeck('pause', () => {
  if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused'
  window.cascade.touchbarUpdate({ playing: false })
  window.cascade.nowPlayingUpdate({ isPlaying: false, positionMs: Math.round(mediaPosition() * 1000) })
  pushMiniplayerState()
})

// Miniplayer control -> the exact same buttons and functions the main window
// already uses, not a second playback path. The message comes from another
// page, so it is parsed and clamped (parseMiniplayerCommand) before anything
// acts on it; an unknown message is dropped.
window.cascade.miniPlayer.onControl(async (raw) => {
  const cmd = CascadeCore.parseMiniplayerCommand(raw)
  if (!cmd) return
  if (cmd.type === 'playpause') document.getElementById('btn-play').click()
  else if (cmd.type === 'next') document.getElementById('btn-next').click()
  else if (cmd.type === 'prev') document.getElementById('btn-prev').click()
  else if (cmd.type === 'like') await toggleLike()
  // Up Next's toggles: the transport bar's own buttons, so the main window's
  // state and its button highlights stay the single source.
  else if (cmd.type === 'shuffle') document.getElementById('btn-shuffle').click()
  else if (cmd.type === 'automix') document.getElementById('btn-automix').click()
  else if (cmd.type === 'repeat') document.getElementById('btn-repeat').click()
  else if (cmd.type === 'seek') { const dur = mediaDuration(); if (dur) await seekTo(cmd.fraction * dur) }
  // `volume`, not audio.volume: mid-crossfade the element is partway through
  // a fade (see openLyricsEditorFor).
  else if (cmd.type === 'volume') setVolumeRatio(volume + cmd.delta)
  else if (cmd.type === 'volumeto') setVolumeRatio(cmd.fraction)
  else if (cmd.type === 'credit') {
    const url = CascadeCore.safeCreditUrl(lyricsCredit?.[cmd.who]?.url)
    if (url) window.cascade.shell.openExternal(url)
    return
  }
  // The miniplayer has a sheetId it holds no sheet for: send it on the push below.
  else if (cmd.type === 'sheet') _mpSheetSent = false
  // Up Next: same as clicking the row in the main queue panel, a Waterfall
  // guest included (it asks the host instead of moving its own queue).
  else if (cmd.type === 'jump') {
    if (cmd.index <= queueIndex || cmd.index >= queue.length) return
    if (isWaterfallFollower()) { if (typeof wfNotifyHostControls === 'function') wfNotifyHostControls(); return }
    skipTo(cmd.index, cmd.index === queueIndex + 1 ? 'next' : 'jump')
    renderQueuePanel()
  }
  // Paused, there is no timeupdate to carry the new state back.
  pushMiniplayerState()
})

// ── Settings ──────────────────────────────────────────────────────────────────

async function loadSettingsFields() {
  document.getElementById('s-url').textContent  = await window.cascade.store.get('serverUrl') || ''
  document.getElementById('s-user').textContent = await window.cascade.store.get('username') || ''
  document.getElementById('s-headers').value = CascadeCore.formatHeaderLines(await window.cascade.connection.getHeaders())
  document.getElementById('s-headers-error').textContent = ''

  document.getElementById('qc-approve-status-row').style.display = 'none'
  _applyQuickConnectGating()
  document.getElementById('s-telemetry-row').style.display = CascadeCore.telemetryAvailable() ? '' : 'none'
  document.getElementById('s-telemetry-toggle').checked = telemetryOptIn
  // Radio (Live TV channels shown as stations) - see applyRadioNavVisibility.
  // The row itself only appears for an account Jellyfin already lets see Live
  // TV; the toggle inside it is the user confirming those channels are radio.
  const radioRow = document.getElementById('s-radio-row')
  const radioToggle = document.getElementById('s-radio-toggle')
  radioRow.style.display = jf.hasLiveTv ? '' : 'none'
  radioToggle.checked = radioEnabled
  radioToggle.onchange = async () => {
    radioEnabled = radioToggle.checked
    await window.cascade.store.set('radioEnabled', radioEnabled)
    applyRadioNavVisibility()
  }

  // Beta updates toggle - defaults on for a beta build itself, same rule main.js
  // uses for the actual update check, unless the user has explicitly chosen otherwise.
  const betaUpdatesToggle = document.getElementById('beta-updates-toggle')
  const savedBetaPref = await window.cascade.store.get('betaUpdates')
  const isBetaBuild = /-b\d*$/.test(appVersion)
  betaUpdatesToggle.checked = savedBetaPref === undefined ? isBetaBuild : savedBetaPref === true
  betaUpdatesToggle.onchange = async () => {
    await window.cascade.store.set('betaUpdates', betaUpdatesToggle.checked)
  }

  // Lyric translation
  document.getElementById('lyrics-translation-toggle').checked = lyricsTranslationEnabled
  renderAppleTranslationRow()
  window.cascade.translationModels.status()
    .then(s => { _translationModels = s; renderTranslationModelRows() })
    .catch(() => {})

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

  // Volume normalization
  const normalizeToggle = document.getElementById('normalize-toggle')
  const normalizeSourceRow = document.getElementById('normalize-source-row')
  const normalizeSourceSelect = document.getElementById('normalize-source')
  normalizeToggle.checked = normalizationEnabled
  normalizeSourceRow.style.display = normalizationEnabled ? '' : 'none'
  normalizeSourceSelect.value = normalizationSource
  const autoSkipToggle = document.getElementById('autoskip-toggle')
  autoSkipToggle.checked = autoSkipSegments
  autoSkipToggle.onchange = async () => {
    autoSkipSegments = autoSkipToggle.checked
    await window.cascade.store.set('autoSkipSegments', autoSkipSegments)
  }
  normalizeToggle.onchange = async () => {
    normalizeSourceRow.style.display = normalizeToggle.checked ? '' : 'none'
    await setNormalizationEnabled(normalizeToggle.checked)
  }
  normalizeSourceSelect.onchange = async () => {
    await setNormalizationSource(normalizeSourceSelect.value)
  }

  // Output device. The row hides itself when setSinkId is not available, so
  // this always runs - it is the one thing deciding whether to show it.
  const outputDeviceSelect = document.getElementById('output-device')
  _refreshOutputDeviceSelect()
  outputDeviceSelect.onchange = async () => {
    await setOutputDeviceId(outputDeviceSelect.value)
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
    _refreshEqUI('music')
    _refreshEqUI('video')
  }

  // One editor per profile, side by side. Each finds its controls inside its
  // own data-eq panel, so the two cannot write to each other's curve.
  for (const mode of ['music', 'video']) {
    const panel = _eqPanel(mode)
    const profileToggle = panel.querySelector('.eq-profile-toggle')
    profileToggle.onchange = async () => {
      _eqProfile(mode).enabled = profileToggle.checked
      _refreshEqUI(mode)
      await _saveEqProfile(mode)
    }

    const presetSel = panel.querySelector('.eq-preset')
    presetSel.innerHTML = '<option value="">Custom</option>' +
      Object.keys(CascadeCore.EQ_PRESETS).map(name => `<option value="${name}">${name}</option>`).join('')
    presetSel.onchange = async () => {
      if (!presetSel.value) return
      _eqProfile(mode).bands = [...CascadeCore.EQ_PRESETS[presetSel.value]]
      _refreshEqUI(mode)
      await _saveEqProfile(mode)
    }

    _buildEqGraphPoints(mode)

    const preampAuto = panel.querySelector('.eq-preamp-auto')
    preampAuto.onchange = async () => {
      const profile = _eqProfile(mode)
      // Seed manual mode with the current auto value instead of jumping to 0.
      profile.preamp = preampAuto.checked ? null : CascadeCore.autoPreamp(profile.bands)
      _refreshEqUI(mode)
      await _saveEqProfile(mode)
    }
    const preampSlider = panel.querySelector('.eq-preamp-slider')
    preampSlider.oninput = async () => {
      _eqProfile(mode).preamp = parseFloat(preampSlider.value)
      _refreshEqUI(mode)
      await _saveEqProfile(mode)
    }

    _refreshEqUI(mode)
  }
}

document.getElementById('s-cert-reset').addEventListener('click', async () => {
  await window.cascade.connection.resetCertificate()
  showToast('Certificate choice cleared. Cascade asks again the next time your server wants one.')
})

// The proxy headers are the one connection setting changed in place: the
// server and the account are Sign out, as on the Mac.
document.getElementById('s-headers-save').addEventListener('click', async () => {
  const url = await window.cascade.store.get('serverUrl')
  if (!url) return
  const parsed = CascadeCore.parseHeaderLines(document.getElementById('s-headers').value)
  document.getElementById('s-headers-error').textContent = parsed.errors.join(' ')
  if (parsed.errors.length) return
  await window.cascade.connection.set(url, parsed.headers)
  const status = document.getElementById('save-status')
  status.classList.add('visible')
  setTimeout(() => status.classList.remove('visible'), 2500)
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
  // Stops this account's downloads, drops the token the main process held for
  // them, and hides its music from whoever signs in next.
  await window.cascade.offline.setOwner(null)
  await refreshOffline()
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
// Cascade stores no password for any sign-in method; the token is the session.

let _qcAbort = null   // set while a request is live; calling it stops the poll

/**
 * Drop back to the sign-in screen because the session is no longer usable.
 *
 * No password is stored for any account, so there is nothing to re-authenticate
 * with silently. probeQuickConnect() re-runs so the code option is showing by
 * the time they read the message, for accounts that never had a password here.
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
/**
 * Tells the main process which server the setup form is about and which
 * reverse-proxy headers to send it, ahead of the first request: a proxy that
 * wants a header refuses the sign-in itself without it. False (and the problem
 * shown, unless `report` is false) when the headers field does not parse.
 */
async function applySetupConnection(url, { report = true, probe = false } = {}) {
  const { headers, errors } = CascadeCore.parseHeaderLines(document.getElementById('setup-headers').value)
  if (errors.length) {
    if (report) document.getElementById('setup-error').textContent = errors.join(' ')
    return false
  }
  // The probe runs as the address is typed: it sends the headers only to the
  // server they were saved for, and saves nothing (see probeHeaders).
  const send = probe ? CascadeCore.probeHeaders(url, await window.cascade.store.get('serverUrl'), headers) : headers
  await window.cascade.connection.set(url, send, !probe)
  // 'withheld': the check went out without the headers this server may need.
  return send.length < headers.length ? 'withheld' : true
}

function probeQuickConnect() {
  clearTimeout(_qcProbeTimer)
  _qcProbeTimer = setTimeout(async () => {
    const url = document.getElementById('setup-url').value.trim().replace(/\/+$/, '')
    const btn = document.getElementById('setup-quickconnect')
    if (!url) { btn.style.display = 'none'; document.getElementById('setup-disclaimer').hidden = true; return }
    const applied = await applySetupConnection(url, { report: false, probe: true })
    const disclaimer = document.getElementById('setup-disclaimer')
    if (!applied) { btn.style.display = 'none'; disclaimer.hidden = true; return }
    CascadeCore.fetchLoginDisclaimer(url).then(text => {
      // Only if the address has not changed since.
      if (document.getElementById('setup-url').value.trim().replace(/\/+$/, '') !== url) return
      disclaimer.textContent = text
      disclaimer.hidden = !text
    })
    // Without its headers a proxy refuses the check, which says nothing about
    // Quick Connect: offer it, and pressing it sends the headers and finds out.
    btn.style.display = (applied === 'withheld' || await CascadeCore.quickConnectEnabled(url)) ? '' : 'none'
  }, 500)
}

document.getElementById('setup-url').addEventListener('input', probeQuickConnect)
document.getElementById('setup-headers').addEventListener('input', probeQuickConnect)

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
  if (!await applySetupConnection(url)) return

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
      // The overlay was hidden for connect(): bring it back with the error.
      document.getElementById('setup-overlay').classList.remove('hidden')
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
  if (!await applySetupConnection(url)) return

  btn.disabled = true
  btn.textContent = 'Connecting…'
  err.textContent = ''

  try {
    const auth = await jfAuth(url, user, pass)
    await window.cascade.store.set('serverUrl', url)
    await window.cascade.store.set('username', user)
    await window.cascade.store.set('token', auth.AccessToken)
    await window.cascade.store.set('userId', auth.User.Id)
    // A fresh login is already bound to the current device id.
    await window.cascade.store.set('deviceIdMigrated', true)

    document.getElementById('setup-overlay').classList.add('hidden')
    await connect(url, auth.AccessToken, auth.User.Id)
  } catch (e) {
    // Signed in but connect() failed: the overlay was already hidden, and the
    // error below would land on it unseen over an empty app.
    document.getElementById('setup-overlay').classList.remove('hidden')
    const msg = e.message || ''
    if (msg.includes('401') || msg.toLowerCase().includes('unauthorized'))
      err.textContent = 'Incorrect username or password.'
    else if (msg.includes('404'))
      err.textContent = 'Server not found. Check your URL.'
    else if (msg.includes('Failed to fetch') || msg.includes('NetworkError') || msg.includes('ECONNREFUSED'))
      err.textContent = 'Could not reach the server. Is it running?'
    else
      err.textContent = `Connection failed: ${msg}`
  } finally {
    // On success too: the overlay is hidden, not torn down, so a button left
    // reading "Connecting…" is what Sign out would show next.
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

// Only Macs that can run the native app see this row. The button hands off to
// the update window, which downloads, checks and swaps it in like any update.
if (window.cascade.platform === 'darwin') {
  window.cascade.canTryNativeMac().then(can => {
    document.getElementById('native-mac-row').style.display = can ? '' : 'none'
  }).catch(() => {})
}
// Not offered in packaged builds yet: the native app is still being finished,
// so a release says it is coming rather than handing people a beta. Dev runs
// keep the button, for testing the switch. Keyed on isPackaged, as the
// miniplayer once was, not on a setting anyone can flip by accident.
let _nativeMacOffered = true
window.cascade?.isPackaged?.().then(packaged => {
  _nativeMacOffered = !packaged
  if (_nativeMacOffered) return
  const btn = document.getElementById('btn-try-native-mac')
  btn.disabled = true
  btn.textContent = 'Native Mac app coming soon'
  btn.title = 'Native Mac app coming soon'
})
document.getElementById('btn-try-native-mac').addEventListener('click', async () => {
  if (!_nativeMacOffered) return
  const btn = document.getElementById('btn-try-native-mac')
  btn.disabled = true
  try {
    const result = await window.cascade.tryNativeMac()
    if (!result?.hasUpdate) showNotice(result?.error || 'Could not look for the native Mac app.', 'Native Mac app')
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
// Runs once, needs the password an install saved before 2.2.0 (read once in
// init() and then deleted), and only swaps the token on success - a failed
// re-auth must leave the working token untouched rather than logging the user
// out. Without that password it cannot run; the old token keeps working, and
// the next real sign-in (which always sets the flag) retires the old id.
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
  // Before anything authenticates: the edition and machine name go into the
  // auth header, which is how the server's Devices screen tells this desktop
  // build apart from the Apple and Android apps.
  const identity = CascadeCore.setClientIdentity({
    client: CascadeCore.ELECTRON_EDITION,
    device: CascadeCore.desktopDeviceName(window.cascade.platform),
  })
  const editionEl = document.getElementById('app-edition')
  if (editionEl) editionEl.textContent = identity.client
  // Before anything authenticates: the device id goes into the auth header.
  deviceId = await window.cascade.store.get('deviceId')
  if (!deviceId) {
    deviceId = crypto.randomUUID()
    await window.cascade.store.set('deviceId', deviceId)
  }

  document.documentElement.setAttribute('data-platform', window.cascade.platform)
  setSearchPlaceholder(_browseMode)
  await window.cascade.getVersion().then(v => {
    appVersion = v
    const el = document.getElementById('app-version')
    if (el) el.textContent = `v${v}`
  })

  // Last session's server style, so the look is right before sign-in finishes;
  // fetchServerStyle() replaces it once the plugin answers.
  try { _serverStyle = CascadeCore.parseServerStyle(JSON.parse(await window.cascade.store.get('serverStyle') || 'null')) } catch {}
  await loadTheme()
  buildPresets()
  await loadUiFont()
  await loadNpTuning()
  await loadLyricStyle()
  await loadDisplayPrefs()
  await loadTelemetry()
  await initDiscordRpc()

  crossfadeEnabled = (await window.cascade.store.get('crossfadeEnabled')) === true
  lyricsTranslateOn = (await window.cascade.store.get('lyricsTranslateOn')) === true
  // Only an explicit false switches the feature off; missing or corrupt means on.
  lyricsTranslationEnabled = (await window.cascade.store.get('lyricsTranslationEnabled')) !== false
  _appleTranslationSupported = await window.cascade.appleTranslation.supported().catch(() => false)
  appleTranslationEnabled = (await window.cascade.store.get('appleTranslationEnabled')) !== false
  {
    // Stored values are untrusted: only real model keys survive.
    const chosen = await window.cascade.store.get('appleTranslationMozillaChosen')
    if (Array.isArray(chosen)) {
      for (const k of chosen) if (CascadeCore.TRANSLATION_MODEL_KEYS.includes(k)) _appleMozillaChosen.add(k)
    }
  }
  syncTranslateButtons()
  refreshAppleLanguageStatus()
  crossfadeSeconds = parseInt(await window.cascade.store.get('crossfadeSeconds'), 10) || 6
  maxStreamingBitrate = parseInt(await window.cascade.store.get('maxStreamingBitrate'), 10) || DEFAULT_MAX_BITRATE
  normalizationEnabled = (await window.cascade.store.get('normalizationEnabled')) === true
  autoSkipSegments = (await window.cascade.store.get('autoSkipSegments')) === true
  {
    const savedSource = await window.cascade.store.get('normalizationSource')
    normalizationSource = savedSource === 'album' ? 'album' : 'track'
  }
  {
    const savedDevice = await window.cascade.store.get('outputDeviceId')
    outputDeviceId = typeof savedDevice === 'string' && savedDevice ? savedDevice : 'default'
  }

  eqEnabled = (await window.cascade.store.get('eqEnabled')) === true
  eqMusicProfile = await _loadEqProfile('eqMusic')
  eqVideoProfile = await _loadEqProfile('eqVideo')

  // Restore saved volume
  const savedVol = await window.cascade.store.get('volume')
  if (savedVol !== undefined && savedVol !== null) setVolumeRatio(parseFloat(savedVol))
  // Shuffle and repeat stay as they were left.
  shuffle = (await window.cascade.store.get('shuffle')) === true
  document.getElementById('btn-shuffle').classList.toggle('active', shuffle)
  document.getElementById('ov-shuffle').classList.toggle('active', shuffle)
  const savedRepeat = await window.cascade.store.get('repeatMode')
  if (['none', 'all', 'one'].includes(savedRepeat)) repeatMode = savedRepeat
  updateRepeatButtons()

  // Local mode: a folder instead of a server. Nothing below runs, so nothing
  // is sent to a Jellyfin server, not even the device id migration.
  if ((await window.cascade.store.get('libraryMode')) === 'local' && await startLocal()) return

  const serverUrl = await window.cascade.store.get('serverUrl')
  const username  = await window.cascade.store.get('username')
  // Only ever read to finish migrateDeviceId() for an install that still has
  // one saved from before 2.2.0, then deleted. Jellyfin tokens do not expire
  // on their own, so the token is the session and a password on disk is only
  // a plaintext liability.
  const legacyPassword = await window.cascade.store.get('password')
  let token       = await window.cascade.store.get('token')
  let userId      = await window.cascade.store.get('userId')

  // Always pre-fill the setup form so the user never has to retype from scratch
  if (serverUrl) document.getElementById('setup-url').value      = serverUrl
  if (username)  document.getElementById('setup-username').value  = username
  // Saved reverse-proxy headers, with the section open so they are not a surprise.
  const savedHeaders = await window.cascade.connection.getHeaders()
  if (savedHeaders.length) {
    document.getElementById('setup-headers').value = CascadeCore.formatHeaderLines(savedHeaders)
    document.getElementById('setup-advanced').open = true
  }
  // The probe normally runs as the user types; a pre-filled URL never fires that.
  // Only when the form stays up: signed in, it would reach the server before
  // a saved Offline Mode switch is read, and promptReauth probes on its own.
  if (serverUrl && !(token && userId)) probeQuickConnect()

  ;({ token, userId } = await migrateDeviceId(serverUrl, username, legacyPassword, token, userId))
  if (legacyPassword !== undefined) await window.cascade.store.delete('password')

  // Before anything draws a cover or resolves a stream: what is downloaded is
  // what works with no server. Each account has its own downloads, and the
  // saved one is whose music offline mode plays. The video settings first:
  // main holds videos back until it has their profile.
  await loadVideoDownloadSettings()
  await window.cascade.offline.setOwner(serverUrl && token && userId ? userId : null)
  await refreshOffline()

  if (serverUrl && token && userId) {
    document.getElementById('setup-overlay').classList.add('hidden')
    // The switch left on stays on: nothing goes to the server, the app opens
    // on the downloads.
    if ((await window.cascade.store.get('offlineMode')) === true) {
      await setOfflineState('manual', { reload: false })
      await connect(serverUrl, token, userId).catch(e => console.error('[cascade] offline start failed:', e))
      return
    }
    try {
      await connect(serverUrl, token, userId)
    } catch (e) {
      if (CascadeCore.failureKind(e?.status) === 'auth') {
        // The token was rejected: Jellyfin tokens only die when revoked (signed
        // out, device removed in the dashboard), so this is a real sign-in, not a
        // refresh. There is no stored password to retry with, by design.
        promptReauth('Your session expired. Sign in again with a code, or enter your password.')
      } else if (CascadeCore.failureKind(e?.status) === 'unreachable' && _offline.collections.length) {
        // The server never answered and there is something on disk: Offline
        // Mode turns on by itself and the app opens on the downloads.
        await setOfflineState('unreachable', { reload: false })
        await connect(serverUrl, token, userId).catch(err => console.error('[cascade] offline start failed:', err))
      } else {
        promptReauth('Could not reach your server. Check your connection or the address, then sign in again.')
      }
    }
  }
  // else setup overlay stays visible (fields already pre-filled above)
}

// ── Offline downloads ─────────────────────────────────────────────────────────
//
// Albums and playlists saved to disk for listening with no network. The files,
// the one index of them and the download queue live in the main process
// (offline.js); the rules about what a removal may delete and what counts as a
// finished download are pure, in src/core/offline-index.ts. Here: a summary
// kept in `_offline` (declared at the top, artUrl() and resolveTrackStream()
// read it), the Downloads view, the buttons, offline mode and play replay.
//
// Toasts do not show in a packaged build, so feedback is the button's own state
// and the Downloads view, never a toast alone.

/** The Authorization header for a call that needs the session. The main
 *  process keeps it in memory for the length of the download queue only. */
function offlineSession() {
  return { authorization: CascadeCore.authHeader(appVersion, deviceId, jf.token) }
}

function offlineCollection(id) {
  return id ? _offline.collections.find(c => c.item.Id === id) || null : null
}

function fmtBytes(n) {
  if (!Number.isFinite(n) || n <= 0) return '0 MB'
  const mb = n / 1048576
  return mb >= 1024 ? `${(mb / 1024).toFixed(1)} GB` : `${Math.max(1, Math.round(mb))} MB`
}

let _offlineRefreshTimer = null
function scheduleOfflineRefresh() {
  if (_offlineRefreshTimer) return
  _offlineRefreshTimer = setTimeout(() => { _offlineRefreshTimer = null; refreshOffline() }, 150)
}

async function refreshOffline() {
  // Local mode's summary is the folder's, not the downloads'.
  if (isLocalMode()) return refreshLocal()
  let summary
  try { summary = await window.cascade.offline.summary() } catch { return }
  _offline = { ...summary, art: new Set(summary.art) }
  // Offline, the engine answers from the catalog as it is now.
  if (CascadeCore.isOffline(_offlineState)) await refreshOfflineEngine()
  for (const id of [..._offlineProgress.keys()]) if (!summary.active.some(a => a.id === id)) _offlineProgress.delete(id)
  renderOfflineButtons()
  if (_currentView === 'downloads') renderDownloadsView()
}

window.cascade.offline.onEvent((event) => {
  if (event.type === 'progress') { _offlineProgress.set(event.id, event); updateDownloadCards(); return }
  if (event.type === 'track-done') _offlineProgress.delete(event.id)
  scheduleOfflineRefresh()
})

/** Starts the download of an album or playlist, or removes it if it is already
 *  asked for: the one handler behind the menu entry and both page buttons. */
async function toggleOfflineDownload(kind, item) {
  if (!item?.Id) return
  if (offlineCollection(item.Id)) { await removeOfflineDownload(item.Id); return }
  if (jfClient.offline) { showNotice('Downloading needs your server. Turn Offline Mode off first.', 'Downloads'); return }
  if (jf.canDownload === false) {
    showNotice('This account is not allowed to download media. An admin can turn it on in the Jellyfin dashboard.', 'Downloads')
    return
  }
  let tracks
  try { tracks = kind === 'album' ? await fetchAlbumTracks(item.Id) : await fetchPlaylistTracks(item.Id) }
  catch { showNotice('Could not read that list from the server.', 'Downloads'); return }
  const music = tracks.filter(t => !t.Type || t.Type === 'Audio')
  if (!music.length) { showNotice('There are no songs to download in that.', 'Downloads'); return }
  const collection = {
    Id: item.Id, Name: item.Name, Type: kind === 'album' ? 'MusicAlbum' : 'Playlist',
    ImageTags: item.ImageTags, AlbumArtist: item.AlbumArtist, ProductionYear: item.ProductionYear, ChildCount: music.length,
  }
  if (!await window.cascade.offline.add(collection, music, offlineSession())) {
    showNotice('Could not start the download.', 'Downloads')
    return
  }
  await refreshOffline()
  placeOfflineDownloads().catch(() => {})
  saveOfflineLyrics(music).catch(() => {})
}

/** Finds each downloaded song's lyrics the way playback would and saves them
 *  with the download, so they show offline. Two at a time, to keep the
 *  lyrics sources and the plugin from seeing a burst; stops if the app goes
 *  offline partway. `dropMissing`: a song nothing answers for loses what was
 *  stored (expired SpicyLyrics are never kept for good). */
async function saveOfflineLyrics(tracks, { dropMissing = false } = {}) {
  const queue = tracks.filter(t => t?.Id)
  const worker = async () => {
    while (queue.length && !jfClient.offline) {
      const t = queue.shift()
      let out = null
      try { out = await fetchLyricsWaterfall(t) } catch {}
      if (jfClient.offline) return
      if (!out?.lines?.length || out.instrumental) {
        if (dropMissing) await window.cascade.offline.dropLyrics(t.Id).catch(() => {})
        continue
      }
      await window.cascade.offline.setLyrics(t.Id, {
        source: CascadeCore.lyricsSourceKey(String(out.source || ''), !!out.credit),
        synced: out.lines.some(l => l.Start > 0),
        lines: out.lines,
        credit: out.credit || null,
      }).catch(() => {})
    }
  }
  await Promise.all([worker(), worker()])
}

/** SpicyLyrics saved with a download stop showing after SPICY_LYRICS_DAYS;
 *  back online they are asked for again (a new answer resets the days, or
 *  another source's never expires) or dropped. At every online connect(). */
async function refreshExpiredLyrics() {
  let catalog = null
  try { catalog = await window.cascade.offline.catalog() } catch {}
  const index = CascadeCore.parseIndex(catalog)
  const expired = CascadeCore.expiredLyricsTrackIds(index, new Date()).map(id => index.tracks[id].item)
  if (expired.length) await saveOfflineLyrics(expired, { dropMissing: true })
}

async function removeOfflineDownload(id) {
  await window.cascade.offline.remove(id)
  await refreshOffline()
}

// ── Video downloads ──
// Movies, episodes, seasons and whole shows (docs/offline-mode-plan.md,
// section 6). The main process negotiates each file with the server using the
// download profile set here (src/core/offline-video.ts says how, and why the
// file is kept as the server sends it); this side asks for them, follows
// shows for new episodes and removes watched ones.

/** What a downloaded video keeps: its page, the player, the subtitle and
 *  audio pickers, chapters, resume and the follow's date check read these. */
const VIDEO_DL_FIELDS = 'Overview,MediaStreams,MediaSources,Genres,Chapters,DateCreated,SortName,OfficialRating,CommunityRating,UserData,ProductionYear'

let _videoDownloadQuality = 'original'
/** Off by default here (the plan's decision); the iPhone defaults it on. */
let _removeWatchedEpisodes = false

async function loadVideoDownloadSettings() {
  _videoDownloadQuality = CascadeCore.parseVideoQuality(await window.cascade.store.get('videoDownloadQuality'), 'original')
  _removeWatchedEpisodes = (await window.cascade.store.get('removeWatchedEpisodes')) === true
  const quality = /** @type {HTMLSelectElement} */ (document.getElementById('dl-video-quality'))
  const removeWatched = /** @type {HTMLInputElement} */ (document.getElementById('dl-remove-watched'))
  quality.value = _videoDownloadQuality
  removeWatched.checked = _removeWatchedEpisodes
  pushVideoDownloadProfile()
  // No limit by default here (the plan's decision); the iPhone asks.
  const limit = Number(await window.cascade.store.get('downloadLimitGB')) || 0
  const limitSelect = /** @type {HTMLSelectElement} */ (document.getElementById('dl-storage-limit'))
  limitSelect.value = String(limit)
  window.cascade.offline.setLimit(limit > 0 ? limit * 2 ** 30 : null).catch(() => {})
}

document.getElementById('dl-storage-limit').addEventListener('change', async (e) => {
  const gb = Number(/** @type {HTMLSelectElement} */ (e.target).value) || 0
  await window.cascade.store.set('downloadLimitGB', gb)
  await window.cascade.offline.setLimit(gb > 0 ? gb * 2 ** 30 : null)
  refreshOffline()
})
document.getElementById('downloads-held-add').addEventListener('click', () => addHeldPlays())
document.getElementById('downloads-held-discard').addEventListener('click', () => discardHeldPlays())

/** Main holds videos back until it has this: built from what this machine
 *  decodes (the same probe playback uses) and the quality setting. */
function pushVideoDownloadProfile() {
  window.cascade.offline.setVideoProfile(CascadeCore.downloadProfile(currentDeviceProfile(), /** @type {any} */ (_videoDownloadQuality),
    { audioCodecs: 'aac', maxAudioChannels: '2' })).catch(() => {})
}

document.getElementById('dl-video-quality').addEventListener('change', async (e) => {
  _videoDownloadQuality = CascadeCore.parseVideoQuality(/** @type {HTMLSelectElement} */ (e.target).value)
  await window.cascade.store.set('videoDownloadQuality', _videoDownloadQuality)
  pushVideoDownloadProfile()
})
document.getElementById('dl-remove-watched').addEventListener('change', async (e) => {
  _removeWatchedEpisodes = /** @type {HTMLInputElement} */ (e.target).checked
  await window.cascade.store.set('removeWatchedEpisodes', _removeWatchedEpisodes)
  sweepWatchedEpisodes()
})

/** Removes episodes finished over a day ago, when the setting is on: at
 *  launch, hourly, and after a downloaded episode stops. */
async function sweepWatchedEpisodes() {
  if (!_removeWatchedEpisodes) return
  const n = await window.cascade.offline.removeWatched().catch(() => 0)
  if (n) refreshOffline()
}
setInterval(sweepWatchedEpisodes, 60 * 60 * 1000)

/** A downloaded video stopped 90 percent in or more: watched, as far as
 *  removing watched episodes goes. */
function noteOfflineWatched(item, positionTicks) {
  if (isLocalMode() || !item || !isVideoItem(item) || !_offline.ready[item.Id]) return
  if (!CascadeCore.isWatchedPosition(positionTicks, item.RunTimeTicks)) return
  window.cascade.offline.watched(item.Id).then(() => sweepWatchedEpisodes()).catch(() => {})
}

/** The show and seasons episodes belong to, so their pages work offline. */
async function videoContainers(seriesId, seasonId) {
  if (!seriesId) return []
  const [series, seasons] = await Promise.all([
    jfGet(`/Items/${seriesId}`, { Fields: 'Overview,Genres,DateCreated,SortName,ProductionYear,OfficialRating,CommunityRating' }).catch(() => null),
    jfGet(`/Shows/${seriesId}/Seasons`, { UserId: jf.userId }).catch(() => null),
  ])
  return [series, ...(seasons?.Items || []).filter(s => !seasonId || s.Id === seasonId)].filter(Boolean)
}

/** Asks for a movie, an episode, a season or a whole show, or removes it
 *  when it is already asked for. opts.burnIn: a picture subtitle's stream
 *  index (a movie or episode alone); opts.follow: a show fetches new
 *  episodes as they arrive. */
async function toggleVideoDownload(kind, item, opts = {}) {
  if (!item?.Id) return
  if (offlineCollection(item.Id)) {
    if (!confirm(`Remove "${item.Name || 'this'}" from your downloads?`)) return
    await removeOfflineDownload(item.Id)
    return
  }
  if (jfClient.offline) { showNotice('Downloading needs your server. Turn Offline Mode off first.', 'Downloads'); return }
  if (jf.canDownload === false) {
    showNotice('This account is not allowed to download media. An admin can turn it on in the Jellyfin dashboard.', 'Downloads')
    return
  }
  let items, collection, containers
  try {
    if (kind === 'movie' || kind === 'episode') {
      const full = await jfGet(`/Items/${item.Id}`, { Fields: VIDEO_DL_FIELDS })
      items = [full]
      collection = full
      containers = kind === 'episode' ? await videoContainers(full.SeriesId, full.SeasonId) : []
    } else if (kind === 'season') {
      const data = await jfGet(`/Shows/${item.SeriesId}/Episodes`, { SeasonId: item.Id, UserId: jf.userId, Fields: VIDEO_DL_FIELDS })
      items = data.Items || []
      collection = { Id: item.Id, Name: item.Name, Type: 'Season', SeriesId: item.SeriesId, SeriesName: item.SeriesName, IndexNumber: item.IndexNumber, ImageTags: item.ImageTags }
      containers = await videoContainers(item.SeriesId, item.Id)
    } else {
      const data = await jfGet(`/Shows/${item.Id}/Episodes`, { UserId: jf.userId, Fields: VIDEO_DL_FIELDS })
      items = data.Items || []
      collection = { Id: item.Id, Name: item.Name, Type: 'Series', ImageTags: item.ImageTags, ProductionYear: item.ProductionYear, Overview: item.Overview, Genres: item.Genres }
      containers = await videoContainers(item.Id, null)
    }
  } catch {
    showNotice('Could not read that from the server.', 'Downloads')
    return
  }
  items = items.filter(i => i?.Type === 'Movie' || i?.Type === 'Episode')
  if (!items.length) { showNotice('There is nothing to download in that.', 'Downloads'); return }
  const ok = await window.cascade.offline.add(collection, items, offlineSession(),
    { burnIn: opts.burnIn ?? null, follow: !!opts.follow, containers })
  if (!ok) { showNotice('Could not start the download.', 'Downloads'); return }
  await refreshOffline()
  placeOfflineDownloads().catch(() => {})
}

/** Fetches the new episodes of every show followed for them. Online only:
 *  after sign-in and hourly. */
let _followSyncing = false
async function syncFollowedSeries() {
  const followed = _offline.collections.filter(c => c.follow)
  if (jfClient.offline || _followSyncing || !followed.length) return
  _followSyncing = true
  try {
    const index = CascadeCore.parseIndex(await window.cascade.offline.catalog())
    for (const c of followed) {
      const data = await jfGet(`/Shows/${c.item.Id}/Episodes`, { UserId: jf.userId, Fields: VIDEO_DL_FIELDS }).catch(() => null)
      const fresh = CascadeCore.newEpisodes(index, c.item.Id, data?.Items || [])
      if (fresh.length) await window.cascade.offline.addEpisodes(c.item.Id, fresh, offlineSession(), await videoContainers(c.item.Id, null))
    }
  } finally {
    _followSyncing = false
  }
  refreshOffline()
}
setInterval(() => syncFollowedSeries().catch(() => {}), 60 * 60 * 1000)

/** The Download button of a movie, episode, season or show page. Offline it
 *  only removes, as the album button does. */
function paintVideoDownloadButton(btn, id) {
  if (!btn) return
  const c = id ? offlineCollection(id) : null
  const shown = !!id && (!!c || !jfClient.offline)
  btn.style.display = shown ? '' : 'none'
  if (!shown) return
  const done = !!c && c.done === c.total
  btn.classList.toggle('on', done)
  btn.title = c ? 'Remove this download' : 'Download to watch without a connection'
  btn.innerHTML = `${DL_ICON} ${!c ? (btn.dataset.label || 'Download') : done ? 'Downloaded' : `Downloading ${c.done}/${c.total}`}`
}

/** Whether an episode is on disk or on its way, by itself or with its season or show. */
const isVideoHeld = (id) => _offline.collections.some(c => c.trackIds.includes(id))

/** The movie, show and season pages' buttons, the follow switch and the
 *  episode list's icons, after the downloads changed. */
function renderVideoDownloadButtons() {
  paintVideoDownloadButton(document.getElementById('movie-download'), _openMovie?.Id)
  const burn = document.getElementById('movie-burnin')
  if (burn) burn.style.display = _openMovie && !offlineCollection(_openMovie.Id) && !jfClient.offline ? '' : 'none'
  paintVideoDownloadButton(document.getElementById('series-download'), _currentSeries?.Id)
  paintVideoDownloadButton(document.getElementById('season-download'), _currentSeason?.Id)
  const follow = /** @type {HTMLInputElement | null} */ (document.getElementById('series-follow'))
  if (follow) {
    const c = _currentSeries ? offlineCollection(_currentSeries.Id) : null
    if (c) follow.checked = c.follow
    follow.closest('label').style.display = c || !jfClient.offline ? '' : 'none'
  }
  for (const b of document.querySelectorAll('#episode-list .ep-dl')) {
    const id = /** @type {HTMLElement} */ (b).dataset.id
    const held = isVideoHeld(id)
    b.classList.toggle('on', held)
    b.setAttribute('title', offlineCollection(id) ? 'Remove this download' : held ? 'Downloaded with its season or show' : 'Download this episode')
  }
}

const DL_ICON = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>'

/** The Download button on the open album and on the open playlist. */
function renderOfflineButtons() {
  paintOfflineButton('btn-offline-album', _openAlbumItem?.Id)
  paintOfflineButton('btn-offline-playlist', currentSmartKind ? null : currentPlaylistId)
  renderVideoDownloadButtons()
}

function paintOfflineButton(buttonId, id) {
  const btn = document.getElementById(buttonId)
  if (!btn) return
  const c = id ? offlineCollection(id) : null
  // Offline, a page can only show what is downloaded: the button removes it,
  // and there is nothing to start.
  const shown = !!id && (!!c || !jfClient.offline)
  btn.style.display = shown ? '' : 'none'
  if (!shown) return
  const done = !!c && c.done === c.total
  btn.classList.toggle('on', done)
  btn.title = c ? 'Remove this download' : 'Download for offline listening'
  btn.innerHTML = `${DL_ICON} ${!c ? 'Download' : done ? 'Downloaded' : `Downloading ${c.done}/${c.total}`}`
}

document.getElementById('btn-offline-album').addEventListener('click', () => {
  if (_openAlbumItem) toggleOfflineDownload('album', _openAlbumItem)
})
document.getElementById('btn-offline-playlist').addEventListener('click', () => {
  if (!currentPlaylistId || currentSmartKind) return
  toggleOfflineDownload('playlist', { Id: currentPlaylistId, Name: document.getElementById('pl-detail-name').textContent })
})

// ── Downloads view ──

/** Which collections have their song list open, kept across a redraw. */
const _dlOpen = new Set()

const VIDEO_COLLECTIONS = new Set(['Movie', 'Episode', 'Season', 'Series'])
const isVideoCollection = (c) => VIDEO_COLLECTIONS.has(c.item.Type)
/** Collections whose items are worth listing: a season or show's episodes. */
const listsItems = (c) => !isVideoCollection(c) || c.item.Type === 'Season' || c.item.Type === 'Series'

function dlCardHtml(c) {
  const id = c.item.Id
  const video = isVideoCollection(c)
  const glyph = video ? '🎞' : '♪'
  // A season's own art is often missing: its show's poster stands in.
  const art = artUrl(id, c.item.ImageTags?.Primary) || (c.item.SeriesId ? artUrl(c.item.SeriesId, 'x') : '')
  const name = c.item.Type === 'Season' && c.item.SeriesName ? `${c.item.SeriesName}: ${c.item.Name || ''}` : (c.item.Name || '')
  return `<div class="dl-card" data-dl-id="${esc(id)}">
    <div class="dl-art">${art ? `<img src="${esc(art)}" alt="" onerror="this.parentNode.textContent='${glyph}'">` : glyph}</div>
    <div class="dl-info">
      <div class="dl-name">${esc(name)}</div>
      <div class="dl-meta"></div>
      <div class="dl-bar"><span></span></div>
      ${c.item.Type === 'Series' ? `<label class="dl-follow"><input type="checkbox" data-dl="follow"${c.follow ? ' checked' : ''}> Download new episodes as they arrive</label>` : ''}
    </div>
    <div class="dl-actions">
      <button class="shuffle-all-btn" data-dl="play" type="button">Play</button>
      <button class="shuffle-all-btn" data-dl="songs" type="button"${listsItems(c) ? '' : ' hidden'}>${video ? 'Episodes' : 'Songs'}</button>
      <button class="shuffle-all-btn" data-dl="retry" type="button" hidden>Try again</button>
      <button class="shuffle-all-btn" data-dl="remove" type="button">Remove</button>
    </div>
  </div>
  <div class="dl-tracks" data-dl-tracks="${esc(id)}" hidden></div>`
}

/** The download manager: what is downloading, what is downloaded, and the
 *  space it takes (docs/offline-mode-plan.md, section 7). A collection moves
 *  from Downloading to its kind once every song is on disk; the 'changed'
 *  event that brings its last song redraws this. */
function renderDownloadsView() {
  const all = _offline.collections
  document.getElementById('downloads-total').textContent = all.length
    ? `${all.length} ${all.length === 1 ? 'collection' : 'collections'} · ${fmtBytes(_offline.totalBytes)}` : ''
  renderDownloadsStorage()
  const held = _offline.playsHeld && _offline.plays > 0
  document.getElementById('downloads-held').hidden = !held
  if (held) {
    const n = _offline.plays
    document.getElementById('downloads-held-text').textContent = `${n} ${n === 1 ? 'play' : 'plays'} from while you were offline ${n === 1 ? 'was' : 'were'} not added to your history, because something was played on this account elsewhere meanwhile.`
  }
  // A followed show with every episode removed as watched waits in TV.
  const active = all.filter(c => c.done < c.total)
  const done = all.filter(c => c.done === c.total)
  const music = done.filter(c => !isVideoCollection(c))
  const movies = done.filter(c => c.item.Type === 'Movie')
  const tv = done.filter(c => isVideoCollection(c) && c.item.Type !== 'Movie')
  fillDownloadCards(document.getElementById('downloads-active'), active)
  fillDownloadCards(document.getElementById('downloads-list'), music)
  fillDownloadCards(document.getElementById('downloads-movies'), movies)
  fillDownloadCards(document.getElementById('downloads-tv'), tv)
  document.getElementById('downloads-active-section').hidden = !active.length
  document.getElementById('downloads-done-section').hidden = !music.length
  document.getElementById('downloads-movies-section').hidden = !movies.length
  document.getElementById('downloads-tv-section').hidden = !tv.length
  document.getElementById('downloads-empty').hidden = all.length > 0
  updateDownloadCards()
}

/** How much the downloads take and how much room the disk has left. */
async function renderDownloadsStorage() {
  const el = document.getElementById('downloads-storage')
  let disk = null
  try { disk = await window.cascade.offline.disk() } catch {}
  const parts = []
  if (_offline.totalBytes > 0) parts.push(`Downloads use ${fmtBytes(_offline.totalBytes)}`)
  if (_offline.limitBytes) parts.push(`limit ${fmtBytes(_offline.limitBytes)}`)
  if (disk && Number.isFinite(disk.free)) parts.push(`${fmtBytes(disk.free)} free on this disk`)
  el.textContent = parts.join(' · ')
}

function fillDownloadCards(list, collections) {
  list.innerHTML = collections.map(dlCardHtml).join('')
  for (const card of list.querySelectorAll('.dl-card')) {
    const id = card.dataset.dlId
    card.querySelector('[data-dl="play"]').addEventListener('click', () => playDownloaded(id))
    card.querySelector('[data-dl="songs"]').addEventListener('click', () => toggleDownloadedSongs(id))
    card.querySelector('[data-dl="retry"]').addEventListener('click', () => {
      // Retrying fetches from the server, which Offline Mode does not reach.
      if (jfClient.offline) { showNotice('Downloads continue when Offline Mode is off.', 'Downloads'); return }
      window.cascade.offline.resume(offlineSession())
    })
    card.querySelector('[data-dl="remove"]').addEventListener('click', async () => {
      const c = offlineCollection(id)
      const name = c?.item.Name || 'this download'
      const what = c && isVideoCollection(c) ? 'Episodes' : 'Songs'
      // Cancelling a download in progress stops the server's conversion too (offline.js).
      if (!confirm(`Remove "${name}" from your downloads? ${what} another download still uses stay.`)) return
      _dlOpen.delete(id)
      await removeOfflineDownload(id)
    })
    card.querySelector('[data-dl="follow"]')?.addEventListener('change', (e) => {
      window.cascade.offline.follow(id, /** @type {HTMLInputElement} */ (e.target).checked).then(refreshOffline)
    })
    if (_dlOpen.has(id)) showDownloadedSongs(id)
  }
}

/** Progress, sizes and failures, set in place: progress events arrive several
 *  times a second and a rebuild would swap a button under the pointer. */
function updateDownloadCards() {
  if (_currentView !== 'downloads') return
  for (const card of document.querySelectorAll('#view-downloads .dl-card')) {
    const c = offlineCollection(card.dataset.dlId)
    if (!c) continue
    let partial = 0
    let moving = false
    /** The video transferring now, which says what the server is doing. */
    let videoStatus = ''
    for (const id of c.trackIds) {
      if (_offline.ready[id]) continue
      const p = _offlineProgress.get(id)
      if (!p) continue
      moving = true
      const size = p.total || p.estimate
      if (size) partial += Math.min(1, p.received / size)
      if (p.outcome) videoStatus = videoProgressText(p)
    }
    const failed = c.trackIds.filter(id => _offline.failed[id])
    const video = isVideoCollection(c)
    const kind = { Playlist: 'Playlist', MusicAlbum: 'Album', Movie: 'Movie', Episode: 'Episode', Season: 'Season', Series: 'Show' }[c.item.Type] || 'Album'
    const unit = video ? (c.total === 1 ? 'episode' : 'episodes') : (c.total === 1 ? 'song' : 'songs')
    const count = c.item.Type === 'Movie' || c.item.Type === 'Episode' ? null : `${c.done} of ${c.total} ${unit}`
    const meta = [kind, count, fmtBytes(c.bytes), videoStatus].filter(Boolean)
    const metaEl = card.querySelector('.dl-meta')
    metaEl.textContent = meta.join(' · ')
    if (failed.length) {
      const bad = document.createElement('span')
      bad.className = 'dl-error'
      bad.textContent = ` · ${failed.length} failed`
      bad.title = _offline.failed[failed[0]]
      metaEl.appendChild(bad)
    }
    card.classList.toggle('done', c.done === c.total)
    card.querySelector('.dl-bar > span').style.width = `${c.total ? ((c.done + partial) / c.total) * 100 : 0}%`
    card.querySelector('[data-dl="retry"]').hidden = !failed.length || moving || jfClient.offline
    card.querySelector('[data-dl="play"]').disabled = c.done === 0
    card.querySelector('[data-dl="songs"]').disabled = c.done === 0
    card.querySelector('[data-dl="remove"]').textContent = c.done < c.total ? 'Cancel' : 'Remove'
  }
}

/** "Converting on the server · about 12 minutes left": what the server is
 *  doing for a video, and how long at the rate so far. */
function videoProgressText(p) {
  const label = CascadeCore.outcomeLabel(p.outcome)
  const secs = p.startedAt ? (Date.now() - p.startedAt) / 1000 : 0
  const left = secs > 3 ? CascadeCore.secondsLeft(p.received, p.total || p.estimate || null, p.received / secs) : null
  if (left === null) return label
  const mins = Math.round(left / 60)
  return `${label} · about ${mins <= 1 ? 'a minute' : `${mins} minutes`} left`
}

async function downloadedTracks(id) {
  const rows = await window.cascade.offline.tracks(id)
  return rows.filter(r => r.ready).map(r => r.item)
}

async function playDownloaded(id) {
  const items = await downloadedTracks(id)
  if (!items.length) return
  const c = offlineCollection(id)
  if (c && isVideoCollection(c)) {
    // Where the person left off, as the show page's Continue does.
    const cont = items.length > 1 ? CascadeCore.continueEpisode(items) : null
    if (cont) playVideo(items, cont.index, cont.startTicks)
    else playVideo(items, 0, resumeTicks(items[0]))
    return
  }
  playItems(items, 0, c?.item.Name)
}

async function showDownloadedSongs(id) {
  const box = document.querySelector(`[data-dl-tracks="${CSS.escape(id)}"]`)
  if (!box) return
  const c = offlineCollection(id)
  if (c && isVideoCollection(c)) {
    const items = await downloadedTracks(id)
    box.innerHTML = `<div class="dl-eps">${items.map((ep, i) => `<div class="dl-ep" data-i="${i}">
      <span>${esc(`${ep.ParentIndexNumber != null ? `S${ep.ParentIndexNumber}:E${ep.IndexNumber ?? '?'} ` : ''}${ep.Name || ''}`)}</span>
      <span class="dl-ep-time">${ep.UserData?.Played ? '✓ ' : ''}${fmtRuntime(ep.RunTimeTicks)}</span></div>`).join('')}</div>`
    box.querySelectorAll('.dl-ep').forEach(el => el.addEventListener('click', () => {
      const i = Number(/** @type {HTMLElement} */ (el).dataset.i)
      playVideo(items, i, resumeTicks(items[i]))
    }))
    box.hidden = false
    return
  }
  const items = await downloadedTracks(id)
  box.innerHTML = `<div class="track-list"><div id="dl-rows-${esc(id)}">${items.map((t, i) => trackRowHtml(t, i)).join('')}</div></div>`
  box.querySelectorAll('.track-row').forEach(el => {
    const i = parseInt(el.dataset.idx)
    wireTrackRow(el, items[i], items, i, { source: offlineCollection(id)?.item.Name })
  })
  highlightPlayingRow()
  box.hidden = false
}

function toggleDownloadedSongs(id) {
  const box = document.querySelector(`[data-dl-tracks="${CSS.escape(id)}"]`)
  if (!box) return
  if (!box.hidden) { box.hidden = true; _dlOpen.delete(id); return }
  _dlOpen.add(id)
  showDownloadedSongs(id)
}

// ── Offline Mode ──
// The normal app showing only what is downloaded (docs/offline-mode-plan.md).
// Three states, whose rules are src/core/offline-mode.ts: 'manual' is the
// Settings switch and sends nothing to the server (main blocks its origin
// too); 'unreachable' turned on by itself when the server stopped answering,
// probes on a backoff and on a network change, and turns off when it answers.
// While either is on, jfClient answers every read from the downloads
// (setOfflineSource), so the screens are the same screens.

/** The query engine over the catalog as it is now; rebuilt when the
 *  downloads change while offline. */
let _offlineEngine = null
/** Whether this launch has a session the server confirmed: until it does, a
 *  failed request is the sign-in's business, not a drop. */
let _connectedOnline = false
let _probeAttempt = 0
let _probeTimer = null
/** The parsed catalog behind the engine, for what is not a server route:
 *  the lyrics saved with each download. */
let _offlineCatalog = null

async function refreshOfflineEngine() {
  if (!CascadeCore.isOffline(_offlineState)) return
  let catalog = null
  try { catalog = await (isLocalMode() ? window.cascade.local.catalog() : window.cascade.offline.catalog()) } catch {}
  _offlineCatalog = CascadeCore.parseIndex(catalog)
  setOfflineEngine()
}

/** The engine over _offlineCatalog as it is now. Local mode's also answers
 *  the playlists made in Cascade that hold nothing yet (localQuery). */
function setOfflineEngine() {
  const engine = isLocalMode() ? CascadeCore.localQuery(_offlineCatalog) : CascadeCore.offlineQuery(_offlineCatalog)
  _offlineEngine = engine
  jfClient.setOfflineSource((path, params) => engine.answer(path, params))
}

/** Moves to a state. Offline, the reads come from the downloads and the
 *  library views are redrawn from them; back online, a full connect() draws
 *  them from the server again and sends what happened offline.
 *  `reload: false` is launch, where connect() draws everything next. */
async function setOfflineState(next, { reload = true } = {}) {
  const before = _offlineState
  if (next === before) return
  _offlineState = next
  // Awaited: turning the switch off must lift main's block before the
  // reconnect below sends anything, or that reconnect is cancelled.
  await window.cascade.offline.setMode(next).catch(() => {})
  const off = CascadeCore.isOffline(next)
  if (off) {
    await refreshOfflineEngine()
  } else {
    _offlineEngine = null
    _offlineCatalog = null
    jfClient.setOfflineSource(null)
  }
  document.body.classList.toggle('offline-on', off)
  document.body.classList.toggle('offline-auto', next === 'unreachable')
  document.body.classList.toggle('local-mode', next === 'local')
  renderOfflineIndicators()
  if (next === 'unreachable') scheduleProbe(true)
  else clearProbe()
  if (!reload) return
  if (before === 'online' && off) await redrawOffline()
  else if (next === 'online') await reconnectOnline()
}

/** Everything on screen came from the server: draw it from the downloads. */
async function redrawOffline() {
  _remote?.stop()
  _connectedOnline = false
  await populateLibraryPicker()
  invalidateLibraryViews()
  invalidateVideoViews()
  await loadHome()
  if (_currentView !== 'home') showView(_currentView)
}

async function reconnectOnline() {
  const [serverUrl, token, userId] = await Promise.all(['serverUrl', 'token', 'userId'].map(k => window.cascade.store.get(k)))
  if (!serverUrl || !token || !userId) return
  try {
    await connect(serverUrl, token, userId)
    if (_currentView !== 'home') showView(_currentView)
  } catch (e) {
    if (CascadeCore.failureKind(e?.status) === 'auth') promptReauth('Your session expired. Sign in again with a code, or enter your password.')
    else await setOfflineState('unreachable')
  }
}

/** The Settings switch. Stays on across launches until turned off. */
async function setOfflineSwitch(on) {
  // The history as it stands, so going back online can tell whether anyone
  // played anything elsewhere meanwhile.
  if (on && !jfClient.offline) await takeHistorySnapshot()
  await window.cascade.store.set('offlineMode', !!on)
  await setOfflineState(CascadeCore.nextOfflineState(_offlineState, { type: 'switch', on: !!on }))
}

/** Whether the server answers at all: its public ping, briefly. */
async function serverAnswers() {
  const serverUrl = await window.cascade.store.get('serverUrl')
  if (!serverUrl) return false
  try {
    // offline-ok: the probe is how the unreachable state ends, so it must go out.
    const r = await fetch(`${serverUrl.replace(/\/+$/, '')}/System/Ping`, { signal: AbortSignal.timeout(5000) })
    return r.ok
  } catch {
    return false
  }
}

function clearProbe() {
  clearTimeout(_probeTimer)
  _probeTimer = null
}

function scheduleProbe(reset) {
  clearProbe()
  if (reset) _probeAttempt = 0
  _probeTimer = setTimeout(probeServer, CascadeCore.probeDelayMs(_probeAttempt++))
}

async function probeServer() {
  if (_offlineState !== 'unreachable') return
  if (await serverAnswers()) await setOfflineState(CascadeCore.nextOfflineState(_offlineState, { type: 'reachable' }))
  else if (_offlineState === 'unreachable') scheduleProbe(false)
}

/** A request found no server. One failed request is not a drop: the ping
 *  decides, so a blip never flips the app. */
let _checkingDrop = false
async function checkForDrop() {
  if (_checkingDrop || _offlineState !== 'online' || !_connectedOnline) return
  _checkingDrop = true
  try {
    if (!await serverAnswers() && _offlineState === 'online') await setOfflineState('unreachable')
  } finally {
    _checkingDrop = false
  }
}

jfClient.onFailure = (status) => {
  if (CascadeCore.failureKind(status) === 'unreachable') checkForDrop()
}
window.addEventListener('offline', checkForDrop)
window.addEventListener('online', () => { if (_offlineState === 'unreachable') probeServer() })

// A network switch while still online (Wi-Fi to Ethernet, a VPN reconnecting):
// 'online' never fires for it, and a stream opened on the old network can hang
// for good. Once the server answers on the new one, a stalled song restarts
// where it was. The server's own ping is the test rather than a public host
// like 1.1.1.1: a LAN server can answer with no internet at all, and nothing
// about a network change goes to a third party.
let _netChangeTimer = null
navigator.connection?.addEventListener('change', () => {
  clearTimeout(_netChangeTimer)
  // The event comes in bursts while a link settles.
  _netChangeTimer = setTimeout(async () => {
    if (_offlineState !== 'online' || !_connectedOnline || blocksLocalPlayback()) return
    // Only for a song that is stuck: Chromium also fires 'change' when its
    // throughput estimates move during ordinary streaming, and those must
    // not ping the server over and over.
    const item = queue[queueIndex]
    if (!item || audio.paused || audio.readyState >= 3) return
    if (!await serverAnswers()) { checkForDrop(); return }
    if (queue[queueIndex] !== item || audio.paused || audio.readyState >= 3) return
    if (CascadeCore.isRadioItem(item)) playRadioStation(item)
    else restartStreamAt(mediaPosition(), { renegotiate: true })
  }, 1500)
})

/** The pill and the banner show by body class (offline-on, offline-auto);
 *  this keeps their words and the Settings switch in step. */
function renderOfflineIndicators() {
  document.getElementById('offline-pill').title = _offlineState === 'manual'
    ? 'Offline Mode is on: only what is downloaded shows'
    : "Your server isn't answering: only what is downloaded shows"
  const toggle = /** @type {HTMLInputElement} */ (document.getElementById('s-offline-toggle'))
  toggle.checked = _offlineState === 'manual'
  if (_offlineState !== 'online') setTimeout(() => showTipOnce('offline-pill', document.getElementById('offline-pill'),
    (_offlineState === 'manual' ? 'Offline Mode is on, so only downloaded music and videos show. Settings > Library turns it off.'
      : "Your server isn't answering, so only downloaded music and videos show. Cascade reconnects on its own.")
    + ' Click this to see your downloads.'), 300)
}

document.getElementById('offline-retry').addEventListener('click', () => probeServer())
document.getElementById('offline-pill').addEventListener('click', () => { markTipSeen('offline-pill'); showView('downloads') })
document.getElementById('s-offline-toggle').addEventListener('change', (e) => setOfflineSwitch(/** @type {HTMLInputElement} */ (e.target).checked))

/** Moves downloads out of the placeholder libraries: each album, show or
 *  movie asks the server for its ancestors and takes the stored library
 *  among them (CascadeCore.placementGroups says why not Ids with ParentId),
 *  and its items' stored fields are refreshed from a fresh copy, which fills
 *  in what version 1 never kept. */
async function placeOfflineDownloads() {
  if (jfClient.offline) return
  let catalog = null
  try { catalog = await window.cascade.offline.catalog() } catch {}
  if (!catalog) return
  const index = CascadeCore.parseIndex(catalog)
  const unplaced = CascadeCore.unplacedTrackIds(index)
  if (!unplaced.length) return
  for (const [groupId, ids] of CascadeCore.placementGroups(index, unplaced)) {
    const ancestors = await jfGet(`/Items/${groupId}/Ancestors`, { UserId: jf.userId }).catch(() => null)
    const lib = CascadeCore.libraryFromAncestors(index, ancestors)
    if (!lib) continue
    for (let i = 0; i < ids.length; i += 100) {
      const found = await jfGet('/Items', {
        Ids: ids.slice(i, i + 100).join(','), UserId: jf.userId,
        Fields: 'Genres,DateCreated,SortName,ProductionYear,Overview,MediaSources',
      }).catch(() => null)
      if (found?.Items?.length) await window.cascade.offline.place(lib, found.Items)
    }
  }
}

// ── Local mode ──
// A folder on this computer instead of a server (docs/local-mode-plan.md).
// The state is 'local' (src/core/offline-mode.ts): the reads answer from a
// catalog the main process builds from the folder (local-library.js), with
// the engine Offline Mode uses (wrapped by CascadeCore.localQuery so a new,
// empty playlist shows), and what needs a server hides as it does offline.
// Unlike Offline Mode the web is there: lyrics, artwork and translation models
// still load (webFetch). Nothing is sent to a Jellyfin server, ever: init()
// starts here before reading the server settings at all.
//
// Picked at setup or in Settings, and kept in the store as libraryMode.
// Switching reloads the window: the two libraries never mix, and a reload is
// the one re-init that leaves nothing of the other behind.

/** The catalog version the engine was built from. local-library.js bumps it
 *  when a scan, a playlist change or the device profile changes the catalog. */
let _localVersion = null

/** A function, not a const: jfFetch and artUrl reach it from the first render. */
function isLocalMode() {
  return _offlineState === 'local'
}

const LOCAL_M3U_READ_ONLY = 'This playlist is an .m3u file in your folder. Cascade plays it but never changes the file.'

/** A playlist the folder's catalog holds (an .m3u or one made in Cascade). */
function isLocalPlaylist(id) {
  return isLocalMode() && !!id && !!_offlineCatalog?.collections.some(c => c.item.Type === 'Playlist' && c.item.Id === id)
}

/**
 * Opens the app on the folder: what connect() does for a server, answered
 * for a folder. False, with nothing changed, when no folder is set (a store
 * edited by hand): the sign-in screen then shows as usual.
 */
async function startLocal() {
  let summary
  try { summary = await window.cascade.local.start(currentDeviceProfile()) } catch (e) {
    console.error('[cascade] Local mode could not start:', e)
    return false
  }
  if (!summary?.local?.root) {
    await window.cascade.store.set('libraryMode', 'jellyfin')
    return false
  }
  document.getElementById('setup-overlay').classList.add('hidden')
  // Nobody is signed in, so nobody's downloads show.
  await window.cascade.offline.setOwner(null)
  jf = { url: '', token: '', userId: CascadeCore.LOCAL_USER_ID, deviceId, appVersion }
  _offline = { ...summary, art: new Set(summary.art) }
  _localVersion = summary.local.version
  await setOfflineState('local', { reload: false })
  renderLocalSettings(summary.local)
  if (summary.local.error === 'missing') showLocalFolderMissing(summary.local.roots)

  // What a server would have said about this account: nothing to administer,
  // delete, download or tune in to.
  jf.isAdmin = false
  jf.canDelete = false
  jf.canDownload = false
  jf.hasLiveTv = false
  applyRadioNavVisibility()
  _applyAdminGating()
  // No plugin. Its controls are disabled here rather than through
  // _applyCascadePluginAvailability, which also turns a saved Server-only
  // lyrics switch off for good: that switch belongs to the server.
  _cascadePluginAbsent = true
  _cascadePluginCaps = new Set()
  _cascadePluginProbed = Promise.resolve()
  for (const id of ['lyrics-edit-btn', 'ov-lyrics-edit-btn']) {
    const btn = /** @type {HTMLButtonElement | null} */ (document.getElementById(id))
    if (btn) btn.disabled = true
  }
  for (const id of ['lyrics-edit-btn-tip', 'ov-lyrics-edit-btn-tip']) document.getElementById(id)?.setAttribute('data-tip', 'Not in Local mode')
  _applyServerOnlyMode(false)

  await populateLibraryPicker()
  invalidateLibraryViews()
  invalidateVideoViews()
  await loadHome()
  await restoreLastQueue()
  // The first-run wizard, as connect() runs it after a sign-in.
  await maybeShowSetupWizard()
  return true
}

/** The folder's summary, and the catalog when it changed. `redraw`: a scan
 *  found something new, so the screens are drawn from it. One at a time: a
 *  change event and a playlist write both ask, and the second must wait for
 *  the first's catalog rather than see its version and return early with the
 *  engine still on the old one. */
let _localRefresh = Promise.resolve()
function refreshLocal(opts = {}) {
  const run = _localRefresh.then(() => refreshLocalNow(opts))
  _localRefresh = run.catch(() => {})
  return run
}

async function refreshLocalNow({ redraw = false } = {}) {
  let summary
  try { summary = await window.cascade.local.summary() } catch { return }
  if (!isLocalMode()) return
  _offline = { ...summary, art: new Set(summary.art) }
  renderLocalSettings(summary.local)
  if (summary.local.version === _localVersion) return
  _localVersion = summary.local.version
  await refreshOfflineEngine()
  if (redraw) await redrawLocal()
}

async function redrawLocal() {
  await populateLibraryPicker()
  invalidateLibraryViews()
  invalidateVideoViews()
  await loadHome()
  if (_currentView !== 'home') showView(_currentView)
}

window.cascade.local.onEvent((event) => {
  if (!isLocalMode()) return
  if (event.type === 'progress') { renderLocalProgress(event); return }
  // A playlist change was asked for here, and that caller has the new catalog.
  refreshLocal({ redraw: event.reason !== 'playlist' })
})

/** A favorite, a play, a position or a played mark: kept by the main process,
 *  then written into this copy of the catalog rather than fetching all of it
 *  again (CascadeCore.setLocalUserData). */
async function localChange(itemId, change) {
  const ud = await window.cascade.local.change(itemId, change)
  if (!ud || !_offlineCatalog || !isLocalMode()) return
  CascadeCore.setLocalUserData(_offlineCatalog, itemId, ud)
  setOfflineEngine()
}

/**
 * jfFetch in Local mode: the playlist writes the screens send Jellyfin,
 * answered by the playlists kept in Cascade, in the shape Jellyfin answers
 * (CascadeCore.playlistOpFor). Anything else fails as it does offline. The
 * engine has the new catalog before this resolves, so the caller's re-read
 * sees the change.
 */
async function localServerWrite(input, init = {}) {
  const op = CascadeCore.playlistOpFor(init.method || 'GET', String(input), init.body, isLocalPlaylist)
  if (!op) throw new CascadeCore.OfflineError('Not available in Local mode')
  const result = await window.cascade.local.playlist(op)
  if (!result?.ok) {
    return new Response(result?.readOnly ? LOCAL_M3U_READ_ONLY : 'Cascade could not change that playlist.', { status: result?.readOnly ? 403 : 400 })
  }
  await refreshLocal()
  if (op.kind === 'create') return new Response(JSON.stringify({ Id: result.id }), { status: 200, headers: { 'content-type': 'application/json' } })
  return new Response(null, { status: 204 })
}

// ── Local mode: Settings and switching ──

function showLocalFolderMissing(roots) {
  const missing = (roots || []).filter(r => r.missing).map(r => r.path)
  if (!missing.length) return
  showNotice(`Cascade can't open ${missing.length === 1 ? 'this library folder' : 'these library folders'}:\n\n${missing.join('\n')}\n\nIf it is on a drive that isn't plugged in, plug it in and choose Rescan in Settings, or remove it there. What Cascade last found in it stays meanwhile.`, 'Local library')
}

const _fmtCount = (n, one, many) => `${n.toLocaleString()} ${n === 1 ? one : many}`

function renderLocalSettings(local) {
  if (!local) return
  const roots = local.roots || []
  document.getElementById('s-local-folders').innerHTML = roots.map(r => `<div class="setting-row">
      <div class="setting-label" style="min-width:0">
        <span class="setting-name">${esc(r.name)}</span>
        <span class="setting-desc" style="overflow-wrap:anywhere">${esc(r.path)}${r.missing ? " · Cascade can't open it right now. Plug in its drive, or remove it." : ''}</span>
      </div>
      <button class="btn btn-secondary" type="button" data-remove-folder="${esc(r.path)}"${roots.length < 2 ? ' disabled title="The last folder can\'t be removed. Switch to Jellyfin in Account instead."' : ''}>Remove</button>
    </div>`).join('')
  const status = document.getElementById('s-local-status')
  if (local.scanning) renderLocalProgress(local.progress)
  else {
    const c = local.counts
    const parts = [_fmtCount(c.songs, 'song', 'songs'), c.movies && _fmtCount(c.movies, 'movie', 'movies'), c.episodes && _fmtCount(c.episodes, 'episode', 'episodes')].filter(Boolean)
    const when = local.lastScan ? ` · scanned ${new Date(local.lastScan).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}` : ''
    status.textContent = parts.join(', ') + when + (local.tagsReadable ? '' : " · Cascade couldn't load its tag reader, so names come from folders")
  }
  const rescan = /** @type {HTMLButtonElement} */ (document.getElementById('s-local-rescan'))
  rescan.disabled = !!local.scanning
  const row = document.getElementById('s-local-unplayable-row')
  row.style.display = local.unplayable?.length ? '' : 'none'
  if (!local.unplayable?.length) return
  document.getElementById('s-local-unplayable-summary').textContent = `Show ${_fmtCount(local.unplayable.length, 'file', 'files')}`
  // Capped: a library of HEVC rips would otherwise draw thousands of rows.
  const shown = local.unplayable.slice(0, 500)
  document.getElementById('s-local-unplayable').innerHTML = shown.map(u => `<li>${esc(u.rel)}<span>${esc(u.reason)}</span></li>`).join('')
    + (local.unplayable.length > shown.length ? `<li>and ${(local.unplayable.length - shown.length).toLocaleString()} more</li>` : '')
}

function renderLocalProgress(p) {
  document.getElementById('s-local-status').textContent = p?.total
    ? `Scanning… read ${p.done.toLocaleString()} of ${p.total.toLocaleString()} new or changed files`
    : 'Scanning the folder…'
  const rescan = /** @type {HTMLButtonElement} */ (document.getElementById('s-local-rescan'))
  rescan.disabled = true
}

/** Picks a folder and opens the app on it. The folder is kept in main; the
 *  window reloads into Local mode (init). */
async function switchToLocal() {
  const picked = await window.cascade.local.chooseFolder()
  if (!picked?.ok) {
    if (picked?.error) showNotice(picked.error, 'Local library')
    return
  }
  await window.cascade.store.set('libraryMode', 'local')
  location.reload()
}

/** Back to a server: the sign-in screen, or the account still saved. */
async function switchToJellyfin() {
  await window.cascade.store.set('libraryMode', 'jellyfin')
  // Main hears the state from the new page only when it is Offline Mode's.
  await window.cascade.offline.setMode('online').catch(() => {})
  location.reload()
}

document.getElementById('setup-local').addEventListener('click', () => switchToLocal())
document.getElementById('s-mode-local').addEventListener('click', () => switchToLocal())
document.getElementById('s-mode-jellyfin').addEventListener('click', () => switchToJellyfin())
// Another folder is another library: the same reload as switching modes.
// Removing one keeps its favorites and plays: adding it back finds them.
document.getElementById('s-local-add').addEventListener('click', async () => {
  const added = await window.cascade.local.addFolder()
  // A saved choice of libraries would leave the new one out: every library
  // shows again, as on a first run.
  if (added?.ok) { await window.cascade.store.delete('localLibraryIds'); location.reload() }
  else if (added?.error) showNotice(added.error, 'Local library')
})
document.getElementById('s-local-folders').addEventListener('click', async e => {
  const btn = /** @type {HTMLElement} */ (e.target).closest('[data-remove-folder]')
  if (!btn || /** @type {HTMLButtonElement} */ (btn).disabled) return
  const removed = await window.cascade.local.removeFolder(btn.getAttribute('data-remove-folder'))
  if (removed?.ok) location.reload()
})
document.getElementById('s-local-rescan').addEventListener('click', async () => {
  if (!isLocalMode()) return
  const summary = await window.cascade.local.rescan().catch(() => null)
  if (summary) renderLocalSettings(summary.local)
})

// ── What happened while the server was out of reach ──
// docs/offline-mode-plan.md, section 5; the rules are src/core/offline-sync.ts.
// Jellyfin counts a play when playback STARTS, so a start report it never
// heard is a play lost; a stop report it never heard is a lost resume point.
// Both are kept (in the main process, across a restart) with favorites and
// played marks made offline, and sent once the server answers:
// - plays are history, replayed only when the server's history still matches
//   the snapshot kept while online, else held for the person in Downloads;
// - positions, played marks and favorites win only over an older server value.

function queueOfflinePlay(itemId) {
  // Local mode: there is no server to tell later, the play is kept now.
  if (isLocalMode()) { localChange(itemId, { kind: 'play' }).catch(() => {}); return }
  window.cascade.offline.addPlay({ itemId, userId: jf.userId, date: new Date().toISOString() })
    .then(() => scheduleOfflineRefresh()).catch(() => {})
}

/** A favorite or played mark made offline, or where a video stopped. */
async function queueOfflineChange(change) {
  if (isLocalMode()) { await localChange(change.itemId, change); return }
  await window.cascade.offline.addChange({ ...change, userId: jf.userId, at: new Date().toISOString() })
  scheduleOfflineRefresh()
}

/** A video stopped with no server to tell: played when it was watched to
 *  the end, as the server would have marked it, else where it stopped. */
function queueVideoPosition(item, ticks) {
  const watched = CascadeCore.isWatchedPosition(ticks, item.RunTimeTicks)
  if (!watched && !(ticks > 0)) return
  queueOfflineChange(watched ? { itemId: item.Id, kind: 'played', played: true } : { itemId: item.Id, kind: 'position', ticks })
    .catch(() => {})
}

/** A sync is running: the snapshot waits for it, since the first thing it
 *  does is compare the server's history with the one kept. */
let _syncing = false
/** Asked for while one ran: it runs once more when that one ends. */
let _syncAgain = false
let _snapshotTimer = null
/** History fetches tried before the plays wait for the next connect. */
const SYNC_TRIES = 3

/** A few seconds after a report lands, one request rather than one a song. */
function scheduleHistorySnapshot() {
  clearTimeout(_snapshotTimer)
  _snapshotTimer = setTimeout(() => takeHistorySnapshot(), 5000)
}

/** Keeps the server's play history as it is now. Not while plays wait for
 *  the compare: the snapshot must stay what it was when they were made, or
 *  the compare would match whatever happened elsewhere. */
async function takeHistorySnapshot(fromSync = false) {
  if (jfClient.offline || !jf?.url || (_syncing && !fromSync)) return
  let summary = null
  try { summary = await window.cascade.offline.summary() } catch {}
  if (!summary || (summary.plays > 0 && !summary.playsHeld)) return
  const list = await jfGet('/Items', { ...CascadeCore.HISTORY_QUERY, UserId: jf.userId }).catch(() => null)
  if (list?.Items && !jfClient.offline) await window.cascade.offline.setHistory(list.Items).catch(() => {})
}

/** Back online (every online connect()): compares the history, then sends
 *  the rest in the background. Returns once the compare is done, so nothing
 *  this app sends can change the history before it is read. */
async function syncOffline(attempt = 1) {
  if (jfClient.offline || !jf?.url) return
  if (_syncing) { _syncAgain = true; return }
  _syncing = true
  _syncAgain = false
  let replay = false
  try {
    const catalog = CascadeCore.parseIndex(await window.cascade.offline.catalog())
    if (catalog.plays.length && !catalog.playsHeld) {
      const list = await jfGet('/Items', { ...CascadeCore.HISTORY_QUERY, UserId: jf.userId }).catch(() => null)
      // No answer: nothing can be told yet. Tried again shortly, then it all
      // waits for the next connect.
      if (!list?.Items) {
        _syncing = false
        const userId = jf.userId
        if (attempt < SYNC_TRIES) setTimeout(() => { if (jf?.userId === userId) syncOffline(attempt + 1) }, 15000)
        return
      }
      replay = CascadeCore.playsCatchUp(catalog, list.Items) === 'replay'
      if (!replay) {
        await window.cascade.offline.holdPlays(true)
        const n = catalog.plays.length
        showToast(`${n} ${n === 1 ? 'play' : 'plays'} from offline are waiting in Downloads`, { level: 'advanced' })
      }
    }
  } catch {
    _syncing = false
    return
  }
  finishOfflineSync(replay).catch(() => {}).finally(() => {
    _syncing = false
    scheduleOfflineRefresh()
    if (_syncAgain) syncOffline()
  })
}

async function finishOfflineSync(replay) {
  await sendOfflineChanges()
  if (replay) await replayOfflinePlays()
  await refreshOfflineUserData()
  await takeHistorySnapshot(true)
}

/** Positions, played marks and favorites, coalesced per item, each sent only
 *  when the server's copy is older. A change the server could not take yet is
 *  kept; one for an item it no longer has (400, 404) is dropped. */
async function sendOfflineChanges() {
  const changes = await window.cascade.offline.takeChanges().catch(() => [])
  if (!changes.length) return
  const keep = (list) => Promise.all(list.map(c => window.cascade.offline.addChange(c).catch(() => {})))
  // Another account's change cannot be sent with this account's token.
  const mine = changes.filter(c => c.userId === jf.userId)
  await keep(changes.filter(c => c.userId !== jf.userId))
  const updates = CascadeCore.coalesceChanges(mine)
  const server = new Map()
  const ids = updates.map(u => u.itemId)
  for (let i = 0; i < ids.length; i += 100) {
    const r = await jfGet('/Items', { Ids: ids.slice(i, i + 100).join(','), UserId: jf.userId }).catch(() => null)
    if (!r?.Items) { await keep(mine); return }
    for (const it of r.Items) server.set(it.Id, it)
  }
  for (let i = 0; i < updates.length; i++) {
    const u = updates[i]
    const send = CascadeCore.updateToSend(u, server.get(u.itemId) ?? null)
    if (!send) continue
    const result = await sendUserDataUpdate(u.itemId, send)
    if (result === 'ok' || result === 'drop') continue
    // No answer at all: the rest would fail the same way.
    const left = new Set(result === 'down' ? updates.slice(i).map(x => x.itemId) : [u.itemId])
    await keep(mine.filter(c => left.has(c.itemId)))
    if (result === 'down') return
  }
}

/** 'ok', 'drop' (the server will never take it), 'later' or 'down'. */
async function sendUserDataUpdate(itemId, send) {
  const q = `userId=${encodeURIComponent(jf.userId)}`
  const calls = []
  if (send.userData) {
    calls.push([`/UserItems/${itemId}/UserData?${q}`, {
      method: 'POST', headers: CascadeCore.authHeaders(jf, { 'Content-Type': 'application/json' }), body: JSON.stringify(send.userData),
    }])
  }
  if (send.favorite !== undefined) {
    calls.push([`/UserFavoriteItems/${itemId}?${q}`, { method: send.favorite ? 'POST' : 'DELETE', headers: CascadeCore.authHeaders(jf) }])
  }
  for (const [path, init] of calls) {
    let status = 0
    try { status = (await jfFetch(`${jf.url}${path}`, init)).status } catch { /* still unreachable */ }
    if (status >= 200 && status < 300) continue
    if (CascadeCore.dropsPlay(status)) return 'drop'
    return status === 0 ? 'down' : 'later'
  }
  return 'ok'
}

/** Every downloaded item's user data from the server, so offline lists start
 *  from its truth next time. A chunk that fails keeps what was stored. */
async function refreshOfflineUserData() {
  let catalog = null
  try { catalog = await window.cascade.offline.catalog() } catch {}
  const ids = CascadeCore.userDataIds(CascadeCore.parseIndex(catalog))
  if (!ids.length) return
  const items = await jfItemsByIds(ids)
  if (items.length) await window.cascade.offline.setUserData(items).catch(() => {})
}

let _replayingPlays = false
/** Sends the queued plays oldest first with their own dates, so the
 *  server's history reads as if they had happened online. */
async function replayOfflinePlays() {
  if (_replayingPlays || !jf?.url) return
  _replayingPlays = true
  try {
    const plays = CascadeCore.playsOldestFirst(await window.cascade.offline.takePlays())
    for (let i = 0; i < plays.length; i++) {
      const p = plays[i]
      // Another account's play cannot be sent with this account's token. Keep it.
      if (p.userId !== jf.userId) { await window.cascade.offline.addPlay(p); continue }
      let status = 0
      try {
        const res = await jfFetch(`${jf.url}/UserPlayedItems/${p.itemId}?userId=${encodeURIComponent(p.userId)}&datePlayed=${encodeURIComponent(p.date)}`,
          { method: 'POST', headers: CascadeCore.authHeaders(jf) })
        status = res.status
        if (res.ok) continue
      } catch { /* still unreachable */ }
      // The item is gone or the request can never succeed: retrying would jam
      // every play behind it. Anything else may clear up, so it is kept.
      if (CascadeCore.dropsPlay(status)) continue
      await window.cascade.offline.addPlay(p)
      // No answer at all: the rest would fail the same way, keep them in order.
      if (status === 0) { for (const rest of plays.slice(i + 1)) await window.cascade.offline.addPlay(rest); break }
    }
  } finally {
    _replayingPlays = false
    scheduleOfflineRefresh()
  }
}

/** Downloads' Add: the held plays go into the server's history after all. */
async function addHeldPlays() {
  if (jfClient.offline) { showNotice('Plays are added once Offline Mode is off.', 'Downloads'); return }
  if (_syncing) return
  _syncing = true
  try {
    await window.cascade.offline.holdPlays(false)
    await replayOfflinePlays()
    await refreshOfflineUserData()
    await takeHistorySnapshot(true)
  } finally {
    _syncing = false
    refreshOffline()
  }
}

/** Downloads' Discard: the held plays are dropped, and the catalog goes back
 *  to the server's counts. */
async function discardHeldPlays() {
  if (!confirm('Discard the plays from while you were offline? They will not be added to your history.')) return
  await window.cascade.offline.discardPlays()
  if (!jfClient.offline) {
    await refreshOfflineUserData()
    await takeHistorySnapshot()
  }
  refreshOffline()
}

// ── Full-screen now-playing overlay ──────────────────────────────────────────

const npOverlay = document.getElementById('np-overlay')
let overlayOpen = false
let overlayLyricsOpen = false

// The traffic lights fade with the video controls. Watching the overlay's own
// class list keeps this in one place: idle, open and video are each set from
// several paths, and all of them end up here.
let _windowButtonsHidden = false
function syncWindowButtons() {
  const hide = overlayOpen && npOverlay.classList.contains('video')
    && npOverlay.classList.contains('idle') && !npOverlay.matches(':has(:focus-visible)')
  if (hide === _windowButtonsHidden) return
  _windowButtonsHidden = hide
  window.cascade.setWindowButtonsVisible?.(!hide)
}
new MutationObserver(() => { syncWindowButtons(); syncCaptionButtons() })
  .observe(npOverlay, { attributes: true, attributeFilter: ['class'] })

// ── Beat-reactive background ───────────────────────────────────────────────
let _currentBgArtUrl = null  // current track's art URL for overlay background
let _beatRafId = null
let _blobColors = []  // extracted colors, stored for blob drift animation
let _driftParams = [] // randomized per-blob drift parameters, set on each color refresh

function randomizeDrift() {
  _driftParams = CascadeCore.randomizeDrift()
}

// Every write to #np-overlay's background goes through here.
//
// The element is position: fixed inset: 0 and the queue, transport, album art
// and lyrics all paint into that same layer, so each assignment re-rasters the
// whole viewport - and assigning a value identical to the current one still
// invalidates paint. The drift loop runs at ~15fps over periods of tens of
// seconds and blobBackgroundCss rounds to one decimal, so most of those frames
// produce a string that is already on the element.
//
// The cache lives here rather than in startBeatLoop's closure because three
// other paths write this same property; a closure-local cache would go stale
// behind them and skip a write that was actually needed.
//
// One cache for one element: every caller passes #np-overlay (the drift loop
// and clearAlbumArtTheme look it up locally). Passing a second element here would make them share a cache and
// suppress each other's writes, and #np-overlay must not be replaced in the
// DOM either - a fresh element would start blank behind a stale cache.
let _lastOverlayBgCss = null
function setOverlayBackgroundImage(overlay, css) {
  if (css === _lastOverlayBgCss) return
  _lastOverlayBgCss = css
  overlay.style.backgroundImage = css
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
    if (ts - _lastBlobFrameTs < CascadeCore.blobTuning.frameMs) return
    _lastBlobFrameTs = ts
    if (_blobColors.length > 0 && themeAlbumArt && _driftParams.length > 0) {
      // Drift speed scales the clock itself, as on the Apple apps, so a change
      // jumps the blobs once rather than easing.
      const t = Date.now() / 1000 * CascadeCore.blobLook.speed
      const blobs = CascadeCore.driftedBlobs(_blobColors, _driftParams, t, _isLightTheme())
      setOverlayBackgroundImage(overlay, CascadeCore.blobBackgroundCss(blobs))
    }
  }
  frame()
}

function stopBeatLoop() {
  if (_beatRafId) { cancelAnimationFrame(_beatRafId); _beatRafId = null }
}

// ── Now-playing equalizer ────────────────────────────────────────────────────
// Drives the .track-eq bars from real playback via Web Audio. eqLevels()
// (src/core/eq.ts) turns one frame of frequency data into 0..1 heights -
// everything here is just wiring: build the graph once, run a throttled rAF
// loop while something plays, and hide the bars for the rest of the session
// if the graph ever produces silence for audio that is actually audible.
//
// Each deck gets its own permanent source + gain node (see _deckSource/
// _deckGain), both feeding the one shared 5-band EQ stage, then the one
// shared analyser, so a crossfade sums cleanly, both decks come out
// equalized the same way, and the bars follow whichever deck(s) are actually
// sounding instead of just the outgoing one.

let _audioCtx = null
let _mediaSrc = null    // MediaElementAudioSourceNode for the CURRENT deck, kept
                         // updated at every crossfade handoff.
const _deckSourceNodes = new Map()   // deck element -> its permanent MediaElementAudioSourceNode
const _deckNormGainNodes = new Map() // deck element -> its permanent GainNode (volume normalization only)
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

// Response-graph pixel size - must match the SVG's viewBox in index.html.
// The graph's markup and CSS size it 1:1 with this viewBox on purpose (no
// scaling), so a pointer's clientY can be turned into a dB straight off
// getBoundingClientRect() without a transform to invert.
const EQ_GRAPH_W = 260
const EQ_GRAPH_H = 140

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

/** The permanent volume-normalization GainNode for a deck, or null if the
 *  graph was never built. Separate from _deckGain: that one is the crossfade
 *  envelope (0..1, ramped per handoff), this one is a static per-track
 *  multiplier - keeping them as two nodes means a crossfade's ramp never has
 *  to know or care what normalization last set, and vice versa. */
function _deckNormGain(deck) {
  return _deckNormGainNodes.get(deck) || null
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
    // Each deck's chain is source -> normGain -> crossfade gain -> preamp, so
    // normalization survives a crossfade the same way the CODEMAP says it
    // must: the incoming deck carries its OWN track's gain into the fade
    // rather than inheriting whatever the outgoing deck was set to.
    DECKS.forEach(d => {
      const normGain = _audioCtx.createGain()
      const gain = _audioCtx.createGain()
      _deckSource(d).connect(normGain)
      normGain.connect(gain)
      gain.connect(_eqPreamp)
      _deckNormGainNodes.set(d, normGain)
      _deckGainNodes.set(d, gain)
    })
    _masterGain = _audioCtx.createGain()
    _eqAnalyser.connect(_masterGain)
    _masterGain.connect(_audioCtx.destination)
    setDeckVolume(volume)
    _mediaSrc = _deckSource(audio)
    _applyEqToGraph()
    // The graph is built lazily on the first 'play' event (see startEqLoop
    // below), which is AFTER playCurrentTrack's own call to
    // _applyNormalizationToDeck for the very first track of a session - that
    // call found no graph yet and was a no-op, same reason _applyEqToGraph
    // is re-run here rather than trusted to have already landed. Apply it
    // now for whatever is actually on `audio` at this point.
    if (queue[queueIndex]) _applyNormalizationToDeck(audio, queue[queueIndex])
    // setSinkId lives on the context, which also does not exist until now -
    // apply whatever was loaded from the store at init() the first chance
    // there is a context to apply it to.
    _applyOutputDevice()
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
    // The elements are back on the normal output, so they carry the volume again.
    if (_masterGain) { try { _masterGain.disconnect() } catch {} }
    _masterGain = null
    setDeckVolume(volume)
  }
}

// ── Volume normalization ─────────────────────────────────────────────────────
// Jellyfin's NormalizationGain (dB), applied on the per-deck GainNode built
// above so it survives a crossfade: each deck carries its OWN track's gain
// into a fade rather than inheriting whatever the outgoing deck had.
//
// Fetched lazily per track (or album), same reasoning as loadChapters(): the
// list/search/playlist queries that populate the queue are owned by several
// other views and none of them request this field, so asking here - once per
// track, cached - beats adding it everywhere a queue can be built from.

const _normGainCache = new Map()   // 'track:<id>' or 'album:<id>' -> NormalizationGain in dB, or null when the server has none

/** One item's NormalizationGain in dB, fetched once and cached; null when the
 *  server has none for it. */
async function _normalizationDb(id, key) {
  if (_normGainCache.has(key)) return _normGainCache.get(key)
  const full = await jfGet(`/Items/${id}`, {})
  const db = Number.isFinite(full?.NormalizationGain) ? full.NormalizationGain : null
  _normGainCache.set(key, db)
  return db
}

/** Resolve the linear gain for one item, honoring the track/album setting.
 *  Missing or corrupt NormalizationGain means unity - see
 *  CascadeCore.normalizationGainLinear, which also clamps a real value into
 *  the safe range.
 *
 *  Album mode falls back to the track's own gain when the album has none.
 *  Jellyfin 10.11 writes a gain onto far fewer albums than tracks: on the
 *  user's own server 300 of 300 sampled tracks had one and 17 of 200 albums,
 *  so without the fallback Album mode left nine albums in ten un-normalized. */
async function _fetchNormalizationGain(item) {
  if (!item?.Id) return 1
  try {
    let db = null
    if (normalizationSource === 'album' && item.AlbumId) db = await _normalizationDb(item.AlbumId, `album:${item.AlbumId}`)
    if (db === null) db = await _normalizationDb(item.Id, `track:${item.Id}`)
    return CascadeCore.normalizationGainLinear(db)
  } catch {
    return 1
  }
}

// Which item id a deck's in-flight normalization fetch is currently for -
// guards against the deck moving on to a different track before the fetch
// lands, same shape as loadChapters' own queue check.
const _deckNormGainTarget = new Map()

/**
 * Set a deck's normalization gain for `item`, or leave it at unity when the
 * feature is off or the item is unknown. Always snaps to unity first: a deck
 * is reused across tracks, and this must never leave it at whatever the
 * PREVIOUS track's gain was while the fetch for the new one is in flight.
 * Ramps to the real value with setTargetAtTime once it lands (click-free,
 * same time constant the EQ bands use), and is a no-op before the graph
 * exists - _deckNormGain returns null until _ensureEqGraph has run.
 */
async function _applyNormalizationToDeck(deck, item) {
  const node = _deckNormGain(deck)
  if (!node || !_audioCtx) return
  node.gain.cancelScheduledValues(_audioCtx.currentTime)
  node.gain.setValueAtTime(1, _audioCtx.currentTime)
  if (!normalizationEnabled || !item?.Id) return
  _deckNormGainTarget.set(deck, item.Id)
  const gain = await _fetchNormalizationGain(item)
  if (_deckNormGainTarget.get(deck) !== item.Id) return   // deck moved on while this was in flight
  const target = _deckNormGain(deck)
  if (!target || !_audioCtx) return
  target.gain.setTargetAtTime(gain, _audioCtx.currentTime, EQ_RAMP_SEC)
}

/**
 * Re-applies normalization to whatever is actually loaded on the decks right
 * now - used when the user flips the setting or the track/album choice
 * mid-playback, so the change is heard immediately rather than only from the
 * next track change.
 */
function _reapplyNormalizationToLiveDecks() {
  if (audio && queue[queueIndex]) _applyNormalizationToDeck(audio, queue[queueIndex])
  const nextIndex = _resolveCrossfadeTarget()
  const nextItem = nextIndex >= 0 ? queue[nextIndex] : null
  if (_cfOtherDeck && nextItem) _applyNormalizationToDeck(_cfOtherDeck, nextItem)
  if (_streamPrefetch && nextItem) _applyNormalizationToDeck(_streamPrefetch.deck, nextItem)
}

// ── Output device ─────────────────────────────────────────────────────────
// All audio leaves through the one shared AudioContext (see _ensureEqGraph),
// never through the deck elements directly - so AudioContext.setSinkId() is
// the single lever that moves every deck's output at once. Nothing here
// touches the elements themselves.

/** True once this build's AudioContext actually has setSinkId - an older
 *  Electron/Chromium simply lacks the method, and the picker hides itself
 *  rather than offering a control that would silently do nothing. */
function _outputDeviceSupported() {
  return typeof (window.AudioContext || window.webkitAudioContext).prototype.setSinkId === 'function'
}

/** Point the shared AudioContext at outputDeviceId, falling back to the
 *  system default cleanly if the device is gone or the call fails - a device
 *  can be unplugged between when the list was built and when this runs. */
async function _applyOutputDevice() {
  if (!_audioCtx || !_outputDeviceSupported()) return
  const target = outputDeviceId === 'default' ? '' : outputDeviceId
  try {
    await _audioCtx.setSinkId(target)
  } catch (e) {
    console.warn('[cascade] output device unavailable, falling back to system default', e)
    outputDeviceId = 'default'
    await window.cascade.store.set('outputDeviceId', 'default')
    try { await _audioCtx.setSinkId('') } catch { /* nothing left to fall back to */ }
    _refreshOutputDeviceSelect()
  }
}

/**
 * Enumerate audiooutput devices and rebuild the Settings dropdown, keeping
 * the current selection if it still exists. Called on Settings load and on
 * every 'devicechange' - a device can appear or disappear at any time, not
 * just while Settings is open.
 */
async function _refreshOutputDeviceSelect() {
  const row = document.getElementById('output-device-row')
  const select = document.getElementById('output-device')
  if (!row || !select) return
  if (!_outputDeviceSupported()) { row.style.display = 'none'; return }
  row.style.display = ''
  let devices = []
  try {
    devices = (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === 'audiooutput')
  } catch (e) {
    console.warn('[cascade] could not enumerate audio output devices', e)
  }
  // The saved device no longer exists (unplugged, or a config carried over
  // from another machine) - fall back rather than silently pointing at
  // nothing until the next play() fails.
  if (outputDeviceId !== 'default' && !devices.some(d => d.deviceId === outputDeviceId)) {
    outputDeviceId = 'default'
    await window.cascade.store.set('outputDeviceId', 'default')
    await _applyOutputDevice()
  }
  // Chromium lists its own 'default' alias alongside the real device it
  // currently points at - "System default" above is that same concept, so
  // the real per-device entries are enough without the duplicate.
  const real = devices.filter(d => d.deviceId && d.deviceId !== 'default')
  select.innerHTML = '<option value="default">System default</option>' +
    real.map((d, i) => `<option value="${esc(d.deviceId)}">${esc(d.label || `Speaker ${i + 1}`)}</option>`).join('')
  select.value = outputDeviceId
}

navigator.mediaDevices?.addEventListener?.('devicechange', () => { _refreshOutputDeviceSelect() })

/** A saved EQ profile by mode, 'music' or 'video'. */
function _eqProfile(mode) {
  return mode === 'video' ? eqVideoProfile : eqMusicProfile
}

/** The settings panel that edits one profile. */
function _eqPanel(mode) {
  return document.querySelector(`.eq-panel[data-eq="${mode}"]`)
}

// Which saved profile is currently wired into the live graph.
function _currentEqProfile() {
  return _eqProfile(eqActiveMode)
}

// Pushes eqEnabled + the active profile onto the actual filter nodes. Always
// ramps with setTargetAtTime rather than a bare assignment, so turning the EQ
// on/off or switching profiles never clicks. Safe to call before the graph
// exists (e.g. a settings change before anything has ever played) - it just
// does nothing until _ensureEqGraph runs.
function _applyEqToGraph() {
  if (!_audioCtx || !_eqPreamp || !_eqBandNodes) return
  const now = _audioCtx.currentTime
  // Flat when the master switch is off, or when the profile for what is
  // playing has its own switch off.
  if (!eqEnabled || !_currentEqProfile().enabled) {
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

// Preset name whose gains match a profile's bands exactly, or '' (Custom).
function _eqMatchingPreset(bands) {
  for (const name in CascadeCore.EQ_PRESETS) {
    if (CascadeCore.EQ_PRESETS[name].every((g, i) => g === bands[i])) return name
  }
  return ''
}

async function _saveEqProfile(mode) {
  await window.cascade.store.set(mode === 'video' ? 'eqVideo' : 'eqMusic', JSON.stringify(_eqProfile(mode)))
  // Only ramp the live graph if the profile just edited is the one actually
  // playing - editing Video while music plays should not be audible yet.
  if (mode === eqActiveMode) _applyEqToGraph()
}

// Builds the graph's five draggable points and their frequency labels from
// CascadeCore.EQ_BANDS, once per settings-view load (loadSettingsFields()
// re-runs every time the view is shown, so this rebuilds from scratch each
// time rather than trying to detect "already built" - five small elements is
// nothing to redo, and it sidesteps ever going stale).
function _buildEqGraphPoints(mode) {
  const SVG_NS = 'http://www.w3.org/2000/svg'
  const panel = _eqPanel(mode)
  const pointsG = panel.querySelector('.eq-graph-points')
  const labelsWrap = panel.querySelector('.eq-graph-labels')
  pointsG.innerHTML = ''
  labelsWrap.innerHTML = ''

  CascadeCore.EQ_BANDS.forEach((hz, i) => {
    const label = CascadeCore.formatEqBandLabel(hz)

    const circle = document.createElementNS(SVG_NS, 'circle')
    circle.setAttribute('class', 'eq-graph-point')
    circle.setAttribute('r', '6')
    circle.setAttribute('cx', String(CascadeCore.eqBandX(i, CascadeCore.EQ_BANDS.length, EQ_GRAPH_W)))
    circle.setAttribute('tabindex', '0')
    circle.setAttribute('role', 'slider')
    circle.setAttribute('aria-label', `${mode === 'video' ? 'Video' : 'Music'} ${label} gain`)
    circle.setAttribute('aria-valuemin', String(-CascadeCore.EQ_GAIN_LIMIT))
    circle.setAttribute('aria-valuemax', String(CascadeCore.EQ_GAIN_LIMIT))
    _wireEqPoint(circle, i, mode)
    pointsG.appendChild(circle)

    const labelEl = document.createElement('div')
    labelEl.className = 'eq-graph-label'
    labelEl.innerHTML = `<span>${esc(label)}</span><span class="eq-band-value"></span>`
    labelsWrap.appendChild(labelEl)
  })
}

// Drag and keyboard for one graph point, mirroring wireBar()'s idiom (mouse
// drag via document-level move/up, arrow keys as a real role="slider") but
// vertical and in dB rather than horizontal and in a 0..1 ratio - the two
// don't share enough shape to reuse the same function.
function _wireEqPoint(circle, i, mode) {
  const apply = async (db) => {
    _eqProfile(mode).bands[i] = db
    _refreshEqUI(mode)
    await _saveEqProfile(mode)
  }
  const dbAt = (e) => {
    const rect = circle.ownerSVGElement.getBoundingClientRect()
    return CascadeCore.eqYToDb(e.clientY - rect.top, rect.height)
  }

  let dragging = false
  function onMove(e) { if (dragging) apply(dbAt(e)) }
  function onUp() {
    if (!dragging) return
    dragging = false
    circle.classList.remove('dragging')
    document.removeEventListener('mousemove', onMove)
    document.removeEventListener('mouseup', onUp)
  }
  circle.addEventListener('mousedown', (e) => {
    dragging = true
    circle.classList.add('dragging')
    circle.focus()
    apply(dbAt(e))
    e.preventDefault()
    document.addEventListener('mousemove', onMove)
    document.addEventListener('mouseup', onUp)
  })

  circle.addEventListener('keydown', (e) => {
    const cur = _eqProfile(mode).bands[i]
    let next
    if (e.key === 'ArrowUp' || e.key === 'ArrowRight') next = cur + 0.5
    else if (e.key === 'ArrowDown' || e.key === 'ArrowLeft') next = cur - 0.5
    else if (e.key === 'PageUp') next = cur + 3
    else if (e.key === 'PageDown') next = cur - 3
    else if (e.key === 'Home') next = -CascadeCore.EQ_GAIN_LIMIT
    else if (e.key === 'End') next = CascadeCore.EQ_GAIN_LIMIT
    else return
    e.preventDefault()
    e.stopPropagation()
    // A key step never goes through eqYToDb (there is no pointer position to
    // read), so it has to clamp itself - this is the same trust boundary
    // eqYToDb enforces for a drag, just reached a different way.
    apply(CascadeCore.clampGain(next))
  })
}

// Syncs one panel's EQ controls to its profile. Called after every edit so
// the preset dropdown, the preamp's auto value, the curve and the band labels
// never drift from the numbers actually in play.
function _refreshEqUI(mode) {
  const profile = _eqProfile(mode)
  const panel = _eqPanel(mode)
  panel.querySelector('.eq-graph-curve').setAttribute('d', CascadeCore.eqCurvePath(profile.bands, EQ_GRAPH_W, EQ_GRAPH_H))
  panel.querySelectorAll('.eq-graph-point').forEach((circle, i) => {
    const db = profile.bands[i]
    circle.setAttribute('cy', String(CascadeCore.eqDbToY(db, EQ_GRAPH_H)))
    circle.setAttribute('aria-valuenow', db.toFixed(1))
    circle.setAttribute('aria-valuetext', `${db.toFixed(1)} dB`)
  })
  panel.querySelectorAll('.eq-graph-labels .eq-band-value').forEach((el, i) => {
    el.textContent = `${profile.bands[i].toFixed(1)} dB`
  })
  const auto = profile.preamp === null
  const preampSlider = panel.querySelector('.eq-preamp-slider')
  const shownPreamp = auto ? CascadeCore.autoPreamp(profile.bands) : profile.preamp
  panel.querySelector('.eq-preamp-auto').checked = auto
  preampSlider.disabled = auto
  preampSlider.value = String(shownPreamp)
  panel.querySelector('.eq-preamp-value').textContent = `${shownPreamp.toFixed(1)} dB`
  panel.querySelector('.eq-preset').value = _eqMatchingPreset(profile.bands)

  // Grayed out and out of reach whenever it would do nothing: its own switch
  // is off, or the master one is. With the master off the side's own switch
  // goes too, since it could not change anything either.
  const profileToggle = panel.querySelector('.eq-profile-toggle')
  profileToggle.checked = profile.enabled
  profileToggle.disabled = !eqEnabled
  panel.classList.toggle('off', !profile.enabled)
  panel.querySelector('.eq-panel-body').inert = !eqEnabled || !profile.enabled
  panel.closest('.eq-panels').classList.toggle('master-off', !eqEnabled)
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

    // Every playing row, not the first: views stay in the DOM when hidden, so
    // the first match can be a row in a view you left (Albums sits before
    // Playlists in index.html), which left the visible row without bars.
    const eqs = document.querySelectorAll('.track-row.playing .track-eq')
    if (!eqs.length) return
    const levels = CascadeCore.eqLevels(_eqFreqData)
    eqs.forEach(eq => {
      eq.classList.add('live')
      eq.querySelectorAll('i').forEach((bar, i) => { bar.style.transform = `scaleY(${levels[i]})` })
    })
  }
  frame()
}

function stopEqLoop() {
  if (_eqRafId) { cancelAnimationFrame(_eqRafId); _eqRafId = null }
  // A stopped loop is not a silent one. Left set, a run of zeros that began
  // before a pause (a quiet intro, say) is still counting when play resumes
  // minutes later, so the first frame back reads the whole pause as silence,
  // trips EQ_SILENCE_MS, sets _eqNoSignal and freezes the bars for the session.
  _eqSilentSinceTs = 0
  // Bars show only while they read real audio: paused, stopped, or a tap that
  // never produced anything shows no bars at all, not a placeholder loop.
  document.querySelectorAll('.track-eq.live').forEach(el => el.classList.remove('live'))
}

onDeck('play', startEqLoop)
onDeck('pause', stopEqLoop)
onDeck('ended', stopEqLoop)
onDeck('emptied', stopEqLoop)

/** Now Playing's one-time tips, at most one per open: the first unseen wins. */
function _overlayTips() {
  if (!overlayOpen || _ce.open) return
  if (playingVideo()) {
    showTipOnce('video-keys', document.getElementById('ov-fullscreen'),
      'Press ? to see every keyboard shortcut, like J and L to skip back and forward.')
    return
  }
  showTipOnce('np-customize', document.getElementById('np-theme-btn'),
    'Customize Now Playing: colors, fonts, lyrics and crossfade, shown live as you change them.')
  || showTipOnce('np-more', document.getElementById('ov-more-btn'),
    'More has the sleep timer, Instant mix, media info and more. Right-clicking the cover in the player bar opens it too.')
  || showTipOnce('automix', document.getElementById('btn-automix'),
    'Automix keeps the music going with similar songs when the queue runs out.')
}

function openOverlay() {
  overlayOpen = true
  npOverlay.classList.add('open')
  setTimeout(_overlayTips, 900)   // after the slide up, so the anchors are where they will stay
  maybeOfferNewLyricDefaults()
  syncOverlayState()
  renderQueuePanel()
  if (overlayLyricsOpen) renderOverlayLyrics()
  document.getElementById('ov-vol-fill').style.width = `${volume * 100}%`

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
      setOverlayBackgroundImage(npOverlay, buildBlobBackground(_blobColors, _isLightTheme()))
      npOverlay.classList.add('art-theme')
    }
    const item = queue[queueIndex]
    if (item) {
      const art = _currentHighResArtUrl || artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
      if (art) {
        themeFromArtUrl(art)
      }
    }
  }

  // A film supplies its own colour, so the art-derived gradient steps aside.
  if (playingVideo()) npOverlay.classList.remove('art-theme')
  else startBeatLoop()
}

function closeOverlay() {
  closeEditor({ instant: true })
  overlayOpen = false
  npOverlay.classList.remove('open')
  stopBeatLoop()
  // Fullscreen is for the film. Closing the player with it still on would
  // leave the library filling the screen.
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {})
}

// Idle fade for the overlay controls. They get out of the way of the artwork
// after a few still seconds, and any sign of life brings them straight back.
// The progress row is deliberately left up, so a glance still tells you where
// you are in the track without having to touch anything.
// Lyrics tab > Controls > Hide after, set by applyLyricStyle().
let ovIdleMs = 3000
let _ovIdleTimer = null

function pokeOverlayControls() {
  const ov = document.getElementById('np-overlay')
  ov.classList.remove('idle')
  clearTimeout(_ovIdleTimer)
  // Paused is not idle. Hiding the controls of something that is not going
  // anywhere reads as broken rather than tidy, and pause is exactly when you
  // are most likely to reach for them next.
  // The editor's sidebar is the transport row itself; it must not fold away.
  // A feature tip pointing at one of these must not watch it fold away.
  if (!overlayOpen || audio.paused || _ce.open || _tipShown) return
  _ovIdleTimer = setTimeout(() => ov.classList.add('idle'), ovIdleMs)
}

;['pointermove', 'pointerdown', 'wheel', 'keydown'].forEach(type =>
  document.getElementById('np-overlay').addEventListener(type, pokeOverlayControls, { passive: true }))
// Play only restarts the hide timer when the controls are already up (after a
// pause, say). A song starting by itself (a crossfade's handover, the next
// track) leaves hidden controls hidden, so the cover slice plays over a clean
// overlay instead of the controls popping back for it.
onDeck('play', () => { if (!document.getElementById('np-overlay').classList.contains('idle')) pokeOverlayControls() })
onDeck('pause', pokeOverlayControls)

// Any empty part of the bar opens the overlay, not just the left section: the
// right half used to be a dead zone. Controls keep their own clicks. A drag
// that starts on a slider and is let go over empty bar still reports a click
// on the bar, so where the press began decides, not where it ended.
const _statusbarControls = 'button, a, input, select, [role="slider"]'
let _statusbarPressOnControl = false
const statusbar = document.querySelector('.statusbar')
statusbar.addEventListener('pointerdown', (e) => { _statusbarPressOnControl = !!e.target.closest(_statusbarControls) })
statusbar.addEventListener('click', (e) => {
  if (_statusbarPressOnControl || e.target.closest(_statusbarControls)) return
  overlayOpen ? closeOverlay() : openOverlay()
})

// The centered chevron is the only close target. A corner x sat right next to
// the Windows and Linux caption buttons, which read as two close buttons.
document.getElementById('np-overlay-collapse').addEventListener('click', closeOverlay)
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape' || !overlayOpen) return
  // The shortcut list closes first, the player on the next press.
  if (document.getElementById('ov-keys').classList.contains('open')) { toggleKeysPanel(false); return }
  // Likewise the customization editor, unless its reset question is up.
  if (_ce.open) { if (document.getElementById('choice-modal').classList.contains('hidden')) closeEditor(); return }
  closeOverlay()
})

// Lyrics toggle - queue slides left out, lyrics slides right in (and vice versa)
// overlayLyricsOpen is what the person asked for. A song with no lyrics shows
// the queue instead (_ovLyricsMissing) and leaves the ask on, so the next song
// that has lyrics brings them back.
let _ovLyricsMissing = false
function _applyOverlayPanels() {
  // The customization editor keeps the lyrics up whatever the song has: they
  // are its live preview.
  const lyrics = (overlayLyricsOpen && !_ovLyricsMissing) || _ce.open
  document.getElementById('ov-panel-lyrics').style.transform = lyrics ? 'translateX(0)' : 'translateX(100%)'
  document.getElementById('ov-panel-queue').style.transform  = lyrics ? 'translateX(-100%)' : 'translateX(0)'
  const toggle = document.getElementById('ov-lyrics-toggle')
  toggle.classList.toggle('active', overlayLyricsOpen)
  _applyLyricsMark()
  _applyLyricsDim()
}

// What the playing song's lyrics search found, shown on both lyrics buttons as
// a slash through the bubble: null (lyrics, or still looking), 'missing' or
// 'instrumental'. Release builds have no toast for a miss, so this is the only
// sign. The buttons stay on, so the next song with lyrics still shows them.
let _lyricsMark = null
function _applyLyricsMark() {
  const next = overlayLyricsOpen ? ' They show again for the next song that has them.' : ''
  // The right-click below works on an instrumental too, for when that call was wrong.
  const canLink = _canLinkSpotify()
  const link = canLink ? ' Right-click to link a Spotify track.' : ''
  const title = _lyricsMark === 'instrumental' ? 'Instrumental, no lyrics.' + next + link
    : _lyricsMark === 'missing' ? 'No lyrics found for this song.' + next + link : 'Lyrics'
  for (const id of ['btn-lyrics-open', 'ov-lyrics-toggle']) {
    const btn = document.getElementById(id)
    btn.classList.toggle('lyrics-none', !!_lyricsMark)
    btn.title = title
  }
  if (!_lyricsMark) return
  // Two keys: someone first told only what the mark means still hears about
  // linking once Cascade Server offers it.
  if (!canLink && tipSeen('lyrics-link')) return
  const what = _lyricsMark === 'instrumental'
    ? 'This mark means this song was detected as instrumental, so it has no lyrics.'
    : 'This mark means no lyrics were found for this song.'
  showTipOnce(canLink ? 'lyrics-link' : 'lyrics-mark',
    document.getElementById(overlayOpen ? 'ov-lyrics-toggle' : 'btn-lyrics-open'),
    what + (canLink ? ' Right-click it to link a Spotify track for Spicy Lyrics.' : ''))
}
/** Marks the lyrics buttons from a lyrics search for `item`, if it is still the playing song. */
function _markLyricsFor(item, result) {
  if (!item || queue[queueIndex]?.Id !== item.Id) return
  _lyricsMark = result?.instrumental ? 'instrumental' : result?.lines?.length ? null : 'missing'
  _applyLyricsMark()
}
// Right-click either lyrics button to link the playing song to Spotify for
// Spicy Lyrics, without opening the lyrics first to reach the empty state's
// link button. Works with lyrics too, for replacing a wrong match.
for (const id of ['btn-lyrics-open', 'ov-lyrics-toggle']) {
  document.getElementById(id).addEventListener('contextmenu', e => {
    if (!_canLinkSpotify()) return
    e.preventDefault()
    openSpotifyLinkModal()
  })
}
function _setOverlayLyricsMissing(missing) {
  if (_ovLyricsMissing === missing) return
  _ovLyricsMissing = missing
  _applyOverlayPanels()
}

document.getElementById('ov-lyrics-toggle').addEventListener('click', () => {
  overlayLyricsOpen = !overlayLyricsOpen
  _applyOverlayPanels()
  if (overlayLyricsOpen) renderOverlayLyrics()
})

// ── Sleep timer ──────────────────────────────────────────────────────────────

let sleepTimerId = null      // setTimeout handle for a duration-based timer
let sleepAtTrackEnd = false  // true when "End of current track" is selected

function clearSleepTimer() {
  if (sleepTimerId) { clearTimeout(sleepTimerId); sleepTimerId = null }
  sleepAtTrackEnd = false
  document.getElementById('ctx-sleep-timer').classList.remove('active')
}

function setSleepTimerMinutes(mins) {
  clearSleepTimer()
  sleepTimerId = setTimeout(() => {
    audio.pause()
    sleepTimerId = null
    document.getElementById('ctx-sleep-timer').classList.remove('active')
    showToast('Sleep timer: playback paused')
  }, mins * 60 * 1000)
  document.getElementById('ctx-sleep-timer').classList.add('active')
  showToast(`Sleep timer set for ${mins} minutes`)
}

function setSleepTimerAtTrackEnd() {
  clearSleepTimer()
  sleepAtTrackEnd = true
  document.getElementById('ctx-sleep-timer').classList.add('active')
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

// Sleep timer moved from its own overlay button into the More menu (see
// #ctx-menu). hideCtxMenu() first, unlike this menu's other rows (CODEMAP
// notes they deliberately never close themselves) - leaving it open behind
// the dropdown this opens would look broken, not deliberate.
document.getElementById('ctx-sleep-timer').addEventListener('click', (e) => {
  e.stopPropagation()
  hideCtxMenu()
  toggleDropdownUnder(sleepTimerDropdown, document.getElementById('ov-more-btn'))
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
  ['sleep-timer-dropdown',  'ctx-sleep-timer'],
  ['subs-dropdown',         'ov-subs'],
  ['chapters-dropdown',     'ov-chapters'],
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
// Overlay progress bar - shares wireProgressBar() with the statusbar one.
wireProgressBar('ov-prog-bar')

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

  if (!_transcodeUrl) {
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
// The whole page goes fullscreen, not the <video> and not the overlay. The
// <video> would trade our controls for the browser's. The overlay was the
// choice until it turned out that element fullscreen draws only that element:
// the More menu, the subtitle, audio and chapter pickers and every dialog
// live outside it and opened invisibly. The overlay already covers the page,
// so it looks the same, and everything layered above it still shows.
function toggleVideoFullscreen() {
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {})
  else document.documentElement.requestFullscreen().catch(() => {})
}

document.getElementById('ov-fullscreen').addEventListener('click', toggleVideoFullscreen)
// Defers to the status bar's mute button rather than duplicating the state
// handling - one button owns muted/unmuted, this is a second way to press it.
document.getElementById('ov-mute').addEventListener('click', () => document.getElementById('btn-mute').click())
onDeck('dblclick', () => { if (playingVideo()) toggleVideoFullscreen() })

// Restores the exit the hidden header would otherwise have provided.
document.getElementById('ov-video-close').addEventListener('click', closeOverlay)

// ── Keyboard ──
//
// YouTube's player keys, as far as they map onto this one. VIDEO_KEYS is only
// the list the ? panel shows; the handler below is what they do.
const VIDEO_KEYS = [
  ['Space  or  K', 'Play or pause'],
  ['J  /  L', 'Back or forward 10 seconds'],
  ['←  /  →', 'Back or forward 5 seconds'],
  ['↑  /  ↓', 'Volume up or down'],
  ['M', 'Mute'],
  ['F', 'Fullscreen'],
  ['C', 'Subtitles on or off'],
  ['0 – 9', 'Jump to 0% – 90%'],
  ['Home  /  End', 'Start or end'],
  [',  /  .', 'Previous or next frame (while paused)'],
  ['<  /  >', 'Slower or faster'],
  ['Shift+P  /  Shift+N', 'Previous or next episode'],
  ['S', 'Skip the intro or credits, when offered'],
  [window.cascade.platform === 'darwin' ? '⌥←  /  ⌥→' : 'Ctrl+←  /  Ctrl+→', 'Previous or next chapter'],
  ['?', 'This list'],
  ['Esc', 'Close'],
]
const ARROW_SECONDS = 5
const PLAYBACK_RATES = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
/** The subtitle track C turns back on, so on/off returns to your pick. */
let _lastSubtitleIndex = 0

const osd = document.getElementById('ov-osd')
let _osdTimer = null
/** A second of feedback in the middle of the picture. */
function videoOsd(text) {
  osd.textContent = text
  osd.classList.add('show')
  clearTimeout(_osdTimer)
  _osdTimer = setTimeout(() => osd.classList.remove('show'), 900)
}

const keysPanel = document.getElementById('ov-keys')
function toggleKeysPanel(open = !keysPanel.classList.contains('open')) {
  if (open) markTipSeen('video-keys')
  if (open && !keysPanel.childElementCount) {
    keysPanel.innerHTML = '<div class="ov-keys-head">Keyboard shortcuts</div>'
      + VIDEO_KEYS.map(([k, what]) => `<kbd>${esc(k)}</kbd><span>${esc(what)}</span>`).join('')
  }
  keysPanel.classList.toggle('open', open)
}

function setVideoRate(rate) {
  _videoRate = rate
  audio.playbackRate = audio.defaultPlaybackRate = rate
  videoOsd(`Speed ${rate}×`)
}

function toggleSubtitles() {
  const tracks = [...audio.querySelectorAll('track')]
  if (!tracks.length) { videoOsd('No subtitles'); return }
  const showing = tracks.findIndex(t => t.track.mode === 'showing')
  if (showing >= 0) {
    _lastSubtitleIndex = showing
    selectSubtitleTrack(null)
    videoOsd('Subtitles off')
  } else {
    const i = Math.min(_lastSubtitleIndex, tracks.length - 1)
    selectSubtitleTrack(i)
    videoOsd(tracks[i].label || 'Subtitles on')
  }
}

function jumpChapter(dir) {
  const target = CascadeCore.chapterTarget(_chapters, mediaPosition(), dir)
  if (target == null) return
  seekTo(target)
  videoOsd(_chapters[CascadeCore.chapterAt(_chapters, target)].name)
}

/** One frame, at the film's own rate when the server told us it. */
function stepFrame(dir) {
  if (!audio.paused) return
  const v = (queue[queueIndex]?.MediaStreams || []).find(s => s.Type === 'Video')
  const fps = v?.RealFrameRate || v?.AverageFrameRate || 24
  seekTo(mediaPosition() + dir / fps)
}

// Escape is handled by the browser, which exits fullscreen without telling the
// overlay - so closing on Escape has to wait until it is no longer fullscreen,
// otherwise one press would both exit fullscreen and close the overlay.
document.addEventListener('keydown', (e) => {
  if (!overlayOpen || !playingVideo()) return
  const t = /** @type {HTMLElement} */ (e.target)
  if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return
  const arrow = e.key === 'ArrowLeft' ? -1 : e.key === 'ArrowRight' ? 1 : 0

  // Chapters are YouTube's Ctrl+arrows, plus Option+arrows because macOS
  // keeps Ctrl+arrows for switching desktops and never delivers them.
  if (arrow && (e.ctrlKey || e.altKey) && !e.metaKey) { e.preventDefault(); jumpChapter(arrow); return }
  // Anything else with Cmd/Ctrl/Option belongs to the app or the OS (Cmd+K
  // search, Cmd+F), not to the player.
  if (e.metaKey || e.ctrlKey || e.altKey) return

  const dur = mediaDuration()
  const key = e.key.length === 1 && !e.shiftKey ? e.key.toLowerCase() : e.key
  let handled = true
  if (key === ' ' || key === 'k') document.getElementById('btn-play').click()
  else if (key === 'j') skipBy(-SKIP_SECONDS)
  else if (key === 'l') skipBy(SKIP_SECONDS)
  else if (arrow) skipBy(arrow * ARROW_SECONDS)
  else if (key === 'ArrowUp' || key === 'ArrowDown') {
    nudgeVolume(key === 'ArrowUp' ? 0.05 : -0.05)
    videoOsd(`Volume ${Math.round(volume * 100)}%`)
  }
  else if (key === 'm') { document.getElementById('btn-mute').click(); videoOsd(_muted ? 'Muted' : 'Unmuted') }
  else if (key === 'f') toggleVideoFullscreen()
  else if (key === 'c') toggleSubtitles()
  else if (key === 's') { if (_activeSegment) skipActiveSegment(); else handled = false }
  else if (/^[0-9]$/.test(key) && dur) seekTo(dur * Number(key) / 10)
  else if (key === 'Home') seekTo(0)
  else if (key === 'End' && dur) seekTo(dur)
  else if (key === ',' || key === '.') stepFrame(key === '.' ? 1 : -1)
  else if (key === '<' || key === '>') {
    const i = PLAYBACK_RATES.indexOf(_videoRate)
    const next = PLAYBACK_RATES[Math.max(0, Math.min(PLAYBACK_RATES.length - 1, (i < 0 ? 3 : i) + (key === '>' ? 1 : -1)))]
    setVideoRate(next)
  }
  else if (key === 'N' && queueIndex < queue.length - 1) document.getElementById('btn-next').click()
  else if (key === 'P' && queue.length > 1) document.getElementById('btn-prev').click()
  else if (key === '?') toggleKeysPanel()
  else handled = false
  if (handled) e.preventDefault()
})

/** Change volume by `delta`. Thin wrapper for the video overlay's own arrow-key
 *  handler above - setVolumeRatio() does the actual work of keeping both
 *  sliders and the stored setting in step. */
function nudgeVolume(delta) {
  setVolumeRatio(volume + delta)
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

// ── Chapter picker ──

const chaptersDropdown = document.getElementById('chapters-dropdown')

document.getElementById('ov-chapters').addEventListener('click', (e) => {
  e.stopPropagation()
  const current = CascadeCore.chapterAt(_chapters, mediaPosition())
  chaptersDropdown.innerHTML = ['<div class="ov-dd-head">Chapters</div>',
    ..._chapters.map((c, i) =>
      `<button class="ov-dd-item${i === current ? ' checked' : ''}" data-chapter="${i}">${esc(c.name)}<span class="ov-dd-time">${fmtTime(c.sec)}</span></button>`),
  ].join('')
  chaptersDropdown.querySelectorAll('[data-chapter]').forEach(btn => {
    btn.addEventListener('click', () => {
      chaptersDropdown.classList.remove('open')
      seekTo(_chapters[Number(/** @type {HTMLElement} */ (btn).dataset.chapter)].sec)
    })
  })
  toggleDropdownUnder(chaptersDropdown, e.currentTarget)
  // Long films have dozens: land on the one playing, not the top of the list.
  chaptersDropdown.querySelector('.checked')?.scrollIntoView({ block: 'nearest' })
})

// ── Audio track picker ──

const audioTrackDropdown = document.getElementById('audio-track-dropdown')

document.getElementById('ov-audio-track').addEventListener('click', (e) => {
  e.stopPropagation()
  const item = queue[queueIndex]
  // A download holds the one track it was saved with (a remux keeps only
  // that one), and there is no server to ask for another.
  const streams = _offline.ready[item?.Id] ? [] : (item?.MediaStreams || []).filter(s => s.Type === 'Audio')

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
      _audioStreamIndexIsExplicit = true
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
  _setArtStill(document.getElementById('ov-art'), art)

  // Info - wrapped so the marquee has an inline-block track to translate
  document.getElementById('ov-track').innerHTML  = `<span class="np-scroll-inner">${esc(item.Name || '')}${explicitBadgeHtml(item.Id)}</span>`
  document.getElementById('ov-artist').innerHTML = `<span class="np-scroll-inner">${esc(item.AlbumArtist || item.Artists?.[0] || '')}</span>`
  refreshMarquees()

  // Shuffle / repeat state
  document.getElementById('ov-shuffle').classList.toggle('active', shuffle)
  updateRepeatButtons()
}

// Auto-mix: when the queue runs dry, keep playing with an instant mix off the last track
let autoMixEnabled = false
document.getElementById('btn-automix').addEventListener('click', () => {
  markTipSeen('automix')
  autoMixEnabled = !autoMixEnabled
  document.getElementById('btn-automix').classList.toggle('active', autoMixEnabled)
  _renderQueueMeta()   // auto-mix means the queue never ends
  showToast(autoMixEnabled ? 'Auto-mix on - similar tracks will keep playing after the queue ends' : 'Auto-mix off')
})

function renderQueuePanel() {
  _refreshLyricsPreviews()   // the next song may be a different one now
  _ceQueueMoved()             // and the editor's preview previews it
  const container = document.getElementById('ov-queue-rows')
  const panel     = document.getElementById('ov-panel-queue')
  const follower  = isWaterfallFollower()

  // Bind once - shifts the Up Next render window as the user scrolls, and
  // when the panel resizes (a taller window shows more rows than were drawn,
  // and the gap below them is just the spacer: blank).
  if (!_queueScrollBound) {
    _queueScrollBound = true
    const rewindow = () => {
      const base = queueIndex + 1
      if (base >= queue.length) return
      const win = _queueWin(panel)
      // Up Next's rows start at container.offsetTop inside the panel.
      const visStart = base + Math.max(0, Math.floor((panel.scrollTop - container.offsetTop) / QUEUE_ROW_H))
      const visEnd   = visStart + Math.ceil(panel.clientHeight / QUEUE_ROW_H)
      const nearTop  = visStart < _queueWinStart + 3
      const nearBot  = visEnd   > _queueWinStart + win - 3
      if (nearTop || nearBot) {
        // Only redraw on a real window change, or a redraw's own scroll
        // re-triggers this and fights it.
        const next = Math.max(base, Math.min(visStart - 3, queue.length - win))
        if (next !== _queueWinStart) { _queueWinStart = next; _drawQueueRows(container) }
      }
    }
    panel.addEventListener('scroll', rewindow, { passive: true })
    new ResizeObserver(rewindow).observe(panel)
  }

  // Now Playing, pinned.
  const cur = queue[queueIndex]
  const nowRow = document.getElementById('q-now-row')
  nowRow.innerHTML = cur ? _queueRowHtml(cur, queueIndex, { current: true }) : '<div class="q-empty">Nothing playing</div>'
  nowRow.querySelectorAll('.queue-row').forEach(el => _wireQueueRow(el, follower))

  // History: the count always, the rows only while it is open.
  document.getElementById('q-history-count').textContent = queueIndex > 0 ? queueIndex : ''
  document.getElementById('q-history-head').hidden = queueIndex <= 0
  // Positions in a Waterfall room are shared (and wfAddedBy is indexed by
  // them), so the history is not this client's to clear there.
  document.getElementById('q-history-clear').hidden =
    typeof wfActive === 'function' && wfActive()
  _renderQueueHistory()

  // Up Next: where the queue came from, its position, and when it ends.
  document.getElementById('q-next-source').textContent = queueSource ? `From ${queueSource}` : ''
  document.getElementById('q-next-clear').hidden = follower || queueIndex + 1 >= queue.length
  _renderQueueMeta()

  // The window starts at the first upcoming track. The panel opens at the
  // top (the History toggle, then Now Playing); with History open, it opens
  // just past it, on Now Playing. Measured from the element before the sticky
  // row, since a sticky element's own offsetTop moves as it sticks.
  _queueWinStart = queueIndex + 1
  _drawQueueRows(container)
  const hist = document.getElementById('q-history-rows')
  panel.scrollTop = hist.hidden ? 0 : hist.offsetTop + hist.offsetHeight
}

/** One queue row. `current` is the pinned Now Playing row; `editable` rows
 *  (Up Next, for a client that owns the queue) get drag and remove. */
function _queueRowHtml(item, i, { current = false, editable = false } = {}) {
  const art   = item.__wfUnavailable ? null
    : artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
  const thumb = art ? `<img src="${art}" alt="" loading="lazy" onerror="this.style.display='none'">` : '♪'
  const dur   = fmtTime((item.RunTimeTicks || 0) / 10000000)
  const by    = queueAddedBy(i)
  const sub   = item.__wfUnavailable ? '' : esc(item.AlbumArtist || item.Artists?.[0] || '')
  return `<div class="queue-row${current ? ' current' : ''}${item.__wfUnavailable ? ' unavailable' : ''}" data-qi="${i}"${editable ? ' draggable="true"' : ''}>
      ${editable ? `<div class="queue-row-drag" title="Drag to reorder">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="8" y1="6" x2="16" y2="6"/><line x1="8" y1="12" x2="16" y2="12"/><line x1="8" y1="18" x2="16" y2="18"/></svg>
      </div>` : ''}
      <div class="queue-row-art">${thumb}</div>
      <div style="min-width:0;flex:1">
        <div class="queue-row-title">${esc(item.Name)}</div>
        <div class="queue-row-artist">${sub}${by ? `<span class="queue-row-by">added by ${esc(by)}</span>` : ''}</div>
      </div>
      <div class="queue-row-dur">${dur}</div>
      ${editable ? `<button class="queue-row-remove" data-qi="${i}" title="Remove from queue">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
      </button>` : ''}
    </div>`
}

/** Click to jump to a row, right-click for the track menu: every section. */
function _wireQueueRow(el, follower) {
  const qi = parseInt(el.dataset.qi)
  el.addEventListener('click', (e) => {
    if (e.target.closest('.queue-row-drag, .queue-row-remove')) return
    // A follower jumping tracks would move queueIndex out of alignment with
    // the host until the next broadcast dragged it back.
    if (follower) { if (typeof wfNotifyHostControls === 'function') wfNotifyHostControls(); return }
    if (qi === queueIndex) return
    skipTo(qi, qi === queueIndex + 1 ? 'next' : qi > queueIndex ? 'jump' : 'prev')
    renderQueuePanel()
  })
  // Right click - reuse the same universal track menu as every other row of
  // tracks in the app rather than a fourth hand-rolled menu.
  el.addEventListener('contextmenu', (e) => {
    e.preventDefault()
    showTrackCtxMenu(queue[qi], el, e.clientX, e.clientY, false)
  })
}

let _queueHistoryOpen = false

/** History rows, drawn only while the section is open: a long session's
 *  history is hundreds of rows nobody is looking at. */
function _renderQueueHistory() {
  const rows = document.getElementById('q-history-rows')
  document.getElementById('q-history-toggle').setAttribute('aria-expanded', String(_queueHistoryOpen))
  rows.hidden = !_queueHistoryOpen || queueIndex <= 0
  if (rows.hidden) { rows.innerHTML = ''; return }
  // ponytail: not virtualised like Up Next; fine for hundreds of rows, window
  // it the same way if a history of thousands ever shows up.
  const follower = isWaterfallFollower()
  rows.innerHTML = queue.slice(0, queueIndex).map((item, i) => _queueRowHtml(item, i)).join('')
  rows.querySelectorAll('.queue-row').forEach(el => _wireQueueRow(el, follower))
}

document.getElementById('q-next-clear').addEventListener('click', () => clearQueueTracks('upnext'))

document.getElementById('q-history-toggle').addEventListener('click', () => {
  _queueHistoryOpen = !_queueHistoryOpen
  _renderQueueHistory()
})

document.getElementById('q-history-clear').addEventListener('click', () => {
  if (queueIndex <= 0 || isWaterfallFollower()) return
  // finishCrossfade() lands on an index captured before the fade started;
  // shifting every index under it would land it on the wrong track.
  if (_cfActive) { showToast('Clear the history once the crossfade finishes'); return }
  const cleared = new Set(queue.splice(0, queueIndex))
  queueIndex = 0
  // Or turning shuffle off would bring the cleared tracks back.
  if (_unshuffledQueue.length) _unshuffledQueue = _unshuffledQueue.filter(t => !cleared.has(t))
  _queueHistoryOpen = false
  _reprefetch()
  renderQueuePanel()
})

/** "12 of 40 · 1h 5m · ends 10:12 PM". The end time moves while paused, so a
 *  timer below refreshes it; with repeat or auto-mix on there is no end. */
function _renderQueueMeta() {
  const meta = document.getElementById('q-next-meta')
  if (queueIndex < 0 || !queue.length) { meta.textContent = ''; return }
  const parts = [`${queueIndex + 1} of ${queue.length}`]
  if (repeatMode === 'none' && !autoMixEnabled) {
    const left = CascadeCore.queueRemainingSec(queue, queueIndex, mediaPosition())
    const end = new Date(Date.now() + left * 1000).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })
    parts.push(`${CascadeCore.formatQueueSpan(left)} · ends ${end}`)
  }
  meta.textContent = parts.join(' · ')
}
setInterval(() => { if (overlayOpen) _renderQueueMeta() }, 30_000)

/** Rows kept drawn in Up Next: a full panel's worth plus slack either side,
 *  never fewer than QUEUE_WIN. A fixed 20 left a maximized window (~23 rows
 *  tall) blank below the last drawn row. */
function _queueWin(panel) {
  return Math.max(QUEUE_WIN, Math.ceil(panel.clientHeight / QUEUE_ROW_H) + QUEUE_BEFORE + 6)
}

/** Up Next, virtualised: rows from _queueWinStart, spacers for the rest. */
function _drawQueueRows(container) {
  const base   = queueIndex + 1
  if (base >= queue.length) {
    container.innerHTML = `<div class="q-empty">${queue.length ? 'Nothing up next' : 'Queue is empty'}</div>`
    return
  }
  const winEnd = Math.min(queue.length, _queueWinStart + _queueWin(document.getElementById('ov-panel-queue')))
  const topH   = (_queueWinStart - base) * QUEUE_ROW_H
  const botH   = (queue.length - winEnd) * QUEUE_ROW_H

  // A guest mirrors the host's queue. Reordering or removing locally would
  // desync it immediately, so those controls are not rendered at all.
  const follower = isWaterfallFollower()
  const rows = queue.slice(_queueWinStart, winEnd)
    .map((item, idx) => _queueRowHtml(item, _queueWinStart + idx, { editable: !follower })).join('')

  // Spacer divs preserve the panel's total scroll height
  container.innerHTML =
    `<div style="height:${topH}px;flex-shrink:0"></div>` +
    rows +
    `<div style="height:${botH}px;flex-shrink:0"></div>`

  container.querySelectorAll('.queue-row').forEach(el => _wireQueueRow(el, follower))

  let dragSrc = null

  container.querySelectorAll('.queue-row').forEach(el => {
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
}

async function renderOverlayLyrics() {
  const body = document.getElementById('ov-lyrics-body')
  const item = queue[queueIndex]
  if (!item) { _ovDropGhost(); body.innerHTML = '<div class="lyrics-empty" style="padding:40px 0;text-align:center">Nothing playing</div>'; return }
  _ovKeepGhost()

  if (!lyricsData.length) {
    // Under a crossfade the last song's lines stay up (the ghost) instead of a skeleton.
    body.innerHTML = _ovGhost ? '' : skeletonHTML('lyrics', 1)
    const gen    = ++_lyricsFetchGen
    const result = await fetchLyricsWaterfall(item)
    if (gen !== _lyricsFetchGen) return
    _markLyricsFor(item, result)
    if (result?.instrumental) {
      _ovDropGhost()
      body.innerHTML = '<div class="lyrics-empty" style="padding:40px 0;text-align:center">This track is instrumental</div>'
      _setOverlayLyricsMissing(true)
      return
    }
    _showLyricsFetchToast(result)
    if (!result) {
      lyricsSource = null
      lyricsCredit = null
      updateSourcePills()
      _ovDropGhost()
      body.innerHTML = `<div class="lyrics-empty" style="padding:40px 0;text-align:center">No lyrics available${_linkSpotifyButton()}</div>`
      _setOverlayLyricsMissing(true)
      return
    }
    lyricsData   = result.lines
    lyricsSource = result.source
    lyricsCredit = result.credit || null
    updateSourcePills()
    _stopWordLoop()
    if (!audio.paused) _startWordLoop()
  }

  if (!lyricsData.length) {
    _ovDropGhost()
    body.innerHTML = `<div class="lyrics-empty" style="padding:40px 0;text-align:center">No lyrics available${_linkSpotifyButton()}</div>`
    _setOverlayLyricsMissing(true)
    return
  }

  _setOverlayLyricsMissing(false)
  renderOverlayLyricLines()
  _resetOverlayManualScroll()
  // A plain sheet sits from the top, with room above the first line. Set
  // before the roll below too: it springs to ovLyricsBaseY, which still held
  // the last synced song's scroll and carried a plain sheet off screen until
  // the pane was reopened.
  if (_lyricsPlain()) ovLyricsBaseY = 40 - (body.querySelector('.ov-lyric-line[data-idx="0"]')?.offsetTop || 0)
  const nowSecRoll = audio.currentTime + _lyricLead
  if (_ovGhost) {
    let idx = 0
    for (let i = 0; i < lyricsData.length; i++) if (lyricsData[i].Start != null && lyricsData[i].Start / 10000000 <= nowSecRoll) idx = i
    _ovRollIn(idx)
    detectOverlayLyricsLanguage()
    ensureLyricsTranslation()
    return
  }

  if (_lyricsPlain()) {
    ovLyricsSpring.jumpTo(ovLyricsBaseY)
    detectOverlayLyricsLanguage()
    ensureLyricsTranslation()
    return
  }

  // Jump to a neutral position instantly, then let the spring glide in to the
  // actual current line - no CSS-transition reflow trick needed since jumpTo()
  // bypasses the animation loop entirely.
  ovLyricsSpring.jumpTo(0)
  const nowSec0 = audio.currentTime + _lyricLead
  let initialIdx = 0
  for (let i = 0; i < lyricsData.length; i++) {
    if (lyricsData[i].Start != null && lyricsData[i].Start / 10000000 <= nowSec0) initialIdx = i
  }
  updateOverlayLyricsActive(initialIdx)

  // Detect language and show translate button if non-English
  detectOverlayLyricsLanguage()
  ensureLyricsTranslation()
}


function renderOverlayLyricLines() {
  const body = document.getElementById('ov-lyrics-body')
  body.classList.toggle('plain', _lyricsPlain())
  body.innerHTML = lyricsData.map((line, i) => {
    const hasTimestamp = line.Start != null
    // The original always stays, karaoke fill included; a translation sits
    // under it inside the same element, so the line's height (which the scroll
    // spring centres on) and its click-to-seek both cover the pair.
    const content = line.Words ? lyricWordSpans(line, 'ov-lyric-word', !!lyricsCredit) : esc(line.Text || '')
    const trans = lyricTranslationFor(i)
    return `<div class="ov-lyric-line${hasTimestamp ? ' seekable' : ''}${line.Opposite ? ' opposite' : ''}" data-idx="${i}"${hasTimestamp ? ` data-start="${line.Start}"` : ''}>${content}${trans ? `<div class="ov-lyric-trans">${esc(trans)}</div>` : ''}</div>`
  }).join('')
  _refreshLyricsPreviews(true)
  _layoutAllGlosses()
  body.querySelectorAll('.ov-lyric-line.seekable').forEach(el => {
    el.addEventListener('click', () => {
      const ticks = parseInt(el.dataset.start)
      if (!isNaN(ticks) && audio.duration) audio.currentTime = Math.max(0, ticks / 10000000 - _lyricLead)
      // Clicking a line is the same intent as the settle timer firing: you are
      // done browsing and back on the current lyric. Drop the manual offset now
      // instead of leaving the view parked until the timer catches up.
      _resetOverlayManualScroll()
    })
  })
}

// ── On-device lyrics translation ──────────────────────────────────────────────
//
// Was MyMemory's free API. Every lyric line the user played left the machine,
// and the language *detection* calls did it automatically with no click and no
// setting, which made playback history readable by a third party. Both halves
// now run locally: franc for detection, and Mozilla's Firefox Translations
// models (Marian, run by the bergamot WASM runtime vendored into
// build/bergamot/ by scripts/build-bergamot.js) for translation.
//
// Each model translates one language into English and is downloaded on first
// use by main.js - see translation-models.json. There is one BatchTranslator per
// model, created lazily: translator.js keys models by from+to, so Simplified and
// Traditional Chinese can only coexist as separate translators, each reading a
// registry that holds just its own model.
//
// Translators are retired once nothing has asked for a translation in
// TRANSLATE_IDLE_MS. A loaded model lives in its translator's worker, so this is
// what hands that memory back after a song or two instead of holding it all
// session. The next translation after an idle spell reloads the model from disk.

const TRANSLATE_IDLE_MS = 5 * 60_000
const _translators = new Map()   // model key -> Bergamot.BatchTranslator
let _translateBusy = 0
let _translateIdleTimer = null

// Translated lines, remembered so going back to a song, or a chorus shared
// across a sheet, costs nothing the second time. Keyed by engine, model and
// exact line text ("apple|ja|..." - neither ever contains "|"), least recently
// used dropped first.
//
// Kept on disk between sessions (main.js, translation-cache.json): a cold
// translation of a whole sheet took a quarter of the song (YOASOBI's Idol),
// and without this every restart paid it again. Each line expires 25 days
// after it was translated, reading it does not extend that; the same limit
// the Cascade Server plugin keeps SpicyLyrics lyrics under, since a
// translation is derived from them. See src/core/translation-cache.ts.
const TRANSLATION_CACHE_LINES = CascadeCore.TRANSLATION_CACHE_MAX
const _translatedLines = new Map()   // cacheKey -> { text, at }
let _translationCacheLoaded = false
let _translationSaveTimer = null

function _rememberedLine(cacheKey) {
  const hit = _translatedLines.get(cacheKey)
  if (!hit) return undefined
  _translatedLines.delete(cacheKey)
  if (CascadeCore.translationExpired(hit.at, Date.now())) return undefined
  _translatedLines.set(cacheKey, hit)   // most recently used goes last
  return hit.text
}
function _rememberLine(cacheKey, text) {
  _translatedLines.set(cacheKey, { text, at: Date.now() })
  if (_translatedLines.size > TRANSLATION_CACHE_LINES) _translatedLines.delete(_translatedLines.keys().next().value)
  _saveTranslationCacheSoon()
}

// ponytail: debounced, so quitting within 3s of a translation loses those
// lines; they are re-translated next time. Flush on quit if that ever matters.
function _saveTranslationCacheSoon() {
  if (!_translationCacheLoaded) return   // the load below merges and saves
  clearTimeout(_translationSaveTimer)
  _translationSaveTimer = setTimeout(() => {
    const now = Date.now()
    const entries = []
    for (const [k, v] of _translatedLines) if (!CascadeCore.translationExpired(v.at, now)) entries.push([k, v.text, v.at])
    window.cascade.translationCache.save(entries).catch(e => console.warn('[Translate] cache not saved:', e))
  }, 3000)
}

window.cascade.translationCache.load().then(raw => {
  const loaded = CascadeCore.liveTranslationEntries(raw, Date.now(), TRANSLATION_CACHE_LINES)
  // Anything translated while the file was loading is newer: it goes last.
  const fresh = [..._translatedLines]
  _translatedLines.clear()
  for (const [k, text, at] of loaded) _translatedLines.set(k, { text, at })
  for (const [k, v] of fresh) { _translatedLines.delete(k); _translatedLines.set(k, v) }
  while (_translatedLines.size > TRANSLATION_CACHE_LINES) _translatedLines.delete(_translatedLines.keys().next().value)
  _translationCacheLoaded = true
  // Rewrite the file when this session added lines, or when loading dropped
  // expired ones: they must leave the disk too, not just memory.
  if (fresh.length || (Array.isArray(raw) && raw.length !== loaded.length)) _saveTranslationCacheSoon()
}).catch(e => {
  console.warn('[Translate] cache not loaded:', e)
  _translationCacheLoaded = true
})

function _retireTranslators() {
  _translateIdleTimer = null
  if (_translateBusy) return   // never pull a worker out from under a translation
  for (const t of _translators.values()) t.delete()
  _translators.clear()
}

function _translatorFor(key) {
  let t = _translators.get(key)
  if (!t) {
    t = new Bergamot.BatchTranslator({
      registryUrl: `cascade-model://app/models/registry.json?key=${encodeURIComponent(key)}`,
      workers: 1,
    })
    _translators.set(key, t)
  }
  return t
}

/** Forget a model's translator: after a failure, or once the model is removed. */
function dropTranslator(key) {
  _translators.get(key)?.delete()
  _translators.delete(key)
}

/** Translates `lines` into English with model `key`, positionally: the result is
 *  the same length as the input and blank lines stay blank. Repeated lines are
 *  translated once, since a lyric sheet is mostly chorus. One line per call:
 *  lines are lyrics, not sentences, and batching them would let one line's
 *  context bleed into the next.
 *  `engine` is 'mozilla' (the bergamot translators here) or 'apple' (the macOS
 *  helper in main.js).
 *
 *  Order follows the song: lines already cached come back at once, then the
 *  line `startAt()` names (the one being sung), then onwards through the sheet,
 *  re-asking `startAt` after every line so a seek re-aims it; lines before the
 *  playhead come last. `onLine(indexes, english)` fires as each one lands, so
 *  a cold sheet (105s for Idol with Apple) shows the current line in about a
 *  second instead of all of it at the end. */
async function translateLines(lines, key, onProgress, engine = 'mozilla', { startAt, onLine } = {}) {
  clearTimeout(_translateIdleTimer)
  _translateIdleTimer = null
  _translateBusy++
  try {
    const out = new Array(lines.length).fill('')
    const pending = new Map()   // line text -> the indexes it appears at
    lines.forEach((line, i) => {
      const text = line.trim()
      if (!text) return
      if (!pending.has(text)) pending.set(text, [])
      pending.get(text).push(i)
    })
    const total = pending.size
    const from = key.slice(0, 2)
    // The engine is part of the key: both translate the same languages, and
    // switching engines must not serve the other one's output from memory.
    const cacheKey = text => `${engine}|${key}|${text}`
    let done = 0
    const land = (text, english) => {
      const indexes = pending.get(text)
      pending.delete(text)
      for (const i of indexes) out[i] = english
      onLine?.(indexes, english)
      onProgress?.({ done: ++done, total })
    }
    for (const text of [...pending.keys()]) {
      const hit = _rememberedLine(cacheKey(text))
      if (hit !== undefined) land(text, hit)
    }
    while (pending.size) {
      // The first line still waiting at or after the playhead, else the first
      // before it.
      const cur = Math.max(0, Math.min(lines.length - 1, startAt?.() ?? 0))
      let text = null
      for (let n = 0; n < lines.length && text == null; n++) {
        const t = lines[(cur + n) % lines.length].trim()
        if (pending.has(t)) text = t
      }
      const english = engine === 'apple'
        ? await window.cascade.appleTranslation.translate(key, text)
        : (await _translatorFor(key).translate({ from, to: 'en', text, html: false })).target.text
      _rememberLine(cacheKey(text), english)
      land(text, english)
    }
    return out
  } catch (e) {
    // A translator whose worker died or whose model would not load must not be
    // reused; the next attempt builds a fresh one. (Apple's helper restarts
    // itself in main.js.)
    if (engine === 'mozilla') dropTranslator(key)
    throw e
  } finally {
    if (!--_translateBusy) _translateIdleTimer = setTimeout(_retireTranslators, TRANSLATE_IDLE_MS)
  }
}

function lyricsPlainLines() {
  return lyricsData.map(l => l.Text || '')
}

// Only a sheet something on this Mac can translate gets a Translate button:
// one Cascade has a model for, or one Apple Translation takes. Offering one
// for anything else would be a button that can only fail.
function detectOverlayLyricsLanguage() {
  syncTranslateButtons()
  const btn = document.getElementById('ov-translate-btn')
  btn.style.display =
    lyricsTranslationEnabled && _canTranslate(CascadeCore.translationLanguageFor(lyricsPlainLines())) ? 'flex' : 'none'
  if (btn.style.display === 'flex') showTipOnce('translate', btn,
    'Translate adds an English translation under each line. The first time, a translation model for this language may need to download.')
}

document.getElementById('ov-translate-btn').addEventListener('click', () => onTranslateButton())

// Lightweight critically-damped-ish spring for scroll position. Unlike a CSS
// transition, it carries velocity across target changes - when a new line
// comes in before the previous move has settled (common in fast verses), it
// keeps moving from its current speed toward the new target instead of
// restarting from a standstill, which is what makes back-to-back line changes
// read as one continuous glide instead of a stutter-restart.
//
// The stepping is CascadeCore.stepSpring (src/core/spring.ts), in fixed small
// substeps. One explicit step per frame diverged below about 25 fps, which a
// fullscreen game starving Cascade's frames reliably caused: the lyrics flung
// or shook on every new line whenever Cascade was not in front.
// Lyric motion, shared by both lyric springs and tunable live from the debug
// tuning panel or DevTools (cascadeDebug.lyricMotion). The spring is
// tuning-defaults.json's motion section (why it is overdamped is noted
// there); the ripple is the Lyrics tab's rippleSeconds, set by applyLyricStyle().
const LYRIC_MOTION = {
  stiffness: CascadeCore.shippedNumber('motion', 'lyricSpringStiffness'),
  damping: CascadeCore.shippedNumber('motion', 'lyricSpringDamping'),
  ripple: 40,
}
// How far ahead of the audio lyrics are drawn, in seconds: the Lyrics
// setting "Lyrics timing" negated (it is negative for earlier, as in the
// Apple app). Set by applyLyricStyle().
let _lyricLead = 0.35

function createSpring(onUpdate, motion = LYRIC_MOTION) {
  let pos = 0, vel = 0, target = 0
  // A target can be a function, re-read every frame while the spring runs.
  // The lyric views pass one: a line's background-vocal row opens and closes
  // over 0.4s, which moves every line under a target measured once, so the
  // "centred" line drifted off centre with no easing at all.
  let targetFn = null
  let raf = null
  let lastTs = null

  function frame(ts) {
    if (lastTs == null) lastTs = ts
    // A gap long enough to mean nothing was drawn snaps instead of animating
    // a stale move (see SPRING_SNAP_GAP_S), so no clamp is needed here.
    const dt = (ts - lastTs) / 1000
    lastTs = ts
    if (targetFn) target = targetFn()

    const next = CascadeCore.stepSpring({ pos, vel }, target, dt, motion)
    pos = next.pos
    vel = next.vel
    const settled = next.settled
    onUpdate(pos)

    if (!settled) raf = requestAnimationFrame(frame)
    else { raf = null; lastTs = null }
  }

  function ensureRunning() {
    if (raf == null) { lastTs = null; raf = requestAnimationFrame(frame) }
  }

  return {
    setTarget(t) {
      targetFn = typeof t === 'function' ? t : null
      target = targetFn ? targetFn() : t
      ensureRunning()
    },
    jumpTo(t) {
      targetFn = null
      target = t; pos = t; vel = 0
      if (raf) { cancelAnimationFrame(raf); raf = null; lastTs = null }
      onUpdate(pos)
    },
    setPos(p) {   // direct 1:1 tracking (manual drag) - no physics involved
      targetFn = null
      pos = p; vel = 0; target = p
      if (raf) { cancelAnimationFrame(raf); raf = null; lastTs = null }
      onUpdate(pos)
    },
  }
}

const ovLyricsSpring = createSpring(pos => {
  const el = document.getElementById('ov-lyrics-body')
  if (el) el.style.transform = `translateY(${pos}px)`
  // The last song's lines ride the same glide up and out (see _ovRollIn).
  if (_ovGhost?.startPos != null) _ovGhost.el.style.transform = `translateY(${_ovGhost.baseY + pos - _ovGhost.startPos}px)`
})

// ── The next song's lyrics under the last line ──────────────────────────────
// Once the next song's lyrics are cached (_prefetchUpcoming), its lines sit
// under this song's last line, dimmed, after a divider two lines tall, so the
// end of a sheet is not a cliff. When playback moves on by itself (a
// crossfade or a song ending), the new sheet's roll starts exactly where
// those preview lines are (_previewAlignedStart), so the scroll just carries on.

/** The song playback moves to by itself, and its cached lyrics; null when there are none to show. */
function _nextSongLyrics() {
  if (repeatMode === 'one') return null
  const next = queue[queueIndex + 1] ?? (repeatMode === 'all' && queue.length > 1 ? queue[0] : null)
  if (!next?.Id || isVideoItem(next)) return null
  const cached = _lyricsCache.get(next.Id)
  return cached?.lines?.length && !cached.instrumental ? { id: next.Id, lines: cached.lines, credit: !!cached.credit } : null
}

/** Adds, swaps or removes the preview in both lyric views; `force` after a view was redrawn. */
function _refreshLyricsPreviews(force = false) {
  const next = _nextSongLyrics()
  const key = next ? next.id : ''
  for (const [id, lineCls, wordCls] of [['ov-lyrics-body', 'ov-lyric-line', 'ov-lyric-word'], ['lyrics-inner', 'lyrics-line', 'lyric-word']]) {
    const body = document.getElementById(id)
    if (!body?.querySelector('[data-idx]')) continue
    if (!force && body.dataset.nextPreview === key) continue
    body.querySelectorAll('.lyric-preview, .lyrics-next-divider').forEach(el => el.remove())
    body.dataset.nextPreview = key
    if (!next) continue
    body.insertAdjacentHTML('beforeend', '<div class="lyrics-next-divider" aria-hidden="true"></div>' + next.lines.map(line =>
      `<div class="${lineCls} lyric-preview${line.Opposite ? ' opposite' : ''}" aria-hidden="true">${line.Words ? lyricWordSpans(line, wordCls, next.credit) : esc(line.Text || '')}</div>`).join(''))
  }
}

/** Playback is moving on by itself: the next sheet rolls in under this one's. */
function _rollLyricsToNext() {
  _lyricsRollUntil = Math.max(_lyricsRollUntil, performance.now() + 3000)
}

/**
 * Where a rolling-in sheet's scroll starts so its first line lands on the
 * ghost's preview of it; null without a preview (the old glide from below).
 * Measured on screen, so nothing depends on how the two are positioned.
 *
 * A skip early in a song leaves the preview far below, and scrolling through
 * every line between in a moment is a blur. So the distance stops at
 * `maxDistance`: the old song's lines scroll up that far and the next song's
 * come up right behind them, the old lines past that point left out.
 */
function _previewAlignedStart(ghostEl, firstLine, spring, target, maxDistance = Infinity) {
  const preview = ghostEl?.querySelector('.lyric-preview')
  // Only a preview of the song now loading (the queue can change under a fade).
  if (!preview || !firstLine || ghostEl.dataset.nextPreview !== queue[queueIndex]?.Id) return null
  spring.jumpTo(target)
  const firstTop = firstLine.getBoundingClientRect().top
  const start = target + Math.min(preview.getBoundingClientRect().top - firstTop, maxDistance)
  // The real lines take the ghost's place from where the first one lands; any
  // ghost line there (its previews, or the old lines a capped roll skips) would
  // be drawn over them.
  const landing = firstTop + (start - target) - 8
  ghostEl.querySelectorAll('[data-idx], .lyric-preview, .lyrics-next-divider').forEach(el => {
    if (el.classList.contains('lyric-preview') || el.getBoundingClientRect().top >= landing) el.style.visibility = 'hidden'
  })
  return start
}

/** How far a rolling sheet travels at most, in panel heights (_previewAlignedStart). */
const LYRIC_ROLL_MAX_PANELS = 1.5

// ── Lyrics roll on crossfade ─────────────────────────────────────────────────
// On a crossfade the next song's lyrics come up from below as the last song's
// roll off the top, one continuous glide, instead of the view emptying and
// jumping to the new song's first line. At the handover the old lines are kept
// as a ghost (a copy, frozen where they were) while the new ones load; when
// they arrive, their scroll starts most of a panel lower and springs to the
// current line, and the ghost moves up with it and fades.
let _lyricsRollUntil = 0   // performance.now() until which a new sheet rolls in (set at a crossfade's handover)
let _ovGhost = null        // { el, baseY, startPos }

/** Keeps the lines on screen as a ghost, once, for a crossfade's new sheet. */
function _ovKeepGhost() {
  const body = document.getElementById('ov-lyrics-body')
  if (_ovGhost || performance.now() > _lyricsRollUntil || !body?.querySelector('.ov-lyric-line')) return
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return
  const ghost = body.cloneNode(true)
  ghost.removeAttribute('id')
  ghost.classList.add('ov-lyrics-ghost')
  ghost.setAttribute('aria-hidden', 'true')
  Object.assign(ghost.style, { top: `${body.offsetTop}px`, left: `${body.offsetLeft}px`, width: `${body.offsetWidth}px` })
  body.parentNode.insertBefore(ghost, body)
  _ovGhost = { el: ghost, baseY: parseFloat(/translateY\((-?[\d.]+)px\)/.exec(body.style.transform)?.[1] ?? '0') || 0, startPos: null }
}

function _ovDropGhost() {
  if (!_ovGhost) return
  const { el } = _ovGhost
  _ovGhost = null
  el.animate([{ opacity: getComputedStyle(el).opacity }, { opacity: 0 }], { duration: 400, fill: 'forwards' })
    .finished.then(() => el.remove()).catch(() => el.remove())
}

/** The new sheet is drawn: start it below and let the spring bring it (and the ghost) up. */
function _ovRollIn(initialIdx) {
  const panel = document.getElementById('ov-panel-lyrics')
  updateOverlayLyricsActive(initialIdx, true)
  const target = ovLyricsBaseY
  const start = _previewAlignedStart(_ovGhost.el, document.querySelector('#ov-lyrics-body .ov-lyric-line[data-idx="0"]'), ovLyricsSpring, target, panel.clientHeight * LYRIC_ROLL_MAX_PANELS)
    ?? target + panel.clientHeight * 0.75
  _ovGhost.startPos = start
  ovLyricsSpring.jumpTo(start)
  ovLyricsSpring.setTarget(target)
  _ovGhost.el.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 900, easing: 'ease-in', fill: 'forwards' })
  const ghost = _ovGhost
  setTimeout(() => { if (_ovGhost === ghost) { _ovGhost = null; ghost.el.remove() } }, 950)
  _lyricsRollUntil = 0
}

const sideLyricsSpring = createSpring(pos => {
  const el = document.getElementById('lyrics-inner')
  if (el) el.style.transform = `translateY(${pos}px)`
  if (_sideGhost?.startPos != null) _sideGhost.el.style.transform = `translateY(${_sideGhost.baseY + pos - _sideGhost.startPos}px)`
})

// The side panel's lyrics roll, as the overlay's (_ovKeepGhost): the last song's
// lines stay as a ghost inside the panel through the next sheet's fetch, then
// ride the spring off the top as the new ones come up from below.
let _sideGhost = null      // { el, baseY, startPos }

function _sideKeepGhost() {
  const body = document.getElementById('lyrics-body')
  const inner = document.getElementById('lyrics-inner')
  if (_sideGhost || performance.now() > _lyricsRollUntil || !inner?.querySelector('.lyrics-line')) return
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return
  const ghost = inner.cloneNode(true)
  ghost.removeAttribute('id')
  ghost.classList.add('lyrics-ghost')
  ghost.setAttribute('aria-hidden', 'true')
  Object.assign(ghost.style, { top: `${inner.offsetTop}px`, left: `${inner.offsetLeft}px`, width: `${inner.offsetWidth}px` })
  inner.remove()
  body.appendChild(ghost)
  _sideGhost = { el: ghost, baseY: parseFloat(/translateY\((-?[\d.]+)px\)/.exec(inner.style.transform)?.[1] ?? '0') || 0, startPos: null }
}

function _sideDropGhost() {
  if (!_sideGhost) return
  const { el } = _sideGhost
  _sideGhost = null
  el.animate([{ opacity: getComputedStyle(el).opacity }, { opacity: 0 }], { duration: 400, fill: 'forwards' })
    .finished.then(() => el.remove()).catch(() => el.remove())
}

/** Replaces what the side panel shows, keeping a rolling ghost. */
function _sideSetBody(html) {
  const body = document.getElementById('lyrics-body')
  if (!_sideGhost) { body.innerHTML = html; return }
  for (const child of [...body.children]) if (child !== _sideGhost.el) child.remove()
  _sideGhost.el.insertAdjacentHTML('beforebegin', html)
}

function _sideRollIn() {
  if (!_sideGhost || !lyricsData.length) return
  const nowSec = audio.currentTime + _lyricLead
  let idx = 0
  for (let i = 0; i < lyricsData.length; i++) if (lyricsData[i].Start != null && lyricsData[i].Start / 10000000 <= nowSec) idx = i
  _applySideLyricsActive(idx, true)
  const inner = document.getElementById('lyrics-inner')
  const target = parseFloat(/translateY\((-?[\d.]+)px\)/.exec(inner?.style.transform || '')?.[1] ?? '0') || 0
  const sidePanel = document.getElementById('lyrics-body').clientHeight
  const start = _previewAlignedStart(_sideGhost.el, inner?.querySelector('.lyrics-line[data-idx="0"]'), sideLyricsSpring, target, sidePanel * LYRIC_ROLL_MAX_PANELS)
    ?? target + sidePanel * 0.75
  _sideGhost.startPos = start
  sideLyricsSpring.jumpTo(start)
  sideLyricsSpring.setTarget(target)
  _sideGhost.el.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 900, easing: 'ease-in', fill: 'forwards' })
  const ghost = _sideGhost
  setTimeout(() => { if (_sideGhost === ghost) { _sideGhost = null; ghost.el.remove() } }, 950)
}

// First line of the overlay's current group; lastOverlayLyricsIdx is the last.
// They differ only while lines overlap (see activeLyricRange).
let ovActiveFirst = -1

function updateOverlayLyricsActive(activeIdx, instant, first = activeIdx) {
  if (_lyricsPlain()) return   // nothing to follow
  const body = document.getElementById('ov-lyrics-body')
  const panel = document.getElementById('ov-panel-lyrics')
  ovActiveFirst = first
  body.querySelectorAll('.ov-lyric-line[data-idx]').forEach(el => {
    const idx = parseInt(el.dataset.idx)
    // Signed distance from the current group: negative = past, positive =
    // upcoming, 0 = any line in the group.
    const dist = idx < first ? idx - first : idx > activeIdx ? idx - activeIdx : 0
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
    el.style.transitionDelay = dist > 0 ? `${Math.min(dist, 3) * LYRIC_MOTION.ripple}ms` : '0ms'
  })
  // GPU-accelerated: translate the container so active line sits at panel center
  _scrollOverlayLyricsTo(activeIdx, instant, first)
}

// Centers the given line in the overlay lyrics panel. `instant` skips the
// spring animation - used when snap-scrolling right as a karaoke line's last
// word finishes, so the jump isn't a glide disconnected from the vocal.
function _scrollOverlayLyricsTo(idx, instant, first = idx) {
  const body = document.getElementById('ov-lyrics-body')
  const panel = document.getElementById('ov-panel-lyrics')
  const el = body.querySelector(`.ov-lyric-line[data-idx="${idx}"]`)
  if (!el) return
  // A group of overlapping lines is centred as one block, top of the first to
  // the bottom of the last; a single line is the same with top === el.
  const top = body.querySelector(`.ov-lyric-line[data-idx="${first}"]`) || el
  // The block's point at the same share of its own height lands at that
  // share of the panel's: 0.5 centers it, lower sits it higher up.
  const centreOn = () => {
    const blockTop = top.offsetTop, blockBottom = el.offsetTop + el.offsetHeight
    return (ovLyricsBaseY = panel.clientHeight * ovLyricLinePosition - (blockTop + (blockBottom - blockTop) * ovLyricLinePosition))
  }
  centreOn()
  // While the user is manually scrolling, leave the spring alone - it gets
  // redirected (base + their offset) from the wheel handler instead.
  if (ovLyricsUserScrolling) return
  if (instant) ovLyricsSpring.jumpTo(ovLyricsBaseY)
  else ovLyricsSpring.setTarget(centreOn)   // re-measured per frame, see createSpring
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

// The line (and its group's first) the scroll heads for when the Scroll ahead
// knob is on: the one current scrollLead seconds from now, if that is past the
// lit one. Null leaves the scroll on the lit line, as before.
function _lyricScrollAhead(nowSec, baseIdx, activeIdx) {
  const lead = lyricStyle.scrollLead
  if (!(lead > 0)) return null
  const t = nowSec + lead
  const idx = CascadeCore.currentLyricIndex(lyricsData, _scanLyricsBaseIdx(t, Math.max(0, baseIdx)), t * 10_000_000)
  if (!(idx > activeIdx)) return null
  return [idx, CascadeCore.activeLyricRange(lyricsData, idx, t * 10_000_000)[0]]
}

// Untimed lyrics (LRCLIB's plain text): a page to read, every line shown and
// nothing followed, rather than the first line lit and the rest blurred away.
const _lyricsPlain = () => lyricsData.length > 0 && lyricsData.every(l => l.Start == null)

// The lit line, moved to the next one tightScrollLead seconds early when that
// follows it closely (tightScrollTarget): the highlight and the scroll go
// together, so back-to-back lines do not arrive late.
function _lyricFocusIdx(nowSec, baseIdx) {
  const idx = CascadeCore.currentLyricIndex(lyricsData, baseIdx, nowSec * 10_000_000)
  return CascadeCore.tightScrollTarget(lyricsData, idx, nowSec * 10_000_000, (lyricStyle.tightScrollLead || 0) * 10_000_000) ?? idx
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
let ovLyricLinePosition = 0.5    // where that line sits, 0.5 = centered (a Lyrics setting)
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
  if (_lyricsPlain()) {
    // A page: it stays where it is scrolled to, between the first line at the top and the last mid-panel.
    const top = 40 - (document.querySelector('#ov-lyrics-body .ov-lyric-line[data-idx="0"]')?.offsetTop || 0)
    ovLyricsBaseY = Math.min(top, Math.max(_ovLyricsTranslateYFor(lyricsData.length - 1), ovLyricsBaseY - e.deltaY))
    ovLyricsSpring.setPos(ovLyricsBaseY)
    return
  }
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
  if (!overlayOpen || !overlayLyricsOpen || !lyricsData.length || _lyricsPlain()) return
  // Same lookahead as word-fill (_wordHighlightFrame) so the last word's fill
  // animation and the line-promotion check complete in lockstep - no gap in
  // either direction (mid-fill cutoff if promotion is earlier, a visible
  // "stick" on the finished word if promotion is later).
  const nowSec = audio.currentTime + _lyricLead
  const baseIdx = _scanLyricsBaseIdx(nowSec, _ovLyricsScanIdx)
  _ovLyricsScanIdx = baseIdx

  // Karaoke: promote early once a line (background vocals included) is sung,
  // and hold a line while its background vocals run into the next one. Shared
  // with the side panel; see currentLyricIndex in src/core/lyrics.ts.
  const activeIdx = _lyricFocusIdx(nowSec, baseIdx)
  // An earlier line still sung when this one began (a duet, a call and
  // response) stays lit with it until 0.7s after it ends: activeLyricRange in
  // src/core/lyrics.ts.
  const [first] = CascadeCore.activeLyricRange(lyricsData, activeIdx, nowSec * 10_000_000)
  const ahead = _lyricScrollAhead(nowSec, baseIdx, activeIdx)
  const aheadKey = ahead ? ahead.join(':') : ''

  if (activeIdx === lastOverlayLyricsIdx && first === ovActiveFirst && aheadKey === ovAheadKey) return
  lastOverlayLyricsIdx = activeIdx
  ovAheadKey = aheadKey
  // Always a glide. An early promotion (a karaoke line sung before the next
  // one's start) used to jump there instantly, and SpicyLyrics' syncs make
  // nearly every change early, so every line change was a snap.
  updateOverlayLyricsActive(activeIdx, false, first)
  if (ahead) _scrollOverlayLyricsTo(ahead[0], false, ahead[1])
})
let ovAheadKey = ''

// Update overlay when track changes
const _baseUpdateNP = updateNowPlaying
updateNowPlaying = function(item) {
  _baseUpdateNP(item)
  if (overlayOpen) { syncOverlayState(); renderQueuePanel() }
}

// ── Context menu ──────────────────────────────────────────────────────────────

const ctxMenu = document.getElementById('ctx-menu')

function showCtxMenu(x, y) {
  markTipSeen('np-more')
  // Same source of truth as toggleLike() uses for the current track: the
  // button's own class, kept live by updateNowPlaying() regardless of
  // whether UserData ever loaded for this item.
  const favLabel = document.getElementById('ctx-favorite-label')
  if (favLabel) favLabel.textContent = likeBtn.classList.contains('liked') ? 'Unfavorite' : 'Favorite'
  // A film has no album, lyrics or instant mix, and belongs in no playlist.
  ctxMenu.classList.toggle('video', playingVideo())
  ctxMenu.style.left = `${x}px`
  ctxMenu.style.top = `${y}px`
  ctxMenu.classList.add('open')
  const rect = ctxMenu.getBoundingClientRect()
  const { left, top } = CascadeCore.clampMenuPosition(x, y, rect.width, rect.height, window.innerWidth, window.innerHeight)
  ctxMenu.style.left = `${left}px`
  ctxMenu.style.top = `${top}px`
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

// Clear queue: keeps the playing track. Dropping it from the queue while the
// deck kept playing left the queue panel and the player disagreeing.
document.getElementById('ctx-clear-queue').addEventListener('click', () => {
  hideCtxMenu()
  clearQueueTracks('all')
})

/**
 * The one place the queue is trimmed by a "Clear". `scope` is 'all' (keep only
 * the playing track, History included) or 'upnext' (keep History and the
 * playing track). Every copy of the queue is trimmed together: the shuffle
 * backup would bring cleared tracks back when shuffle is turned off, the
 * Waterfall attribution list is parallel to `queue`, and a prefetched next
 * track is for a track that is gone.
 */
function clearQueueTracks(scope) {
  if (isWaterfallFollower()) return
  // finishCrossfade() lands on an index captured before the fade started;
  // removing the incoming track under it would land it on the wrong one.
  if (_cfActive) { showToast('Clear the queue once the crossfade finishes'); return }
  const before = queueIndex
  const next = scope === 'upnext'
    ? CascadeCore.clearUpNext(queue, queueIndex)
    : CascadeCore.trimToCurrent(queue, queueIndex)
  const kept = new Set(next.queue)
  queue = next.queue
  queueIndex = next.index
  queueSource = null
  if (_unshuffledQueue.length) _unshuffledQueue = _unshuffledQueue.filter(t => kept.has(t))
  // Parallel to `queue`: the host's own wfOnQueueChanged() only truncates, which
  // is right for 'upnext' but would hand the kept track its old neighbor's name.
  if (scope !== 'upnext' && typeof wfActive === 'function' && wfActive() && Array.isArray(wfAddedBy)) {
    wfAddedBy = queueIndex >= 0 ? [wfAddedBy[before] ?? null] : []
  }
  _queueHistoryOpen = false
  _reprefetch()
  _saveQueueState()
  renderQueuePanel()
}

// Instant mix
document.getElementById('ctx-instant-mix').addEventListener('click', async () => {
  const item = queue[queueIndex]
  if (!item) return
  try {
    const data = await jfGet(`/Items/${item.Id}/InstantMix`, {
      UserId: jf.userId, Limit: 25,
      Fields: 'AlbumId,AlbumPrimaryImageTag'
    })
    if (data.Items?.length) playItems(data.Items, 0, 'Instant mix')
  } catch (e) { console.error('Instant mix failed', e) }
})

// Favorite / unfavorite - toggleLike() defined with the transport bar's heart
// button above. No hideCtxMenu() call, matching every other row in this menu
// (see the "known gap" note in CODEMAP: #ctx-menu never closes itself on click).
document.getElementById('ctx-favorite').addEventListener('click', () => toggleLike())

// Add to playlist
// Set by a context menu before opening the modal; falls back to now-playing.
// A single item or an array (the album menu's "Add all to playlist" adds a
// whole album's tracks in one POST - Jellyfin's Ids param takes a comma-
// separated list, so this was never a second endpoint, just more ids).
let _atpTargetItem = null

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
    const data = await jfGet(`/Items`, {
      IncludeItemTypes: 'Playlist', Recursive: true, SortBy: 'SortName'
    })
    list.innerHTML = (data.Items || []).map(pl =>
      `<div class="modal-pl-item" data-id="${pl.Id}" data-name="${esc(pl.Name)}"><span>${esc(pl.Name)}</span></div>`
    ).join('') || '<div style="font-size:12px;color:var(--text3);text-align:center;padding:20px 0">No playlists</div>'
    _atpMarkContaining(list)
    list.querySelectorAll('.modal-pl-item').forEach(el => {
      el.addEventListener('click', async () => {
        const raw = _atpTargetItem || queue[queueIndex]
        _atpTargetItem = null
        const items = Array.isArray(raw) ? raw : (raw ? [raw] : [])
        if (!items.length) return
        try {
          const ids = items.map(i => encodeURIComponent(i.Id)).join(',')
          await waitForPlaylistWrite(el.dataset.id)
          const res = await jfFetch(`${jf.url}/Playlists/${el.dataset.id}/Items?Ids=${ids}&UserId=${encodeURIComponent(jf.userId)}`, {
            method: 'POST',
            headers: CascadeCore.authHeaders(jf)
          })
          if (!res.ok) {
            const errMsg = await CascadeCore.readErrorMessage(res)
            showNotice(`Could not add to that playlist.\n\n${errMsg}`, 'Playlist')
          } else {
            showToast(items.length > 1 ? `Added ${items.length} tracks to "${el.dataset.name}"` : `Added to "${el.dataset.name}"`)
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

/**
 * A check on each playlist that already holds what is being added (all of it,
 * when it is several songs). Jellyfin cannot be asked which playlists hold a
 * song: an Ids or name filter on a playlist's items is ignored (checked on
 * 12.2), so each playlist's track ids are fetched, light, every time the popup
 * opens. Never stale, and filled in as each answer lands.
 * ponytail: one request per playlist per open; cache per playlist if huge playlists make it slow.
 */
function _atpMarkContaining(list) {
  const raw = _atpTargetItem || queue[queueIndex]
  const ids = (Array.isArray(raw) ? raw : raw ? [raw] : []).map(i => i.Id)
  if (!ids.length) return
  list.querySelectorAll('.modal-pl-item').forEach(el => {
    jfGet(`/Items`, { ParentId: el.dataset.id, EnableImages: false, EnableUserData: false, Fields: '' })
      .then(d => {
        const held = new Set((d.Items || []).map(i => i.Id))
        if (!ids.every(id => held.has(id)) || !el.isConnected) return
        el.classList.add('has-item')
        el.title = ids.length > 1 ? 'Already holds these songs' : 'Already in this playlist'
        el.insertAdjacentHTML('beforeend', '<span class="modal-pl-check" aria-label="Already added">✓</span>')
      })
      .catch(() => {})
  })
}

document.getElementById('ctx-add-playlist').addEventListener('click', () => {
  _atpTargetItem = null  // use now-playing
  openAtpModal()
})

// The same three actions as buttons over the overlay's art (see #ov-art-like
// in index.html); the More menu keeps its rows too.
document.getElementById('ov-art-like').addEventListener('click', () => toggleLike())
document.getElementById('ov-art-playlist').addEventListener('click', () => {
  _atpTargetItem = null
  openAtpModal()
})
document.getElementById('ov-art-album').addEventListener('click', () => openAlbumFromTrack(queue[queueIndex]))

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
    const res = await jfFetch(`${jf.url}/Playlists?Name=${encodeURIComponent(name)}&Ids=${encodeURIComponent(item.Id)}&UserId=${encodeURIComponent(jf.userId)}&MediaType=Audio`, {
      method: 'POST',
      headers: CascadeCore.authHeaders(jf)
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
  const url = `${jf.url}/Items/${item.Id}/Download?ApiKey=${jf.token}`
  window.cascade.download(url, item.Name)
})

// Copy stream URL
document.getElementById('ctx-copy-url').addEventListener('click', () => {
  const item = queue[queueIndex]
  if (!item) return
  window.cascade.clipboard.write(streamUrl(item.Id, isVideoItem(item) ? 'Video' : 'Audio'))
})

// Media info - shared by the now-playing and track context menus, so there is
// one fetch-and-render instead of a second copy hardwired to queue[queueIndex].
async function openMediaInfoFor(item) {
  if (!item) return
  const modal = document.getElementById('mi-modal')
  const grid = document.getElementById('mi-grid')
  modal.classList.remove('hidden')
  try {
    const d = await jfGet(`/Items/${item.Id}`)
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
}
document.getElementById('ctx-media-info').addEventListener('click', () => openMediaInfoFor(queue[queueIndex]))
document.getElementById('mi-close').addEventListener('click', () => document.getElementById('mi-modal').classList.add('hidden'))

// Refresh metadata - refreshItemMetadata() defined with the track context
// menu above, shared by both.
document.getElementById('ctx-refresh-meta').addEventListener('click', () => refreshItemMetadata(queue[queueIndex]))

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

// DELETE /Items/{id} - works on any item type (a track, a whole playlist).
// Shared by "Delete media" (now-playing) and the playlist card menu's
// "Delete playlist" so there is one delete call, not one per menu.
async function deleteItemFromServer(item, { confirmMsg, onDeleted }) {
  if (!item) return
  // The entry is greyed for an account without the deletion right, but a
  // disabled-looking div can still be clicked programmatically - don't trust
  // the DOM state alone against a server call that would just 403 anyway.
  // Local mode deletes nothing but a playlist made in Cascade (localServerWrite).
  if (!jf.canDelete && !isLocalPlaylist(item.Id)) return
  if (!confirm(confirmMsg)) return
  try {
    const res = await jfFetch(`${jf.url}/Items/${item.Id}`, {
      method: 'DELETE', headers: CascadeCore.authHeaders(jf)
    })
    // The response was never read, so a 403 (e.g. a library outside this
    // account's granted folders) reported success for a delete the server
    // had refused outright.
    if (!res.ok) throw new Error(String(res.status))
    onDeleted()
  } catch (e) {
    console.error('Delete failed', e)
    showNotice('Could not delete this item from the server.', 'Delete failed')
  }
}

// Delete media
document.getElementById('ctx-delete').addEventListener('click', () => {
  const item = queue[queueIndex]
  if (!item) return
  deleteItemFromServer(item, {
    confirmMsg: `Delete "${item.Name}" from your server? This cannot be undone.`,
    onDeleted: () => {
      audio.pause(); _detachDeck(audio)
      queue.splice(queueIndex, 1)
      queueIndex = Math.min(queueIndex, queue.length - 1)
      // playCurrentTrack() below re-checks the prefetch for the new current
      // item; an empty queue has nothing left to play it into.
      if (queue.length) playCurrentTrack()
      else _clearStreamPrefetch()
    }
  })
})

// ── Universal item context menu ─────────────────────────────────────────────
//
// Right-click for album/artist/movie/series/playlist cards - previously only
// track rows and the now-playing art had a menu at all. One more menu
// element, not one per kind: rows are shown/hidden per kind the same way
// #track-ctx-menu already does for its playlist-only rows (.tctx-pl-only
// above), driven by CascadeCore.menuItemsForKind() (src/core/context-menu.ts).
//
// Every action below calls a function that already exists for the equivalent
// click/button elsewhere (playItems, shuffleAndPlay, enqueueTracks, the
// rename modal, deleteItemFromServer, ...) - this file only adds the fetch
// helpers (fetchAlbumTracks/fetchArtistSongs/fetchPlaylistTracks, defined
// with their detail views above) needed to hand those functions a track list
// from a card that has no tracks loaded yet.

const itemCtxMenu = document.getElementById('item-ctx-menu')
let _ictxKind     = null   // MenuItemKind
let _ictxItem     = null   // the Jellyfin item (or a {smartKind,Name} stand-in)
let _ictxEl       = null   // the right-clicked card
let _ictxOnDetail = null   // "View detail"/"Go to artist page" handler - the
                            // same onPick already passed to wire*Cards, since
                            // every card's click already IS its own detail nav

const ICTX_FLAG_IDS = {
  play: 'ictx-play', playNext: 'ictx-play-next', playLast: 'ictx-play-last',
  shuffle: 'ictx-shuffle', instantMix: 'ictx-instant-mix', addPlaylist: 'ictx-add-playlist',
  download: 'ictx-download', offline: 'ictx-offline', favorite: 'ictx-favorite',
  markPlayed: 'ictx-mark-played', markUnplayed: 'ictx-mark-unplayed',
  goArtist: 'ictx-go-artist', viewDetail: 'ictx-view-detail',
  rename: 'ictx-rename', deleteItem: 'ictx-delete',
  refreshMeta: 'ictx-refresh-meta', editMeta: 'ictx-edit-meta',
}

// Hides a .ctx-sep that has no visible item before it (leading, or right
// after another sep) or none after it (trailing) - needed because which rows
// are visible changes by kind, and a menu with two blank separators stacked
// looks broken. Generic over itemCtxMenu's own children; not worth pushing to
// core, this is DOM layout bookkeeping, not "which items apply to a kind".
function _reflowItemCtxSeparators() {
  let sawItem = false
  let pendingSep = null
  for (const n of itemCtxMenu.children) {
    if (n.classList.contains('ctx-sep')) {
      n.classList.toggle('hidden', !sawItem)
      pendingSep = n
      sawItem = false
    } else if (!n.classList.contains('hidden')) {
      sawItem = true
    }
  }
  if (pendingSep && !sawItem) pendingSep.classList.add('hidden')
}

function showItemCtxMenu(kind, item, el, x, y, onDetail) {
  markTipSeen('card-menu')
  _ictxKind = kind; _ictxItem = item; _ictxEl = el; _ictxOnDetail = onDetail || null

  // 'video'/'series' UserData carries the real played state already loaded on
  // the grid DTO; anything else has no such concept, so mark-played/unplayed
  // stay hidden rather than guessing (see menuItemsForKind's isPlayed handling).
  const isPlayed = (kind === 'video' || kind === 'series') ? !!item?.UserData?.Played : undefined
  const vis = CascadeCore.menuItemsForKind(kind, { isPlayed, offline: jfClient.offline, local: isLocalMode() })
  // An album with no AlbumArtist has nowhere for "Go to artist" to go.
  if (kind === 'album' && !item?.AlbumArtist) vis.goArtist = false

  for (const [flag, id] of Object.entries(ICTX_FLAG_IDS)) {
    const node = document.getElementById(id)
    if (node) node.classList.toggle('hidden', !vis[flag])
  }

  const playLabel = document.getElementById('ictx-play-label')
  if (playLabel) playLabel.textContent = kind === 'artist' ? 'Play all' : (kind === 'video' && resumeTicks(item)) ? 'Resume' : 'Play'
  // As on song menus: only while a device is picked in the Devices panel, and
  // only for music (a remote session's video playback is its own business).
  const device = vis.play && kind !== 'video' && kind !== 'series' ? _dpCurrentSession() : null
  document.getElementById('ictx-play-on-device').classList.toggle('hidden', !device)
  if (device) document.getElementById('ictx-play-on-device-label').textContent = `Play on ${device.DeviceName || device.Client || 'device'}`
  const shuffleLabel = document.getElementById('ictx-shuffle-label')
  if (shuffleLabel) shuffleLabel.textContent = kind === 'artist' ? 'Shuffle all' : 'Shuffle'
  const detailLabel = document.getElementById('ictx-view-detail-label')
  if (detailLabel) detailLabel.textContent = kind === 'artist' ? 'Go to artist page' : 'Go to details'
  const favLabel = document.getElementById('ictx-favorite-label')
  if (favLabel) favLabel.textContent = item?.UserData?.IsFavorite ? 'Unfavorite' : 'Favorite'
  const offlineLabel = document.getElementById('ictx-offline-label')
  if (offlineLabel) offlineLabel.textContent = offlineCollection(item?.Id) ? 'Remove download' : 'Download for offline'
  // Offline there is nothing to start: only a download can be removed.
  if (jfClient.offline && !offlineCollection(item?.Id)) document.getElementById('ictx-offline').classList.add('hidden')
  // A user smart playlist repurposes the rename/delete rows (its own
  // definition, never gated on server delete permission the way a real
  // playlist is - see menuItemsForKind) rather than adding two more rows that
  // would only ever apply to one kind.
  const renameLabel = document.getElementById('ictx-rename-label')
  if (renameLabel) renameLabel.textContent = kind === 'user-smart-playlist' ? 'Edit rules…' : kind === 'playlist' ? 'Edit…' : 'Rename…'
  const deleteLabel = document.getElementById('ictx-delete-label')
  if (deleteLabel) deleteLabel.textContent = kind === 'user-smart-playlist' ? 'Delete smart playlist' : 'Delete playlist'
  // _applyAdminGating() gates ictx-delete on jf.canDelete for a real playlist's
  // server-side delete - a user smart playlist has nothing server-side to gate,
  // it's deleting a local definition, so this open of the menu is the one place
  // that decides which rule applies and re-asserts it every time, rather than
  // leaving whatever _applyAdminGating last set (which knows nothing about
  // `kind`) stuck on from a previous menu of the other kind.
  const deleteEl = document.getElementById('ictx-delete')
  const deleteNote = document.getElementById('ictx-delete-note')
  const deleteGated = kind === 'playlist' && !jf.canDelete && !isLocalMode()
  if (deleteEl) deleteEl.classList.toggle('needs-admin', deleteGated)
  if (deleteNote) deleteNote.hidden = !deleteGated

  _reflowItemCtxSeparators()

  itemCtxMenu.style.left = `${x}px`
  itemCtxMenu.style.top  = `${y}px`
  itemCtxMenu.classList.add('open')
  const r = itemCtxMenu.getBoundingClientRect()
  const { left, top } = CascadeCore.clampMenuPosition(x, y, r.width, r.height, window.innerWidth, window.innerHeight)
  itemCtxMenu.style.left = `${left}px`
  itemCtxMenu.style.top  = `${top}px`
}

function hideItemCtxMenu() { itemCtxMenu.classList.remove('open') }

document.addEventListener('mousedown', e => { if (!itemCtxMenu.contains(e.target)) hideItemCtxMenu() })
document.addEventListener('keydown', e => { if (e.key === 'Escape') hideItemCtxMenu() })

/** Track list for whatever's under the item menu right now - the one thing
 *  every kind's Play/Shuffle/Play next/Play last/Add-to-playlist action needs
 *  before it can call the same functions the rest of the app already uses. */
async function _ictxTracks() {
  if (!_ictxItem) return []
  if (_ictxKind === 'album') return fetchAlbumTracks(_ictxItem.Id)
  if (_ictxKind === 'artist') return fetchArtistSongs(_ictxItem.Id)
  if (_ictxKind === 'playlist') return fetchPlaylistTracks(_ictxItem.Id)
  if (_ictxKind === 'smart-playlist' || _ictxKind === 'user-smart-playlist') {
    const sp = smartPlaylistEntry(_ictxItem.smartKind)
    return sp ? sp.fetch() : []
  }
  return []
}

document.getElementById('ictx-play').addEventListener('click', async () => {
  hideItemCtxMenu()
  if (!_ictxItem) return
  if (_ictxKind === 'video') { playVideo([_ictxItem], 0, resumeTicks(_ictxItem) || 0); return }
  const tracks = await _ictxTracks()
  if (tracks.length) playItems(tracks, 0, _ictxItem.Name)
})

document.getElementById('ictx-play-on-device').addEventListener('click', async () => {
  hideItemCtxMenu()
  if (!_ictxItem) return
  // The ids ride in the query string, and Jellyfin's server refuses a request
  // line over 8 KB: 200 ids is about 6.6 KB. A bigger artist starts with its first 200.
  const tracks = (await _ictxTracks()).slice(0, 200)
  if (tracks.length) _dpPlayItemsOnDevice(tracks)
})

document.getElementById('ictx-shuffle').addEventListener('click', async () => {
  hideItemCtxMenu()
  const tracks = await _ictxTracks()
  if (tracks.length) shuffleAndPlay(tracks, _ictxItem.Name)
})

// Play next/last, add to playlist: album, artist, playlist and smart-playlist
// (see menuItemsForKind) - same ownership guard as the track menu's
// tctx-play-next/tctx-add-queue, not a relaxed copy of it. _ictxTracks()
// fetches whichever container's tracks the current kind needs.
const ICTX_QUEUEABLE_KINDS = ['album', 'artist', 'playlist', 'smart-playlist']

document.getElementById('ictx-play-next').addEventListener('click', async () => {
  hideItemCtxMenu()
  if (!ICTX_QUEUEABLE_KINDS.includes(_ictxKind) || !_ictxItem) return
  if (isWaterfallFollower()) { showToast('Only the host can choose what plays next'); return }
  const tracks = await _ictxTracks()
  if (tracks.length) playNextTracks(tracks, `"${_ictxItem.Name}"`)
})

document.getElementById('ictx-play-last').addEventListener('click', async () => {
  hideItemCtxMenu()
  if (!ICTX_QUEUEABLE_KINDS.includes(_ictxKind) || !_ictxItem) return
  const tracks = await _ictxTracks()
  if (tracks.length) enqueueTracks(tracks, `"${_ictxItem.Name}"`)
})

// Instant mix: album and artist (see menuItemsForKind) - the endpoint takes
// any item id, so seeding it from an album works exactly like from a track.
document.getElementById('ictx-instant-mix').addEventListener('click', () => {
  hideItemCtxMenu()
  if (!['album', 'artist'].includes(_ictxKind) || !_ictxItem) return
  instantMixAndPlay(_ictxItem.Id, _ictxItem.Name)
})

document.getElementById('ictx-add-playlist').addEventListener('click', async () => {
  hideItemCtxMenu()
  if (!ICTX_QUEUEABLE_KINDS.includes(_ictxKind) || !_ictxItem) return
  const tracks = await _ictxTracks()
  if (!tracks.length) return
  _atpTargetItem = tracks   // array - atpLoadPlaylists() POSTs every id at once
  openAtpModal()
})

// Download for offline, or remove it: album and playlist (see menuItemsForKind).
document.getElementById('ictx-offline').addEventListener('click', () => {
  hideItemCtxMenu()
  if (!['album', 'playlist'].includes(_ictxKind) || !_ictxItem) return
  toggleOfflineDownload(_ictxKind, _ictxItem)
})

// Download: album-only (see menuItemsForKind) - there is no single file to
// hand window.cascade.download for a whole album, so this queues one download
// per track the same way tctx-download does for a single one.
document.getElementById('ictx-download').addEventListener('click', async () => {
  hideItemCtxMenu()
  if (_ictxKind !== 'album' || !_ictxItem) return
  const tracks = await fetchAlbumTracks(_ictxItem.Id)
  for (const t of tracks) {
    window.cascade.download(`${jf.url}/Items/${t.Id}/Download?ApiKey=${jf.token}`, t.Name)
  }
})

// Favorite/unfavorite: album and artist (see menuItemsForKind) - toggleLike()
// defined with the transport bar's heart button.
document.getElementById('ictx-favorite').addEventListener('click', () => {
  hideItemCtxMenu()
  if (!['album', 'artist'].includes(_ictxKind) || !_ictxItem) return
  toggleLike(_ictxItem)
})

document.getElementById('ictx-go-artist').addEventListener('click', () => {
  hideItemCtxMenu()
  if (_ictxKind !== 'album' || !_ictxItem?.AlbumArtist) return
  openArtistFromTrack({ AlbumArtist: _ictxItem.AlbumArtist })
})

document.getElementById('ictx-view-detail').addEventListener('click', () => {
  hideItemCtxMenu()
  if (_ictxItem && _ictxOnDetail) _ictxOnDetail(_ictxItem)
})

/** POST/DELETE /UserPlayedItems/{id} - the one Jellyfin played-state endpoint,
 *  used identically for a movie, an episode, or a whole series.
 *
 *  NOT /Users/{userId}/PlayedItems/{id}. That older route is gone in 10.11:
 *  checked against this server's own OpenAPI spec, where /UserPlayedItems is
 *  the only played-state path that exists. The old one would have 404'd, and
 *  since the handler reads res.ok it would at least have said so rather than
 *  silently doing nothing. */
async function setItemPlayed(item, played) {
  try {
    if (jfClient.offline) {
      await queueOfflineChange({ itemId: item.Id, kind: 'played', played })
    } else {
      const res = await jfFetch(`${jf.url}/UserPlayedItems/${item.Id}?userId=${encodeURIComponent(jf.userId)}`, {
        method: played ? 'POST' : 'DELETE', headers: CascadeCore.authHeaders(jf)
      })
      if (!res.ok) throw new Error(String(res.status))
    }
    // Keeps a re-opened menu on the same card showing the right toggle for the
    // rest of this session, without a round trip back to the grid's own fetch.
    if (item.UserData) item.UserData.Played = played
    showToast(played ? 'Marked as played' : 'Marked as unplayed')
  } catch (e) { showNotice('Could not update played status on the server.', 'Mark played') }
}

document.getElementById('ictx-mark-played').addEventListener('click', () => {
  hideItemCtxMenu()
  if (_ictxItem) setItemPlayed(_ictxItem, true)
})
document.getElementById('ictx-mark-unplayed').addEventListener('click', () => {
  hideItemCtxMenu()
  if (_ictxItem) setItemPlayed(_ictxItem, false)
})

// A real playlist's "Edit…" opens it in Edit mode, where its name,
// description, picture and Public switch are edited in place.
document.getElementById('ictx-rename').addEventListener('click', async () => {
  hideItemCtxMenu()
  if (_ictxKind === 'user-smart-playlist' && _ictxItem) {
    const sp = smartPlaylistEntry(_ictxItem.smartKind)
    if (sp?.isUser) openSmartPlaylistEditor(sp.def)
    return
  }
  if (_ictxKind !== 'playlist' || !_ictxItem) return
  // Edited in place now: open it, switch Edit on, and put the cursor in the name.
  showView('playlists')
  await openPlaylist(_ictxItem.Id, _ictxItem.Name)
  if (!plEditMode) document.getElementById('btn-edit-playlist').click()
  for (let i = 0; i < 20 && !_plEdit; i++) await new Promise(r => setTimeout(r, 50))
  if (_plEdit) _plNameEl.focus()
})

// Delete reuses deleteItemFromServer (defined with "Delete media" above) - a
// Jellyfin playlist is an Item like any other, so the same DELETE applies.
// A user smart playlist has no server item at all: "delete" just drops it
// from the local store (see saveUserSmartPlaylists) and is never gated on
// server delete permission (see showItemCtxMenu's deleteGated above).
document.getElementById('ictx-delete').addEventListener('click', () => {
  hideItemCtxMenu()
  if (_ictxKind === 'user-smart-playlist' && _ictxItem) {
    const kindId = _ictxItem.smartKind
    if (!confirm(`Delete the smart playlist "${_ictxItem.Name}"? This cannot be undone.`)) return
    userSmartPlaylists = userSmartPlaylists.filter(d => d.id !== kindId)
    saveUserSmartPlaylists()
    _ictxEl?.remove()
    delete document.getElementById('playlists-grid').dataset.loaded
    if (currentSmartKind === kindId) {
      document.getElementById('playlist-detail').classList.remove('active')
      document.getElementById('playlist-index').style.display = ''
      currentSmartKind = null
    }
    showToast('Smart playlist deleted')
    return
  }
  if (_ictxKind !== 'playlist' || !_ictxItem) return
  deleteItemFromServer(_ictxItem, {
    confirmMsg: `Delete the playlist "${_ictxItem.Name}"? This cannot be undone.`,
    onDeleted: () => {
      _ictxEl?.remove()
      delete document.getElementById('playlists-grid').dataset.loaded
      if (currentPlaylistId === _ictxItem.Id) {
        document.getElementById('playlist-detail').classList.remove('active')
        document.getElementById('playlist-index').style.display = ''
        currentPlaylistId = null
      }
      showToast('Playlist deleted')
    }
  })
})

// Refresh/edit metadata are album-only (see menuItemsForKind) and reuse the
// exact same functions as the track/now-playing menus - refreshItemMetadata
// above, openMetadataEditorFor with the metadata editor window.
document.getElementById('ictx-refresh-meta').addEventListener('click', () => {
  hideItemCtxMenu()
  if (_ictxKind === 'album') refreshItemMetadata(_ictxItem)
})
document.getElementById('ictx-edit-meta').addEventListener('click', () => {
  hideItemCtxMenu()
  if (_ictxKind === 'album') openMetadataEditorFor(_ictxItem)
})

// ── Lyrics panel ──────────────────────────────────────────────────────────────

let lyricsSource        = null   // source that was actually used: 'Kugou' | 'LRCLIB' | 'LRCLIB (plain)' | 'Jellyfin' | 'Karaoke' | 'Synced' | a SpicyLyrics provider
// SpicyLyrics' credit for the lyrics on screen ({ provider, uploader, maker },
// see src/core/spicy-lyrics.ts), or null for every other source. Its terms
// require it wherever the lyrics show: the side panel, the overlay and the
// miniplayer. Non-null also means these lines must never be saved anywhere
// permanent (see openLyricsEditorFor).
let lyricsCredit        = null
let lyricsForcedSource  = 'auto' // 'auto' | 'Kugou' | 'LRCLIB' | 'Jellyfin' | 'cascade-karaoke' | 'cascade-synced'
let serverOnlyMode    = false  // fetch exclusively from Cascade plugin when true

// Valid lyrics source keys - any stored value not in this set is stale and gets reset
const VALID_LYRICS_SOURCES = new Set(['auto', 'Kugou', 'LRCLIB', 'Jellyfin', 'cascade-karaoke', 'cascade-synced'])

// ── Cascade Server plugin detection ─────────────────────────────────────────
// Whether the connected server has the plugin at all. Probed once per
// connection (see probeCascadePlugin, called from connect()) and cached here
// for the session - not worth a round trip per track.
let _cascadePluginAbsent = false
const NO_PLUGIN_TIP = 'No Cascade Server plugin'
// Which route family answered: 'server' (CascadeServer/*, 2.0.0.0+) or
// 'legacy' (the plugin's pre-rename CascadeLyrics routes). The lyrics fetch
// awaits _cascadePluginProbed so a track loaded during connect does not hit
// the wrong route.
let _cascadePluginApi = 'server'
let _cascadePluginProbed = Promise.resolve()
// What the plugin's Info route says it can do. 'syllable' means a SpicyLyrics
// key is set on the server, so asking for SpicyLyrics is worth a request.
let _cascadePluginCaps = new Set()
let _spotifyLinkServerWide = true

// ── SpicyLyrics from the app ─────────────────────────────────────────────────
// For when the plugin cannot ask (docs/local-mode-plan.md, section 6): Local
// mode always, a Jellyfin server without the plugin otherwise. The main
// process asks with the person's own key (spicy-client.js); a server
// with the plugin keeps asking through it, key or no key here.
let _spicyKeySet = false
window.cascade.spicy.status().then(s => { _spicyKeySet = !!s?.hasKey; renderSpicyKeyStatus() }).catch(() => {})

function spicyFromApp() {
  return _spicyKeySet && (isLocalMode() || _cascadePluginAbsent)
}

function renderSpicyKeyStatus(message, isError = false) {
  const el = document.getElementById('s-spicy-key-status')
  if (!el) return
  el.textContent = message || (_spicyKeySet ? 'A key is saved on this computer.' : 'No key saved.')
  el.style.color = isError ? 'var(--red)' : ''
  document.getElementById('s-spicy-key-clear').hidden = !_spicyKeySet
}

async function saveSpicyKey(value) {
  const result = await window.cascade.spicy.setKey(value).catch(() => ({ ok: false, error: 'Could not save the key.' }))
  if (!result.ok) { renderSpicyKeyStatus(result.error, true); return }
  _spicyKeySet = value !== null
  const input = /** @type {HTMLInputElement} */ (document.getElementById('s-spicy-key'))
  input.value = ''
  renderSpicyKeyStatus(_spicyKeySet ? 'Saved. Songs you play now ask Spicy Lyrics first.' : 'Key removed.')
  // What was found without it (or with it) is stale now.
  _lyricsCache.clear()
}

document.getElementById('s-spicy-key-save').addEventListener('click', () => {
  const value = /** @type {HTMLInputElement} */ (document.getElementById('s-spicy-key')).value.trim()
  if (value) saveSpicyKey(value)
})
document.getElementById('s-spicy-key-clear').addEventListener('click', () => saveSpicyKey(null))
document.getElementById('s-spicy-key-docs').addEventListener('click', () => window.cascade.shell.openExternal('https://developers.spicylyrics.org/docs'))

/** Full URL of the plugin's lyrics GET/POST route for an item. */
function cascadeLyricsUrl(itemId) {
  return `${jf.url}/${CascadeCore.cascadeLyricsPath(_cascadePluginApi, itemId)}`
}

/**
 * GET {jf.url}/CascadeServer/Info with the normal auth header, and on a 404
 * the pre-rename CascadeLyrics/Info. The plugin exposes that route for
 * exactly this question, so reaching it is the answer and the body is not
 * read here.
 *
 * Neither of the obvious alternatives works. Jellyfin's own /Plugins needs
 * elevation and Cascade signs in as a normal user, and the lyrics route
 * cannot answer either, since a server without the plugin and a track with
 * genuinely no lyrics both return a bare 404.
 */
function probeCascadePlugin() {
  _cascadePluginApi = 'server'
  _cascadePluginCaps = new Set()
  _resetExplicit()
  const statusOf = async (path) => {
    try {
      const r = await jfFetch(`${jf.url}/${path}`, {
        headers: CascadeCore.authHeaders(jf),
        signal: AbortSignal.timeout(8000),
      })
      // The body is only read for the capability list; the status alone is
      // still the presence answer, so a body that fails to parse costs nothing.
      if (r.ok) {
        try {
          const info = await r.json()
          const caps = info?.capabilities
          if (Array.isArray(caps)) _cascadePluginCaps = new Set(caps.filter(c => typeof c === 'string'))
          // Whether this user's Spotify links apply to the whole server. A plugin
          // from before the setting existed sends nothing, and there any user could.
          _spotifyLinkServerWide = info?.spotifyLinkServerWide !== false
        } catch {}
      }
      return r.status
    } catch {
      return null  // network failure reads as 'unknown'
    }
  }
  _cascadePluginProbed = (async () => {
    const serverStatus = await statusOf('CascadeServer/Info')
    const legacyStatus = serverStatus === 404 ? await statusOf('CascadeLyrics/Info') : null
    const { probe, api } = CascadeCore.resolveCascadePluginProbe(serverStatus, legacyStatus)
    _cascadePluginApi = api
    // 'unknown' (401, 5xx, network failure) is treated as present: never grey
    // out a working feature because the network hiccuped.
    _cascadePluginAbsent = probe === 'absent'
    _applyCascadePluginAvailability()
    fetchServerStyle()
    // Rows drawn before the answer came in ask now.
    if (_cascadePluginCaps.has('explicit')) {
      document.querySelectorAll('.track-row[data-id]').forEach(row => explicitBadgeHtml(row.dataset.id))
      if (queue[queueIndex]) explicitBadgeHtml(queue[queueIndex].Id)
    }
  })()
  return _cascadePluginProbed
}

// ── Display preferences ──────────────────────────────────────────────────────
// The cover and color transitions (set in Now Playing's customization editor),
// the plain lyrics size, and the Cascade Server extras in Settings > Playback,
// under the keys the Apple apps' DisplayPrefs uses, so their settings import
// is a copy.
const displayPrefs = {
  coverSlice: true, coverSliceIn: 0.8, coverSlideOut: 1.2,
  coverSliceStyle: 'slice', coverSliceDirection: 'up-left', coverSliceHold: 'half', coverSliceEasing: 'smooth',
  coverSliceSeam: 'white', coverSliceGlow: 1, coverSliceShadow: 1,
  colorFade: true, colorFadeSeconds: 0.7,
  // A skip's short transition (Smooth skips, see skipTo).
  skipTransitions: true,
  explicitMarks: true, videoCovers: true,
  // Unsynced lyrics' size in Now Playing, apart from the synced size
  // (lyricScale), since a whole page of plain text reads better smaller.
  plainLyricScale: 0.55,
}
// The shipped values, for the customization editor's "Reset this tab".
const DISPLAY_PREF_DEFAULTS = Object.freeze({ ...displayPrefs })
const DISPLAY_PREF_RANGES = { plainLyricScale: [0.3, 1.4], coverSliceIn: [0.2, 2], coverSlideOut: [0.3, 3], coverSliceGlow: [0, 2], coverSliceShadow: [0, 2], colorFadeSeconds: [0.2, 2] }
const DISPLAY_PREF_CHOICES = {
  coverSliceStyle: ['slice', 'fade', 'push'],
  coverSliceDirection: ['up-left', 'up', 'up-right', 'right', 'down-right', 'down', 'down-left', 'left'],
  coverSliceHold: ['half', 'old', 'new', 'sweep'],
  coverSliceEasing: ['smooth', 'snappy', 'linear'],
  coverSliceSeam: ['white', 'accent', 'off'],
}
// Sliders: [element id, key, shown as seconds or percent]
const DISPLAY_PREF_SLIDERS = [
  ['cover-slice-in', 'coverSliceIn', 's'], ['cover-slide-out', 'coverSlideOut', 's'],
  ['cover-slice-glow', 'coverSliceGlow', '%'], ['cover-slice-shadow', 'coverSliceShadow', '%'],
  ['color-fade-seconds', 'colorFadeSeconds', 's'], ['plain-lyric-scale', 'plainLyricScale', '%'],
]
const DISPLAY_PREF_MENUS = [
  ['cover-slice-style', 'coverSliceStyle'], ['cover-slice-direction', 'coverSliceDirection'],
  ['cover-slice-hold', 'coverSliceHold'], ['cover-slice-easing', 'coverSliceEasing'], ['cover-slice-seam', 'coverSliceSeam'],
]
const _prefText = (v, unit) => unit === '%' ? `${Math.round(v * 100)}%` : `${v.toFixed(1)}s`

async function loadDisplayPrefs() {
  for (const key of Object.keys(displayPrefs)) {
    const v = await window.cascade.store.get(key)
    const range = DISPLAY_PREF_RANGES[key], choices = DISPLAY_PREF_CHOICES[key]
    if (range) { if (typeof v === 'number' && Number.isFinite(v)) displayPrefs[key] = Math.min(range[1], Math.max(range[0], v)) }
    else if (choices) { if (choices.includes(v)) displayPrefs[key] = v }
    else if (typeof v === 'boolean') displayPrefs[key] = v
  }
  _syncDisplayPrefControls()
}

function _syncDisplayPrefControls() {
  const set = (id, on) => { const el = document.getElementById(id); if (el) el.checked = on }
  set('cover-slice-toggle', displayPrefs.coverSlice)
  set('color-fade-toggle', displayPrefs.colorFade)
  set('skip-transitions-toggle', displayPrefs.skipTransitions)
  set('explicit-marks-toggle', displayPrefs.explicitMarks)
  set('video-covers-toggle', displayPrefs.videoCovers)
  for (const [id, key, unit] of DISPLAY_PREF_SLIDERS) {
    const el = document.getElementById(id)
    if (el) { el.value = String(displayPrefs[key]); document.getElementById(id + '-value').textContent = _prefText(displayPrefs[key], unit) }
  }
  for (const [id, key] of DISPLAY_PREF_MENUS) { const el = document.getElementById(id); if (el) el.value = displayPrefs[key] }
  document.documentElement.style.setProperty('--np-plain-lyric-scale', String(displayPrefs.plainLyricScale))
  // Only the rows that do something for the style picked.
  const on = displayPrefs.coverSlice, style = displayPrefs.coverSliceStyle
  const shown = {
    'cover-slice-style-row': on, 'cover-slice-in-row': on && displayPrefs.coverSliceHold !== 'sweep', 'cover-slide-out-row': on,
    'cover-slice-direction-row': on && style !== 'fade', 'cover-slice-hold-row': on, 'cover-slice-easing-row': on,
    'cover-slice-seam-row': on && style === 'slice', 'cover-slice-glow-row': on && style === 'slice' && displayPrefs.coverSliceSeam !== 'off',
    'cover-slice-shadow-row': on && style !== 'fade', 'color-fade-seconds-row': displayPrefs.colorFade,
  }
  for (const [row, show] of Object.entries(shown)) { const el = document.getElementById(row); if (el) el.style.display = show ? '' : 'none' }
}

async function setDisplayPref(key, value) {
  displayPrefs[key] = value
  _syncDisplayPrefControls()
  // A cover setting replays the editor's preview. Sliders only report a
  // change when let go, so a drag replays once, not on every step.
  if (key.startsWith('coverSli')) _cePreviewSoon()
  await window.cascade.store.set(key, value)
  _ceChanged()
}

for (const [id, key] of [['cover-slice-toggle', 'coverSlice'], ['color-fade-toggle', 'colorFade'], ['skip-transitions-toggle', 'skipTransitions'], ['explicit-marks-toggle', 'explicitMarks'], ['video-covers-toggle', 'videoCovers']]) {
  document.getElementById(id)?.addEventListener('change', e => setDisplayPref(key, e.target.checked))
}
for (const [id, key, unit] of DISPLAY_PREF_SLIDERS) {
  const el = document.getElementById(id)
  el?.addEventListener('input', e => { document.getElementById(id + '-value').textContent = _prefText(parseFloat(e.target.value), unit) })
  el?.addEventListener('change', e => setDisplayPref(key, parseFloat(e.target.value)))
}
for (const [id, key] of DISPLAY_PREF_MENUS) {
  document.getElementById(id)?.addEventListener('change', e => setDisplayPref(key, e.target.value))
}

// ── Cover slice on crossfade ─────────────────────────────────────────────────
//
// docs/demos/album-art-slice-transition.html, for real: when a crossfade
// starts, the outgoing cover (on top of the incoming one) is cut from the
// bottom-right corner to the diagonal, holds half and half while both songs
// play, then the cut slides off through the top-left corner once the old song
// has faded. A crossfade cut short (pause, seek) slides it out at once. A skip
// while the cut is on screen lays the skipped song's cover under it and sweeps
// both off, one behind the other, so the next cover is only ever uncovered
// whole and never swapped in under the old one (trailArtSlice).
// Skipped for two songs with the same cover, for video, and under Reduce Motion.
// That is the default; the customization editor's Crossfade tab picks the
// style (slice, fade, push), direction, hold, easing, seam and shadow
// (displayPrefs), and previews it on a slice of its own (_cePreviewPlay).
//
// Built for the compositor, since the handover and the fade's end are the
// busiest moments the app has (new title, lyrics, cover colors, the next
// stream loading): the cut is a turned frame whose clipping box slides across
// it while the cover inside slides back the other way, so the cover stays put
// and only its visible part moves. Every change is a transform or opacity run
// by element.animate(), which the GPU keeps going while the main thread is
// busy; nothing is repainted per frame (the edge shadow is a box-shadow that
// moves with the box). The outgoing cover is a copy of the image already on
// screen, so nothing decodes, and the cut waits (briefly) for the new cover
// to decode before it starts uncovering it.
//
// Every style runs on one number, s: 2 is all old cover, 1 half and half, 0
// all new. For the default slice it is the cut x + y = s across the unit square.
const SLICE_WAIT_FOR_COVER = 0.4
// [cut in, slide out]: ease-out then ease-in-out, in cubic (the demo's) or quint.
const SLICE_EASINGS = {
  smooth: ['cubic-bezier(0.33, 1, 0.68, 1)', 'cubic-bezier(0.65, 0, 0.35, 1)'],
  snappy: ['cubic-bezier(0.22, 1, 0.36, 1)', 'cubic-bezier(0.83, 0, 0.17, 1)'],
  linear: ['linear', 'linear'],
}
// Where the cut waits while both songs play; a sweep never waits.
const SLICE_HOLDS = { half: 1, old: 1.4, new: 0.6, sweep: 0 }
// The way the cut, or the old cover, moves.
const SLICE_MOVES = { 'up-left': [-1, -1], up: [0, -1], 'up-right': [1, -1], right: [1, 0], 'down-right': [1, 1], down: [0, 1], 'down-left': [-1, 1], left: [-1, 0] }
// A skipped song's cover trails the cut out by this much of the slide-out time.
const SLICE_TRAIL = 1.4
// The real crossfade's slice, on Now Playing's art and the player bar's. Every
// slice keeps its own state and touches only its own hosts and layers, so the
// customization editor's preview (its own slice on its own card) and a real
// crossfade can run at the same time without meeting.
let _slice = null

function _sliceGeometry() {
  const [mx, my] = SLICE_MOVES[displayPrefs.coverSliceDirection] || SLICE_MOVES['up-left']
  const diagonal = mx !== 0 && my !== 0
  return {
    // The frame's x axis points where the cut comes from; a diagonal frame is
    // the square's diagonal long, so its cut sweeps corner to corner.
    turn: Math.atan2(-my, -mx) * 180 / Math.PI,
    frame: diagonal ? 141.4214 : 100,
    // ponytail: a diagonal push would leave two corners empty, so it pushes sideways only.
    push: diagonal ? [mx, 0] : [mx, my],
  }
}

/** Every animated property for s, by the slice-* class it goes on; each is a
 *  straight line in s, so the animations' easing is the cut's own. */
function _sliceFrames(s, g) {
  const t = s / 2 - 1, pc = n => `${(n * 100).toFixed(4)}%`
  const [px, py] = g.push
  return {
    keep: { transform: `translateX(${pc(t)})` },
    img: { transform: `translateX(${pc(-t * g.frame / 100)}) rotate(${-g.turn}deg)` },
    seam: { transform: `translateX(${pc(t)})` },
    fade: { opacity: s / 2 },
    old: { transform: `translate(${pc(-t * px)}, ${pc(-t * py)})` },
    new: { transform: `translate(${pc((-t - 1) * px)}, ${pc((-t - 1) * py)})` },
  }
}

function _sliceCopy(img, cls) {
  const copy = img.cloneNode(false)
  copy.removeAttribute('onerror'); copy.removeAttribute('id'); copy.className = cls; copy.alt = ''
  return copy
}

/** The real crossfade's slice: the outgoing cover laid over Now Playing's art
 *  and the player bar's, uncut. False when there is nothing to cut, or the
 *  animation is switched off. */
function prepareCrossfadeSlice() {
  _removeArtSlice(_slice)
  if (!displayPrefs.coverSlice || matchMedia('(prefers-reduced-motion: reduce)').matches) return false
  _slice = prepareArtSlice([document.getElementById('ov-art'), document.getElementById('np-art')])
  return !!_slice
}

/** Lays the cover each host shows over it, uncut, and returns the new slice's
 *  state, or null when no host has a cover to cut. The first host is the one
 *  whose incoming cover startArtSlice waits for. */
function prepareArtSlice(hosts) {
  const style = DISPLAY_PREF_CHOICES.coverSliceStyle.includes(displayPrefs.coverSliceStyle) ? displayPrefs.coverSliceStyle : 'slice'
  const geo = _sliceGeometry()
  const layers = []
  for (const host of hosts) {
    const shown = host?.querySelector(':scope > img')
    if (!shown?.complete || !shown.naturalWidth) continue
    const layer = _sliceLayer(host, shown, style, geo)
    host.appendChild(layer)
    layers.push(layer)
  }
  if (!layers.length) return null
  return { hosts, layers, trails: [], style, geo, holdEnd: 0, sliding: false, anims: [], from: 2, to: 2, under: null, trailAnims: [], running: 0, removed: false }
}

/** One host's copy of `shown`, uncut (s = 2), in the chosen style. */
function _sliceLayer(host, shown, style, geo) {
  const seamColor = displayPrefs.coverSliceSeam === 'accent' ? 'var(--accent)' : '#fff'
  const glow = displayPrefs.coverSliceGlow
  const layer = document.createElement('div')
  layer.className = 'art-slice'
  layer.setAttribute('aria-hidden', 'true')
  layer.style.setProperty('--slice-shadow-a', String(0.45 * displayPrefs.coverSliceShadow))
  if (style === 'slice') {
    // The player bar's thumbnail is too small for the glowing seam.
    const seam = host.id !== 'np-art' && displayPrefs.coverSliceSeam !== 'off'
    layer.innerHTML = `<div class="slice-frame"><div class="slice-keep"></div>${seam ? '<div class="slice-seam"></div>' : ''}</div>`
    const frame = layer.querySelector('.slice-frame'), inner = 10000 / geo.frame
    Object.assign(frame.style, { width: `${geo.frame}%`, height: `${geo.frame}%`, left: `${(100 - geo.frame) / 2}%`, top: `${(100 - geo.frame) / 2}%`, transform: `rotate(${geo.turn}deg)` })
    const img = _sliceCopy(shown, 'slice-img')
    Object.assign(img.style, { width: `${inner}%`, height: `${inner}%`, left: `${(100 - inner) / 2}%`, top: `${(100 - inner) / 2}%` })
    layer.querySelector('.slice-keep').appendChild(img)
    if (seam) {
      layer.style.setProperty('--seam-color', seamColor)
      layer.style.setProperty('--seam-glow', `0 0 ${6 * glow}px ${2 * glow}px color-mix(in srgb, ${seamColor} ${Math.min(100, 65 * glow)}%, transparent)`)
    }
  } else {
    layer.appendChild(_sliceCopy(shown, style === 'fade' ? 'slice-fade' : 'slice-old'))
  }
  for (const [part, props] of Object.entries(_sliceFrames(2, geo))) {
    const el = layer.querySelector('.slice-' + part)
    if (el) Object.assign(el.style, props)
  }
  return layer
}

/** Starts the cut once the new cover can be shown under it (or after a short wait). */
async function startArtSlice(slice, fadeSecs) {
  if (!slice) return
  slice.holdEnd = performance.now() + fadeSecs * 1000
  const incoming = slice.hosts[0]?.querySelector(':scope > img')
  if (incoming) {
    await Promise.race([incoming.decode().catch(() => {}), new Promise(r => setTimeout(r, SLICE_WAIT_FOR_COVER * 1000))])
  }
  if (slice.removed || slice.sliding) return
  // A push carries a copy of the new cover in behind the old one.
  if (slice.style === 'push') {
    for (const layer of slice.layers) {
      const shown = layer.parentElement?.querySelector(':scope > img')
      if (!shown) continue
      const copy = _sliceCopy(shown, 'slice-new')
      Object.assign(copy.style, _sliceFrames(2, slice.geo).new)
      layer.appendChild(copy)
    }
  }
  // A skip's slice sweeps straight across at its own length (_beginSkip).
  if (slice.sweepMs) {
    const easeOut = (SLICE_EASINGS[displayPrefs.coverSliceEasing] || SLICE_EASINGS.smooth)[1]
    _animateSlice(slice, 2, 0, slice.sweepMs, easeOut, 'in').then(() => endArtSlice(slice))
    return
  }
  const left = slice.holdEnd - performance.now()
  if (left <= 0) { endArtSlice(slice); return }
  const [easeIn, easeOut] = SLICE_EASINGS[displayPrefs.coverSliceEasing] || SLICE_EASINGS.smooth
  const hold = SLICE_HOLDS[displayPrefs.coverSliceHold] ?? 1
  if (hold === 0) _animateSlice(slice, 2, 0, left, easeOut, 'in')
  else _animateSlice(slice, 2, hold, Math.min(displayPrefs.coverSliceIn * 1000, left), easeIn, 'in')
}

/** The old song is gone, or its fade was cut short: slide the cut out from wherever it is. */
function endArtSlice(slice) {
  if (!slice || slice.sliding) return
  slice.sliding = true
  // Where the cut is now: on its way in, holding, or not started (from = to = 2).
  const p = slice.anims[0]?.effect?.getComputedTiming().progress
  const s = slice.from + (slice.to - slice.from) * (p ?? 1)
  if (s <= 0.001) { if (!slice.running) _removeArtSlice(slice); return }
  const easeOut = (SLICE_EASINGS[displayPrefs.coverSliceEasing] || SLICE_EASINGS.smooth)[1]
  slice.running++
  _animateSlice(slice, s, 0, (slice.slideOutMs ?? displayPrefs.coverSlideOut * 1000) * Math.min(1, s), easeOut, 'out')
    .then(() => _sliceSlid(slice))
}

/** A skip to `item` while the cut is on screen. The cover under the cut (the
 *  song being skipped) is about to be replaced, which used to swap the next
 *  cover in under the old one mid-cut. Instead a copy of it goes under the cut
 *  and sweeps off the whole way behind it, so the next cover is uncovered only
 *  once both are gone. Two skips in a row stack a third, and so on. */
function trailArtSlice(slice, item) {
  // Not started yet: this is the crossfade handover's own track change.
  if (!slice || !slice.holdEnd || !item || isVideoItem(item)) return
  const key = item.AlbumId || item.Id
  if (key === slice.under) return
  slice.under = key
  const layers = []
  for (const layer of slice.layers) {
    const host = layer.parentElement
    const shown = host?.querySelector(':scope > img')
    if (!host || !shown?.complete || !shown.naturalWidth) continue
    const trail = _sliceLayer(host, shown, slice.style, slice.geo)
    host.insertBefore(trail, host.querySelector('.art-slice'))
    layers.push(trail)
  }
  if (!layers.length) return
  slice.trails.push(...layers)
  // A push carries the skipped cover in as a copy (.slice-new), part way in
  // at s. The trailing copy takes over from it where it is, at 2 + s (one
  // cover width behind the old one), or the cover would jump into place.
  const pushing = slice.layers.flatMap(l => [...l.querySelectorAll('.slice-new')]).filter(el => el.style.visibility !== 'hidden')
  const p = slice.anims[0]?.effect?.getComputedTiming().progress
  const from = pushing.length ? 2 + slice.from + (slice.to - slice.from) * (p ?? 1) : 2
  for (const el of pushing) el.style.visibility = 'hidden'
  endArtSlice(slice)
  const easeOut = (SLICE_EASINGS[displayPrefs.coverSliceEasing] || SLICE_EASINGS.smooth)[1]
  // A little slower than the cut's slide-out, so the cut above (which has at
  // most one unit of s left against this one's two) always stays ahead of it.
  const anims = _animateLayers(slice, layers, from, 0, (slice.slideOutMs ?? displayPrefs.coverSlideOut * 1000) * SLICE_TRAIL, easeOut, 'out')
  slice.trailAnims.push(...anims)
  slice.running++
  Promise.all(anims.map(x => x.finished.catch(() => {}))).then(() => _sliceSlid(slice))
}

/** One slide-out finished; the slice goes once every one has. */
function _sliceSlid(slice) {
  if (!slice.removed && --slice.running <= 0) _removeArtSlice(slice)
}

function _animateSlice(slice, from, to, ms, easing, phase) {
  for (const a of slice.anims) { a.commitStyles?.(); a.cancel() }
  slice.from = from; slice.to = to
  slice.anims = _animateLayers(slice, slice.layers, from, to, ms, easing, phase)
  return Promise.all(slice.anims.map(x => x.finished.catch(() => {})))
}

function _animateLayers(slice, layers, from, to, ms, easing, phase) {
  const anims = []
  const a = _sliceFrames(from, slice.geo), b = _sliceFrames(to, slice.geo)
  const opts = { duration: Math.max(1, ms), easing, fill: 'forwards' }
  for (const layer of layers) {
    for (const part of Object.keys(a)) {
      const el = layer.querySelector('.slice-' + part)
      if (el) anims.push(el.animate([a[part], b[part]], opts))
    }
    const seam = layer.querySelector('.slice-seam')
    if (seam) {
      // Bright while the blade moves in, settled while it holds, gone as it leaves.
      const glow = phase === 'in' ? [{ opacity: 1 }, { opacity: 0.55 }] : [{ opacity: 0.55 }, { opacity: 1, offset: 0.3 }, { opacity: 0 }]
      anims.push(seam.animate(glow, { duration: Math.max(1, ms), easing: 'linear', fill: 'forwards' }))
    }
  }
  return anims
}

function _removeArtSlice(slice) {
  if (!slice || slice.removed) return
  slice.removed = true
  for (const a of [...slice.anims, ...slice.trailAnims]) a.cancel()
  for (const el of [...slice.layers, ...slice.trails]) el.remove()
  if (_slice === slice) _slice = null
}

// ── Server style ─────────────────────────────────────────────────────────────
//
// A look an admin sets in Cascade Server for everyone (src/core/server-style.ts):
// layered over each person's own settings when they are applied, never saved
// into them. Cached so the next launch starts with it.
let _serverStyle = CascadeCore.SERVER_STYLE_OFF

async function fetchServerStyle() {
  let next = CascadeCore.SERVER_STYLE_OFF, raw = null
  if (_cascadePluginCaps.has('server-style')) {
    try {
      const r = await jfFetch(`${jf.url}/CascadeServer/Style`, { headers: CascadeCore.authHeaders(jf), signal: AbortSignal.timeout(8000) })
      if (!r.ok) return   // keep what we have rather than drop a style on a hiccup
      raw = await r.json()
      next = CascadeCore.parseServerStyle(raw)
    } catch { return }
  }
  _applyServerStyleAdminUi()
  if (JSON.stringify(next) === JSON.stringify(_serverStyle)) { applyServerStyleLocks(); return }
  _serverStyle = next
  await window.cascade.store.set('serverStyle', next.mode === 'off' ? null : JSON.stringify(raw))
  await reapplyLook()
}

async function reapplyLook() {
  await loadTheme()
  await loadNpTuning()
  await loadLyricStyle()
}

/** Controls the server enforces are shown but cannot be changed, with a line
 *  saying why. Light/dark mode and the font are always the person's own. */
function applyServerStyleLocks() {
  const theme = CascadeCore.serverStylePart(_serverStyle, 'theme') === 'force'
  const lyrics = CascadeCore.serverStylePart(_serverStyle, 'lyrics') === 'force'
  for (const id of ['grad-start', 'grad-end', 'toggle-album-art', 'tp-bg-dim', 'tp-bg-blend']) {
    const el = document.getElementById(id); if (el) el.disabled = theme
  }
  document.querySelector('.tp-colors')?.classList.toggle('server-locked', theme)
  document.getElementById('tp-presets')?.classList.toggle('server-locked', theme)
  for (const el of document.querySelectorAll('#tp-lyric-knobs input, #tp-lyric-knobs button, #tp-lyric-scale')) el.disabled = lyrics
  // The editor says it once per section rather than once per control.
  for (const sect of document.querySelectorAll('.ce-sect[data-lock]')) sect.classList.toggle('locked', sect.dataset.lock === 'theme' ? theme : lyrics)
  const note = document.getElementById('tp-server-style-note')
  if (note) {
    const what = theme && lyrics ? 'colors and lyrics look' : theme ? 'colors' : lyrics ? 'lyrics look' : ''
    note.hidden = !what
    note.textContent = what ? `Your server sets the ${what} for everyone.` : ''
  }
}

function _applyServerStyleAdminUi() {
  const box = document.getElementById('tp-server-style')
  if (!box) return
  box.hidden = !(jf.isAdmin && _cascadePluginCaps.has('server-style'))
  const status = document.getElementById('tp-server-style-status')
  const s = _serverStyle
  status.textContent = s.mode === 'off' ? 'Off. Everyone uses their own look.'
    : s.mode === 'default' ? `Offered: "${s.preset?.name}" is the look for anything people have not changed.`
    : `Enforced: "${s.preset?.name}" is over everyone's own ${[s.enforceTheme && 'colors', s.enforceLyrics && 'lyrics'].filter(Boolean).join(' and ')}.`
  document.getElementById('tp-server-style-off').disabled = s.mode === 'off'
}

async function publishServerStyle(mode) {
  let body = { mode }
  if (mode !== 'off') {
    const preset = currentPreset()
    if (!preset) return
    if (mode === 'enforced') {
      const parts = [preset.theme && 'colors', preset.lyrics && 'lyrics look'].filter(Boolean).join(' and ')
      const ok = await showChoice('Enforce for everyone?', `Everyone on this server gets this ${parts} over their own, and cannot change it until you turn it off. Light or dark mode and the font stay theirs.`, 'Enforce', 'Cancel')
      if (!ok) return
    }
    body = { mode, enforce: { theme: mode === 'enforced' && !!preset.theme, lyrics: mode === 'enforced' && !!preset.lyrics }, preset }
  }
  const r = await jfFetch(`${jf.url}/CascadeServer/Style`, {
    method: mode === 'off' ? 'DELETE' : 'PUT',
    headers: { ...CascadeCore.authHeaders(jf), 'Content-Type': 'application/json' },
    body: mode === 'off' ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(10000),
  })
  if (!r.ok) {
    let msg = `The server said ${r.status}.`
    try { msg = (await r.json())?.error || msg } catch {}
    showNotice(`Could not set the server style.\n\n${msg}`, 'Server style')
    return
  }
  await fetchServerStyle()
}

document.getElementById('tp-server-style-default').addEventListener('click', () => runPresetAction(() => publishServerStyle('default')))
document.getElementById('tp-server-style-enforce').addEventListener('click', () => runPresetAction(() => publishServerStyle('enforced')))
document.getElementById('tp-server-style-off').addEventListener('click', () => runPresetAction(() => publishServerStyle('off')))

// ── Explicit marks ───────────────────────────────────────────────────────────
//
// Jellyfin has no explicit flag; Cascade Server (the `explicit` capability)
// works one out per song and answers from what it already knows, queueing the
// rest. A row asks for its song as it is drawn; the asks are gathered into one
// request per screenful (the plugin takes 500 at a time) and, once per
// session, the answer's explicit songs get an E in whatever is on screen.
const EXPLICIT_BADGE = '<span class="explicit-badge" title="Explicit" aria-label="Explicit">E</span>'
let _explicitIds = new Set()
let _explicitAsked = new Set()
let _explicitPending = []
let _explicitTimer = null

function _resetExplicit() {
  _explicitIds = new Set(); _explicitAsked = new Set(); _explicitPending = []
  clearTimeout(_explicitTimer); _explicitTimer = null
}

/** The badge for a song already known to be explicit, else '' (and the song
 *  is asked about, once). '' without the plugin's explicit marks. */
function explicitBadgeHtml(id) {
  if (!id || !displayPrefs.explicitMarks || !_cascadePluginCaps.has('explicit')) return ''
  if (_explicitIds.has(id)) return EXPLICIT_BADGE
  if (!_explicitAsked.has(id)) {
    _explicitAsked.add(id)
    _explicitPending.push(id)
    _explicitTimer ??= setTimeout(_flushExplicit, 60)
  }
  return ''
}

async function _flushExplicit() {
  _explicitTimer = null
  const asked = _explicitAsked
  while (_explicitPending.length) {
    const ids = _explicitPending.splice(0, 500)
    try {
      const r = await jfFetch(`${jf.url}/CascadeServer/Explicit/Query`, {
        method: 'POST',
        headers: { ...CascadeCore.authHeaders(jf), 'Content-Type': 'application/json' },
        body: JSON.stringify({ Ids: ids }),
        signal: AbortSignal.timeout(10000),
      })
      if (!r.ok || asked !== _explicitAsked) continue   // failed, or signed out meanwhile
      const items = (await r.json())?.items
      for (const [id, rating] of Object.entries(items || {})) {
        if (rating === 'explicit' && !_explicitIds.has(id)) { _explicitIds.add(id); _showExplicit(id) }
      }
    } catch { /* best effort: no badge is the same as before */ }
  }
}

function _showExplicit(id) {
  const add = el => { if (el && !el.querySelector('.explicit-badge')) el.insertAdjacentHTML('beforeend', EXPLICIT_BADGE) }
  document.querySelectorAll(`.track-row[data-id="${CSS.escape(id)}"] .track-title`).forEach(add)
  if (queue[queueIndex]?.Id === id) {
    add(document.querySelector('#np-info .np-title'))
    add(document.querySelector('#ov-track .np-scroll-inner'))
    refreshMarquees()   // the badge widens the line, and a scrolling copy needs it too
  }
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
    showToast('Server-only lyrics mode turned off - the Cascade Server plugin was not found on this server')
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
// ── Link a Spotify track (Spicy Lyrics) ───────────────────────────────────────
// Cascade Server finds a song's Spotify id itself (ListenBrainz); for the songs
// it cannot, or where it picked the wrong release, a user pastes the link here.
// Stored on the server for everyone, as saved lyrics are.

function _canLinkSpotify() {
  const item = queue[queueIndex]
  return !!item && !isVideoItem(item) && !_cascadePluginAbsent && _cascadePluginCaps.has('spotify-link')
}

/** The empty lyrics state's way in, when linking is possible. */
function _linkSpotifyButton() {
  return _canLinkSpotify() ? '<div><button type="button" class="lyrics-link-spotify">Link a Spotify track</button></div>' : ''
}

let _spotifyLinkItem = null

// Links this user made for themselves, when the server does not let them link
// songs for everyone: kept on this computer (store key spotifyLinks, item id to
// Spotify id) and sent with each lyrics request, which the server uses for
// that request only. Store values are untrusted, so each entry is re-checked.
let _localSpotifyLinks = {}
window.cascade.store.get('spotifyLinks').then(raw => {
  try {
    const obj = typeof raw === 'string' ? JSON.parse(raw) : raw
    for (const [item, id] of Object.entries(obj || {})) {
      const clean = CascadeCore.parseSpotifyTrackId(id)
      if (/^[0-9a-f]{32}$/i.test(item) && clean) _localSpotifyLinks[item] = clean
    }
  } catch {}
})
function _saveLocalSpotifyLinks() {
  window.cascade.store.set('spotifyLinks', JSON.stringify(_localSpotifyLinks))
}
/** `&spotifyId=...` for a song this user linked for themselves, or ''. */
function _localSpotifyParam(itemId) {
  const id = _localSpotifyLinks[itemId]
  return id ? `&spotifyId=${encodeURIComponent(id)}` : ''
}

async function openSpotifyLinkModal() {
  document.getElementById('lyrics-source-dropdown').classList.remove('open')
  const item = queue[queueIndex]
  if (!item || !_canLinkSpotify()) return
  markTipSeen('lyrics-link')
  _spotifyLinkItem = item
  const input = document.getElementById('spotify-link-input')
  const remove = document.getElementById('spotify-link-remove')
  input.value = ''
  remove.hidden = true
  document.getElementById('spotify-link-error').textContent = ''
  document.getElementById('spotify-link-desc').textContent = _spotifyLinkServerWide
    ? "Paste this song's Spotify link and Cascade Server will look for Spicy Lyrics with it. The link is saved on the server, so it works for everyone there."
    : "Paste this song's Spotify link and Cascade will look for Spicy Lyrics with it. The link is saved on this computer, for you only; a server admin can let you link songs for everyone."
  document.getElementById('spotify-link-modal').classList.remove('hidden')
  input.focus()
  const mine = _localSpotifyLinks[item.Id]
  if (mine) {
    input.value = `https://open.spotify.com/track/${mine}`
    remove.hidden = false
  }
  if (mine || !_spotifyLinkServerWide) return
  // What it is linked to now: a hand link can be removed, handing the song
  // back to the automatic lookup.
  try {
    const r = await jfFetch(`${jf.url}/CascadeServer/SpotifyId/${item.Id}`, { headers: CascadeCore.authHeaders(jf) })
    const cur = r.ok ? await r.json() : null
    if (_spotifyLinkItem !== item) return
    if (cur?.spotifyId && !input.value) input.value = `https://open.spotify.com/track/${cur.spotifyId}`
    remove.hidden = !cur?.manual
  } catch {}
}

function closeSpotifyLinkModal() {
  document.getElementById('spotify-link-modal').classList.add('hidden')
  _spotifyLinkItem = null
}

async function _spotifyLinkRequest(method, body) {
  const item = _spotifyLinkItem
  const error = document.getElementById('spotify-link-error')
  try {
    const r = await jfFetch(`${jf.url}/CascadeServer/SpotifyId/${item.Id}`, {
      method,
      headers: CascadeCore.authHeaders(jf, body ? { 'Content-Type': 'application/json' } : {}),
      body: body ? JSON.stringify(body) : undefined,
    })
    if (!r.ok) { error.textContent = await CascadeCore.readErrorMessage(r); return }
  } catch {
    error.textContent = 'Could not reach the server.'
    return
  }
  closeSpotifyLinkModal()
  _reloadLyricsFor(item.Id)
}

document.getElementById('spotify-link-save').addEventListener('click', () => {
  const id = CascadeCore.parseSpotifyTrackId(document.getElementById('spotify-link-input').value)
  if (!id) {
    document.getElementById('spotify-link-error').textContent = 'That is not a Spotify track link. Copy it from Share → Copy Song Link.'
    return
  }
  if (!_spotifyLinkServerWide) { _setLocalSpotifyLink(id); return }
  _spotifyLinkRequest('POST', { spotifyId: id })
})

function _setLocalSpotifyLink(id) {
  const item = _spotifyLinkItem
  if (id) _localSpotifyLinks[item.Id] = id
  else delete _localSpotifyLinks[item.Id]
  _saveLocalSpotifyLinks()
  closeSpotifyLinkModal()
  _reloadLyricsFor(item.Id)
}
document.getElementById('spotify-link-input').addEventListener('keydown', e => {
  if (e.key === 'Enter') document.getElementById('spotify-link-save').click()
  if (e.key === 'Escape') closeSpotifyLinkModal()
})
document.getElementById('spotify-link-remove').addEventListener('click', () => {
  // A personal link is removed here; a server-wide one on the server.
  if (_localSpotifyLinks[_spotifyLinkItem?.Id] || !_spotifyLinkServerWide) _setLocalSpotifyLink(null)
  else _spotifyLinkRequest('DELETE')
})
document.getElementById('spotify-link-cancel').addEventListener('click', closeSpotifyLinkModal)
document.getElementById('lsd-spotify-link').addEventListener('click', e => { e.stopPropagation(); openSpotifyLinkModal() })
document.addEventListener('click', e => {
  if (e.target.closest('.lyrics-link-spotify')) openSpotifyLinkModal()
})

async function _reloadLyricsFor(itemId) {
  const cur = queue[queueIndex]
  _lyricsCache.delete(itemId ?? cur?.Id)
  _lyricsInflight.delete(itemId ?? cur?.Id)   // a search from before the change must not be joined
  if (!cur || (itemId != null && itemId !== cur.Id)) return
  lyricsData = []; lastLyricsIdx = -1; lastOverlayLyricsIdx = -1; _lyricsScanIdx = 0; _ovLyricsScanIdx = 0
  await fetchLyrics()
  // fetchLyrics() only redraws the side panel. Now Playing's lyrics have their
  // own renderer, so a Spotify link saved from there kept showing the old
  // lyrics until the view was closed and reopened. After the fetch, not
  // alongside it: both bump _lyricsFetchGen, and the later one wins.
  if (queue[queueIndex] !== cur) return   // the song changed meanwhile
  if (overlayOpen && overlayLyricsOpen) renderOverlayLyrics()
}

// The editor writes straight to the server from its own window, so without this the
// cache below keeps handing back the copy from before the edit.
window.cascade.lyricsEditor.onSaved(itemId => _reloadLyricsFor(itemId))

// DevTools helper for testing SpicyLyrics before the plugin can match tracks to
// Spotify ids on its own:  cascadeDebug.spicy('<spotify track id>')
// Asks Cascade Server's admin-only test route (the plugin fetches with the
// server's key; the key never comes near this window), runs the real
// converter, and shows the result as the playing track's lyrics, credit and
// all, exactly as the real path would. Session only: the next track, or a
// reload of this one, goes back to normal. Needs an admin account.
//   cascadeDebug.spicy()           no id: look the playing track up on MusicBrainz first
//   cascadeDebug.spotifyId()       just the lookup, for the playing track
window.cascadeDebug = {
  // Try the crossfade cover slice without waiting for one:
  //   cascadeDebug.artSlice()            the previous song's cover over this one, a 6 s fade
  //   cascadeDebug.artSlice(url, 4)      any image; cascadeDebug.artSliceCut() cuts it short
  artSlice(url, fadeSecs = 6) {
    // The cover on screen goes out; `url` (or the previous song's cover) comes in.
    const prev = queue[queueIndex - 1]
    const src = url || (prev && artUrl(prev.AlbumId || prev.Id, prev.AlbumPrimaryImageTag || prev.ImageTags?.Primary))
    if (!src) { console.warn('[cascadeDebug] no previous song with a cover; pass an image url'); return }
    if (!prepareCrossfadeSlice()) { console.warn('[cascadeDebug] no cover on screen to cut'); return }
    _setArtStill(document.getElementById('np-art'), src)
    _setArtStill(document.getElementById('ov-art'), src)
    startArtSlice(_slice, fadeSecs)
    setTimeout(() => endArtSlice(_slice), fadeSecs * 1000)
  },
  artSliceCut() { endArtSlice(_slice) },
  // Tune the lyric motion live:  cascadeDebug.lyricMotion({ stiffness: 150 })
  // stiffness: how hard lines are pulled to centre (higher = quicker).
  // damping: how much the movement is resisted (2 * sqrt(stiffness) = settles
  // with no overshoot; less bounces, more crawls). ripple: ms each following
  // line lags behind the one above it in the overlay's fade. Session only;
  // tell Claude the numbers you like and they become the defaults.
  // The scroll spring (stiffness, damping) and the ripple between lines, in
  // ms. Everything else about the lyrics' look and motion is a setting now:
  // Theme > Lyrics (src/core/lyric-style.ts).
  lyricMotion(opts = {}) {
    for (const k of ['stiffness', 'damping', 'ripple']) {
      if (Number.isFinite(opts[k]) && opts[k] >= 0) LYRIC_MOTION[k] = opts[k]
    }
    const critical = 2 * Math.sqrt(LYRIC_MOTION.stiffness)
    console.log(`[cascadeDebug] lyric motion`, { ...LYRIC_MOTION }, `(no-overshoot damping for this stiffness: ${critical.toFixed(1)})`)
    return { ...LYRIC_MOTION }
  },

  // Port of scripts/test-spotify-id.js: search MusicBrainz for the recording,
  // check up to 10 candidates for a Spotify link, and pick the one closest in
  // length to what is playing (the top hit is often a remaster with no link;
  // "I Write Sins Not Tragedies" had it on the 6th). 1.1s between lookups,
  // per MusicBrainz's 1 request/second rule, so a miss can take ~12s.
  // ponytail: debug-only, and a browser cannot set MusicBrainz's requested
  // User-Agent. The real resolver belongs in the plugin (or SpicyLyrics'
  // coming search), where it can.
  async spotifyId(item = queue[queueIndex]) {
    if (!item) return console.warn('[cascadeDebug] Nothing playing.')
    const title = item.Name || ''
    const artist = item.AlbumArtist || item.Artists?.[0] || ''
    const durationMs = (item.RunTimeTicks || 0) / 10_000
    const q = s => `"${s.replace(/["\\]/g, '\\$&')}"`
    const mb = async url => {
      const r = await webFetch(url)
      if (!r.ok) throw new Error(`MusicBrainz HTTP ${r.status}`)
      return r.json()
    }
    console.log(`[cascadeDebug] Looking up "${title}" by ${artist} on MusicBrainz (up to ~12s)...`)
    const search = await mb(`https://musicbrainz.org/ws/2/recording/?query=${encodeURIComponent(`recording:${q(title)} AND artist:${q(artist)}`)}&fmt=json&limit=10`)
    const candidates = search.recordings || []
    if (!candidates.length) { console.warn('[cascadeDebug] No MusicBrainz recording matched.'); return null }
    const hits = []
    for (const c of candidates) {
      await new Promise(r => setTimeout(r, 1100))
      const rec = await mb(`https://musicbrainz.org/ws/2/recording/${c.id}?inc=url-rels&fmt=json`).catch(() => null)
      const rel = (rec?.relations || []).find(r => r.url?.resource?.includes('open.spotify.com/track/'))
      if (rel) hits.push({ spotifyId: rel.url.resource.split('/track/')[1].split(/[?/]/)[0], mbid: c.id, lengthMs: c.length ?? null })
    }
    if (!hits.length) { console.warn(`[cascadeDebug] Checked ${candidates.length} recordings; none has a Spotify link.`); return null }
    // Closest length wins; a candidate with no length sorts last.
    hits.sort((a, b) => (a.lengthMs == null) - (b.lengthMs == null) || Math.abs(a.lengthMs - durationMs) - Math.abs(b.lengthMs - durationMs))
    console.log(`[cascadeDebug] Spotify id ${hits[0].spotifyId} (MusicBrainz recording ${hits[0].mbid}; ${hits.length} of ${candidates.length} candidates had a link)`)
    return hits[0].spotifyId
  },

  async spicy(spotifyId) {
    const cur = queue[queueIndex]
    if (!jf || !cur) return console.warn('[cascadeDebug] Play something first; the lyrics go on the current track.')
    if (!spotifyId) spotifyId = await this.spotifyId(cur)
    if (!spotifyId) return
    const id = String(spotifyId || '').trim().replace(/^spotify:track:/, '').replace(/^https?:\/\/open\.spotify\.com\/track\//, '').split('?')[0]
    const r = await jfFetch(`${jf.url}/CascadeServer/SpicyLyrics/${encodeURIComponent(id)}`, { headers: CascadeCore.authHeaders(jf) })
    const body = await r.json().catch(() => null)
    if (!r.ok) return console.error(`[cascadeDebug] HTTP ${r.status}`, body ?? '(no body; 404 with no body means the plugin is older than this route, 401/403 means not an admin)')
    const conv = CascadeCore.convertSpicyLyrics(body.spicy)
    console.log('[cascadeDebug] raw SpicyLyrics response:', body.spicy)
    if (!conv) return console.error('[cascadeDebug] The converter produced nothing from that response. That is a converter bug worth reporting, with the raw response above.')
    const durationSec = (cur.RunTimeTicks || 0) / 10_000_000
    if (!CascadeCore.spicyFitsTrack(body.spicy, durationSec)) {
      console.warn(`[cascadeDebug] Version mismatch: this sync runs to ${body.spicy?.Body?.EndTime}s but the file is ${durationSec.toFixed(1)}s, so it is for another release and will drift. Loaded anyway so you can see it; normal playback rejects it and falls back to Kugou/LRCLIB. Try the id from Spotify's Share link for the matching release.`)
    }
    const words = conv.lines.reduce((n, l) => n + (l.Words?.length || 0), 0)
    console.log(`[cascadeDebug] ${body.spicy?.Body?.Type} sync, ${conv.lines.length} lines, ${words} timed words`, conv.credit)
    if (lyricsForcedSource && lyricsForcedSource !== 'auto') console.warn('[cascadeDebug] A lyrics source is forced in the pill; set it to Auto or this is overridden on the next fetch.')
    _cachePut(cur.Id, { lines: conv.lines, source: conv.credit.provider, credit: conv.credit, tried: {} })
    lyricsData = []; lastLyricsIdx = -1; lastOverlayLyricsIdx = -1; _lyricsScanIdx = 0; _ovLyricsScanIdx = 0
    fetchLyrics()
    return conv
  },
}

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
    showToast(msg, { level: 'advanced', duration: 3500 })
  } else {
    // All tried sources failed (no result)
    const tried_names = Object.entries(tried).filter(([, v]) => v === 'fail').map(([k]) => k)
    if (tried_names.length) showToast(`No lyrics - ${tried_names.join(', ')} all failed`, { level: 'advanced', duration: 3500 })
  }
}

function updateSourcePills() {
  for (const id of ['lyrics-edit-btn', 'ov-lyrics-edit-btn']) {
    const btn = document.getElementById(id)
    if (btn) btn.title = lyricsCredit ? "Edit in Spicy Lyrics' TTML tool" : 'Edit lyrics'
  }
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
  renderLyricsCredit()
}

/** The always-visible credit line at the foot of each lyrics panel, for
 *  SpicyLyrics lyrics: the provider, then the uploader and maker of a
 *  community sync. Not left to the source pill, which only shows on hover -
 *  the terms want it on screen, not tucked away. Links are https only
 *  (safeCreditUrl) and open in the browser. */
function renderLyricsCredit() {
  const c = lyricsCredit
  const people = c ? [['Uploaded by', c.uploader], ['Synced by', c.maker]].filter(([, p]) => p) : []
  const html = c ? [esc(c.provider), ...people.map(([role, p]) => p.url
    ? `${role} <a href="#" class="lyrics-credit-link" data-url="${esc(p.url)}">${esc(p.name)}</a>`
    : `${role} ${esc(p.name)}`)].join(' · ') : ''
  document.querySelectorAll('.lyrics-credit').forEach(el => {
    el.innerHTML = html
    el.hidden = !html
  })
  pushMiniplayerState()
}

document.addEventListener('click', (e) => {
  const a = e.target.closest?.('.lyrics-credit-link')
  if (!a) return
  e.preventDefault()
  const url = CascadeCore.safeCreditUrl(a.dataset.url)
  if (url) window.cascade.shell.openExternal(url)
})

function _openSourceDropdown(nearEl) {
  const dd   = document.getElementById('lyrics-source-dropdown')
  // Link a Spotify track: only where Cascade Server offers it, and worded for
  // whether Spicy Lyrics already matched (then it is a correction).
  const canLink = _canLinkSpotify()
  dd.querySelectorAll('.lsd-spotify').forEach(el => { el.style.display = canLink ? '' : 'none' })
  document.getElementById('lsd-spotify-label').textContent = lyricsCredit ? 'Change Spotify track…' : 'Link a Spotify track…'
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

// ── Cascade Server plugin one-time info modal ────────────────────────────────
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
  // the plugin is missing. Wait for the probe first so the verdict and the
  // route it picked are both settled.
  await _cascadePluginProbed
  if (_cascadePluginAbsent) {
    showToast('The lyrics editor needs the Cascade Server plugin, which was not found on this server')
    return
  }
  const proceed = await _ensureCascadePluginNotice()
  if (!proceed) return
  // lyricsData holds the playing track's lines - only seed the editor with it when
  // that is actually the track being edited, otherwise let the editor fetch its own.
  // Never from SpicyLyrics (lyricsCredit set): saving writes a permanent .slrc,
  // and its terms allow keeping that data 30 days at most and forbid building
  // an archive of it. The editor then fetches its own, which never asks for it.
  const seed = item.Id === queue[queueIndex]?.Id && !lyricsCredit ? (lyricsData || []) : []
  // Pass `volume`, not audio.volume: mid-crossfade the element is partway
  // through a fade and would hand the editor whatever that transient value is.
  window.cascade.lyricsEditor.open({ item, jf: { ...jf, ...CascadeCore.clientIdentity() }, lyricsData: seed, volume, lyricsUrl: cascadeLyricsUrl(item.Id) })
}

// Spicy Lyrics' own sync editor, its fork of the AMLL TTML Tool, which its
// guides (guides.spicylyrics.org) point makers to. No deep link to a song is
// documented, so it opens on its start page; uploads go through Spicy
// Lyrics' TTML Maker program, not through Cascade.
const SPICY_TTML_TOOL_URL = 'https://tool.community.spicylyrics.org/'

// The lyric views' edit buttons: with Spicy Lyrics on screen they open that
// tool, since Cascade's editor never takes its lyrics (see above). The
// context menu's Edit lyrics still opens Cascade's own editor, for a local
// .slrc of the same song.
;['lyrics-edit-btn', 'ov-lyrics-edit-btn'].forEach(id => {
  const btn = document.getElementById(id)
  if (!btn) return
  btn.addEventListener('click', e => {
    e.stopPropagation()
    if (lyricsCredit) {
      window.cascade.shell.openExternal(SPICY_TTML_TOOL_URL)
      showToast("Opened Spicy Lyrics' TTML tool in your browser")
      return
    }
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
  window.cascade.metadataEditor.open({ item, jf: { ...jf, ...CascadeCore.clientIdentity() } })
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
    const res = await jfGet(`/Items`, {
      Ids: itemId,
      Fields: 'AlbumId,AlbumPrimaryImageTag,UserData',
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

document.getElementById('lyrics-source-dropdown').querySelectorAll('.lsd-item[data-source]').forEach(item => {
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

// lyricWordSpans and _paintWordSpans live in lyric-karaoke.js, shared with
// the miniplayer.

function _wordHighlightFrame() {
  _wordRafId = requestAnimationFrame(_wordHighlightFrame)
  const nowTicks = (audio.currentTime + _lyricLead) * 10_000_000

  // Side panel - CSS scoping (.lyrics-line.active .lyric-word) handles inactive lines.
  // Guard on the panel being open, which is exactly "the user can see this":
  // .lyrics-panel is position: fixed above every view, so it is NOT hidden by
  // navigating elsewhere and .open is the whole condition. This guard read
  // getElementById('view-lyrics') until 2026-09-15; no such element has ever
  // existed (the only match is #ctx-view-lyrics, a context menu item), so the
  // optional chain yielded undefined and this branch never ran once.
  // Every line of the current group: more than one while lines overlap.
  const paintGroup = (container, sel, first, last) => {
    if (!container || last < 0) return
    for (let i = first >= 0 && first <= last ? first : last; i <= last; i++) {
      if (lyricsData[i]?.Words) _paintWordSpans(container.querySelector(`${sel}[data-idx="${i}"]`), nowTicks)
    }
  }
  if (lyricsPanelOpen()) paintGroup(document.getElementById('lyrics-inner'), '.lyrics-line', lyricsActiveFirst, lastLyricsIdx)

  // Overlay - same: CSS scoping handles inactive lines automatically
  if (overlayOpen && overlayLyricsOpen) {
    paintGroup(document.getElementById('ov-lyrics-body'), '.ov-lyric-line', ovActiveFirst, lastOverlayLyricsIdx)
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

// The panel is position: fixed above every view, so .open is the whole answer to
// "can the user see this" - navigating elsewhere does not hide it. Both lyrics
// loops guard on this to stay off the CPU while the panel is closed.
function lyricsPanelOpen() { return document.getElementById('lyrics-panel').classList.contains('open') }

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

// One search per song at a time. The side panel, the overlay and the
// look-ahead for upcoming tracks can all ask for the same song before its
// first search lands (the cache below is only filled at the end), and each
// used to start its own: one track's Jellyfin /Lyrics 404 showed up ten times
// in a row. Later askers now wait on the search already running.
const _lyricsInflight = new Map()   // item id -> promise of the waterfall's result
function fetchLyricsWaterfall(item) {
  // Films and episodes have no lyrics. Guarded here, where every caller
  // routes, because only updateNowPlaying() checked: the lyrics panel and the
  // overlay still sent a movie's title to LRCLIB, Kugou and the plugin.
  if (isVideoItem(item)) return Promise.resolve(null)
  // Nothing found anywhere, and the track's own tags say it is instrumental:
  // say so rather than "no lyrics" (looksInstrumental).
  const orTagged = r => r || (CascadeCore.looksInstrumental(item) ? { instrumental: true } : null)
  const forced = lyricsForcedSource && lyricsForcedSource !== 'auto'
  if (forced || _lyricsCache.has(item.Id)) return _lyricsWaterfall(item).then(orTagged)
  // A look ahead at the next song skips SpicyLyrics from the app (see
  // spicyFromApp), so the song playing must not wait on that look's answer.
  const key = spicyFromApp() && item.Id === queue[queueIndex]?.Id ? `${item.Id}:spicy` : item.Id
  let pending = _lyricsInflight.get(key)
  if (!pending) {
    pending = _lyricsWaterfall(item).finally(() => _lyricsInflight.delete(key))
    _lyricsInflight.set(key, pending)
  }
  return pending.then(orTagged)
}

async function _lyricsWaterfall(item) {
  // Offline, the only lyrics are the ones saved with the download. Not
  // cached: going back online should search again.
  // Local mode has the web, so it searches as online does, with the song's own
  // files where Jellyfin's lyrics would be.
  if (jfClient.offline && !isLocalMode()) {
    const saved = _offlineCatalog ? CascadeCore.lyricsOf(_offlineCatalog, item.Id, new Date()) : null
    _lastFetchStatus = { Cascade: null, Kugou: null, LRCLIB: null, Jellyfin: null }
    return saved ? { lines: saved.lines, source: CascadeCore.lyricsSourceLabel(saved), credit: saved.credit, tried: {} } : null
  }
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
  // Not in Local mode: there is no server, and the saved switch is left as it
  // is for when there is one again.
  if (serverOnlyMode && !isLocalMode()) {
    const wantType = forced === 'cascade-karaoke' ? 'karaoke'
                   : forced === 'cascade-synced'  ? 'synced'
                   : null   // auto = accept either (plugin returns karaoke first)
    const tried = { Cascade: null }
    try {
      await _cascadePluginProbed
      // Auto asks for SpicyLyrics first; the plugin answers it only with a key
      // set and a Spotify id for the track, and otherwise falls through to its
      // own files. A forced karaoke/synced choice means exactly those files.
      const url = !wantType && _cascadePluginCaps.has('syllable')
        ? `${cascadeLyricsUrl(item.Id)}?syllable=true${_localSpotifyParam(item.Id)}` : cascadeLyricsUrl(item.Id)
      const r = await jfFetch(url,
        { headers: CascadeCore.authHeaders(jf), signal: AbortSignal.timeout(8000) })
      if (!r.ok) throw new Error(`HTTP ${r.status}`)
      let d = await r.json()
      if (d.type === 'syllable') {
        // A sync for a longer version drifts against this file; the plugin's
        // own files beat that (spicyFitsTrack).
        const conv = CascadeCore.spicyFitsTrack(d.spicy, (item.RunTimeTicks || 0) / 10_000_000)
          ? CascadeCore.convertSpicyLyrics(d.spicy) : null
        if (conv) {
          tried.Cascade = 'ok'
          _lastFetchStatus = tried
          const out = { lines: conv.lines, source: conv.credit.provider, credit: conv.credit, tried }
          _cachePut(item.Id, out)
          return out
        }
        // Unusable SpicyLyrics body: ask again for the plugin's own files
        // rather than showing nothing when they exist.
        const r2 = await jfFetch(cascadeLyricsUrl(item.Id),
          { headers: CascadeCore.authHeaders(jf), signal: AbortSignal.timeout(8000) })
        if (!r2.ok) throw new Error(`HTTP ${r2.status}`)
        d = await r2.json()
      }
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
      const r = await webFetch(
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
      // Local mode: the .lrc beside the song, else the lyrics in its tags.
      if (isLocalMode()) {
        const own = await window.cascade.local.lyrics(item.Id)
        if (!own?.text) return null
        const lines = own.synced
          ? parseLRC(own.text).filter(l => !metaPattern.test(l.Text))
          : own.text.split('\n').map(t => t.trim()).filter(Boolean).map(t => ({ Start: null, End: null, Text: t, Words: null }))
        return lines.length ? { lines, source: own.synced ? 'Your file' : 'Your file (plain)' } : null
      }
      const r = await jfFetch(`${jf.url}/Audio/${item.Id}/Lyrics`,
        { headers: CascadeCore.authHeaders(jf), ...sig })
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

  // SpicyLyrics through the plugin, ahead of everything else when it answers.
  // Only asked when the plugin reports a key (the 'syllable' capability), and
  // only a SpicyLyrics body counts: the plugin's own files are server-only
  // mode's business, not this waterfall's. Outside `sources`, so it is not a
  // forceable choice and a miss is never reported as a failed source - most
  // tracks will not have one. spicyOnly stops the plugin there on a miss
  // instead of reading its files, or fetching Kugou and LRCLIB live, for an
  // answer this ignores. A plugin older than the flag ignores it.
  // Without the plugin (Local mode, or a server without it), SpicyLyrics comes
  // from the app with the person's own key, and only for the song playing:
  // the terms allow fetching on play, never a crawl, and a look ahead at the
  // next songs or a download's lyrics is not a play. Such an answer is not
  // cached here, so the song asks again once it plays.
  const spicySkipped = spicyFromApp() && item.Id !== queue[queueIndex]?.Id
  const spicyProm = (async () => {
    await _cascadePluginProbed
    if (spicyFromApp()) {
      if (spicySkipped) return null
      const found = await window.cascade.spicy.lyrics({
        itemId: item.Id, title: item.Name || '', artist: item.Artists?.[0] || item.AlbumArtist || '', album: item.Album || '',
        durationSec: (item.RunTimeTicks || 0) / 10_000_000, spotifyId: _localSpotifyLinks[item.Id] || null,
      })
      const conv = found ? CascadeCore.convertSpicyLyrics(found.raw) : null
      return conv ? { lines: conv.lines, source: conv.credit.provider, credit: conv.credit } : null
    }
    if (_cascadePluginAbsent || !_cascadePluginCaps.has('syllable')) return null
    const r = await jfFetch(`${cascadeLyricsUrl(item.Id)}?syllable=true&spicyOnly=true${_localSpotifyParam(item.Id)}`, { headers: CascadeCore.authHeaders(jf), ...sig })
    if (!r.ok) return null
    const d = await r.json()
    if (d?.type !== 'syllable') return null
    // Another version's sync drifts against this file: let the others win.
    if (!CascadeCore.spicyFitsTrack(d.spicy, (item.RunTimeTicks || 0) / 10_000_000)) return null
    const conv = CascadeCore.convertSpicyLyrics(d.spicy)
    return conv ? { lines: conv.lines, source: conv.credit.provider, credit: conv.credit } : null
  })().catch(err => { if (!_isAbort(err)) console.error('[Lyrics] SpicyLyrics error:', err); return null })

  // Fire all sources simultaneously
  const [kugouProm, lrcProm, jfProm] = sources.map(([name, fn]) =>
    fn().then(r => ({ name, result: r }))
      .catch(err => { if (!_isAbort(err)) console.error(`[Lyrics] ${name} error:`, err); return { name, result: null } })
  )

  const [kugouRes, lrcRes, jfRes, spicyRes] = await Promise.all([kugouProm, lrcProm, jfProm, spicyProm])

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

  const winner = spicyRes || kugouRes.result || lrcRes.result || jfRes.result
  if (winner) {
    _lastFetchStatus = tried
    const out = { ...winner, tried }
    if (!spicySkipped) _cachePut(item.Id, out)
    return out
  }

  _lastFetchStatus = tried
  // Cache the miss too, not just the hits. Both readers gate on .has(), so an
  // uncached miss meant every track with no lyrics anywhere re-ran all three
  // sources on every single advance - for the track AND for the five that
  // _prefetchUpcoming looks ahead at. On an instrumental album that is the
  // whole waterfall, per track, forever. A forced source still bypasses the
  // cache above, and _reloadLyricsFor() stays the escape hatch if a source was
  // merely down rather than actually missing the track.
  if (!forced && !spicySkipped) _cachePut(item.Id, null)
  return null
}

// ── Lyrics fetch ──────────────────────────────────────────────────────────────

let _lyricsFetchGen = 0  // incremented on every fetchLyrics() call; stale results are discarded

async function fetchLyrics() {
  const gen  = ++_lyricsFetchGen
  const item = queue[queueIndex]
  const body = document.getElementById('lyrics-body')
  const translateBar = document.getElementById('lyrics-translate-bar')
  if (!item) { _sideDropGhost(); body.innerHTML = '<div class="lyrics-empty">Nothing playing</div>'; return }

  // Under a crossfade the last song's lines stay up (the ghost) instead of a skeleton.
  _sideKeepGhost()
  _sideSetBody(_sideGhost ? '' : skeletonHTML('lyrics', 1))
  translateBar.classList.remove('visible')
  lyricsData = []
  lyricsTranslated = []
  lastLyricsIdx = -1
  _lyricsScanIdx = 0

  const result = await fetchLyricsWaterfall(item)
  if (gen !== _lyricsFetchGen) return  // a newer fetch superseded this one
  _markLyricsFor(item, result)

  if (result?.instrumental) {
    _sideDropGhost()
    _sideSetBody('<div class="lyrics-empty">This track is instrumental</div>')
    return
  }
  _showLyricsFetchToast(result)
  if (!result) {
    lyricsSource = null
    lyricsCredit = null
    updateSourcePills()
    _sideDropGhost()
    _sideSetBody(`<div class="lyrics-empty">No lyrics available for this track${_linkSpotifyButton()}</div>`)
    return
  }
  lyricsData   = result.lines
  lyricsSource = result.source
  lyricsCredit = result.credit || null
  updateSourcePills()
  renderLyrics()
  _sideRollIn()
  detectAndShowTranslateBar()
  ensureLyricsTranslation()
  _stopWordLoop()
  if (!audio.paused) _startWordLoop()
}

function detectAndShowTranslateBar() {
  // The whole sheet, not the first line: a song opening on an English title line
  // must still read as the language the rest of it is in.
  const lang = lyricsTranslationEnabled && CascadeCore.translationLanguageFor(lyricsPlainLines())
  const key = _canTranslate(lang) ? lang : null
  document.getElementById('lyrics-translate-bar').classList.toggle('visible', !!key)
  document.getElementById('lyrics-translate-label').textContent = key ? `${_translationModelName(key)} lyrics` : ''
}

function renderLyrics() {
  const body = document.getElementById('lyrics-body')
  const lines = lyricsData.map((line, i) => {
    const hasTimestamp = line.Start != null
    // Same shape as the overlay: original (karaoke intact) with the translation
    // nested under it. This used to replace the line's text with the translation
    // AND append the translation again as a sibling, so a translated sheet showed
    // every translation twice and the original not at all.
    const content = line.Words ? lyricWordSpans(line, 'lyric-word', !!lyricsCredit) : esc(line.Text || '')
    const trans = lyricTranslationFor(i)
    return `<div class="lyrics-line${hasTimestamp ? ' seekable' : ''}${line.Opposite ? ' opposite' : ''}" data-idx="${i}"${hasTimestamp ? ` data-start="${line.Start}"` : ''}>${content}${trans ? `<div class="lyric-trans">${esc(trans)}</div>` : ''}</div>`
  }).join('')

  // Wrap in a translateY-driven inner div - position is spring-animated in JS
  // (see sideLyricsSpring), not CSS transitions, so no transition property here.
  _sideSetBody(`<div id="lyrics-inner" style="will-change:transform;padding-bottom:50%">${lines}</div>`)
  sideLyricsSpring.jumpTo(0)  // fresh element, don't carry over the previous track's position
  // Untimed lyrics are a plain list to scroll (_lyricsPlain), not a sheet that follows the song.
  body.classList.toggle('plain', _lyricsPlain())
  if (_lyricsPlain()) body.scrollTop = 0
  _refreshLyricsPreviews(true)
  _layoutAllGlosses()

  body.querySelectorAll('.lyrics-line.seekable').forEach(el => {
    el.style.cursor = 'pointer'
    el.addEventListener('click', () => {
      const ticks = parseInt(el.dataset.start)
      if (isNaN(ticks) || !audio.duration) return
      lyricsScrollSuppressed = true
      clearTimeout(lyricsScrollTimer)
      lyricsScrollTimer = setTimeout(() => { lyricsScrollSuppressed = false }, 1500)
      audio.currentTime = Math.max(0, ticks / 10000000 - _lyricLead)
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
  if (!lyricsData.length || _lyricsPlain()) return
  // Nothing below is visible with the panel closed, and all of it is expensive:
  // a class pass over every line, then clientHeight/offsetTop reads that force
  // synchronous layout, then a spring that starts its own rAF. Safe to bail
  // outright rather than keep the index in sync, because showLyrics() always
  // routes through fetchLyrics(), which resets lastLyricsIdx and redraws.
  if (!lyricsPanelOpen()) return
  // Same lookahead as word-fill (_wordHighlightFrame) so the last word's fill
  // animation and the line-promotion check complete in lockstep - no gap in
  // either direction (mid-fill cutoff if promotion is earlier, a visible
  // "stick" on the finished word if promotion is later).
  const nowSec = audio.currentTime + _lyricLead
  const baseIdx = _scanLyricsBaseIdx(nowSec, _lyricsScanIdx)
  _lyricsScanIdx = baseIdx

  // Karaoke: promote early once a line (background vocals included) is sung,
  // and hold a line while its background vocals run into the next one. Shared
  // with the overlay; see currentLyricIndex in src/core/lyrics.ts.
  const activeIdx = _lyricFocusIdx(nowSec, baseIdx)
  // Overlapping lines stay lit together, as in the overlay above.
  const [first] = CascadeCore.activeLyricRange(lyricsData, activeIdx, nowSec * 10_000_000)
  const ahead = _lyricScrollAhead(nowSec, baseIdx, activeIdx)
  const aheadKey = ahead ? ahead.join(':') : ''

  if (activeIdx === lastLyricsIdx && first === lyricsActiveFirst && aheadKey === sideAheadKey) return
  sideAheadKey = aheadKey
  _applySideLyricsActive(activeIdx, false, first, ahead)   // always a glide, as in the overlay above
})
let sideAheadKey = ''

// Highlight and centre one line in the side panel. Split out of the timeupdate
// handler so a re-render (a translation arriving, say) can put the highlight
// back straight away - while paused, no timeupdate would come to do it.
// First line of the side panel's current group; lastLyricsIdx is the last.
// They differ only while lines overlap (see activeLyricRange).
let lyricsActiveFirst = -1

function _applySideLyricsActive(activeIdx, instant, first = activeIdx, ahead = null) {
  if (_lyricsPlain()) return   // nothing to follow
  lastLyricsIdx = activeIdx
  lyricsActiveFirst = first
  const body = document.getElementById('lyrics-body')
  // The sheet only: a rolling ghost of the last song (_sideKeepGhost) shares the panel.
  document.getElementById('lyrics-inner')?.querySelectorAll('.lyrics-line[data-idx]').forEach(el => {
    const idx = parseInt(el.dataset.idx)
    el.classList.toggle('active', idx >= first && idx <= activeIdx)
  })

  if (!lyricsScrollSuppressed) {
    const inner = document.getElementById('lyrics-inner')
    // With Scroll ahead on, the line coming up rather than the lit one.
    const [toIdx, toFirst] = ahead || [activeIdx, first]
    const target = inner?.querySelector(`.lyrics-line[data-idx="${toIdx}"]`)
    if (target) {
      // A group of overlapping lines is centred as one block.
      const top = inner.querySelector(`.lyrics-line[data-idx="${toFirst}"]`) || target
      const centreOn = () => body.clientHeight / 2 - (top.offsetTop + target.offsetTop + target.offsetHeight) / 2
      if (instant) sideLyricsSpring.jumpTo(centreOn())
      else sideLyricsSpring.setTarget(centreOn)   // re-measured per frame, see createSpring
    }
  }
}

document.getElementById('lyrics-translate-btn').addEventListener('click', () => onTranslateButton())

// ── Translation state shared by both lyric views ──────────────────────────────
//
// One switch, remembered across songs and restarts: turn it on and every later
// foreign-language sheet translates as soon as it is on screen, in either view.
// Nothing is translated while neither view is showing lyrics.

let _lyricsTranslatedFor = null   // the lyricsData array lyricsTranslated was made from
// What each line of that sheet translates (CascadeCore.planSheet): nothing, the
// whole line, or one foreign phrase. lyricsTranslated[i] is that unit's English.
let _lyricsPlans = null           // { sheet, plans, lang }
let _lyricsTranslating = null     // { sheet, key, promise } while one is in flight
let _translateStatus = ''         // transient button label: download or translate progress, 'Failed'
let _translateStatusTimer = null

// Names and sizes of the downloadable models, straight from main.js's manifest,
// so the renderer never keeps its own copy to drift. Kept current from progress
// events; the key itself shows only if a label renders before the first read.
let _translationModels = {}
// Languages only Apple takes have no manifest entry, so their name comes from
// the platform's own list ("Ukrainian", "Thai").
const _languageNames = new Intl.DisplayNames(['en'], { type: 'language' })
const _translationModelName = key => {
  if (_translationModels[key]?.name) return _translationModels[key].name
  try { return _languageNames.of(key) || key } catch { return key }
}

window.cascade.translationModels.status().then(s => { _translationModels = s }).catch(() => {})

window.cascade.translationModels.onProgress(p => {
  if (_translationModels[p.key]) {
    _translationModels[p.key].state = p.state
    _translationModels[p.key].transferred = p.transferred
  }
  if (p.state === 'absent') dropTranslator(p.key)
  updateTranslationModelRow(p.key)
  if (_lyricsTranslating?.key === p.key && p.state === 'downloading' && p.total) {
    _flashTranslateStatus(`Downloading ${Math.round(p.transferred / p.total * 100)}%`, 0)
  }
})

// Said once per model per session, the moment a download actually starts. The
// wizard and Settings carry the full disclosure; this is the "it's happening
// now". Toasts can be switched off, which is fine for that reason.
const _announcedDownloads = new Set()
function _announceModelDownload(key) {
  if (_announcedDownloads.has(key)) return
  _announcedDownloads.add(key)
  const m = _translationModels[key]
  showToast(`Downloading the ${_translationModelName(key)} translation model${m ? ` (${Math.round(m.bytes / 1e6)} MB)` : ''}`, { duration: 3500 })
}

// ── Apple Translation or Mozilla's models ─────────────────────────────────────
//
// On a Mac that supports it (macOS 26+), Apple's built-in translation is the
// default: more accurate, and nothing downloads through Cascade. It needs each
// language installed in macOS. When a song's language is installable but not
// installed, the Translate press asks rather than quietly downloading Mozilla's
// model: install it in macOS (recommended), or use Cascade's model for that
// language. That choice is remembered per language, and only applies while the
// language is missing from macOS, so installing it later brings Apple back.

let _pendingInstallKey = null   // the sheet's language, while it waits on macOS

const _appleInUse = () => _appleTranslationSupported && appleTranslationEnabled

// macOS's last answer per language, so the Translate button can be decided
// without a round trip on every sheet. Refreshed at startup, when Apple
// Translation is switched, and whenever the settings row or a translation
// asks again - the last one catches a language installed since.
let _appleLanguageStatus = {}

async function refreshAppleLanguageStatus() {
  if (!_appleTranslationSupported) return _appleLanguageStatus
  try {
    _appleLanguageStatus = await window.cascade.appleTranslation.availability(CascadeCore.APPLE_TRANSLATION_KEYS)
  } catch { /* keep the last answer */ }
  detectOverlayLyricsLanguage()
  detectAndShowTranslateBar()
  return _appleLanguageStatus
}

function _engineFor(key, status) {
  return CascadeCore.pickTranslationEngine({
    appleEnabled: _appleInUse(),
    appleStatus: _appleInUse() ? status[key] : undefined,
    hasModel: CascadeCore.isModelKey(key),
    mozillaChosen: _appleMozillaChosen.has(key),
  })
}

/** Whether anything on this Mac could translate a sheet in `key`, from the cached answer. */
const _canTranslate = key => !!key && _engineFor(key, _appleLanguageStatus) !== 'none'

async function _translationEngineFor(key) {
  if (!_appleInUse()) return _engineFor(key, {})
  return _engineFor(key, await refreshAppleLanguageStatus())
}

function openAppleInstallPrompt(key) {
  const name = _translationModelName(key)
  const m = _translationModels[key]
  const modal = document.getElementById('apple-install-modal')
  modal.dataset.key = key
  document.getElementById('apple-install-title').textContent = `Install ${name} in macOS?`
  document.getElementById('apple-install-lang').textContent = name
  const mozillaBtn = document.getElementById('apple-install-mozilla')
  mozillaBtn.textContent = `Use Cascade's model${m ? ` (${Math.round(m.bytes / 1e6)} MB)` : ''}`
  // Most languages Apple takes have no Cascade model to fall back on.
  mozillaBtn.style.display = CascadeCore.isModelKey(key) ? '' : 'none'
  modal.classList.remove('hidden')
}

function _closeAppleInstallPrompt() {
  document.getElementById('apple-install-modal').classList.add('hidden')
}

// Cancel and "Open System Settings" both leave the song untranslated for now,
// so the Translate button goes back to plain Translate: after installing the
// language, pressing it again is all that is needed.
document.getElementById('apple-install-open').addEventListener('click', () => {
  _closeAppleInstallPrompt()
  window.cascade.appleTranslation.openSettings()
  setLyricsTranslateOn(false)
})
document.getElementById('apple-install-cancel').addEventListener('click', () => {
  _closeAppleInstallPrompt()
  setLyricsTranslateOn(false)
})
document.getElementById('apple-install-mozilla').addEventListener('click', () => {
  const key = document.getElementById('apple-install-modal').dataset.key
  _closeAppleInstallPrompt()
  if (!CascadeCore.TRANSLATION_MODEL_KEYS.includes(key)) return
  _appleMozillaChosen.add(key)
  window.cascade.store.set('appleTranslationMozillaChosen', [..._appleMozillaChosen])
  _pendingInstallKey = null
  _flashTranslateStatus('', 0)
  ensureLyricsTranslation(true)
  renderAppleTranslationRow()
})

// Both Translate buttons. While a sheet is waiting on its language, the button
// reads "Install Korean…" and pressing it asks again instead of switching off.
function onTranslateButton() {
  markTipSeen('translate')
  if (lyricsTranslateOn && _pendingInstallKey) return openAppleInstallPrompt(_pendingInstallKey)
  setLyricsTranslateOn(!lyricsTranslateOn)
}

// The one path for the Settings toggle.
async function setAppleTranslationEnabled(enabled) {
  appleTranslationEnabled = enabled
  const toggle = document.getElementById('apple-translation-toggle')
  if (toggle) toggle.checked = enabled
  // The translation on screen came from the other engine, which is no longer
  // the one asked for: drop it and translate again.
  _pendingInstallKey = null
  _lyricsTranslatedFor = null
  _flashTranslateStatus('', 0)
  rerenderLyricViews()
  ensureLyricsTranslation()
  renderAppleTranslationRow()
  await window.cascade.store.set('appleTranslationEnabled', enabled)
}

async function renderAppleTranslationRow() {
  const row = document.getElementById('apple-translation-row')
  if (!_appleTranslationSupported) { row.style.display = 'none'; return }
  row.style.display = ''
  document.getElementById('apple-translation-toggle').checked = appleTranslationEnabled
  document.getElementById('apple-translation-reset').style.display = _appleMozillaChosen.size ? '' : 'none'
  const statusEl = document.getElementById('apple-translation-status')
  try {
    const status = await refreshAppleLanguageStatus()
    // Every language Apple takes, not only the five Cascade has models for:
    // System Settings undercounts too, since macOS 27's multilingual model
    // covers languages it never lists as downloaded.
    const byName = keys => keys.map(_translationModelName).sort((a, b) => a.localeCompare(b))
    const keys = CascadeCore.APPLE_TRANSLATION_KEYS
    const installed = keys.filter(k => status[k] === 'installed')
    const missing = keys.filter(k => status[k] === 'supported')
    const parts = []
    if (installed.length) parts.push(`Installed in macOS (${installed.length}): ${byName(installed).join(', ')}.`)
    if (missing.length) {
      parts.push(`Not installed: ${missing.map(k => _translationModelName(k) + (_appleMozillaChosen.has(k) ? ' (using Cascade’s model)' : '')).join(', ')}.`)
    }
    statusEl.textContent = parts.join(' ')
  } catch {
    statusEl.textContent = 'Could not check which languages are installed in macOS.'
  }
}

document.getElementById('apple-translation-toggle').addEventListener('change', e => setAppleTranslationEnabled(e.target.checked))
document.getElementById('apple-translation-open').addEventListener('click', () => window.cascade.appleTranslation.openSettings())
document.getElementById('apple-translation-reset').addEventListener('click', () => {
  _appleMozillaChosen.clear()
  window.cascade.store.set('appleTranslationMozillaChosen', [])
  // A sheet showing Cascade's model for a language Apple could handle should
  // go back to asking.
  _lyricsTranslatedFor = null
  rerenderLyricViews()
  ensureLyricsTranslation()
  renderAppleTranslationRow()
})

// ── Lyric translation in Settings: the feature switch and the models ──────────

// The feature switch, deliberately separate from lyricsTranslateOn: this one
// says whether translation exists at all (default on), that one whether
// translations are showing right now (default off). Off hides both Translate
// buttons, strips any translation already on screen, and nothing downloads.
// The one code path for Settings and the first-run wizard alike.
async function setLyricsTranslationEnabled(enabled) {
  lyricsTranslationEnabled = enabled
  for (const id of ['lyrics-translation-toggle', 'fr-lyrics-translation-toggle']) {
    const el = document.getElementById(id)
    if (el) el.checked = enabled
  }
  if (lyricsData.length) {
    detectAndShowTranslateBar()
    detectOverlayLyricsLanguage()
  }
  rerenderLyricViews()
  renderTranslationModelRows()
  if (enabled) ensureLyricsTranslation()
  await window.cascade.store.set('lyricsTranslationEnabled', enabled)
}

document.getElementById('lyrics-translation-toggle').addEventListener('change', e => setLyricsTranslationEnabled(e.target.checked))

// Last download failure per model, this session, shown on its row until the
// next attempt.
const _translationModelErrors = {}

// ipcRenderer.invoke wraps a main-process throw as "Error invoking remote
// method 'x': Error: <message>"; only the message means anything to a person.
const _ipcErrorMessage = err =>
  String(err?.message || err).replace(/^Error invoking remote method '[^']*': (Error: )?/, '')

const _mb = bytes => `${Math.round(bytes / 1e6)} MB`

function renderTranslationModelRows() {
  const list = document.getElementById('translation-models-list')
  const keys = Object.keys(_translationModels)
  // Rows are built once, then updated in place: a download sends several
  // progress events a second, and rebuilding would swap out the button under
  // the pointer mid-click on the other rows.
  if (list.children.length !== keys.length) {
    list.innerHTML = keys.map(key => `
      <div class="setting-row tm-row" data-key="${esc(key)}">
        <div class="setting-label">
          <span class="setting-name">${esc(_translationModelName(key))}</span>
          <span class="setting-desc tm-status"></span>
          <div class="tm-bar" hidden><div class="tm-bar-fill"></div></div>
        </div>
        <div class="tm-actions"></div>
      </div>`).join('')
  }
  for (const key of keys) updateTranslationModelRow(key)
}

function updateTranslationModelRow(key) {
  const row = document.querySelector(`#translation-models-list .tm-row[data-key="${CSS.escape(key)}"]`)
  const m = _translationModels[key]
  if (!row || !m) return
  const pct = m.state === 'downloading' && m.bytes ? Math.round(m.transferred / m.bytes * 100) : 0
  row.querySelector('.tm-status').textContent =
    m.state === 'ready' ? `Downloaded · ${_mb(m.bytes)}`
    : m.state === 'downloading' ? `Downloading ${pct}% · ${_mb(m.transferred)} of ${_mb(m.bytes)}`
    : _translationModelErrors[key] ? `Download failed: ${_translationModelErrors[key]}`
    : `Not downloaded · ${_mb(m.bytes)}`
  row.querySelector('.tm-bar').hidden = m.state !== 'downloading'
  row.querySelector('.tm-bar-fill').style.width = `${pct}%`

  // Buttons change only when the state (or the feature switch) does. Remove
  // stays available with translation switched off, so the space can still be
  // freed; fetching anything new does not.
  const actions = row.querySelector('.tm-actions')
  const signature = `${m.state}:${lyricsTranslationEnabled}`
  if (actions.dataset.signature === signature) return
  actions.dataset.signature = signature
  const off = lyricsTranslationEnabled ? '' : ' disabled'
  actions.innerHTML =
    m.state === 'ready'
      ? `<button class="btn btn-secondary" data-action="redownload"${off}>Redownload</button><button class="btn btn-danger" data-action="remove">Remove</button>`
    : m.state === 'absent'
      ? `<button class="btn btn-secondary" data-action="download"${off}>Download</button>`
    : '<button class="btn btn-secondary" disabled>Downloading…</button>'
}

document.getElementById('translation-models-list').addEventListener('click', async e => {
  const btn = e.target.closest('button[data-action]')
  const row = btn?.closest('.tm-row')
  if (!btn || !row || btn.disabled) return
  const key = row.dataset.key
  const action = btn.dataset.action
  const state = _translationModels[key]?.state
  // Guarded here as well as by `disabled`: a disabled-looking button can still
  // be clicked programmatically, and a row can briefly lag its model's state.
  if (action === 'download' && (state !== 'absent' || !lyricsTranslationEnabled)) return
  if (action === 'redownload' && (state !== 'ready' || !lyricsTranslationEnabled)) return
  if (action === 'remove' && state !== 'ready') return

  delete _translationModelErrors[key]
  try {
    if (action === 'remove' || action === 'redownload') {
      dropTranslator(key)
      await window.cascade.translationModels.remove(key)
    }
    if (action === 'download' || action === 'redownload') {
      await window.cascade.translationModels.download(key)
    }
  } catch (err) {
    _translationModelErrors[key] = _ipcErrorMessage(err)
  }
  _translationModels = await window.cascade.translationModels.status()
  renderTranslationModelRows()
})

// The translation to show under line i, or '' for none. Only a translation of
// THIS sheet counts - checked by array identity, so any reload, source switch or
// edit that replaces lyricsData invalidates it without every such path having to
// remember. A line the model returned unchanged (English lines in a mixed song)
// is not repeated under itself.
function lyricTranslationFor(i) {
  if (!lyricsTranslationEnabled || !lyricsTranslateOn) return ''
  // Done, or still arriving line by line for this sheet.
  if (_lyricsTranslatedFor !== lyricsData && _lyricsTranslating?.sheet !== lyricsData) return ''
  // Drawn under the words instead (_layoutGlosses): a phrase's translation, and
  // every line of a Latin-script sheet.
  if (_lyricsPlanFor(i)?.mode === 'run') return ''
  if (_lyricsPlans?.sheet === lyricsData && !CascadeCore.isNonLatinLanguage(_lyricsPlans.lang)) return ''
  const t = (lyricsTranslated[i] || '').trim()
  return t && t.toLowerCase() !== (lyricsData[i]?.Text || '').trim().toLowerCase() ? t : ''
}

function _lyricsPlanFor(i) {
  return _lyricsPlans?.sheet === lyricsData ? _lyricsPlans.plans[i] : null
}

/**
 * What goes under line i's words, or null: { glosses: [{ source, text }] } to
 * put each English under its source phrase, or { rows: english } to cut the
 * English across the line's rows. A non-Latin sheet's phrase line
 * (CascadeCore.planLine's 'run') is one gloss. Every line of a Latin-script
 * sheet was translated whole and is compared with its English
 * (CascadeCore.latinView): passed through is nothing, a changed phrase in an
 * English line a gloss, a changed line rows.
 */
function _lineGlossFor(i) {
  if (!lyricsTranslationEnabled || !lyricsTranslateOn) return null
  if (_lyricsTranslatedFor !== lyricsData && _lyricsTranslating?.sheet !== lyricsData) return null
  const plan = _lyricsPlanFor(i)
  const t = (lyricsTranslated[i] || '').trim()
  if (!plan || plan.mode === 'skip' || !t) return null
  if (plan.mode === 'run') return t.toLowerCase() === plan.text.toLowerCase() ? null : { glosses: [{ source: plan.text, text: t }] }
  if (CascadeCore.isNonLatinLanguage(_lyricsPlans.lang)) return null   // its whole-line row (lyricTranslationFor)
  const source = (lyricsData[i]?.Text || '').trim()
  const view = CascadeCore.latinView(source, t)
  if (view.mode === 'rows') return { rows: t }
  if (view.mode === 'glosses') return { glosses: view.glosses.map(g => ({ source: source.slice(g.from, g.to), text: g.text })) }
  return null
}

// ── Translations under the words ──
// Glosses (_lineGlossFor) are laid out by measuring where the words are drawn,
// not by marking them up: the karaoke word spans stay exactly as
// lyric-karaoke.js draws them. The line gets .glossed, which opens a gap under
// each of its rows (styles/lyrics.css, --gloss-h), and each gloss is an
// absolutely placed .lyric-gloss in the line, in its own unscaled coordinates
// (a past line is scaled): under its phrase's first part, or under its row.
// A line whose glosses are all on its last row takes .glossed-last instead,
// room at the bottom only.
// Laid out again whenever a lyric body changes size (the rows rewrap).
function _layoutGlosses(lineEl, i) {
  const rowCls = lineEl.classList.contains('ov-lyric-line') ? 'ov-lyric-trans' : 'lyric-trans'
  lineEl.querySelectorAll(':scope > .lyric-gloss').forEach(el => el.remove())
  lineEl.classList.remove('glossed', 'glossed-last')
  const g = _lineGlossFor(i)
  const text = g && _lineText(lineEl, rowCls)
  if (!g || !text || !lineEl.offsetWidth) return
  // Each gloss's text and the box it goes under, measured as the line is now.
  const targets = () => {
    const rows = _textRows(text)
    if (g.rows) {
      const total = rows.reduce((n, r) => n + r.chars, 0) || 1
      return CascadeCore.splitForRows(g.rows, rows.map(r => r.chars / total))
        .map((piece, k) => ({ text: piece, rect: rows[k]?.rect, last: k === rows.length - 1 }))
        .filter(t => t.text && t.rect)
    }
    const out = []
    let from = 0
    for (const { source, text: en } of g.glosses) {
      const at = text.text.indexOf(source, from)
      if (at < 0) continue
      from = at + source.length
      const rect = text.rects(at, from)[0]
      const lastRow = rows[rows.length - 1]?.rect
      if (rect) out.push({ text: en, rect, last: !!lastRow && Math.abs(rect.bottom - lastRow.bottom) < rect.height / 2 })
    }
    return out
  }
  const first = targets()
  if (!first.length) return
  const make = str => {
    const el = document.createElement('div')
    el.className = `${rowCls} lyric-gloss`
    el.textContent = str
    lineEl.appendChild(el)
    return el
  }
  const probe = make('x')
  lineEl.style.setProperty('--gloss-h', `${probe.offsetHeight}px`)
  probe.remove()
  // Room under every row only when a gloss is under an earlier row; under the
  // last row alone, room at the bottom is enough. The rows move down with the
  // gap but do not rewrap, so the boxes are measured again after.
  lineEl.classList.add(first.every(t => t.last) ? 'glossed-last' : 'glossed')
  const lr = lineEl.getBoundingClientRect()
  const scale = lr.width / lineEl.offsetWidth
  const maxRight = lineEl.clientWidth - (parseFloat(getComputedStyle(lineEl).paddingRight) || 0)
  let prev = null
  for (const { text: str, rect } of targets()) {
    const el = make(str)
    let left = (rect.left - lr.left) / scale
    const top = (rect.bottom - lr.top) / scale
    // Not over the one before on the same row, and inside the line where it fits.
    if (prev && Math.abs(prev.top - top) < 1) left = Math.max(left, prev.right + 8)
    left = Math.max(0, Math.min(left, maxRight - el.offsetWidth))
    el.style.left = `${left}px`
    el.style.top = `${top}px`
    prev = { top, right: left + el.offsetWidth }
  }
}

/** A line's own text (not its rows, glosses or background vocals) and the
 *  boxes a stretch of it is drawn in; null with no text. */
function _lineText(lineEl, rowCls) {
  const nodes = []
  let text = ''
  const walker = document.createTreeWalker(lineEl, NodeFilter.SHOW_TEXT, {
    acceptNode: n => n.parentElement.closest(`.${rowCls}, .lyric-bg, .lyric-gloss`) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT,
  })
  for (let n; (n = walker.nextNode());) { nodes.push({ n, at: text.length }); text += n.data }
  if (!nodes.length) return null
  const point = (off, end) => {
    const k = nodes.find(({ n, at }) => end ? off <= at + n.data.length : off < at + n.data.length)
    return k && [k.n, off - k.at]
  }
  const rects = (start, end) => {
    const a = point(start, false), b = point(end, true)
    if (!a || !b) return []
    const range = document.createRange()
    range.setStart(a[0], a[1])
    range.setEnd(b[0], b[1])
    return [...range.getClientRects()].filter(r => r.width > 0)
  }
  return { text, rects }
}

/** The rows a line's words are drawn in, top to bottom: where each starts and
 *  how many characters it holds. */
function _textRows({ text, rects }) {
  const rows = []
  for (const t of CascadeCore.wordTokens(text)) {
    const r = rects(t.start, t.end)[0]
    if (!r) continue
    const row = rows.find(x => Math.abs(x.rect.bottom - r.bottom) < r.height / 2)
    if (row) {
      row.chars = t.end - row.start
      if (r.left < row.rect.left) row.rect = r
    } else {
      rows.push({ rect: r, start: t.start, chars: t.end - t.start })
    }
  }
  return rows.sort((a, b) => a.rect.top - b.rect.top)
}

/** Lays out every line's glosses, in both lyric views. */
function _layoutAllGlosses() {
  document.querySelectorAll('.lyrics-line[data-idx], .ov-lyric-line[data-idx]').forEach(el => {
    // A rolling sheet's ghost is the last song's lines: not this sheet's plan.
    if (el.closest('.ov-lyrics-ghost, .lyrics-ghost')) return
    _layoutGlosses(el, Number(el.getAttribute('data-idx')))
  })
}
{
  // A width or font change rewraps the rows: lay the glosses out again.
  let queued = false
  const ro = new ResizeObserver(() => {
    if (queued) return
    queued = true
    requestAnimationFrame(() => { queued = false; _layoutAllGlosses() })
  })
  for (const id of ['ov-lyrics-body', 'lyrics-body']) { const el = document.getElementById(id); if (el) ro.observe(el) }
}

/** The line being sung at `nowTicks`: the last one that has started. */
function _lyricLineAt(sheet, nowTicks) {
  let at = 0
  for (let i = 0; i < sheet.length; i++) if (sheet[i].Start != null && sheet[i].Start <= nowTicks) at = i
  return at
}

/** Puts line `i`'s translation into whichever lyric views are showing it,
 *  without re-rendering the sheet (which would restart the karaoke fill). */
function _showLineTranslation(i) {
  const text = lyricTranslationFor(i)
  document.querySelectorAll(`.lyrics-line[data-idx="${i}"], .ov-lyric-line[data-idx="${i}"]`).forEach(el => {
    const cls = el.classList.contains('ov-lyric-line') ? 'ov-lyric-trans' : 'lyric-trans'
    let t = el.querySelector(`.${cls}`)
    if (!text) { t?.remove(); return }
    if (!t) { t = document.createElement('div'); t.className = cls; el.appendChild(t) }
    t.textContent = text
  })
  document.querySelectorAll(`.lyrics-line[data-idx="${i}"], .ov-lyric-line[data-idx="${i}"]`).forEach(el => {
    if (!el.closest('.ov-lyrics-ghost, .lyrics-ghost')) _layoutGlosses(el, i)
  })
}

function _flashTranslateStatus(label, ms) {
  _translateStatus = label
  clearTimeout(_translateStatusTimer)
  if (ms) _translateStatusTimer = setTimeout(() => { _translateStatus = ''; syncTranslateButtons() }, ms)
  syncTranslateButtons()
}

function syncTranslateButtons() {
  const side = document.getElementById('lyrics-translate-btn')
  const ov = document.getElementById('ov-translate-btn')
  side.textContent = _translateStatus || (lyricsTranslateOn ? 'Show original' : 'Translate')
  ov.classList.toggle('translated', lyricsTranslateOn)
  ov.classList.toggle('loading', !!_lyricsTranslating)
  ov.title = _translateStatus === 'Failed' ? 'Translation unavailable'
    : _pendingInstallKey ? `Install ${_translationModelName(_pendingInstallKey)} in macOS to translate`
    : lyricsTranslateOn ? 'Show original' : 'Translate lyrics'
}

function setLyricsTranslateOn(on) {
  lyricsTranslateOn = on
  if (!on) _pendingInstallKey = null
  _flashTranslateStatus('', 0)
  rerenderLyricViews()
  window.cascade.store.set('lyricsTranslateOn', on)
  if (on) ensureLyricsTranslation(true)
}

// Re-render whichever lyric views are showing, keeping their active line.
function rerenderLyricViews() {
  if (!lyricsData.length) return
  if (document.getElementById('lyrics-inner')) {
    const idx = lastLyricsIdx
    renderLyrics()
    if (idx >= 0) _applySideLyricsActive(idx, true)
  }
  if (overlayOpen && overlayLyricsOpen && document.querySelector('#ov-lyrics-body .ov-lyric-line')) {
    renderOverlayLyricLines()
    if (lastOverlayLyricsIdx >= 0) updateOverlayLyricsActive(lastOverlayLyricsIdx, true)
  }
}

// Translate the current sheet if the switch is on and it needs it. Safe to call
// from every place a sheet appears: a finished translation just re-renders, and
// a second call for the same sheet joins the one in flight. Picks Apple or
// Mozilla per sheet; with Mozilla, a model not installed yet downloads here.
// `userAsked` is true only for an actual Translate press, the one moment the
// install prompt may appear - a song change must never pop a dialog.
function ensureLyricsTranslation(userAsked = false) {
  if (!lyricsTranslationEnabled || !lyricsTranslateOn || !lyricsData.length) return
  const sheet = lyricsData
  if (_lyricsTranslatedFor === sheet) return rerenderLyricViews()
  if (_lyricsTranslating?.sheet === sheet) return _lyricsTranslating.promise

  const lines = lyricsPlainLines()
  const lang = CascadeCore.translationLanguageFor(lines)
  const key = _canTranslate(lang) ? lang : null
  // A new sheet in another language (or none) is no longer waiting on the old one.
  if (_pendingInstallKey && _pendingInstallKey !== key) {
    _pendingInstallKey = null
    _flashTranslateStatus('', 0)
  }
  if (!key) return

  const promise = (async () => {
    // Yield once first, so the finally below always runs after `promise` and
    // _lyricsTranslating are assigned - even if something throws synchronously,
    // which would otherwise leave the button stuck spinning.
    await null
    try {
      const engine = await _translationEngineFor(key)
      if (lyricsData !== sheet || engine === 'none') { _flashTranslateStatus('', 0); return }
      if (engine === 'needs-install') {
        _pendingInstallKey = key
        _flashTranslateStatus(`Install ${_translationModelName(key)}…`, 0)
        if (userAsked) openAppleInstallPrompt(key)
        return
      }
      _pendingInstallKey = null

      if (engine === 'mozilla') {
        const status = await window.cascade.translationModels.status()
        _translationModels = status
        if (status[key]?.state !== 'ready') {
          _announceModelDownload(key)
          _flashTranslateStatus('Downloading…', 0)
          // Progress arrives through onProgress. The download carries on in
          // main.js even if the song changes, so a model fetched for one song
          // is ready for the next.
          try {
            await window.cascade.translationModels.download(key)
          } catch (err) {
            _translationModelErrors[key] = _ipcErrorMessage(err)
            throw err
          }
        }
        if (lyricsData !== sheet) { _flashTranslateStatus('', 0); return }   // the song moved on
      }

      _flashTranslateStatus(engine === 'apple' ? 'Translating…' : 'Loading…', 0)
      // Filled in line by line as translations land (see translateLines), and
      // shown as they do: lyricTranslationFor reads it while this runs. Each
      // line sends only what its plan says: nothing for an English line, the
      // phrase for a mostly-English one, else the whole line.
      lyricsTranslated = new Array(lines.length).fill('')
      const plans = CascadeCore.planSheet(lines, key)
      _lyricsPlans = { sheet, plans, lang: key }
      const units = plans.map(p => p.mode === 'skip' ? '' : p.text)
      const out = await translateLines(units, key, ({ done, total }) => {
        if (lyricsData === sheet) _flashTranslateStatus(`${Math.round(done / total * 100)}%`, 0)
      }, engine, {
        startAt: () => _lyricLineAt(sheet, mediaPosition() * 10_000_000),
        onLine: (indexes, english) => {
          if (lyricsData !== sheet) return
          for (const i of indexes) { lyricsTranslated[i] = english; _showLineTranslation(i) }
        },
      })
      if (lyricsData !== sheet) { _flashTranslateStatus('', 0); return }
      lyricsTranslated = out
      _lyricsTranslatedFor = sheet
      _flashTranslateStatus('', 0)
    } catch (e) {
      console.error('Translation failed', e)
      _flashTranslateStatus('Failed', 2500)
    } finally {
      if (_lyricsTranslating?.promise === promise) _lyricsTranslating = null
      syncTranslateButtons()
    }
  })()
  _lyricsTranslating = { sheet, key, promise }
  syncTranslateButtons()
  return promise
}

// Re-fetch lyrics when track changes
const _origUpdateNP = updateNowPlaying
updateNowPlaying = function(item) {
  _origUpdateNP(item)
  // Always clear stale lyrics so panels re-fetch for the new track
  lyricsData = []
  lyricsCredit = null   // the old song's Spicy credit, until the new lyrics say otherwise
  lyricsTranslated = []
  lastLyricsIdx = -1
  _lyricsScanIdx = 0
  document.getElementById('ov-translate-btn').style.display = 'none'
  _refetchLyricViews(item)
}

// One fetch, then Now Playing draws from it. Started together, both bumped
// _lyricsFetchGen, the side panel's result was thrown away, and with both
// views open it sat on its loading placeholder after every song change.
async function _refetchLyricViews(item) {
  if (lyricsPanelOpen() || _miniplayerOpen) await fetchLyrics()
  // Another song since: its own call draws it, and fetching here would
  // supersede that one's fetch in turn.
  if (queue[queueIndex] !== item) return
  if (overlayOpen && overlayLyricsOpen) renderOverlayLyrics()
}

// ── Discord RPC ───────────────────────────────────────────────────────────────

let discordEnabled = false
let rpcTrackStart = 0

/** Re-anchors the wall-clock instant Discord's progress bar is drawn from to
 *  wherever playback actually is. Needed after anything that moves the head
 *  without restarting the track - a seek, or resuming from a pause. */
function _syncRpcClock() {
  rpcTrackStart = Date.now() - Math.round(mediaPosition() * 1000)
}

// Discord renders large_image by fetching the URL from its own servers, so it
// has to be reachable from the public internet. A Jellyfin on a LAN, a
// Tailscale address or any private host never is, and the https check this used
// to do could not tell the difference.
//
// It was also handing over a Jellyfin image URL, and those carry the token (ApiKey), so
// the user's server token went to a third party and ended up baked into the
// proxied image URL that hangs off their presence. iTunes art is public,
// keyless, needs no reachable server, and the app already fetches it elsewhere
// through the same cache.
//
// A track iTunes has never heard of gets no image rather than a wrong one, and
// Discord falls back to the app icon. Same for video, which iTunes is not being
// asked about.
let _rpcArtToken = 0

// How long the presence waits on an iTunes cover before pushing without one.
// Warmed covers resolve instantly (see warmItunesArt), so this only governs the
// cold case - the first track after launch, or one picked out by hand. Long
// enough for a typical iTunes round trip, because pushing without the cover
// means Discord shows the app icon until the follow-up clears the throttle.
const RPC_ART_WAIT_MS = 800

async function updateDiscordPresence(item) {
  if (!discordEnabled || !item) return
  const video = isVideoItem(item)
  const activity = {
    details:  item.Name?.slice(0, 128) || 'Unknown Track',
    state:    (secondaryLine(item) || (video ? '' : 'Unknown Artist')).slice(0, 128),
    // Flips Discord from "Listening to Cascade" to "Watching Cascade". Read and
    // stripped in main.js - setActivity() would drop it.
    watching: video,
  }

  // Discord draws the elapsed/total progress bar itself, but only when the
  // activity carries BOTH timestamps - a start on its own gets the plain
  // "XX:XX elapsed" line instead. Prefer Jellyfin's runtime over the deck's
  // own duration: it is known before the media loads, and a progressive
  // transcode's audio.duration only counts what has been encoded so far.
  //
  // Pausing clears the presence outright rather than trying to freeze the bar,
  // so anything built here is playing by definition.
  const durMs = item.RunTimeTicks ? item.RunTimeTicks / 10_000 : mediaDuration() * 1000
  activity.startTimestamp = rpcTrackStart
  if (Number.isFinite(durMs) && durMs > 0) activity.endTimestamp = rpcTrackStart + Math.round(durMs)

  const token = ++_rpcArtToken
  const artist = item.AlbumArtist || item.Artists?.[0] || ''
  const album  = item.Album || ''
  if (video || (!artist && !album)) { window.cascade.discord.update(activity); return }

  // Discord renders assets.large_text as the third line of a listening card -
  // the album, below the track and the artist - not merely as the cover's hover
  // tooltip. So it must not be gated on the cover the way it used to be: the
  // album name is on the Jellyfin item already, while the artwork is a network
  // round trip to iTunes, and pairing them made the album name wait on a
  // lookup that has nothing to do with it.
  if (album) activity.largeImageText = album.slice(0, 128)

  // Give the cover a moment to land so the first push can carry it. An album
  // already in the cache resolves straight away, which is the common case, and
  // sending once means the card arrives complete. Anything slower still shows
  // the text now and the cover when it turns up, rather than holding the whole
  // presence hostage to a network round trip.
  //
  // This matters more than it looks: main.js throttles to one update every
  // RPC_MIN_INTERVAL_MS, so a cover sent as a separate second update waits out
  // that whole window before Discord sees it.
  const art = await Promise.race([
    fetchItunesArt(artist, album),
    new Promise(r => setTimeout(() => r(undefined), RPC_ART_WAIT_MS)),
  ])
  // The track can change while that is in flight, and a late answer for the
  // previous one would overwrite the presence that replaced it.
  if (token !== _rpcArtToken || !discordEnabled) return
  if (art) activity.largeImageKey = art
  window.cascade.discord.update(activity)
  // null is a real answer ("iTunes has never heard of this"); only undefined
  // means the deadline beat the lookup and a cover may still be coming.
  if (art !== undefined) return

  const late = await fetchItunesArt(artist, album)
  if (!late || token !== _rpcArtToken || !discordEnabled) return
  activity.largeImageKey = late
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

    // Connecting is async and main.js drops any update that lands before the
    // handshake finishes, so a track already playing by then had its presence
    // thrown away with nothing to send it again - which is why it took a
    // disable/re-enable to appear. Push it once the socket is actually up.
    // Also covers Discord itself restarting, which reconnects the same way.
    if (connected && !audio.paused) updateDiscordPresence(queue[queueIndex])
  })
}

// ── Search (persistent top bar, live dropdown) ─────────────────────────────────

let searchDebounce = null
const searchInput    = document.getElementById('search-input')
const searchDropdown = document.getElementById('search-results')

function closeSearchDropdown() { searchDropdown.classList.remove('open'); syncSearchOpen() }

// ── Search placement (title bar) ──
// A centered field on Home; on every other view (or a window too narrow for a
// centered field) the title bar takes .search-tucked and the field folds into
// a "Search" pill beside .tb-right. .search-open slides it back out while it
// has focus or results showing. The CSS does the sliding (components.css,
// "Search (in the title bar)"); this decides the classes and where the pill
// sits. Everything is looked up here rather than through the consts above, so
// showView can call it at any point.
function syncSearchPlacement() {
  const bar = /** @type {HTMLElement} */ (document.querySelector('.titlebar'))
  const box = bar.getBoundingClientRect()
  const right = bar.querySelector('.tb-right').getBoundingClientRect()
  const title = bar.querySelector('.tb-title').getBoundingClientRect()
  bar.style.setProperty('--tb-search-end', `${box.right - right.left + 8}px`)
  // The centered field's width, as components.css has it: min(340px, 36vw).
  const w = Math.min(340, window.innerWidth * 0.36)
  const mid = box.left + box.width / 2
  const narrow = mid - w / 2 < title.right + 12 || mid + w / 2 > right.left - 12
  bar.classList.toggle('search-tucked', _currentView !== 'home' || narrow)
  syncSearchOpen()
}

function syncSearchOpen() {
  const bar = document.querySelector('.titlebar')
  const input = /** @type {HTMLInputElement} */ (document.getElementById('search-input'))
  const open = document.getElementById('tb-search').contains(document.activeElement)
    || document.getElementById('search-results').classList.contains('open')
  bar.classList.toggle('search-open', open)
  input.dataset.placeholder ??= input.placeholder
  if (!open) input.placeholder = input.dataset.placeholder
}

{
  const bar = document.getElementById('tb-search')
  // Opening the pill with a click, the empty field says the shortcut exists.
  // Not when the shortcut opened it: that person already knows.
  bar.querySelector('.search-input-wrap').addEventListener('mousedown', (e) => {
    const tb = document.querySelector('.titlebar')
    if (!tb.classList.contains('search-tucked') || tb.classList.contains('search-open')) return
    e.preventDefault()
    const input = /** @type {HTMLInputElement} */ (searchInput)
    input.dataset.placeholder ??= input.placeholder
    input.placeholder = `You can use ${window.cascade.platform === 'darwin' ? '⌘K' : 'Ctrl+K'} too`
    input.focus()
  })
  bar.addEventListener('focusin', syncSearchOpen)
  // After the focus has landed, so a click into the dropdown still counts as inside.
  bar.addEventListener('focusout', () => setTimeout(syncSearchOpen))
  new ResizeObserver(syncSearchPlacement).observe(document.querySelector('.tb-right'))
  window.addEventListener('resize', syncSearchPlacement)
  syncSearchPlacement()
}

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
  if (e.key === 'Escape' && (searchDropdown.classList.contains('open') || document.activeElement === searchInput)) {
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
    markTipSeen('search-key')
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
      jfGetMerged(`/Items`, { SearchTerm: query, Recursive: true, Limit: 10, IncludeItemTypes: 'Audio', Fields: 'AlbumId,AlbumPrimaryImageTag' }),
      jfGetMerged(`/Items`, { SearchTerm: query, Recursive: true, Limit: 8,  IncludeItemTypes: 'MusicAlbum' }),
      jfGetMerged(`/Artists`,                  { SearchTerm: query, UserId: jf.userId, Limit: 8 }),
      wantMovies
        ? jfClient.getMerged(`/Items`, { SearchTerm: query, Recursive: true, Limit: 8, IncludeItemTypes: 'Movie', Fields: 'ProductionYear' }, movieLibIds)
        : Promise.resolve({ Items: [] }),
      wantShows
        ? jfClient.getMerged(`/Items`, { SearchTerm: query, Recursive: true, Limit: 8, IncludeItemTypes: 'Series', Fields: 'ProductionYear' }, showLibIds)
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

    // Wire up album/artist cards - same helpers the Albums/Artists grids use,
    // so search results get the same right-click menu for free.
    if (hasAlbums) wireAlbumCards(results, albums.Items, item => { showView('albums'); openAlbum(item.Id) })
    if (hasArtists) wireArtistCards(results, artists.Items, item => { showView('artists'); openArtist(item.Id, item.Name) })

    // Wire up movie/show cards - same detail views Movies/TV browsing opens
    if (hasMovies) wirePosterCards(document.getElementById('search-movie-grid'), movies.Items,
      item => { showView('movies'); openMovie(item.Id) }, 'video')
    if (hasShows) wirePosterCards(document.getElementById('search-show-grid'), shows.Items,
      item => { showView('shows'); openSeries(item.Id) }, 'series')
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
  syncCaptionButtons()
}

// The Windows/Linux caption buttons' symbols: the theme's, except over a film,
// where they are light in either theme so they stay visible on the picture.
// Also run by the overlay's class observer (syncWindowButtons), which sees a
// video open or close.
let _captionMode = null
function syncCaptionButtons() {
  const overVideo = overlayOpen && npOverlay.classList.contains('video')
  const mode = overVideo || document.documentElement.getAttribute('data-theme') !== 'light' ? 'dark' : 'light'
  if (mode === _captionMode) return
  _captionMode = mode
  window.cascade.setTitleBarOverlay(mode)
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
  let gradStart = document.getElementById('grad-start').value
  let gradEnd = document.getElementById('grad-end').value
  let albumArt = themeAlbumArt
  // Under a server style the controls can be showing the server's colors:
  // those are not the person's own (CascadeCore.ownValue), so switching
  // light/dark keeps what they had stored.
  const server = CascadeCore.serverStylePart(_serverStyle, 'theme') !== 'none' ? _serverStyle.preset.theme : null
  if (server) {
    let stored = {}
    try { stored = JSON.parse(await window.cascade.store.get('theme') || '{}') || {} } catch {}
    if (gradStart === server.gradStart && gradEnd === server.gradEnd) { gradStart = stored.gradStart; gradEnd = stored.gradEnd }
    albumArt = CascadeCore.ownValue(albumArt, server.albumArt, stored.albumArt, true)
  }
  await window.cascade.store.set('theme', JSON.stringify({
    mode: document.documentElement.getAttribute('data-theme') || 'dark',
    gradStart, gradEnd, albumArt,
  }))
  _ceChanged()
}

async function loadTheme() {
  let t = null
  try { t = JSON.parse(await window.cascade.store.get('theme') || 'null') } catch {}
  if (t?.mode === 'light') setThemeMode('light')
  // The server style (src/core/server-style.ts) layers over what is stored and
  // is never saved into it. "Set" colors are ones moved off the shipped
  // gradient, since switching light/dark alone also writes this key.
  const def = CascadeCore.PRESET_DEFAULT_GRADIENT
  const hasGradient = !!(t?.gradStart && t?.gradEnd)
  const colorsSet = !!t?.albumArt || (hasGradient && (t.gradStart !== def.start || t.gradEnd !== def.end))
  const look = CascadeCore.layeredLook({
    gradStart: hasGradient ? t.gradStart : def.start, gradEnd: hasGradient ? t.gradEnd : def.end,
    albumArt: !!t?.albumArt, bgDim: 0, bgBlend: true, lyricScale: 1,
  }, { colors: colorsSet, bgDim: true, bgBlend: true, lyricScale: true }, _serverStyle)
  document.getElementById('grad-start').value = look.gradStart
  document.getElementById('grad-end').value = look.gradEnd
  const wasAlbumArt = themeAlbumArt
  themeAlbumArt = look.albumArt
  document.getElementById('toggle-album-art').checked = look.albumArt
  if (look.albumArt) {
    const img = document.querySelector('#ov-art img') || document.querySelector('#np-art img')
    if (img) themeFromArtUrl(img.src)
  } else {
    if (wasAlbumArt) clearAlbumArtTheme()
    applyGradient(look.gradStart, look.gradEnd)
  }
  buildPresets()
  updateAccentLock()
}

// ── UI font ───────────────────────────────────────────────────────────────────
// Same store-then-apply shape as theme above, kept in its own key (uiFont)
// rather than folded into 'theme' - font family and colour theme are
// unrelated settings that happen to share a popover for now.

/** The one place that writes --font (styles/base.css). CascadeCore.resolveUiFont()
 *  is the one place that turns a stored (preset, custom name) pair into a safe
 *  value - see src/core/font.ts for why an unsanitized custom name can't go
 *  straight into a CSS custom property with no fallback downstream. */
function applyUiFont(preset, custom) {
  document.documentElement.style.setProperty('--font', CascadeCore.resolveUiFont(preset, custom))
}

async function saveUiFont(preset, custom) {
  await window.cascade.store.set('uiFont', JSON.stringify({ preset, custom }))
  applyUiFont(preset, custom)
  _ceChanged()
}

async function loadUiFont() {
  let preset = 'system', custom = ''
  try {
    const raw = await window.cascade.store.get('uiFont')
    if (raw) {
      const f = JSON.parse(raw)
      preset = f.preset
      custom = f.custom
    }
  } catch {}
  applyUiFont(preset, custom)
  const presetSel = document.getElementById('tp-font-preset')
  const customInput = document.getElementById('tp-font-custom')
  // A stale preset id from an older build falls back to System in the UI too,
  // not just in the resolved CSS value.
  const validPreset = (preset === 'custom' || preset in CascadeCore.FONT_PRESETS) ? preset : 'system'
  if (presetSel) presetSel.value = validPreset
  if (customInput) {
    customInput.value = typeof custom === 'string' ? custom : ''
    customInput.hidden = validPreset !== 'custom'
  }
}

document.getElementById('tp-font-preset').addEventListener('change', (e) => {
  const preset = e.target.value
  const customInput = document.getElementById('tp-font-custom')
  customInput.hidden = preset !== 'custom'
  if (preset === 'custom') customInput.focus()
  saveUiFont(preset, customInput.value)
})

document.getElementById('tp-font-custom').addEventListener('input', (e) => {
  saveUiFont('custom', e.target.value)
})

// ── Now Playing tuning ───────────────────────────────────────────────────────
// Lyric size, background dim and background blend: persisted, user-facing
// versions of the same CSS custom properties initLightTuningPanel() (below)
// exposes as session-only debug sliders - --np-lyric-scale drives
// .ov-lyric-line's font-size, --np-scrim-left/right/header and --np-blend
// drive the light-theme art-accent scrims (styles/theme.css's "four custom
// properties" block). One dim knob sets all three scrims identically, since
// they already share one shipped default (see src/core/np-tuning.ts) and the
// debug panel's per-scrim split exists for tuning, not for a normal setting
// to expose. setOverlayBackgroundImage() stays the only writer of the
// overlay's actual background image - none of this touches it, only the
// blend/scrim painted on top of whatever that set.
//
// CascadeCore's clamp*() functions are the one place a corrupted stored
// number gets turned into something safe before it can reach a CSS value -
// same "store values are untrusted" rule as everywhere else.
function applyNpTuning(lyricScale, bgDim, bgBlend) {
  const root = document.documentElement
  root.style.setProperty('--np-lyric-scale', String(CascadeCore.clampLyricScale(lyricScale)))
  const dim = String(CascadeCore.clampBgDim(bgDim))
  root.style.setProperty('--np-scrim-left', dim)
  root.style.setProperty('--np-scrim-right', dim)
  root.style.setProperty('--np-scrim-header', dim)
  root.style.setProperty('--np-blend', CascadeCore.clampBgBlend(bgBlend) ? 'multiply' : 'normal')
}

async function saveNpTuning(lyricScale, bgDim, bgBlend) {
  applyNpTuning(lyricScale, bgDim, bgBlend)
  // Each value that only shows the server style through stays as stored (or
  // unset), so it keeps filling in for this person (CascadeCore.ownValue).
  const t = _serverStyle.preset?.theme, l = _serverStyle.preset?.lyrics
  let own = { lyricScale, bgDim, bgBlend }
  if (_serverStyle.mode !== 'off') {
    let stored = {}
    try { stored = JSON.parse(await window.cascade.store.get('npTuning') || '{}') || {} } catch {}
    const theme = CascadeCore.serverStylePart(_serverStyle, 'theme') !== 'none'
    const lyrics = CascadeCore.serverStylePart(_serverStyle, 'lyrics') !== 'none'
    own = {
      lyricScale: CascadeCore.ownValue(lyricScale, l?.lyricScale, stored.lyricScale, lyrics),
      bgDim: CascadeCore.ownValue(bgDim, t?.bgDim, stored.bgDim, theme),
      bgBlend: CascadeCore.ownValue(bgBlend, t?.bgBlend, stored.bgBlend, theme),
    }
  }
  await window.cascade.store.set('npTuning', JSON.stringify(own))
  _ceChanged()
}

// ── Lyrics look (Theme panel > Lyrics) ──────────────────────────────────────
// Knobs, ranges and defaults live in src/core/lyric-style.ts. Most are CSS
// custom properties on :root; three are read from JS: where the current line
// sits, the ripple between lines, and how early lyrics are drawn. Only the
// changed knobs are stored, under 'lyricStyle'.
let lyricStyle = CascadeCore.lyricStyleFrom({})

function applyLyricStyle(style) {
  lyricStyle = CascadeCore.lyricStyleFrom(style)
  const root = document.documentElement
  for (const [prop, value] of Object.entries(CascadeCore.lyricStyleCss(lyricStyle))) root.style.setProperty(prop, value)
  ovLyricLinePosition = lyricStyle.currentLinePosition
  LYRIC_MOTION.ripple = lyricStyle.rippleSeconds * 1000
  _lyricLead = -lyricStyle.lyricsDelay
  ovIdleMs = lyricStyle.controlsIdleSeconds * 1000
  // The drift loop repaints the blobs with these on its next frame; the base
  // colour and the dim are set here.
  Object.assign(CascadeCore.blobLook, {
    saturation: lyricStyle.bgSaturation, brightness: lyricStyle.bgBrightness,
    intensity: lyricStyle.bgIntensity, speed: lyricStyle.bgSpeed,
  })
  const overlay = document.getElementById('np-overlay')
  if (overlay?.classList.contains('art-theme')) {
    overlay.style.backgroundColor = _blobBaseColor()
    if (_blobColors.length) setOverlayBackgroundImage(overlay, buildBlobBackground(_blobColors, _isLightTheme()))
  }
  _applyLyricsDim()
}

async function saveLyricStyle(style) {
  applyLyricStyle(style)
  const changes = CascadeCore.lyricStyleChanges(lyricStyle)
  // Knobs only showing the server style through stay as stored (CascadeCore.ownValue).
  if (CascadeCore.serverStylePart(_serverStyle, 'lyrics') !== 'none') {
    let stored = {}
    try { stored = JSON.parse(await window.cascade.store.get('lyricStyle') || '{}') || {} } catch {}
    const server = _serverStyle.preset.lyrics.style
    for (const key of Object.keys(server)) {
      const v = CascadeCore.ownValue(changes[key], server[key], stored[key], true)
      if (v === undefined) delete changes[key]; else changes[key] = v
    }
  }
  await window.cascade.store.set('lyricStyle', JSON.stringify(changes))
  _ceChanged()
}

async function loadLyricStyle() {
  let stored = null
  try { stored = JSON.parse(await window.cascade.store.get('lyricStyle') || 'null') } catch {}
  applyLyricStyle(CascadeCore.layeredLyricChanges(stored, _serverStyle))
  renderLyricKnobs()
  applyServerStyleLocks()
}

// Re-baked lyric defaults reach everyone who never touched those knobs by
// themselves. Someone who did is asked once, on opening Now Playing, naming
// the knobs (CascadeCore.lyricKnobsWithNewDefaults). Asked at most once a session.
let _lyricDefaultsAsked = false
async function maybeOfferNewLyricDefaults() {
  if (_lyricDefaultsAsked) return
  _lyricDefaultsAsked = true
  const seen = await window.cascade.store.get('lyricStyleDefaultsSeen')
  const knobs = CascadeCore.lyricKnobsWithNewDefaults(CascadeCore.lyricStyleChanges(lyricStyle), seen)
  const markSeen = () => window.cascade.store.set('lyricStyleDefaultsSeen', CascadeCore.LYRIC_DEFAULTS_REVISION)
  if (!knobs.length) { markSeen(); return }
  // A beat after opening, so it does not land on the transition.
  await new Promise(r => setTimeout(r, 600))
  const count = knobs.length === 1 ? 'one of these settings' : `${knobs.length} of these settings`
  const useNew = await showChoice('New lyric defaults',
    `Cascade's lyric look was retuned. You changed ${count} yourself: ${knobs.map(k => k.label).join(', ')}. Use the new defaults for them, or keep yours?`,
    'Use the New Defaults', 'Keep Mine')
  if (useNew) {
    const next = { ...lyricStyle }
    const defaults = CascadeCore.lyricStyleFrom({})
    for (const k of knobs) next[k.key] = defaults[k.key]
    await saveLyricStyle(next)
    renderLyricKnobs()
  }
  await markSeen()
}

async function loadNpTuning() {
  let lyricScale, bgDim, bgBlend
  try {
    const raw = await window.cascade.store.get('npTuning')
    if (raw) {
      const t = JSON.parse(raw)
      lyricScale = t.lyricScale; bgDim = t.bgDim; bgBlend = t.bgBlend
    }
  } catch {}
  const look = CascadeCore.layeredLook({
    gradStart: '', gradEnd: '', albumArt: false,
    bgDim: CascadeCore.clampBgDim(bgDim), bgBlend: CascadeCore.clampBgBlend(bgBlend), lyricScale: CascadeCore.clampLyricScale(lyricScale),
  }, { colors: true, bgDim: bgDim !== undefined, bgBlend: bgBlend !== undefined, lyricScale: lyricScale !== undefined }, _serverStyle)
  lyricScale = look.lyricScale; bgDim = look.bgDim; bgBlend = look.bgBlend
  applyNpTuning(lyricScale, bgDim, bgBlend)
  const scaleInput = document.getElementById('tp-lyric-scale')
  const dimInput = document.getElementById('tp-bg-dim')
  const blendInput = document.getElementById('tp-bg-blend')
  if (scaleInput) scaleInput.value = String(lyricScale)
  if (dimInput) dimInput.value = String(bgDim)
  if (blendInput) blendInput.checked = bgBlend
  _syncNpTuningLabels()
}

/** The percentages beside the text size and background dim sliders. */
function _syncNpTuningLabels() {
  for (const id of ['tp-lyric-scale', 'tp-bg-dim']) {
    document.getElementById(id + '-value').textContent = `${Math.round(parseFloat(document.getElementById(id).value) * 100)}%`
  }
}

/** Reads all three controls' current values, so any one changing saves and
 *  applies the whole set together - matches how they are stored (one key). */
function _npTuningInputValues() {
  return [
    parseFloat(document.getElementById('tp-lyric-scale').value),
    parseFloat(document.getElementById('tp-bg-dim').value),
    document.getElementById('tp-bg-blend').checked,
  ]
}

document.getElementById('tp-lyric-scale').addEventListener('input', () => { _syncNpTuningLabels(); saveNpTuning(..._npTuningInputValues()) })
document.getElementById('tp-bg-dim').addEventListener('input', () => { _syncNpTuningLabels(); saveNpTuning(..._npTuningInputValues()) })
document.getElementById('tp-bg-blend').addEventListener('change', () => saveNpTuning(..._npTuningInputValues()))

/** Album art accent mode overrides whatever gradient/preset is picked, so
 *  those controls do nothing while it's on - dim them and say why rather
 *  than leaving them clickable but inert. */
function updateAccentLock() {
  const locked = themeAlbumArt
  ;[document.querySelector('.tp-colors'), document.getElementById('tp-presets')].forEach(host => {
    if (!host) return
    host.classList.toggle('locked', locked)
    if (locked) host.setAttribute('data-tip', 'Album art theme overrides this')
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
    const side = CascadeCore.blobTuning.sampleSide
    canvas.width = canvas.height = side
    const ctx = canvas.getContext('2d', { willReadFrequently: true })
    // Nearest-neighbour, not the default smooth scale. Smoothing blends
    // neighbouring pixels, so red beside blue produces purple that appears
    // nowhere in the artwork - and with only 6400 samples an invented colour
    // could win outright. Sampling real pixels can miss a very small detail;
    // inventing colours misreports the whole cover, which is worse.
    ctx.imageSmoothingEnabled = false
    ctx.drawImage(img, 0, 0, side, side)
    return CascadeCore.extractTopColors(ctx.getImageData(0, 0, side, side).data, n, light)
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
  return CascadeCore.blobBaseCss(_isLightTheme())
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

// Extract colours from an art URL and theme from them.
//
// Always go via fetch -> blob -> objectURL, never hand applyAlbumArtTheme an
// <img> that is already in the DOM: those are written by innerHTML with no
// crossorigin, so the canvas extractTopColors draws them into is tainted,
// getImageData throws, and the catch there returns no colours at all - the
// symptom being a theme toggle that looks completely dead. Do NOT "fix" that by
// putting crossorigin="anonymous" on the img tags instead; that sends an Origin
// header the Jellyfin server may not answer, which breaks the image itself
// rather than only its colours.
function themeFromArtUrl(art) {
  if (!art) return
  // offline-ok: art is a downloaded cover (cascade-offline://) as often as the
  // server's; offline, main's block or no network answers a server URL.
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
  fadeOverlayColors(overlay)
  // Set gradient directly on the overlay - no z-index/clipping issues
  overlay.style.backgroundColor = _blobBaseColor()
  setOverlayBackgroundImage(overlay, buildBlobBackground(_blobColors, light))
  overlay.classList.add('art-theme')
  _applyLyricsDim()
}

// The background's colors fade from the last song's instead of jumping: over
// the crossfade itself while one runs (set at its handover), briefly for any
// other song change. Only the first colors for a song fade; the sharper
// cover's second pass (the iTunes upgrade) just settles under the same fade.
let _ovColorFadeUntil = 0   // performance.now() the crossfade ends, set at its handover
let _ovColorsFor = null     // the song the background's colors are for

function fadeOverlayColors(overlay) {
  const songId = queue[queueIndex]?.Id ?? null
  if (songId === _ovColorsFor) return
  _ovColorsFor = songId
  const prev = document.getElementById('ov-bg-prev')
  if (!prev || !overlay.classList.contains('art-theme') || !overlay.style.backgroundImage) return
  const left = _ovColorFadeUntil - performance.now()
  _ovColorFadeUntil = 0
  const skipMs = displayPrefs.colorFadeSeconds * 1000
  const ms = left > skipMs ? left : skipMs
  if (!displayPrefs.colorFade || matchMedia('(prefers-reduced-motion: reduce)').matches) return
  for (const a of prev.getAnimations()) a.cancel()
  prev.style.backgroundImage = overlay.style.backgroundImage
  prev.style.backgroundColor = overlay.style.backgroundColor
  const fade = prev.animate([{ opacity: 1 }, { opacity: 0 }], { duration: ms, easing: 'ease-in-out', fill: 'forwards' })
  fade.finished.then(() => { prev.style.backgroundImage = ''; prev.style.backgroundColor = '' }).catch(() => {})
}

function clearAlbumArtTheme() {
  const overlay = document.getElementById('np-overlay')
  overlay.classList.remove('art-theme')
  setOverlayBackgroundImage(overlay, '')
  overlay.style.backgroundColor = ''
  document.documentElement.style.removeProperty('--art-overlay-bg')
  _blobColors = []
  _driftParams = []
  _applyLyricsDim()
}

// The background darkens behind lyrics: by lyricsDimBase, plus up to
// lyricsDimBright more for a bright cover (Oklab lightness from lyricsDimFrom
// up to the dark palette's 0.82 ceiling), so faint upcoming lines still read
// over a light salmon or yellow. #ov-bg-pulse is the black layer over the
// blobs and under everything else. Dark theme only, as on the Apple apps: the
// light theme lays its own scrims. Both dims default to 0 on the desktop
// (tuning-defaults.json), whose panels are already tinted.
function _applyLyricsDim() {
  const el = document.getElementById('ov-bg-pulse')
  if (!el) return
  const lyrics = (overlayLyricsOpen && !_ovLyricsMissing) || _ce.open
  let dim = 0
  if (lyrics && themeAlbumArt && _blobColors.length && !_isLightTheme()) {
    const from = lyricStyle.lyricsDimFrom
    const bright = Math.min(1, Math.max(0, (CascadeCore.blobBrightness(_blobColors) - from) / Math.max(0.82 - from, 0.01)))
    dim = Math.min(1, lyricStyle.lyricsDimBase + lyricStyle.lyricsDimBright * bright)
  }
  el.style.opacity = String(dim)
}

// Wire up theme picker UI
// The Theme panel has two pages: the main one, and Share a look behind its
// row. Every way of closing it goes back to the main page.
function showThemePage(name) {
  if (name === 'presets') markTipSeen('presets')
  const picker = document.getElementById('theme-picker')
  for (const page of picker.querySelectorAll('.tp-page')) page.classList.toggle('active', page.dataset.page === name)
  picker.scrollTop = 0
}
function closeThemePicker() {
  document.getElementById('theme-picker').classList.remove('open')
  showThemePage('main')
}
// Opened from the paintbrush in the title bar. Now Playing's paintbrush opens
// the customization editor instead (openEditor).
document.getElementById('theme-btn').addEventListener('click', (e) => {
  e.stopPropagation()
  const picker = document.getElementById('theme-picker')
  if (picker.classList.contains('open')) closeThemePicker()
  else {
    _syncStyleEntries()
    picker.classList.add('open')
    setTimeout(() => showTipOnce('presets', picker.querySelector('[data-open="presets"]'),
      'Share a look saves this theme as a file or text you can send someone, and loads looks other people made.'), 300)
  }
})
document.getElementById('theme-picker').addEventListener('click', (e) => {
  if (e.target.closest('.tp-close')) { closeThemePicker(); return }
  const nav = e.target.closest('[data-open]')
  if (nav) showThemePage(nav.dataset.open)
})
document.addEventListener('mousedown', (e) => {
  const picker = document.getElementById('theme-picker')
  if (picker.classList.contains('open') && !picker.contains(e.target) && !e.target.closest('#theme-btn')) {
    closeThemePicker()
  }
})

// Lyrics tab: one section per CascadeCore.LYRIC_KNOBS section, one slider per
// knob, each with its value and a reset arrow that shows once it differs from
// the default.
function renderLyricKnobs() {
  const box = document.getElementById('tp-lyric-knobs')
  box.replaceChildren()
  let sect = null
  for (const k of CascadeCore.LYRIC_KNOBS) {
    if (sect?.dataset.section !== k.section) {
      sect = document.createElement('section')
      sect.className = 'ce-sect'
      sect.dataset.lock = 'lyrics'
      sect.dataset.section = k.section
      sect.innerHTML = '<h3 class="ce-sect-title"></h3><p class="ce-lock-note">Set by your server admin.</p>'
      sect.querySelector('h3').textContent = k.section
      box.append(sect)
    }
    const row = document.createElement('div')
    row.className = 'setting-row tp-knob'
    row.dataset.key = k.key
    row.innerHTML = `<div class="setting-label tp-knob-head"><label class="setting-name" for="knob-${k.key}"></label>`
      + '<button type="button" class="tp-knob-reset" title="Reset to default">↺</button></div>'
      + `<div class="setting-slider-row"><input type="range" class="tp-range" id="knob-${k.key}"><span class="eq-band-value tp-knob-value"></span></div>`
    row.querySelector('label').textContent = k.label
    row.querySelector('.tp-knob-reset').setAttribute('aria-label', `Reset ${k.label} to default`)
    const input = row.querySelector('input')
    Object.assign(input, { min: k.min, max: k.max, step: k.step })
    input.setAttribute('aria-label', `${k.section}: ${k.label}`)
    sect.append(row)
  }
  syncLyricKnobs()
}

function syncLyricKnobs() {
  for (const row of document.querySelectorAll('#tp-lyric-knobs .tp-knob')) {
    const k = CascadeCore.lyricKnob(row.dataset.key)
    const v = lyricStyle[k.key]
    const decimals = (String(k.step).split('.')[1] || '').length
    row.querySelector('input').value = String(v)
    row.querySelector('.tp-knob-value').textContent = v.toFixed(decimals)
    row.classList.toggle('changed', Math.abs(v - k.value) > 1e-9)
  }
}

document.getElementById('tp-lyric-knobs').addEventListener('input', (e) => {
  const row = e.target.closest('.tp-knob')
  if (!row) return
  saveLyricStyle({ ...lyricStyle, [row.dataset.key]: parseFloat(e.target.value) })
  syncLyricKnobs()
})
document.getElementById('tp-lyric-knobs').addEventListener('click', (e) => {
  const row = e.target.closest('.tp-knob-reset') && e.target.closest('.tp-knob')
  if (!row) return
  saveLyricStyle({ ...lyricStyle, [row.dataset.key]: CascadeCore.lyricKnob(row.dataset.key).value })
  syncLyricKnobs()
})

// ── Presets (Theme panel > Share a look) ────────────────────────────────────
// A preset is the theme (mode, gradient, album art accent, background dim and
// blend, font) and/or the lyrics style (knobs plus text size). The format and
// every check live in src/core/presets.ts; this reads the live controls and
// applies a preset through the same save paths those controls use, so an
// imported look is stored exactly as if it had been set by hand.

let _presetBusy = false

/** The current look as a preset, limited to the parts switched on, or null
 *  (after saying why) when both are off. */
function currentPreset() {
  const withTheme = document.getElementById('tp-preset-theme').checked
  const withLyrics = document.getElementById('tp-preset-lyrics').checked
  if (!withTheme && !withLyrics) {
    showNotice('Switch on colors, lyrics style, or both to make a preset.', 'Preset')
    return null
  }
  const theme = withTheme ? {
    mode: _isLightTheme() ? 'light' : 'dark',
    gradStart: document.getElementById('grad-start').value,
    gradEnd: document.getElementById('grad-end').value,
    albumArt: themeAlbumArt,
    bgDim: parseFloat(document.getElementById('tp-bg-dim').value),
    bgBlend: document.getElementById('tp-bg-blend').checked,
    font: { preset: document.getElementById('tp-font-preset').value, custom: document.getElementById('tp-font-custom').value },
  } : undefined
  const lyrics = withLyrics ? {
    style: CascadeCore.lyricStyleChanges(lyricStyle),
    lyricScale: parseFloat(document.getElementById('tp-lyric-scale').value),
  } : undefined
  return CascadeCore.buildPreset({ name: document.getElementById('tp-preset-name').value, theme, lyrics })
}

/** Applies a parsed (already validated) preset. Parts it does not carry are
 *  left alone. */
async function applyPreset(preset) {
  const t = preset.theme
  if (t) {
    setThemeMode(t.mode)
    document.getElementById('grad-start').value = t.gradStart
    document.getElementById('grad-end').value = t.gradEnd
    applyGradient(t.gradStart, t.gradEnd)
    // Saves the theme key too, with the mode and gradient set just above.
    setAlbumArtAccent(t.albumArt)
    markActivePreset()
    await saveUiFont(t.font.preset, t.font.custom)
    await loadUiFont()
  }
  if (preset.lyrics) {
    await saveLyricStyle(preset.lyrics.style)
    syncLyricKnobs()
  }
  // Text size, background dim and blend share one store key (npTuning), so
  // they are written together from whichever side the preset carries.
  if (t || preset.lyrics) {
    const [scale, dim, blend] = _npTuningInputValues()
    await saveNpTuning(preset.lyrics ? preset.lyrics.lyricScale : scale, t ? t.bgDim : dim, t ? t.bgBlend : blend)
    await loadNpTuning()
  }
  document.getElementById('tp-preset-name').value = preset.name === 'Untitled' ? '' : preset.name
  // What the server enforces stays on top of an imported look.
  if (_serverStyle.mode !== 'off') await reapplyLook()
}

async function importPresetText(text) {
  const r = CascadeCore.parsePreset(text)
  if (!r.ok) { showNotice(r.error, 'Preset'); return }
  await applyPreset(r.preset)
  showToast(`Applied "${r.preset.name}"`)
}

/** Toasts are dev-only, so a button that has nothing visible to show for
 *  itself (a copy, a save) says it worked in its own label for a moment. */
function flashPresetButton(btn, label) {
  const original = btn.dataset.label || btn.textContent
  btn.dataset.label = original
  btn.textContent = label
  clearTimeout(btn._flashTimer)
  btn._flashTimer = setTimeout(() => { btn.textContent = original }, 1600)
}

/** One preset action at a time: a second press while a dialog is open would
 *  otherwise stack another dialog or apply twice. */
async function runPresetAction(fn) {
  if (_presetBusy) return
  _presetBusy = true
  try { await fn() } catch (e) { showNotice(`Something went wrong with the preset.\n\n${e.message}`, 'Preset') }
  finally { _presetBusy = false }
}

document.getElementById('tp-preset-export').addEventListener('click', () => runPresetAction(async () => {
  const preset = currentPreset()
  if (!preset) return
  const res = await window.cascade.presets.save(CascadeCore.presetFileName(preset.name), CascadeCore.serializePreset(preset))
  if (res.ok) flashPresetButton(document.getElementById('tp-preset-export'), 'Exported')
  else if (!res.canceled) showNotice(`Could not save the preset.\n\n${res.error || ''}`, 'Preset')
}))

document.getElementById('tp-preset-copy').addEventListener('click', () => runPresetAction(async () => {
  const preset = currentPreset()
  if (!preset) return
  await window.cascade.clipboard.write(CascadeCore.serializePreset(preset))
  flashPresetButton(document.getElementById('tp-preset-copy'), 'Copied')
}))

document.getElementById('tp-preset-import').addEventListener('click', () => runPresetAction(async () => {
  const res = await window.cascade.presets.open()
  if (res.canceled) return
  if (!res.ok) { showNotice(`Could not open the preset.\n\n${res.error || ''}`, 'Preset'); return }
  await importPresetText(res.text)
}))

document.getElementById('tp-preset-paste').addEventListener('click', () => runPresetAction(async () => {
  await importPresetText(await window.cascade.clipboard.read())
}))

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
  if (themeAlbumArt) {
    // Apply immediately from current art
    const img = document.querySelector('#ov-art img') || document.querySelector('#np-art img')
    themeFromArtUrl(img?.src)
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

// ── Customization editor ─────────────────────────────────────────────────────
//
// docs/customization-editor-spec.md. Now Playing's paintbrush (or the title bar
// dropdown's Style button, or Settings > Playback > Cover transitions) turns the
// left column into a narrow sidebar and puts the look's settings beside the
// live lyrics. Every control saves the moment it changes, through the save path
// it always used; the editor adds only a reset per tab and an undo back to how
// things were when it opened.
//
// The sidebar is the player's own art and transport buttons restyled by
// .editing (styles/editor.css), so it can never disagree with the player.
// Mode, colors, font and Share a look are the title bar dropdown's own
// elements, moved in while the editor is open (_ceMoveShared): one set of
// controls, so the two are in sync by construction.
//
// Motion is transforms and opacity only: the art travels into the sidebar by
// FLIP (_ceFlip), never by animating its size.
const CE_TABS = ['appearance', 'nowplaying', 'lyrics', 'crossfade', 'presets']
const CE_EASE = 'cubic-bezier(0.2, 0.7, 0.3, 1)'
// Every displayPrefs key the editor can change (the Cascade Server extras stay in Settings).
const CE_DISPLAY_KEYS = Object.keys(DISPLAY_PREF_DEFAULTS).filter(k => k !== 'explicitMarks' && k !== 'videoCovers' && k !== 'skipTransitions')
const CE_NO_SONG_TIP = 'Start playing something to customize Now Playing.'
const CE_VIDEO_TIP = 'Now Playing for videos has nothing to customize. Play a song to customize it.'
const CE_RESET_TEXT = {
  appearance: 'Mode, colors and font go back to how Cascade ships them.',
  nowplaying: 'The album art theme, background dim and blend, and the color fade go back to how Cascade ships them.',
  lyrics: 'Both text sizes and every lyrics setting go back to how Cascade ships them.',
  crossfade: 'The cover animation goes back to how Cascade ships it.',
  presets: 'Both Include switches turn back on and the name is cleared.',
}
// open; tab is remembered for the session only; snapshot is what undo goes back to.
const _ce = { open: false, tab: 'appearance', snapshot: null, wasLyrics: false, applying: false, previewKey: '', previewTemp: null }
const _ceTabs = [...document.querySelectorAll('.ce-tabs .sn-item')]
const _cePill = document.querySelector('.ce-tabs .sn-pill')
const _ceReduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches
const _ceNarrow = () => matchMedia('(max-width: 699px)').matches

function _ceCanOpen() {
  const item = queue[queueIndex]
  return !!item && !isVideoItem(item)
}

/** The Style button and the Settings link: disabled with a tooltip saying why
 *  while there is no song to customize. aria-disabled keeps them focusable, so
 *  the tooltip shows for keyboard focus too; their handlers check again. */
function _syncStyleEntries() {
  const item = queue[queueIndex]
  const tip = !item ? CE_NO_SONG_TIP : isVideoItem(item) ? CE_VIDEO_TIP : ''
  for (const id of ['tp-style-btn', 's-customize-np']) {
    const el = document.getElementById(id)
    el.setAttribute('aria-disabled', String(!!tip))
    if (tip) el.setAttribute('data-tip', tip)
    else el.removeAttribute('data-tip')
  }
}

function _ceMoveShared(intoEditor) {
  for (const el of document.querySelectorAll('[data-share]')) {
    const to = document.querySelector(`[data-${intoEditor ? 'slot' : 'home'}="${el.dataset.share}"]`)
    if (to && el.parentElement !== to) to.append(el)
  }
}

/** The art and the three transport buttons, which travel between the player
 *  and the sidebar. */
const _ceFlipEls = () => [document.querySelector('.np-overlay-art'), ...['ov-prev', 'ov-play', 'ov-next'].map(id => document.getElementById(id))]

/** Runs `mutate` (a layout change) and animates `els` from where they were to
 *  where they are now, by transform alone. */
function _ceFlip(els, mutate, ms) {
  // Measured mid-flight if a flip is still running (a quick reopen), so the
  // next one starts from where the element is, then takes over from it.
  const before = els.map(el => el.getBoundingClientRect())
  for (const el of els) for (const a of el.getAnimations()) if (a.id === 'ce-flip') a.cancel()
  mutate()
  const anims = []
  els.forEach((el, i) => {
    const a = before[i], b = el.getBoundingClientRect()
    if (!a.width || !b.width) return
    const from = `translate(${a.left - b.left}px, ${a.top - b.top}px) scale(${a.width / b.width}, ${a.height / b.height})`
    anims.push(el.animate([{ transform: from, transformOrigin: '0 0' }, { transform: 'none', transformOrigin: '0 0' }], { duration: ms, easing: CE_EASE, id: 'ce-flip' }))
  })
  return Promise.all(anims.map(a => a.finished.catch(() => {})))
}

/** A layout change with the art's width transition held off, so the art jumps
 *  to its new size and only the FLIP (or nothing) moves it. */
function _ceRelayout(mutate, animate, ms) {
  npOverlay.classList.add('ce-moving')
  const done = animate ? _ceFlip(_ceFlipEls(), mutate, ms) : (mutate(), npOverlay.offsetWidth, Promise.resolve())
  done.then(() => npOverlay.classList.remove('ce-moving'))
}

function openEditor({ tab = _ce.tab, instant = false } = {}) {
  if (_ce.open || !_ceCanOpen()) return
  markTipSeen('np-customize')
  closeThemePicker()
  if (!overlayOpen) { openOverlay(); instant = true }
  const menu = document.getElementById('ce-menu')
  // A close still fading out is dropped first.
  for (const a of menu.getAnimations()) a.cancel()
  menu.classList.remove('leaving')
  menu.removeAttribute('style')
  _ce.open = true
  _ceMoveShared(true)
  _ce.snapshot = _ceSnapshot()
  document.getElementById('ce-undo').hidden = true
  _ce.wasLyrics = overlayLyricsOpen
  overlayLyricsOpen = true
  clearTimeout(_ovIdleTimer)
  npOverlay.classList.remove('idle')
  const reduced = _ceReduced()
  _ceRelayout(() => { npOverlay.classList.add('editing'); _applyOverlayPanels() }, !instant && !reduced, 350)
  _ceShowTab(CE_TABS.includes(tab) ? tab : 'appearance', false)
  if (!_ce.wasLyrics) renderOverlayLyrics()
  if (!instant) {
    if (reduced) document.querySelector('.np-overlay-body').animate([{ opacity: 0 }, { opacity: 1 }], { duration: 150, easing: 'linear' })
    else menu.animate([{ opacity: 0, transform: 'translateX(-32px)' }, { opacity: 1, transform: 'none' }], { duration: 350, delay: 100, easing: CE_EASE, fill: 'backwards' })
  }
  document.getElementById('np-theme-btn').setAttribute('aria-expanded', 'true')
  _ceTabs[CE_TABS.indexOf(_ce.tab)].focus({ preventScroll: true })
}

/** Instant when Now Playing itself is closing (closeOverlay) or a video took over. */
function closeEditor({ instant = false } = {}) {
  if (!_ce.open) return
  _ce.open = false
  _ce.snapshot = null
  _cePreviewStop()
  clearTimeout(_ce.previewTemp)
  const menu = document.getElementById('ce-menu')
  const animate = !instant && overlayOpen && !_ceReduced()
  const settle = () => {
    if (_ce.open) return
    for (const a of menu.getAnimations()) a.cancel()
    menu.classList.remove('leaving')
    menu.removeAttribute('style')
    _ceMoveShared(false)
  }
  if (animate) {
    // Pinned where it is, so the layout can change under it while it fades
    // and the art travels back at the same time.
    const r = menu.getBoundingClientRect(), body = menu.parentElement.getBoundingClientRect()
    Object.assign(menu.style, { left: `${r.left - body.left}px`, top: `${r.top - body.top}px`, width: `${r.width}px`, height: `${r.height}px` })
    menu.classList.add('leaving')
    // Held at its end (fill) until settle drops it, so it cannot flash back for a frame.
    menu.animate([{ opacity: 1, transform: 'none' }, { opacity: 0, transform: 'translateX(-32px)' }], { duration: 200, easing: CE_EASE, fill: 'forwards' })
      .finished.catch(() => {}).then(settle)
  }
  _ceSetPreview(false, !instant && overlayOpen)
  overlayLyricsOpen = _ce.wasLyrics
  _ceRelayout(() => {
    npOverlay.classList.remove('editing', 'ce-show-preview')
    _applyOverlayPanels()
  }, animate, 300)
  if (!animate) {
    settle()
    if (!instant && overlayOpen) document.querySelector('.np-overlay-body').animate([{ opacity: 0 }, { opacity: 1 }], { duration: 150, easing: 'linear' })
  }
  _ceShowPreviewPane(false)
  document.getElementById('np-theme-btn').setAttribute('aria-expanded', 'false')
  if (!instant && overlayOpen) document.getElementById('np-theme-btn').focus({ preventScroll: true })
}

function _cePlacePill(animate) {
  const t = _ceTabs[CE_TABS.indexOf(_ce.tab)]
  if (!t.offsetWidth) return   // hidden; the observer below places it on show
  if (!animate) _cePill.style.transition = 'none'
  _cePill.style.width = `${t.offsetWidth}px`
  _cePill.style.transform = `translateX(${t.offsetLeft}px)`
  if (!animate) { _cePill.offsetWidth; _cePill.style.transition = '' }
}

function _ceShowTab(name, animate) {
  const from = document.getElementById(`ce-panel-${_ce.tab}`), to = document.getElementById(`ce-panel-${name}`)
  _ce.tab = name
  _ceTabs.forEach(t => {
    const on = t.dataset.tab === name
    t.classList.toggle('active', on)
    t.setAttribute('aria-selected', String(on))
    t.tabIndex = on ? 0 : -1
  })
  _cePlacePill(animate)
  for (const el of [from, to]) el.getAnimations().forEach(a => a.finish())
  for (const p of document.querySelectorAll('.ce-panel')) p.classList.toggle('active', p === to)
  document.getElementById('ce-body').scrollTop = 0
  if (name === 'crossfade') {
    document.getElementById('ce-cf-length').textContent = crossfadeEnabled ? `Crossfade length: ${crossfadeSeconds}s.` : 'Crossfade is off.'
  }
  _ceSetPreview(name === 'crossfade', animate)
  if (name === 'developer') { refreshDebugMetrics(); _renderDevDiagnostics() }
  if (!animate || from === to) return
  // The old tab sinks away while the new one rises into place, in one cell.
  const reduced = _ceReduced()
  const timing = { duration: reduced ? 150 : 200, easing: reduced ? 'linear' : CE_EASE }
  from.classList.add('leaving')
  const out = from.animate([{ opacity: 1, transform: 'none' }, { opacity: 0, transform: reduced ? 'none' : 'translateY(8px)' }], { ...timing, fill: 'forwards' })
  // Hidden and released in one step. The cancel event arrives a frame after
  // cancel(), so dropping the class only there drew the old tab at full
  // opacity for that frame: the flash at the end of every switch.
  out.onfinish = () => { from.classList.remove('leaving'); out.cancel() }
  out.oncancel = () => from.classList.remove('leaving')
  to.animate([{ opacity: 0, transform: reduced ? 'none' : 'translateY(8px)' }, { opacity: 1, transform: 'none' }], timing)
}

/** The right pane on the Crossfade tab: the lyrics slide down and fade while
 *  the preview card rises from below, and the reverse on the way out. Animates
 *  `translate`, not `transform`, which _applyOverlayPanels owns on the lyrics. */
function _ceSetPreview(on, animate) {
  const lyrics = document.getElementById('ov-panel-lyrics'), card = document.getElementById('ce-preview')
  if (on === npOverlay.classList.contains('ce-crossfade')) { if (on) _cePreviewPlay(); return }
  for (const el of [lyrics, card]) for (const a of el.getAnimations()) if (a.id === 'ce') a.finish()
  npOverlay.classList.toggle('ce-crossfade', on)
  if (on) _cePreviewPlay()
  else _cePreviewStop()
  if (!animate) return
  const reduced = _ceReduced()
  const timing = { duration: reduced ? 150 : on ? 350 : 300, easing: reduced ? 'linear' : CE_EASE, id: 'ce' }
  const leaving = on ? lyrics : card, coming = on ? card : lyrics
  const offLyrics = reduced ? '0 0' : '0 48px', offCard = reduced ? '0 0' : '0 100%'
  leaving.classList.add(on ? 'ce-leaving' : 'leaving')
  const out = leaving.animate([{ opacity: 1, translate: '0 0' }, { opacity: 0, translate: on ? offLyrics : offCard }], { ...timing, fill: 'forwards' })
  // Same step for the same reason as _ceShowTab's fade.
  out.onfinish = () => { leaving.classList.remove('ce-leaving', 'leaving'); out.cancel() }
  out.oncancel = () => leaving.classList.remove('ce-leaving', 'leaving')
  coming.animate([{ opacity: 0, translate: on ? offCard : offLyrics }, { opacity: 1, translate: '0 0' }], timing)
}

// Under 700px wide the menu and the preview take turns.
function _ceShowPreviewPane(on) {
  clearTimeout(_ce.previewTemp)
  npOverlay.classList.toggle('ce-show-preview', on)
  document.getElementById('ce-preview-toggle').textContent = on ? 'Show menu' : 'Show preview'
}

// ── The crossfade preview ──
// Its own slice on its own card (#ce-preview-art), never _slice or the
// player's art, so a real crossfade and the preview never touch each other.
const _cePrev = { run: 0, slice: null, timers: [] }

function _cePreviewStop() {
  _cePrev.run++
  _cePrev.timers.forEach(clearTimeout)
  _cePrev.timers = []
  _removeArtSlice(_cePrev.slice)
  _cePrev.slice = null
}

const _ceCoverKey = item => item && (item.AlbumId || item.Id)
const _ceCoverUrl = item => item && artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
// ponytail: the next song in queue order (repeat-one replays this one); repeat-all wrap and shuffle edge cases ignored, per the spec.
const _ceNextItem = () => repeatMode === 'one' ? queue[queueIndex] : queue[queueIndex + 1]

/** The card's base image, swapped in place so a slice laid over it stays. */
function _ceSetPreviewCover(host, url) {
  let img = host.querySelector(':scope > img')
  if (!url) { img?.remove(); if (!host.querySelector('.art-slice')) host.textContent = '♪'; return }
  if (!img) { host.textContent = ''; img = document.createElement('img'); img.alt = ''; host.prepend(img) }
  if (img.getAttribute('src') !== url) img.src = url
}

/** Shows the current cover, then (when there is something to show) runs the
 *  configured transition to the next queued cover, holds it, and resets.
 *  Restarts from the current cover if called mid-run. Returns how long the
 *  run takes in ms, or 0 when it does not run. */
function _cePreviewPlay() {
  _cePreviewStop()
  const run = _cePrev.run
  const cur = queue[queueIndex], next = _ceNextItem()
  _ce.previewKey = `${cur?.Id}|${next?.Id}|${repeatMode}`
  const host = document.getElementById('ce-preview-art')
  const curUrl = _currentHighResArtUrl || _ceCoverUrl(cur)
  const plan = CascadeCore.coverPreviewPlan({
    hasNext: !!next, nextIsVideo: isVideoItem(next), sameCover: !!next && _ceCoverKey(next) === _ceCoverKey(cur),
    coverSlice: displayPrefs.coverSlice, reduceMotion: _ceReduced(), crossfadeOn: crossfadeEnabled, crossfadeSeconds,
  })
  _ceSetPreviewCover(host, curUrl)
  document.getElementById('ce-preview-hint').textContent = plan.notes.join('\n')
  document.getElementById('ce-replay').disabled = !plan.run
  const nextUrl = _ceCoverUrl(next)
  if (!plan.run || !curUrl || !nextUrl) return 0
  ;(async () => {
    // Both covers decoded first, so the cut never waits on the network.
    const incoming = new Image()
    incoming.src = nextUrl
    await Promise.all([incoming.decode(), host.querySelector(':scope > img')?.decode()].map(p => p?.catch(() => {})))
    if (run !== _cePrev.run) return
    const slice = prepareArtSlice([host])
    if (!slice) return
    _cePrev.slice = slice
    _ceSetPreviewCover(host, nextUrl)
    startArtSlice(slice, plan.seconds)
    _cePrev.timers.push(setTimeout(() => endArtSlice(slice), plan.seconds * 1000))
    // Held on the next cover for a moment once the slide-out is done, then back.
    _cePrev.timers.push(setTimeout(() => {
      if (run !== _cePrev.run) return
      _removeArtSlice(slice)
      _ceSetPreviewCover(host, curUrl)
    }, (plan.seconds + displayPrefs.coverSlideOut + 1.5) * 1000))
  })()
  return (plan.seconds + displayPrefs.coverSlideOut + 1.5) * 1000
}

/** A cover setting changed: replay once, after every change in a batch (an
 *  undo or a reset sets several). Under 700px the preview shows for the run,
 *  then gives the menu back. */
let _cePreviewQueued = false
function _cePreviewSoon() {
  if (!_ce.open || _ce.tab !== 'crossfade' || _cePreviewQueued) return
  _cePreviewQueued = true
  setTimeout(() => {
    _cePreviewQueued = false
    if (!_ce.open || _ce.tab !== 'crossfade') return
    const ms = _cePreviewPlay()
    if (ms && _ceNarrow() && !npOverlay.classList.contains('ce-show-preview')) {
      _ceShowPreviewPane(true)
      _ce.previewTemp = setTimeout(() => _ceShowPreviewPane(false), ms)
    }
  }, 0)
}

/** The song or the queue moved: the sidebar follows by itself (it is the
 *  player), the preview follows here, and a video closes the editor. */
function _ceQueueMoved() {
  if (!_ce.open) return
  if (!_ceCanOpen()) { closeEditor({ instant: true }); return }
  if (_ce.tab !== 'crossfade') return
  const next = _ceNextItem()
  if (`${queue[queueIndex]?.Id}|${next?.Id}|${repeatMode}` !== _ce.previewKey) _cePreviewPlay()
}

// ── Undo and reset ──

/** Every value the editor can change, read from where it lives now. */
function _ceSnapshot() {
  const [lyricScale, bgDim, bgBlend] = _npTuningInputValues()
  return {
    mode: _isLightTheme() ? 'light' : 'dark',
    gradStart: document.getElementById('grad-start').value,
    gradEnd: document.getElementById('grad-end').value,
    albumArt: themeAlbumArt,
    font: { preset: document.getElementById('tp-font-preset').value, custom: document.getElementById('tp-font-custom').value },
    lyricScale, bgDim, bgBlend,
    lyricStyle: { ...lyricStyle },
    display: Object.fromEntries(CE_DISPLAY_KEYS.map(k => [k, displayPrefs[k]])),
  }
}

/** Called by every save path the editor's controls use: shows the undo button
 *  once anything differs from the snapshot, hides it once nothing does. */
function _ceChanged() {
  if (!_ce.open || !_ce.snapshot || _ce.applying) return
  document.getElementById('ce-undo').hidden = JSON.stringify(_ceSnapshot()) === JSON.stringify(_ce.snapshot)
}

/** The shipped values of one tab's settings, in _ceSnapshot's shape. */
function _ceDefaults(tab) {
  const pick = keys => Object.fromEntries(keys.map(k => [k, DISPLAY_PREF_DEFAULTS[k]]))
  const g = CascadeCore.PRESET_DEFAULT_GRADIENT
  if (tab === 'appearance') return { mode: 'dark', gradStart: g.start, gradEnd: g.end, font: { preset: 'system', custom: '' } }
  if (tab === 'nowplaying') return { albumArt: false, bgDim: CascadeCore.clampBgDim(undefined), bgBlend: CascadeCore.clampBgBlend(undefined), display: pick(['colorFade', 'colorFadeSeconds']) }
  if (tab === 'lyrics') return { lyricStyle: {}, lyricScale: CascadeCore.clampLyricScale(undefined), display: pick(['plainLyricScale']) }
  if (tab === 'crossfade') return { display: pick(CE_DISPLAY_KEYS.filter(k => k.startsWith('coverSli'))) }
  return {}
}

/** Puts back whatever `v` (part of a snapshot) holds, through the same save
 *  paths the controls use, in applyPreset's order. What the server admin
 *  enforces is skipped. */
async function _ceApply(v) {
  const themeLocked = CascadeCore.serverStylePart(_serverStyle, 'theme') === 'force'
  const lyricsLocked = CascadeCore.serverStylePart(_serverStyle, 'lyrics') === 'force'
  _ce.applying = true
  try {
    let themeDirty = false
    if ('mode' in v) { setThemeMode(v.mode); themeDirty = true }
    if ('gradStart' in v && !themeLocked) {
      document.getElementById('grad-start').value = v.gradStart
      document.getElementById('grad-end').value = v.gradEnd
      if (!themeAlbumArt) applyGradient(v.gradStart, v.gradEnd)
      markActivePreset()
      themeDirty = true
    }
    // setAlbumArtAccent saves the theme key too, with the mode and gradient above.
    if ('albumArt' in v && !themeLocked && v.albumArt !== themeAlbumArt) setAlbumArtAccent(v.albumArt)
    else if (themeDirty) await saveTheme()
    if (v.font) { await saveUiFont(v.font.preset, v.font.custom); await loadUiFont() }
    if (v.lyricStyle && !lyricsLocked) { await saveLyricStyle(v.lyricStyle); syncLyricKnobs() }
    if ('lyricScale' in v || 'bgDim' in v) {
      const [scale, dim, blend] = _npTuningInputValues()
      await saveNpTuning(
        'lyricScale' in v && !lyricsLocked ? v.lyricScale : scale,
        'bgDim' in v && !themeLocked ? v.bgDim : dim,
        'bgBlend' in v && !themeLocked ? v.bgBlend : blend)
      await loadNpTuning()
    }
    for (const [k, x] of Object.entries(v.display || {})) if (displayPrefs[k] !== x) await setDisplayPref(k, x)
  } finally {
    _ce.applying = false
  }
  _ceChanged()
}

/** Sliders glide to the values `apply` sets over 150ms instead of jumping
 *  (display only; the values are already saved). */
async function _ceGlide(apply) {
  const ranges = [...document.querySelectorAll('#ce-menu input[type="range"]')]
  const before = ranges.map(r => parseFloat(r.value))
  await apply()
  if (_ceReduced()) return
  const after = ranges.map(r => parseFloat(r.value))
  const moving = ranges.map((r, i) => i).filter(i => before[i] !== after[i])
  if (!moving.length) return
  const t0 = performance.now()
  const frame = now => {
    const p = Math.min(1, (now - t0) / 150), e = 1 - (1 - p) ** 3
    for (const i of moving) ranges[i].value = String(p < 1 ? before[i] + (after[i] - before[i]) * e : after[i])
    if (p < 1) requestAnimationFrame(frame)
  }
  for (const i of moving) ranges[i].value = String(before[i])
  requestAnimationFrame(frame)
  // rAF does not run in a hidden window; the sliders still end where they belong.
  setTimeout(() => { for (const i of moving) ranges[i].value = String(after[i]) }, 200)
}

document.getElementById('ce-undo').addEventListener('click', async () => {
  const snap = _ce.snapshot
  if (!snap) return
  await _ceGlide(() => _ceApply(snap))
  // Gone after an undo even if a value the admin enforces could not go back.
  document.getElementById('ce-undo').hidden = true
  _ceTabs[CE_TABS.indexOf(_ce.tab)].focus({ preventScroll: true })
})

document.getElementById('ce-menu').addEventListener('click', async (e) => {
  const tab = e.target.closest('[data-reset]')?.dataset.reset
  if (!tab) return
  if (!await showChoice('Reset this tab?', CE_RESET_TEXT[tab], 'Reset', 'Cancel') || !_ce.open) return
  if (tab === 'presets') {
    document.getElementById('tp-preset-theme').checked = true
    document.getElementById('tp-preset-lyrics').checked = true
    document.getElementById('tp-preset-name').value = ''
    return
  }
  await _ceGlide(() => _ceApply(_ceDefaults(tab)))
})

// ── Wiring ──
_ceTabs.forEach(t => t.addEventListener('click', () => _ceShowTab(t.dataset.tab, true)))
// A real tablist: arrows move between tabs (wrapping), Home and End jump to the ends.
document.querySelector('.ce-tabs').addEventListener('keydown', e => {
  const i = CE_TABS.indexOf(_ce.tab)
  const to = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: CE_TABS.length - 1 }[e.key]
  if (to === undefined) return
  e.preventDefault()
  const n = (to + CE_TABS.length) % CE_TABS.length
  _ceShowTab(CE_TABS[n], true)
  _ceTabs[n].focus()
})
new ResizeObserver(() => _cePlacePill(false)).observe(document.querySelector('.ce-tabs'))
document.getElementById('np-theme-btn').addEventListener('click', () => _ce.open ? closeEditor() : openEditor())
document.getElementById('ce-close').addEventListener('click', () => closeEditor())
document.getElementById('ce-replay').addEventListener('click', () => _cePreviewPlay())
document.getElementById('ce-preview-toggle').addEventListener('click', () => _ceShowPreviewPane(!npOverlay.classList.contains('ce-show-preview')))
document.getElementById('ce-cf-settings').addEventListener('click', () => {
  // The length row is hidden while crossfade is off, so that jumps to the switch.
  revealSetting('playback', crossfadeEnabled ? 'crossfade-duration' : 'crossfade-toggle')
})
document.getElementById('tp-style-btn').addEventListener('click', () => {
  if (!_ceCanOpen()) return
  closeThemePicker()
  openEditor({ instant: true })
})
document.getElementById('s-customize-np').addEventListener('click', () => {
  if (_ceCanOpen()) openEditor({ tab: 'crossfade', instant: true })
})
_syncStyleEntries()

// ── revealSetting ──
/** Opens Settings on `section` and draws the eye to one setting, the way a
 *  browser shows a searched setting: its row scrolled to the middle, tinted
 *  with the accent and fading back over about 2s, and its control focused.
 *  `id` is the row or any control in it. */
async function revealSetting(section, id) {
  if (overlayOpen) closeOverlay()
  showView('settings')
  const tab = _settingsTabs.findIndex(t => t.dataset.section === section)
  if (tab >= 0) showSettingsTab(tab)
  // After the pane's slide, which also resets the scroll.
  const pane = document.getElementById(`section-${section}`)
  await Promise.all(pane.getAnimations().map(a => a.finished.catch(() => {})))
  const target = document.getElementById(id)
  const row = target?.closest('.setting-row') || target
  if (!row?.offsetParent) return
  row.scrollIntoView({ block: 'center', behavior: _ceReduced() ? 'auto' : 'smooth' })
  const control = target.matches('input, select, button, textarea') ? target : row.querySelector('input, select, button, textarea')
  control?.focus({ preventScroll: true, focusVisible: true })
  const accent = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#6e4ff6'
  const tint = `color-mix(in srgb, ${accent} 26%, transparent)`
  row.classList.add('revealed')
  row.animate([{ backgroundColor: tint }, { backgroundColor: tint, offset: 0.3 }, { backgroundColor: 'transparent' }], { duration: 2000, easing: 'ease-out' })
    .finished.catch(() => {}).then(() => row.classList.remove('revealed'))
}

// ── Tooltips ─────────────────────────────────────────────────────────────────
//
// One element on <body>, moved to whichever [data-tip] is hovered, rather than
// a ::after on each host. A pseudo-element cannot escape its host's clipping or
// its stacking context, which is why these kept disappearing behind the player
// bar and inside Settings - no z-index can lift a child out of a stacking
// context its ancestor created.
//
// Delegated, so anything given a data-tip later (the plugin gating, the admin
// gating, the theme swatches, the miniplayer button) is covered with no
// registration step.

const TOOLTIP_GAP = 6

function _positionTooltip(host) {
  const tip = document.getElementById('tooltip')
  const text = host.getAttribute('data-tip')
  if (!tip || !text) return
  tip.textContent = text
  tip.classList.add('show')
  tip.setAttribute('aria-hidden', 'false')

  const h = host.getBoundingClientRect()
  const t = tip.getBoundingClientRect()
  // Below by default, matching what these used to do: the lyrics panel's
  // buttons sit at the top of it and a tip above them would land off-panel.
  let top = h.bottom + TOOLTIP_GAP
  if (top + t.height > window.innerHeight - 4) top = h.top - t.height - TOOLTIP_GAP
  // Clamped so a tip on a control near either edge stays fully on screen
  // instead of being cut off, which the centred pseudo-element also did.
  const left = Math.max(4, Math.min(window.innerWidth - t.width - 4, h.left + h.width / 2 - t.width / 2))
  tip.style.transform = `translate(${Math.round(left)}px, ${Math.round(top)}px)`
}

function _hideTooltip() {
  const tip = document.getElementById('tooltip')
  if (!tip) return
  tip.classList.remove('show')
  tip.setAttribute('aria-hidden', 'true')
}

document.addEventListener('mouseover', (e) => {
  const host = e.target.closest?.('[data-tip]')
  if (host) _positionTooltip(host)
})
document.addEventListener('mouseout', (e) => {
  const host = e.target.closest?.('[data-tip]')
  // A drag routinely carries the pointer outside the bar's rect (dragging the
  // volume handle past its ends, for one), which fires this same mouseout -
  // wireBar's .dragging class is what tells a live drag from an actual leave.
  // wireBar hides the tip itself once the drag ends.
  if (host && !host.classList.contains('dragging')) _hideTooltip()
})
// Keyboard parity with the old :focus-visible rule.
document.addEventListener('focusin', (e) => {
  const host = e.target.closest?.('[data-tip]')
  if (host && host.matches(':focus-visible')) _positionTooltip(host)
})
document.addEventListener('focusout', _hideTooltip)
// A tip pinned to a rect that has moved is worse than no tip.
window.addEventListener('scroll', _hideTooltip, true)
window.addEventListener('resize', _hideTooltip)

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
  // Local mode has nothing to transcode with: the folder's files in that
  // codec move to the "Can't play these" list instead.
  if (isLocalMode()) window.cascade.local.setProfile(currentDeviceProfile()).catch(() => {})
  showToast(`No audio from ${codec.toUpperCase()} on this machine - switching to a transcode`, { level: 'advanced' })

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

// Last reading from main's app-metrics. debugPanelText() is synchronous, so the
// IPC round trip happens on the panel's 1s tick and the text reads this copy.
let _debugMetrics = null

function refreshDebugMetrics() {
  window.cascade.appMetrics().then(m => { _debugMetrics = m }).catch(() => {})
}

function debugResourceLines() {
  if (!_debugMetrics) return ['(first reading pending)']
  const rows = [..._debugMetrics].sort((x, y) => y.memMB - x.memMB)
  const total = rows.reduce((t, r) => ({ mem: t.mem + r.memMB, cpu: t.cpu + r.cpu }), { mem: 0, cpu: 0 })
  return [
    ...rows.map(r => `${r.type.padEnd(9)} pid ${String(r.pid).padEnd(6)} ${String(r.memMB).padStart(5)} MB   cpu ${r.cpu.toFixed(1).padStart(5)}%   wake ${r.wakeups}/s`),
    `total                ${String(total.mem).padStart(5)} MB   cpu ${total.cpu.toFixed(1).padStart(5)}%`,
    `translators loaded: ${[..._translators.keys()].join(', ') || 'none'}`,
  ]
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

  const ident = CascadeCore.clientIdentity()
  return [
    `client: ${ident.client} ${appVersion} on ${ident.device}   deviceId: ${deviceId}`,
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
    `volume: ${volume.toFixed(2)}   muted: ${_muted}   via ${_masterGain ? 'gain after the analyser' : 'the element'}`,
    `profile claims decodable: ${decodableVideoAudioCodecs().join(',')}`,
    `withdrawn at runtime: ${[..._undecodableAudioCodecs].join(',') || 'none'}`,
    `decoded audio bytes: ${audio.webkitAudioDecodedByteCount ?? 'n/a'}`,
    'audio tracks on this item:',
    ...debugAudioTracks(item),
    '',
    '── web audio / eq ──',
    `graph failed: ${_eqGraphFailed}   no signal: ${_eqNoSignal}   ever had signal: ${_eqEverHadSignal}`,
    '',
    '── resources ──',
    ...debugResourceLines(),
    '',
    `Cascade Server plugin absent: ${_cascadePluginAbsent}`,
  ].join('\n')
}

// The diagnostics readout lives in the customization editor's Developer tab
// (initDevTuningTab), as its Playback diagnostics section. It ticks once a
// second only while that tab is showing, so app-metrics' CPU figure for the
// first tick after opening covers the whole time it was closed.
function _devDiagnosticsShowing() {
  return _ce.open && _ce.tab === 'developer'
}
function _renderDevDiagnostics() {
  const el = document.getElementById('ce-dev-diag')
  if (el && _devDiagnosticsShowing()) el.textContent = debugPanelText()
}
setInterval(() => {
  if (!_devDiagnosticsShowing()) return
  refreshDebugMetrics()
  _renderDevDiagnostics()
}, 1000)
document.getElementById('ce-dev-diag-copy').addEventListener('click', () => {
  // This text exists to be pasted into a bug report.
  window.cascade.clipboard.write(debugPanelText())
  showToast('Diagnostics copied', { level: 'debug' })
})
// The one internal flag worth flipping by hand that has no real Settings UI:
// previews a working plugin's greyed-out state without a second server.
document.getElementById('ce-dev-plugin-absent').addEventListener('change', (e) => {
  _cascadePluginAbsent = /** @type {HTMLInputElement} */ (e.target).checked
  _applyCascadePluginAvailability()
  _renderDevDiagnostics()
})

// ── Developer tab (debug only) ──────────────────────────────────────────────
// The customization editor's last tab, shown only with the .cascade-debug
// sentinel: playback diagnostics (above), and live knobs for what tuning-defaults.json holds beyond the Lyrics
// tab, the cover-color background (CascadeCore.blobTuning, album-colors.ts)
// and the lyric spring (LYRIC_MOTION), plus the light theme's scrims and
// blend. Every slider changes the running app with no rebuild and nothing is
// saved: Bake writes the result (and the Lyrics tab's own changes) into
// tuning-defaults.json through `npm run tuning -- bake`, Copy puts it on the
// clipboard for that command.
//   - Extraction knobs only apply when a cover is clustered, so they reapply
//     the theme. The rest (slots, drift, opacity, frame rate) are read every
//     drift frame.
//   - Scrims and blend are CSS custom properties index.html's light-theme
//     rules read with a fallback equal to the shipped value. They are not in
//     tuning-defaults.json, so Copy logs them to the console instead.
function _debugReapplyBlobs() {
  if (!themeAlbumArt) return
  const img = document.querySelector('#ov-art img') || document.querySelector('#np-art img')
  themeFromArtUrl(img?.src)
}

const DEV_BLOB_KNOBS = [
  { key: 'clusters', label: 'Clusters', min: 2, max: 10, step: 1, extract: true },
  { key: 'iterations', label: 'k-means iterations', min: 1, max: 30, step: 1, extract: true },
  { key: 'minSeparation', label: 'Min separation', min: 0, max: 0.4, step: 0.01, extract: true },
  { key: 'minSampleL', label: 'Ignore pixels darker than', min: 0, max: 0.3, step: 0.01, extract: true },
  { key: 'maxSampleL', label: 'Ignore pixels lighter than', min: 0.7, max: 1, step: 0.01, extract: true },
  { key: 'minShare', label: 'Min cluster share', min: 0, max: 0.1, step: 0.005, extract: true },
  { key: 'chromaPower', label: 'Colorfulness weight', min: 0, max: 4, step: 0.1, extract: true },
  { key: 'minL', label: 'Dark: min lightness', min: 0, max: 1, step: 0.01, extract: true },
  { key: 'maxL', label: 'Dark: max lightness', min: 0, max: 1, step: 0.01, extract: true },
  { key: 'minLLight', label: 'Light: min lightness', min: 0, max: 1, step: 0.01, extract: true },
  { key: 'maxLLight', label: 'Light: max lightness', min: 0, max: 1, step: 0.01, extract: true },
  { key: 'minChroma', label: 'Min chroma', min: 0, max: 0.3, step: 0.01, extract: true },
  { key: 'lightAlphaScale', label: 'Light: blob opacity', min: 0, max: 1.5, step: 0.01 },
  { key: 'driftScale', label: 'Drift distance', min: 0, max: 3, step: 0.05 },
  { key: 'frameMs', label: 'Drift frame (ms)', min: 16, max: 200, step: 1 },
]
const DEV_SLOT_KNOBS = [
  { key: 'x', label: 'Left (%)', min: 0, max: 100, step: 1 }, { key: 'y', label: 'Top (%)', min: 0, max: 100, step: 1 },
  { key: 'w', label: 'Width (%)', min: 10, max: 150, step: 1 }, { key: 'h', label: 'Height (%)', min: 10, max: 150, step: 1 },
  { key: 'alpha', label: 'Opacity', min: 0, max: 1, step: 0.01 },
]
const DEV_MOTION_KNOBS = [
  { key: 'lyricSpringStiffness', label: 'Lyric spring stiffness', min: 50, max: 600, step: 5, prop: 'stiffness' },
  { key: 'lyricSpringDamping', label: 'Lyric spring damping', min: 5, max: 120, step: 1, prop: 'damping' },
]
const DEV_SCRIMS = [
  { label: 'Left scrim opacity', prop: '--np-scrim-left', fallback: 0.35 },
  { label: 'Right scrim opacity', prop: '--np-scrim-right', fallback: 0.16 },
  { label: 'Header scrim opacity', prop: '--np-scrim-header', fallback: 0.4 },
]
const _shippedMotion = { stiffness: LYRIC_MOTION.stiffness, damping: LYRIC_MOTION.damping }

/** What this tab and the Lyrics tab moved away from the shipped defaults, in
 *  the shape `npm run tuning -- bake` reads. */
function devTuningBake() {
  const blob = CascadeCore.blobTuning, shipped = CascadeCore.SHIPPED_BLOB_TUNING
  const albumColors = {}
  for (const k of DEV_BLOB_KNOBS) if (blob[k.key] !== shipped[k.key]) albumColors[k.key] = blob[k.key]
  if (JSON.stringify(blob.slots) !== JSON.stringify(shipped.slots)) albumColors.slots = blob.slots
  const motion = {}
  for (const k of DEV_MOTION_KNOBS) if (LYRIC_MOTION[k.prop] !== _shippedMotion[k.prop]) motion[k.key] = LYRIC_MOTION[k.prop]
  return { bake: 'desktop', style: CascadeCore.lyricStyleChanges(lyricStyle), albumColors, motion }
}

/** Every Developer tab row: label, value, shipped default, how to set it. */
function _devTuningGroups() {
  const root = document.documentElement
  const blob = CascadeCore.blobTuning, shipped = CascadeCore.SHIPPED_BLOB_TUNING
  const cssVar = (name, fallback) => parseFloat(getComputedStyle(root).getPropertyValue(name)) || fallback
  return [
    { title: 'Album colors', defs: DEV_BLOB_KNOBS.map(k => ({ ...k, shipped: shipped[k.key],
      get: () => blob[k.key],
      set: v => { blob[k.key] = v; if (k.extract) _debugReapplyBlobs() } })) },
    ...blob.slots.map((slot, i) => ({ title: `Blob ${i + 1}`, defs: DEV_SLOT_KNOBS.map(k => ({ ...k,
      key: `slot${i}-${k.key}`, shipped: shipped.slots[i]?.[k.key] ?? slot[k.key],
      get: () => slot[k.key],
      set: v => { slot[k.key] = v } })) })),
    { title: 'Lyric scroll', defs: DEV_MOTION_KNOBS.map(k => ({ ...k, shipped: _shippedMotion[k.prop],
      get: () => LYRIC_MOTION[k.prop],
      set: v => { LYRIC_MOTION[k.prop] = v } })) },
    { title: 'Light theme scrims', defs: DEV_SCRIMS.map(d => ({ ...d, key: d.prop.slice(2), min: 0, max: 1, step: 0.01, shipped: d.fallback,
      get: () => cssVar(d.prop, d.fallback),
      set: v => root.style.setProperty(d.prop, v) })) },
  ]
}

let _devRows = []

/** Fills the Developer tab with the editor's own section and slider rows (the
 *  Lyrics tab's tp-knob markup), and shows its tab. */
function initDevTuningTab() {
  const box = document.getElementById('ce-dev-knobs')
  const root = document.documentElement
  const decimals = step => (String(step).split('.')[1] || '').length
  _devRows = []
  box.replaceChildren()
  for (const g of _devTuningGroups()) {
    const sect = document.createElement('section')
    sect.className = 'ce-sect'
    sect.innerHTML = '<h3 class="ce-sect-title"></h3>'
    sect.querySelector('h3').textContent = g.title
    for (const d of g.defs) {
      const row = document.createElement('div')
      row.className = 'setting-row tp-knob'
      row.innerHTML = `<div class="setting-label tp-knob-head"><label class="setting-name" for="dev-${d.key}"></label>`
        + '<button type="button" class="tp-knob-reset" title="Reset to shipped">↺</button></div>'
        + `<div class="setting-slider-row"><input type="range" class="tp-range" id="dev-${d.key}"><span class="eq-band-value tp-knob-value"></span></div>`
      row.querySelector('label').textContent = d.label
      row.querySelector('.tp-knob-reset').setAttribute('aria-label', `Reset ${d.label} to shipped`)
      const input = row.querySelector('input')
      Object.assign(input, { min: d.min, max: d.max, step: d.step })
      input.setAttribute('aria-label', `${g.title}: ${d.label}`)
      const show = () => {
        const v = d.get()
        input.value = String(v)
        row.querySelector('.tp-knob-value').textContent = Number(v).toFixed(decimals(d.step))
        row.classList.toggle('changed', Math.abs(v - d.shipped) > 1e-9)
      }
      input.addEventListener('input', () => { d.set(parseFloat(input.value)); show() })
      row.querySelector('.tp-knob-reset').addEventListener('click', () => { d.set(d.shipped); show() })
      show()
      _devRows.push(show)
      sect.append(row)
    }
    if (g.title === 'Light theme scrims') {
      const row = document.createElement('div')
      row.className = 'setting-row'
      row.innerHTML = '<div class="setting-label"><span class="setting-name">Multiply blend</span>'
        + '<span class="setting-desc">The light theme lays the blobs on like ink.</span></div>'
        + '<label class="toggle"><input type="checkbox" id="dev-np-blend" aria-label="Multiply blend"><span class="toggle-track"></span></label>'
      const check = row.querySelector('input')
      const show = () => { check.checked = (getComputedStyle(root).getPropertyValue('--np-blend').trim() || 'multiply') !== 'normal' }
      check.addEventListener('change', () => root.style.setProperty('--np-blend', check.checked ? 'multiply' : 'normal'))
      show()
      _devRows.push(show)
      sect.append(row)
    }
    box.append(sect)
  }
  const absent = /** @type {HTMLInputElement} */ (document.getElementById('ce-dev-plugin-absent'))
  absent.checked = _cascadePluginAbsent
  if (!CE_TABS.includes('developer')) CE_TABS.push('developer')
  document.getElementById('ce-tab-developer').hidden = false
}

document.getElementById('ce-dev-bake').addEventListener('click', async () => {
  const payload = devTuningBake()
  const r = await window.cascade.tuningBake(payload)
  if (r?.report) { showNotice(r.report, 'Baked'); return }
  await window.cascade.clipboard.write(JSON.stringify(payload))
  showNotice(`${r?.error || 'Baking failed.'}\n\nCopied instead: run npm run tuning -- bake in the checkout.`, 'Tuning')
})
document.getElementById('ce-dev-copy').addEventListener('click', () => {
  window.cascade.clipboard.write(JSON.stringify(devTuningBake()))
  const scrims = DEV_SCRIMS.map(d => `${d.label} = ${(parseFloat(getComputedStyle(document.documentElement).getPropertyValue(d.prop)) || d.fallback).toFixed(2)}`)
  console.log('[tuning] light theme scrims (CSS, not in tuning-defaults.json):\n' + scrims.join('\n'))
  showToast('Tuning copied. Scrims are in the console.', { level: 'debug' })
})
document.getElementById('ce-dev-reset').addEventListener('click', () => {
  const root = document.documentElement
  const blob = CascadeCore.blobTuning, shipped = structuredClone(CascadeCore.SHIPPED_BLOB_TUNING)
  for (const k of DEV_BLOB_KNOBS) blob[k.key] = shipped[k.key]
  blob.slots.forEach((slot, i) => Object.assign(slot, shipped.slots[i]))
  Object.assign(LYRIC_MOTION, _shippedMotion)
  for (const d of DEV_SCRIMS) root.style.removeProperty(d.prop)
  root.style.removeProperty('--np-blend')
  _devRows.forEach(show => show())
  _debugReapplyBlobs()
})

window.cascade.isDebugMode().then(on => { if (on) initDevTuningTab() })

init()
