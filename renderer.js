// ── Cascade renderer ──────────────────────────────────────────────────────────

// State
let jf = { url: '', token: '', userId: '' }
let appVersion = '1.0.0'
let queue = []
let queueIndex = -1
let shuffle = false
let repeatMode = 'none' // 'none' | 'all' | 'one'
let _unshuffledQueue = []   // original order saved when shuffle is enabled

// Queue panel virtualisation
const QUEUE_WIN      = 20   // rows kept in DOM at once
const QUEUE_ROW_H    = 53   // approximate px per row (padding 8+8 + art 36 + border 1)
const QUEUE_BEFORE   = 5    // rows to show before current track when re-centering
let _queueWinStart   = 0    // index of first rendered row
let _queueScrollBound = false
let volume = 1.0
let muted = false

const audio = new Audio()
audio.crossOrigin = 'anonymous'
audio.volume = volume

// ── Helpers ───────────────────────────────────────────────────────────────────

function fmtTime(sec) {
  if (!sec || !isFinite(sec)) return '0:00'
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

function artUrl(itemId, tag) {
  if (!tag) return null
  return `${jf.url}/Items/${itemId}/Images/Primary?fillHeight=600&fillWidth=600&quality=90&api_key=${jf.token}`
}

function artistArtUrl(itemId) {
  return `${jf.url}/Items/${itemId}/Images/Primary?fillHeight=600&fillWidth=600&quality=90&api_key=${jf.token}`
}

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
  _itunesArtCache.set(key, null) // mark in-flight to avoid duplicate requests
  try {
    const term = encodeURIComponent(`${artist} ${album}`.trim())
    const r = await fetch(
      `https://itunes.apple.com/search?term=${term}&entity=album&limit=5&media=music`,
      { signal: AbortSignal.timeout(7000) }
    )
    if (!r.ok) return null
    const d = await r.json()
    const result = d.results?.[0]
    if (!result?.artworkUrl100) return null
    // Scale from 100px thumbnail to 600px — just replace the size token in the URL
    const url = result.artworkUrl100.replace(/\d+x\d+bb/, '600x600bb')
    _itunesArtCache.set(key, url)
    return url
  } catch {
    return null
  }
}

// Tracks the best available art URL for the current track (iTunes > Jellyfin)
let _currentHighResArtUrl = null

function streamUrl(itemId) {
  return `${jf.url}/Audio/${itemId}/universal?UserId=${jf.userId}&api_key=${jf.token}&Container=opus,mp3,aac,flac,wav,ogg&TranscodingContainer=ts&TranscodingProtocol=hls&AudioCodec=aac&MaxStreamingBitrate=140000000`
}

// ── Toast ─────────────────────────────────────────────────────────────────────
// Toasts are dev-only noise in production builds — only show when running
// unpackaged (i.e. launched from the command line via `npm start`/`electron .`).
let _toastsEnabled = false
window.cascade?.isPackaged?.().then(packaged => { _toastsEnabled = !packaged })

function showToast(msg, duration = 2200) {
  if (!_toastsEnabled) return
  const t = document.getElementById('toast')
  t.textContent = msg
  t.style.opacity = '1'
  clearTimeout(t._to)
  t._to = setTimeout(() => { t.style.opacity = '0' }, duration)
}

// ── Jellyfin API ──────────────────────────────────────────────────────────────

async function jfGet(path, params = {}) {
  const url = new URL(`${jf.url}${path}`)
  Object.entries(params).forEach(([k, v]) => url.searchParams.set(k, v))
  const res = await fetch(url, {
    headers: { 'X-Emby-Token': jf.token }
  })
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`)
  return res.json()
}

async function jfAuth(serverUrl, username, password) {
  const res = await fetch(`${serverUrl}/Users/AuthenticateByName`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Emby-Authorization': `MediaBrowser Client="Cascade", Device="Cascade", DeviceId="cascade-app", Version="${appVersion}"`
    },
    body: JSON.stringify({ Username: username, Pw: password })
  })
  if (!res.ok) {
    const txt = await res.text()
    throw new Error(txt || `${res.status}`)
  }
  return res.json()
}

// ── Connection ────────────────────────────────────────────────────────────────

function setConnected(yes) {
  const dot = document.getElementById('ws-dot')
  const label = document.getElementById('ws-label')
  dot.className = 'ws-dot' + (yes ? ' connected' : '')
  label.textContent = yes ? 'connected' : 'disconnected'
}

async function connect(serverUrl, token, userId) {
  jf = { url: serverUrl.replace(/\/$/, ''), token, userId }

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

  // Verify the token is still valid with a lightweight ping, retry up to 3x
  let verified = false
  for (let attempt = 1; attempt <= 3; attempt++) {
    showLoading(attempt === 1 ? 'Connecting…' : `Retrying… (${attempt}/3)`)
    try {
      await jfGet(`/Users/${userId}`)
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

  setConnected(true)
  await populateLibraryPicker()
  await loadHome()
}

async function populateLibraryPicker() {
  try {
    const data = await jfGet(`/Users/${jf.userId}/Views`)
    const musicLibs = (data.Items || []).filter(i =>
      i.CollectionType === 'music' || i.CollectionType === 'musicvideos'
    )
    const savedRaw = await window.cascade.store.get('libraryIds')
    let savedIds = []
    try { savedIds = savedRaw ? JSON.parse(savedRaw) : [] } catch {}

    // Auto-select all music libs on first connect
    if (!savedIds.length && musicLibs.length) {
      savedIds = musicLibs.map(l => l.Id)
      await window.cascade.store.set('libraryIds', JSON.stringify(savedIds))
    }

    jf.libraryIds = savedIds

    const container = document.getElementById('s-library-list')
    if (!musicLibs.length) {
      container.innerHTML = '<span style="font-size:12px;color:var(--text3);">No music libraries found</span>'
      return
    }
    container.innerHTML = musicLibs.map(lib => `
      <label class="lib-check-row">
        <input type="checkbox" value="${lib.Id}" ${savedIds.includes(lib.Id) ? 'checked' : ''} />
        <span class="lib-check-label">${esc(lib.Name)}</span>
      </label>
    `).join('')
  } catch {}
}

function getCheckedLibraryIds() {
  return [...document.querySelectorAll('#s-library-list input[type=checkbox]:checked')]
    .map(cb => cb.value)
}

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

function showView(name) {
  document.querySelectorAll('.view').forEach(v => v.classList.remove('active'))
  document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'))
  document.getElementById(`view-${name}`).classList.add('active')
  document.querySelector(`[data-view="${name}"]`)?.classList.add('active')
  sidenav.classList.remove('expanded')
  backdrop.classList.remove('dim')

  if (name === 'albums' && !document.getElementById('albums-grid').dataset.loaded) loadAlbums()
  if (name === 'artists' && !document.getElementById('artists-grid').dataset.loaded) loadArtists()
  if (name === 'songs' && !document.getElementById('songs-rows').dataset.loaded) loadSongs()
  if (name === 'playlists' && !document.getElementById('playlists-grid').dataset.loaded) loadPlaylists()
  if (name === 'settings') loadSettingsFields()
  if (name === 'search') setTimeout(() => document.getElementById('search-input').focus(), 80)
}

document.querySelectorAll('.nav-item[data-view]').forEach(el => {
  el.addEventListener('click', () => showView(el.dataset.view))
})

// ── Home ──────────────────────────────────────────────────────────────────────

async function loadHome() {
  document.getElementById('greeting').textContent = `${greeting()}, ${await window.cascade.store.get('username') || 'there'}`

  loadRecentlyPlayed()
  loadRecentlyAdded()
}

async function loadRecentlyPlayed() {
  const grid = document.getElementById('rp-grid')
  try {
    const data = await jfGet(`/Users/${jf.userId}/Items`, {
      SortBy: 'DatePlayed',
      SortOrder: 'Descending',
      IncludeItemTypes: 'Audio',
      Filters: 'IsPlayed',
      Limit: 8,
      Recursive: true,
      Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag'
    })
    if (!data.Items?.length) { grid.innerHTML = '<div class="empty-state" style="grid-column:1/3">No play history yet</div>'; return }
    grid.innerHTML = data.Items.map(item => rpCard(item)).join('')
    grid.querySelectorAll('.rp-item').forEach((el, i) => {
      el.addEventListener('click', () => playItems(data.Items, i))
    })
  } catch (e) {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/3">Could not load history</div>`
  }
}

function rpCard(item) {
  const art = artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
  const img = art ? `<img src="${art}" alt="" onerror="this.style.display='none'">` : '♪'
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
      Limit: 8,
      Recursive: true,
      Fields: 'PrimaryImageAspectRatio'
    })
    if (!data.Items?.length) { grid.innerHTML = '<div class="empty-state" style="grid-column:1/-1">No albums yet</div>'; return }
    grid.innerHTML = data.Items.map(item => albumCard(item)).join('')
    grid.querySelectorAll('.album-card').forEach((el, i) => {
      el.addEventListener('click', () => playAlbum(data.Items[i].Id))
    })
  } catch (e) {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">Could not load albums</div>`
  }
}

// ── Albums ────────────────────────────────────────────────────────────────────

// Fetch items across all selected libraries and merge, deduplicating by Id
async function jfGetMerged(path, params = {}) {
  const ids = jf.libraryIds || []
  if (!ids.length) {
    return jfGet(path, params)
  }
  const results = await Promise.all(ids.map(libId =>
    jfGet(path, { ...params, ParentId: libId }).catch(() => ({ Items: [], TotalRecordCount: 0 }))
  ))
  const seen = new Set()
  const items = []
  for (const r of results) {
    for (const item of (r.Items || [])) {
      if (!seen.has(item.Id)) { seen.add(item.Id); items.push(item) }
    }
  }
  return { Items: items, TotalRecordCount: items.length }
}

// Like jfGetMerged, but paginates each library until every matching item is
// fetched instead of stopping at params.Limit. Pages within a library are
// fetched in parallel once the first page reveals TotalRecordCount.
async function jfGetAllPaged(path, params = {}) {
  const ids = jf.libraryIds?.length ? jf.libraryIds : [null]
  const pageSize = params.Limit || 500

  const perLibrary = await Promise.all(ids.map(async libId => {
    const baseParams = libId ? { ...params, ParentId: libId } : params
    const first = await jfGet(path, { ...baseParams, StartIndex: 0 }).catch(() => ({ Items: [], TotalRecordCount: 0 }))
    const items = [...(first.Items || [])]
    const total = first.TotalRecordCount ?? items.length

    if (total > items.length) {
      const starts = []
      for (let start = items.length; start < total; start += pageSize) starts.push(start)
      const pages = await Promise.all(starts.map(start =>
        jfGet(path, { ...baseParams, StartIndex: start }).catch(() => ({ Items: [] }))
      ))
      for (const p of pages) items.push(...(p.Items || []))
    }
    return items
  }))

  const seen = new Set()
  const items = []
  for (const libItems of perLibrary) {
    for (const item of libItems) {
      if (!seen.has(item.Id)) { seen.add(item.Id); items.push(item) }
    }
  }
  return { Items: items, TotalRecordCount: items.length }
}

async function loadAlbums() {
  const grid = document.getElementById('albums-grid')
  grid.dataset.loaded = '1'
  try {
    const params = { SortBy: 'SortName', SortOrder: 'Ascending', IncludeItemTypes: 'MusicAlbum', Recursive: true, Fields: 'PrimaryImageAspectRatio', Limit: 200 }
    const data = await jfGetMerged(`/Users/${jf.userId}/Items`, params)
    grid.innerHTML = data.Items.map(item => albumCard(item)).join('')
    grid.querySelectorAll('.album-card').forEach((el, i) => {
      el.addEventListener('click', () => playAlbum(data.Items[i].Id))
    })
  } catch (e) {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">Could not load albums</div>`
  }
}

function albumCard(item) {
  const art = artUrl(item.Id, item.ImageTags?.Primary)
  const img = art ? `<img src="${art}" alt="" onerror="this.style.display='none'">` : '♪'
  return `<div class="album-card" data-id="${item.Id}">
    <div class="album-art">${img}</div>
    <div class="album-body">
      <div class="album-name">${esc(item.Name)}</div>
      <div class="album-artist">${esc(item.AlbumArtist || '')}</div>
    </div>
  </div>`
}

async function playAlbum(albumId) {
  const data = await jfGet(`/Users/${jf.userId}/Items`, {
    ParentId: albumId,
    SortBy: 'ParentIndexNumber,IndexNumber,SortName',
    IncludeItemTypes: 'Audio',
    Recursive: true,
    Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag'
  })
  if (data.Items?.length) playItems(data.Items, 0)
}

// ── Artists ───────────────────────────────────────────────────────────────────

async function loadArtists() {
  const grid = document.getElementById('artists-grid')
  grid.dataset.loaded = '1'
  try {
    const params = { UserId: jf.userId, SortBy: 'SortName', SortOrder: 'Ascending', Limit: 200 }
    const data = await jfGetMerged(`/Artists`, params)
    grid.innerHTML = data.Items.map(item => {
      const art = artistArtUrl(item.Id)
      const img = `<img src="${art}" alt="" onerror="this.style.display='none'">`
      return `<div class="artist-card" data-id="${item.Id}" data-name="${esc(item.Name)}">
        <div class="artist-avatar">${img}</div>
        <div class="artist-name">${esc(item.Name)}</div>
      </div>`
    }).join('')
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
      el.addEventListener('click', () => playAlbum(albums[i].Id))
    })

    // Play all button
    document.getElementById('btn-play-artist-discography').onclick = () => {
      if (songs.length) playItems(songs, 0)
    }

    // Songs list
    document.getElementById('artist-songs-rows').innerHTML = songs.map((item, i) => {
      const thumbArt = artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
      return `<div class="track-row" data-idx="${i}" data-id="${item.Id}">
        <div class="track-num">${i + 1}</div>
        ${trackThumbHtml(thumbArt)}
        <div style="min-width:0">
          <div class="track-title">${esc(item.Name)}</div>
          <div class="track-artist">${esc(item.AlbumArtist || item.Artists?.[0] || '')}</div>
        </div>
        <div class="track-album-name">${esc(item.Album || '')}</div>
        <div class="track-dur">${fmtTime((item.RunTimeTicks || 0) / 10000000)}</div>
      </div>`
    }).join('')

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

// Shared thumb HTML — includes the EQ bars for the now-playing animation
function trackThumbHtml(art) {
  const img = art ? `<img src="${art}" alt="" onerror="this.style.display='none'">` : ''
  return `<div class="track-thumb">${img}<span class="track-eq"><i></i><i></i><i></i></span></div>`
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
    sortSongs()
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

function songSortValue(item, field) {
  switch (field) {
    case 'artist': return (item.AlbumArtist || item.Artists?.[0] || '').toLowerCase()
    case 'album':  return (item.Album || '').toLowerCase()
    case 'added':  return item.DateCreated ? Date.parse(item.DateCreated) || 0 : 0
    case 'played': return item.UserData?.LastPlayedDate ? Date.parse(item.UserData.LastPlayedDate) || 0 : 0
    default:       return (item.Name || '').toLowerCase()
  }
}

function sortSongs() {
  const dir = songsSortDir === 'desc' ? -1 : 1
  allSongs.sort((a, b) => {
    const va = songSortValue(a, songsSortField)
    const vb = songSortValue(b, songsSortField)
    if (va < vb) return -1 * dir
    if (va > vb) return 1 * dir
    return 0
  })
}

function updateSongsSortUI() {
  document.getElementById('songs-sort-label').textContent = SONG_SORT_LABELS[songsSortField]
  document.querySelectorAll('#songs-sort-dropdown [data-sort-field]').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.sortField === songsSortField)
  })
  document.getElementById('songs-sort-dir-label').textContent = songsSortDir === 'desc' ? 'Descending' : 'Ascending'
  document.getElementById('songs-sort-dir-icon').style.transform = songsSortDir === 'desc' ? 'rotate(180deg)' : ''
}

function resortSongsAndRerender() {
  sortSongs()
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

// Songs list virtualisation — with large libraries (1000+ tracks) rendering
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

    // Delegated row interactions — bound once on the container instead of
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
      document.querySelectorAll('.track-row.selected').forEach(r => r.classList.remove('selected'))
      el.classList.add('selected')
    })
    rows.addEventListener('dblclick', (e) => {
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
  }

  _songsWinStart = 0
  _drawSongRows(rows)
}

function _drawSongRows(rows) {
  const winEnd    = Math.min(allSongs.length, _songsWinStart + SONG_WIN)
  const currentId = queue[queueIndex]?.Id

  rows.innerHTML = allSongs.slice(_songsWinStart, winEnd).map((item, offset) => {
    const i   = _songsWinStart + offset
    const art = artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
    const playingCls = currentId && item.Id === currentId ? ' playing' : ''
    return `
    <div class="track-row${playingCls}" data-idx="${i}" data-id="${item.Id}" style="top:${i * SONG_ROW_H}px">
      <div class="track-num">${i + 1}</div>
      ${trackThumbHtml(art)}
      <div style="min-width:0">
        <div class="track-title">${esc(item.Name)}</div>
        <div class="track-artist">${esc(item.AlbumArtist || item.Artists?.[0] || '')}</div>
      </div>
      <div class="track-album-name">${esc(item.Album || '')}</div>
      <div class="track-dur">${fmtTime((item.RunTimeTicks || 0) / 10000000)}</div>
    </div>`
  }).join('')
}

// ── Playlists ─────────────────────────────────────────────────────────────────

async function loadPlaylists() {
  const grid = document.getElementById('playlists-grid')
  grid.dataset.loaded = '1'
  try {
    const data = await jfGet(`/Users/${jf.userId}/Items`, {
      SortBy: 'SortName',
      SortOrder: 'Ascending',
      IncludeItemTypes: 'Playlist',
      Recursive: true,
      Fields: 'PrimaryImageAspectRatio,ChildCount'
    })
    if (!data.Items?.length) { grid.innerHTML = '<div class="empty-state" style="grid-column:1/-1">No playlists found</div>'; return }
    grid.innerHTML = data.Items.map(item => {
      const art = artUrl(item.Id, item.ImageTags?.Primary)
      const img = art ? `<img src="${art}" alt="" onerror="this.style.display='none'">` : '♪'
      const count = item.ChildCount != null ? `${item.ChildCount} songs` : ''
      return `<div class="playlist-card" data-id="${item.Id}" data-name="${esc(item.Name)}">
        <div class="playlist-art">${img}</div>
        <div class="playlist-body">
          <div class="playlist-name">${esc(item.Name)}</div>
          <div class="playlist-count">${count}</div>
        </div>
      </div>`
    }).join('')
    grid.querySelectorAll('.playlist-card').forEach(el => {
      el.addEventListener('click', () => openPlaylist(el.dataset.id, el.dataset.name))
    })
  } catch (e) {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">Could not load playlists</div>`
  }
}

document.getElementById('playlists-refresh').addEventListener('click', async () => {
  const grid = document.getElementById('playlists-grid')
  delete grid.dataset.loaded
  await loadPlaylists()
  document.getElementById('view-playlists').scrollTop = 0
})

let currentPlaylistId = null
let currentPlaylistItems = []

async function openPlaylist(playlistId, name) {
  currentPlaylistId = playlistId
  document.getElementById('playlist-index').style.display = 'none'
  const detail = document.getElementById('playlist-detail')
  detail.classList.add('active')
  document.getElementById('pl-detail-name').textContent = name
  document.getElementById('pl-detail-meta').innerHTML = '<span class="skel skel-text" style="display:inline-block;width:70px"></span>'
  document.getElementById('pl-detail-rows').innerHTML = skeletonHTML('track', 6)

  try {
    const data = await jfGet(`/Playlists/${playlistId}/Items`, {
      UserId: jf.userId,
      Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag'
    })
    const items = data.Items || []
    currentPlaylistItems = items
    document.getElementById('pl-detail-meta').textContent = `${items.length} songs`

    const artEl = document.getElementById('pl-detail-art')
    const plArtUrl = `${jf.url}/Items/${playlistId}/Images/Primary?fillHeight=160&fillWidth=160&quality=80&api_key=${jf.token}`
    artEl.innerHTML = `<img src="${plArtUrl}" alt="" onerror="this.innerHTML='♪'">`

    document.getElementById('pl-detail-rows').innerHTML = items.map((item, i) => {
      const art = artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
      return `
      <div class="track-row" data-idx="${i}" data-id="${item.Id}" data-entry-id="${item.PlaylistItemId || item.Id}">
        <div class="track-num">${i + 1}</div>
        ${trackThumbHtml(art)}
        <div style="min-width:0">
          <div class="track-title">${esc(item.Name)}</div>
          <div class="track-artist">${esc(item.AlbumArtist || item.Artists?.[0] || '')}</div>
        </div>
        <div class="track-album-name">${esc(item.Album || '')}</div>
        <div class="track-dur">${fmtTime((item.RunTimeTicks || 0) / 10000000)}</div>
      </div>`
    }).join('')

    const rowsEl = document.getElementById('pl-detail-rows')
    rowsEl.querySelectorAll('.track-row').forEach(el => {
      const idx = parseInt(el.dataset.idx)
      wireTrackRow(el, items[idx], items, idx, { inPlaylist: true })
    })
  } catch (e) {
    document.getElementById('pl-detail-rows').innerHTML = `<div class="empty-state">Could not load playlist</div>`
  }
}

document.getElementById('pl-back-btn').addEventListener('click', () => {
  document.getElementById('playlist-detail').classList.remove('active')
  document.getElementById('playlist-index').style.display = ''
})

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
  // Click on the thumb (play button overlay) — play immediately
  const thumb = el.querySelector('.track-thumb')
  if (thumb) {
    thumb.addEventListener('click', e => {
      e.stopPropagation()
      playItems(items, idx)
    })
  }
  // Single click on rest of row — select
  el.addEventListener('click', e => {
    if (e.target.closest('.track-thumb')) return  // handled above
    document.querySelectorAll('.track-row.selected').forEach(r => r.classList.remove('selected'))
    el.classList.add('selected')
  })
  // Double click anywhere — play
  el.addEventListener('dblclick', () => playItems(items, idx))
  // Right click — context menu
  el.addEventListener('contextmenu', e => {
    e.preventDefault()
    showTrackCtxMenu(item, el, e.clientX, e.clientY, opts.inPlaylist || false)
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
  const insertAt = queueIndex + 1
  queue.splice(insertAt, 0, _ctxItem)
  showToast(`"${_ctxItem.Name}" plays next`)
})

document.getElementById('tctx-add-queue').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  if (wfQueueAdd(_ctxItem)) { showToast(`Added "${_ctxItem.Name}" to the Waterfall`); return }
  queue.push(_ctxItem)
  showToast(`Added "${_ctxItem.Name}" to queue`)
})

document.getElementById('tctx-instant-mix').addEventListener('click', async () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  // Reuse the existing instant mix logic via the ctx-instant-mix path
  try {
    const data = await jfGet(`/Items/${_ctxItem.Id}/InstantMix`, { UserId: jf.userId, Limit: 50, Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag' })
    if (!data.Items?.length) { showToast('No instant mix found'); return }
    playItems(data.Items, 0)
    showToast(`Instant mix from "${_ctxItem.Name}"`)
  } catch (e) { showToast('Instant mix failed') }
})

document.getElementById('tctx-add-playlist').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  // Reuse existing add-to-playlist modal — store item for it
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

document.getElementById('tctx-view-album').addEventListener('click', () => {
  if (!_ctxItem?.AlbumId) return
  closeTrackCtxMenu()
  showView('albums')
  openAlbum(_ctxItem.AlbumId)
})

document.getElementById('tctx-view-artist').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  const artistName = _ctxItem.AlbumArtist || _ctxItem.Artists?.[0]
  if (!artistName) return
  showView('artists')
  // Find artist by name in loaded list, or search
  const artistCard = document.querySelector(`.artist-card[data-name="${CSS.escape(artistName)}"]`)
  if (artistCard) artistCard.click()
})

document.getElementById('tctx-refresh-meta').addEventListener('click', async () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  try {
    await fetch(`${jf.url}/Items/${_ctxItem.Id}/Refresh?MetadataRefreshMode=FullRefresh&ImageRefreshMode=FullRefresh&ReplaceAllMetadata=false&ReplaceAllImages=false`, {
      method: 'POST', headers: { 'X-Emby-Token': jf.token }
    })
    showToast('Metadata refresh queued')
  } catch { showToast('Refresh failed') }
})

document.getElementById('tctx-edit-meta').addEventListener('click', () => {
  if (!_ctxItem) return
  closeTrackCtxMenu()
  const url = `${jf.url}/web/index.html#!/edititemmetadata.html?id=${_ctxItem.Id}`
  require('electron').shell.openExternal(url)
})

document.getElementById('tctx-pl-remove').addEventListener('click', async () => {
  if (!_ctxEl || !currentPlaylistId) return
  closeTrackCtxMenu()
  const entryId = _ctxEl.dataset.entryId
  if (!entryId) { showToast('Cannot remove — missing entry ID'); return }
  try {
    const res = await fetch(`${jf.url}/Playlists/${currentPlaylistId}/Items?EntryIds=${encodeURIComponent(entryId)}`, {
      method: 'DELETE', headers: { 'X-Emby-Token': jf.token }
    })
    if (!res.ok) throw new Error(res.status)
    _ctxEl.remove()
    const remaining = document.getElementById('pl-detail-rows').querySelectorAll('.track-row').length
    document.getElementById('pl-detail-meta').textContent = `${remaining} songs`
    showToast('Removed from playlist')
  } catch (e) { showToast(`Failed to remove (${e.message})`) }
})

// ── Playback ──────────────────────────────────────────────────────────────────

function playItems(items, startIndex) {
  if (wfIsActive()) { wfQueueAdd(items[startIndex]); return }
  if (shuffle) {
    // New queue loaded while shuffle is on — shuffle the new queue immediately
    _unshuffledQueue = [...items]
    queue = [...items]
    const startItem = queue[startIndex]
    for (let i = queue.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [queue[i], queue[j]] = [queue[j], queue[i]]
    }
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

async function playCurrentTrack() {
  if (wfIsActive()) return  // in a Waterfall session — playback is driven by sync.js, not the solo queue
  if (queueIndex < 0 || queueIndex >= queue.length) return
  const item = queue[queueIndex]

  initBeatDetection()  // wire up AudioContext before play to avoid mid-playback glitch
  audio.src = streamUrl(item.Id)
  audio.play()

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

function updateNowPlaying(item) {
  // Warm the cache for the current song and the next 5 in queue
  if (item?.Id) {
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
      <span class="np-sep">—</span>
      <span class="np-artist">${esc(item.AlbumArtist || item.Artists?.[0] || '')}</span>
    </span>
  `
  // Measure overflow after paint and apply marquee if needed
  requestAnimationFrame(() => {
    const info  = document.getElementById('np-info')
    const inner = info.querySelector('.np-scroll-inner')
    if (!inner) return
    inner.style.animation = 'none'
    const overflow = inner.scrollWidth - info.clientWidth
    if (overflow > 4) {
      const duration = Math.max(5, overflow / 25) // speed ~25px/s
      inner.style.setProperty('--marquee-dist', `-${overflow + 8}px`)
      inner.style.animation = `np-marquee ${duration}s ease-in-out infinite`
    }
  })
  // Sync like state from Jellyfin user data
  const liked = item.UserData?.IsFavorite || false
  document.getElementById('btn-like').classList.toggle('liked', liked)

  // Update Touch Bar track label
  window.cascade.touchbarUpdate({ title: `${item.Name}  —  ${item.AlbumArtist || item.Artists?.[0] || ''}` })

  // Notify Cha0s Stream of the new track
  window.cascade.nowPlayingUpdate({ title: item.Name || '', artist: item.AlbumArtist || item.Artists?.[0] || '', isPlaying: true })

  // Push track info to OS (lock screen, taskbar, Now Playing widget)
  if ('mediaSession' in navigator) {
    const artwork = art ? [{ src: art, sizes: '200x200', type: 'image/jpeg' }] : []
    navigator.mediaSession.metadata = new MediaMetadata({
      title:  item.Name || '',
      artist: item.AlbumArtist || item.Artists?.[0] || '',
      album:  item.Album || '',
      artwork,
    })
  }

  // Discord RPC
  rpcTrackStart = Date.now()
  updateDiscordPresence(item)

  // Album art accent: fetch for canvas color extraction (api_key is in URL, no extra header needed)
  if (themeAlbumArt && art) {
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

  // Upgrade to iTunes high-res art in normal mode (async — replaces Jellyfin art when resolved)
  if (!serverOnlyMode) {
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
}

// Tracks the currently-highlighted row elements so highlightPlayingRow() only
// ever touches the handful of rows that actually change, instead of scanning
// every .track-row in the document (which can be 1000s on large libraries).
let _playingRowEls = []

function highlightPlayingRow() {
  const currentId = queue[queueIndex]?.Id
  _playingRowEls.forEach(r => r.classList.remove('playing'))
  _playingRowEls = currentId
    ? Array.from(document.querySelectorAll(`.track-row[data-id="${currentId}"]`))
    : []
  _playingRowEls.forEach(r => r.classList.add('playing'))
}

// Report playback to Jellyfin so history updates
async function reportPlaybackStart(itemId) {
  try {
    await fetch(`${jf.url}/Sessions/Playing`, {
      method: 'POST',
      headers: { 'X-Emby-Token': jf.token, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ItemId: itemId, CanSeek: true, QueueableMediaTypes: ['Audio'] })
    })
  } catch {}
}

async function reportPlaybackStopped(itemId, positionTicks) {
  try {
    await fetch(`${jf.url}/Sessions/Playing/Stopped`, {
      method: 'POST',
      headers: { 'X-Emby-Token': jf.token, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ItemId: itemId, PositionTicks: positionTicks })
    })
  } catch {}
}

// ── Audio events ──────────────────────────────────────────────────────────────

audio.addEventListener('timeupdate', () => {
  const cur = audio.currentTime
  const dur = audio.duration || 0
  document.getElementById('prog-cur').textContent = fmtTime(cur)
  document.getElementById('prog-dur').textContent = fmtTime(dur)
  document.getElementById('prog-fill').style.width = dur ? `${(cur / dur) * 100}%` : '0%'
})

audio.addEventListener('play', () => {
  document.getElementById('icon-play').style.display = 'none'
  document.getElementById('icon-pause').style.display = ''
  updateDiscordPresence(queue[queueIndex])
})

audio.addEventListener('pause', () => {
  document.getElementById('icon-play').style.display = ''
  document.getElementById('icon-pause').style.display = 'none'
  window.cascade.discord.clear()
})

audio.addEventListener('ended', () => {
  if (wfHandleEnded()) return  // Waterfall session drove this; solo-queue logic below doesn't apply

  const item = queue[queueIndex]
  if (item) reportPlaybackStopped(item.Id, Math.round(audio.duration * 10000000))

  if (repeatMode === 'one') {
    audio.currentTime = 0
    audio.play()
    return
  }

  let next = queueIndex + 1
  if (next >= queue.length) {
    if (repeatMode === 'all') next = 0
    else return
  }
  queueIndex = next
  playCurrentTrack()
})

// ── Player controls ───────────────────────────────────────────────────────────

document.getElementById('btn-play').addEventListener('click', () => {
  if (audio.paused) { audio.play(); wfBroadcastPlay() }
  else { audio.pause(); wfBroadcastPause() }
})

document.getElementById('btn-prev').addEventListener('click', () => {
  if (audio.currentTime > 3) { audio.currentTime = 0; return }
  if (wfSkip(-1)) return
  queueIndex = Math.max(0, queueIndex - 1)
  playCurrentTrack()
})

document.getElementById('btn-next').addEventListener('click', () => {
  if (wfSkip(1)) return
  queueIndex = Math.min(queue.length - 1, queueIndex + 1)
  playCurrentTrack()
})

document.getElementById('btn-shuffle').addEventListener('click', () => {
  shuffle = !shuffle
  document.getElementById('btn-shuffle').classList.toggle('active', shuffle)

  const currentId = queue[queueIndex]?.Id

  if (shuffle) {
    // Save original order and Fisher-Yates shuffle the queue
    _unshuffledQueue = [...queue]
    for (let i = queue.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [queue[i], queue[j]] = [queue[j], queue[i]]
    }
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
})

// Progress bar scrubbing
document.getElementById('prog-bar').addEventListener('click', (e) => {
  const rect = e.currentTarget.getBoundingClientRect()
  const ratio = (e.clientX - rect.left) / rect.width
  if (audio.duration) audio.currentTime = ratio * audio.duration
})

// Volume bar — click and drag
;(function () {
  const bar = document.getElementById('vol-bar')
  const fill = document.getElementById('vol-fill')
  let dragging = false

  function setVol(e) {
    const rect = bar.getBoundingClientRect()
    const ratio = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width))
    volume = ratio
    applyVolume()
    fill.style.width = `${ratio * 100}%`
    window.cascade.store.set('volume', ratio)
  }

  function onMove(e) { if (dragging) setVol(e) }
  function onUp() { dragging = false; document.removeEventListener('mousemove', onMove); document.removeEventListener('mouseup', onUp) }
  bar.addEventListener('mousedown', (e) => {
    dragging = true; setVol(e); e.preventDefault()
    document.addEventListener('mousemove', onMove)
    document.addEventListener('mouseup', onUp)
  })
})()

document.getElementById('btn-mute').addEventListener('click', () => {
  muted = !muted
  applyVolume()
})

// Lyrics open button
document.getElementById('btn-lyrics-open').addEventListener('click', () => showLyrics())

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

async function shuffleAllSongs() {
  // Load songs if not yet fetched
  if (!allSongs.length) {
    // No SortBy here — the result is shuffled immediately below, so making the
    // server sort the whole library first would be wasted work. Paginate with
    // jfGetAllPaged instead of jfGetMerged so libraries over 500 tracks aren't
    // silently truncated.
    const params = { IncludeItemTypes: 'Audio', Recursive: true, Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag,UserData', Limit: 500 }
    const data = await jfGetAllPaged(`/Users/${jf.userId}/Items`, params)
    allSongs = data.Items || []
    // If songs view is open, render the rows too
    if (document.getElementById('songs-rows').dataset.loaded) renderSongRows()
  }
  if (!allSongs.length) return

  // Fisher-Yates shuffle a copy
  const shuffled = [...allSongs]
  for (let i = shuffled.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [shuffled[i], shuffled[j]] = [shuffled[j], shuffled[i]]
  }

  // Store originals so toggling shuffle off restores order
  _unshuffledQueue = allSongs
  shuffle = true
  document.getElementById('btn-shuffle').classList.add('active')
  document.getElementById('ov-shuffle').classList.add('active')

  playItems(shuffled, 0)
}

document.getElementById('btn-shuffle-songs').addEventListener('click', shuffleAllSongs)
document.getElementById('btn-shuffle-albums').addEventListener('click', shuffleAllSongs)
document.getElementById('btn-shuffle-artists').addEventListener('click', shuffleAllSongs)

// ── Native media session (OS media keys + lock screen / taskbar integration) ──

if ('mediaSession' in navigator) {
  navigator.mediaSession.setActionHandler('play',          () => { if (audio.paused) audio.play() })
  navigator.mediaSession.setActionHandler('pause',         () => { if (!audio.paused) audio.pause() })
  navigator.mediaSession.setActionHandler('stop',          () => { audio.pause(); audio.currentTime = 0 })
  navigator.mediaSession.setActionHandler('nexttrack',     () => document.getElementById('btn-next').click())
  navigator.mediaSession.setActionHandler('previoustrack', () => document.getElementById('btn-prev').click())
  navigator.mediaSession.setActionHandler('seekto', (details) => {
    if (audio.duration && details.seekTime != null) audio.currentTime = details.seekTime
  })
}

// IPC fallback for Windows globalShortcut (covers cases where mediaSession alone isn't enough)
window.cascade.onMediaKey((key) => {
  if (key === 'playpause') document.getElementById('btn-play').click()
  else if (key === 'next')  document.getElementById('btn-next').click()
  else if (key === 'prev')  document.getElementById('btn-prev').click()
})

// ── Remote control (Android app) ──────────────────────────────────────────────

function remoteStatePayload() {
  const track = queue[queueIndex]
  return {
    playing:  !audio.paused,
    position: audio.currentTime || 0,
    duration: audio.duration   || 0,
    volume:   volume,
    track: track ? {
      id:     track.Id,
      name:   track.Name,
      artist: track.AlbumArtist || (track.Artists && track.Artists[0]) || '',
      album:  track.Album || '',
    } : null,
  }
}

window.cascade.remote.onGetState(() => {
  window.cascade.remote.pushState(remoteStatePayload())
})

window.cascade.remote.onSeek((pos) => {
  if (audio.duration && pos >= 0) audio.currentTime = pos
})

window.cascade.remote.onVolume((vol) => {
  const v = Math.max(0, Math.min(1, vol))
  volume = v
  applyVolume()
  const slider = document.getElementById('volume-slider')
  if (slider) slider.value = v
})

// Keep OS media session state in sync with playback
audio.addEventListener('play',  () => {
  if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing'
  window.cascade.touchbarUpdate({ playing: true })
  window.cascade.nowPlayingUpdate({ isPlaying: true })
  window.cascade.remote.pushState(remoteStatePayload())
})
audio.addEventListener('pause', () => {
  if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused'
  window.cascade.touchbarUpdate({ playing: false })
  window.cascade.nowPlayingUpdate({ isPlaying: false })
  window.cascade.remote.pushState(remoteStatePayload())
})

// ── Settings ──────────────────────────────────────────────────────────────────

async function loadSettingsFields() {
  document.getElementById('s-url').value  = await window.cascade.store.get('serverUrl') || ''
  document.getElementById('s-user').value = await window.cascade.store.get('username') || ''
  document.getElementById('s-pass').value = ''

  // Beta updates toggle
  const betaUpdatesToggle = document.getElementById('beta-updates-toggle')
  betaUpdatesToggle.checked = (await window.cascade.store.get('betaUpdates')) === true
  betaUpdatesToggle.onchange = async () => {
    await window.cascade.store.set('betaUpdates', betaUpdatesToggle.checked)
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
    if (queue[queueIndex]) {
      _lyricsCache.delete(queue[queueIndex].Id)
      lyricsData = []; lastLyricsIdx = -1; lastOverlayLyricsIdx = -1; _lyricsScanIdx = 0; _ovLyricsScanIdx = 0; fetchLyrics()
    }
  }

  // Lyrics source preference
  const lyricsSourceSel = document.getElementById('s-lyrics-source')
  lyricsSourceSel.value = VALID_LYRICS_SOURCES.has(lyricsForcedSource) ? lyricsForcedSource : 'auto'
  _applyServerOnlyMode(serverOnlyMode)  // apply visibility after options exist in DOM
  lyricsSourceSel.onchange = async () => {
    lyricsForcedSource = lyricsSourceSel.value
    await window.cascade.store.set('lyricsForcedSource', lyricsForcedSource)
    updateSourcePills()
    if (queue[queueIndex]) {
      _lyricsCache.delete(queue[queueIndex].Id)
      lyricsData = []; lastLyricsIdx = -1; lastOverlayLyricsIdx = -1; _lyricsScanIdx = 0; _ovLyricsScanIdx = 0; fetchLyrics()
    }
  }

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
    const auth = await jfAuth(url, user, pass || await window.cascade.store.get('password') || '')
    await window.cascade.store.set('token', auth.AccessToken)
    await window.cascade.store.set('userId', auth.User.Id)
    if (pass) await window.cascade.store.set('password', pass)

    // Save selected libraries
    const checkedIds = getCheckedLibraryIds()
    if (checkedIds.length) {
      await window.cascade.store.set('libraryIds', JSON.stringify(checkedIds))
      jf.libraryIds = checkedIds
    }

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
  await window.cascade.store.delete('token')
  await window.cascade.store.delete('userId')
  await window.cascade.store.delete('password')
  setConnected(false)
  document.getElementById('setup-overlay').classList.remove('hidden')
})

// ── Setup overlay ─────────────────────────────────────────────────────────────

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

document.getElementById('btn-check-updates').addEventListener('click', () => {
  window.cascade.checkForUpdates()
})

async function init() {
  document.documentElement.setAttribute('data-platform', window.cascade.platform)
  await window.cascade.getVersion().then(v => {
    appVersion = v
    const el = document.getElementById('app-version')
    if (el) el.textContent = `v${v}`
  })

  await loadTheme()
  buildPresets()
  await initDiscordRpc()

  // Restore saved volume
  const savedVol = await window.cascade.store.get('volume')
  if (savedVol !== undefined && savedVol !== null) {
    volume = parseFloat(savedVol)
    applyVolume()
    const fill = document.getElementById('vol-fill')
    if (fill) fill.style.width = `${volume * 100}%`
  }

  const serverUrl = await window.cascade.store.get('serverUrl')
  const username  = await window.cascade.store.get('username')
  const password  = await window.cascade.store.get('password')
  const token     = await window.cascade.store.get('token')
  const userId    = await window.cascade.store.get('userId')

  // Always pre-fill the setup form so the user never has to retype from scratch
  if (serverUrl) document.getElementById('setup-url').value      = serverUrl
  if (username)  document.getElementById('setup-username').value  = username
  if (password)  document.getElementById('setup-password').value  = password

  if (serverUrl && token && userId) {
    document.getElementById('setup-overlay').classList.add('hidden')
    try {
      await connect(serverUrl, token, userId)
    } catch (e) {
      // Token stale — silently re-auth with stored credentials before giving up
      if (serverUrl && username && password) {
        try {
          const auth = await jfAuth(serverUrl, username, password)
          await window.cascade.store.set('token', auth.AccessToken)
          await window.cascade.store.set('userId', auth.User.Id)
          await connect(serverUrl, auth.AccessToken, auth.User.Id)
          return
        } catch {}
      }
      document.getElementById('setup-overlay').classList.remove('hidden')
    }
  }
  // else setup overlay stays visible (fields already pre-filled above)
}

// ── Full-screen now-playing overlay ──────────────────────────────────────────

const npOverlay = document.getElementById('np-overlay')
let overlayOpen = false
let overlayLyricsOpen = false

// ── Beat-reactive background ───────────────────────────────────────────────
let _currentBgArtUrl = null  // current track's art URL for overlay background
let _audioCtx = null
let _analyser = null
let _mediaSrc = null   // shared MediaElementAudioSourceNode — also tapped by sync.js for Waterfall
let _localGain = null  // local-monitoring-only volume/mute — see applyVolume() below
let _beatRafId = null
let _blobColors = []  // extracted colors, stored for blob drift animation
let _driftParams = [] // randomized per-blob drift parameters, set on each color refresh

function randomizeDrift() {
  const r = () => Math.random()
  _driftParams = [0, 1, 2].map(() => ({
    // Two independent sin/cos pairs per axis — gives Lissajous-style organic motion
    xF1: 0.11 + r() * 0.13,  xP1: r() * Math.PI * 2,  xA1: 10 + r() * 10,
    xF2: 0.04 + r() * 0.09,  xP2: r() * Math.PI * 2,  xA2: 3  + r() * 6,
    yF1: 0.10 + r() * 0.13,  yP1: r() * Math.PI * 2,  yA1: 10 + r() * 10,
    yF2: 0.04 + r() * 0.09,  yP2: r() * Math.PI * 2,  yA2: 3  + r() * 6,
  }))
}

function initBeatDetection() {
  if (_audioCtx) { if (_audioCtx.state === 'suspended') _audioCtx.resume(); return }
  try {
    _audioCtx = new AudioContext()
    _analyser = _audioCtx.createAnalyser()
    _analyser.fftSize = 512           // more bins = better low-end resolution
    _analyser.smoothingTimeConstant = 0.4
    _mediaSrc = _audioCtx.createMediaElementSource(audio)

    // Once an element is routed through Web Audio, .volume/.muted get baked
    // into the samples _mediaSrc captures — which sync.js also taps for the
    // Waterfall broadcast. Without this, muting/lowering your own monitoring
    // volume would mute/lower it for everyone listening to your stream too.
    // So local volume/mute lives in this gain node instead, and the element
    // itself stays pinned at "clean" (full, unmuted) — see applyVolume()
    // below, which every volume/mute control routes through instead of
    // writing audio.volume/.muted directly. _mediaSrc's output then always
    // stays the true, unattenuated signal.
    _localGain = _audioCtx.createGain()
    _mediaSrc.connect(_localGain)
    _localGain.connect(_analyser)
    _analyser.connect(_audioCtx.destination)
    applyVolume()
  } catch(e) { console.warn('Beat detection unavailable:', e) }
}

// Single place that actually writes volume/mute state — reads the `volume`/
// `muted` variables and applies them to whichever output actually exists.
// (An earlier version of this tried to detect+undo our own audio.volume
// writes via the 'volumechange' event, but that event is dispatched
// asynchronously — by the time the echo from our own reset arrived, it read
// back audio.volume as already-reset and clobbered the gain node. Routing
// every write through one function sidesteps that race entirely.)
function applyVolume() {
  if (_localGain) {
    _localGain.gain.value = muted ? 0 : volume
    audio.volume = 1
    audio.muted = false
  } else {
    audio.volume = volume
    audio.muted = muted
  }
}

function startBeatLoop() {
  if (_beatRafId) return
  const overlay = document.getElementById('np-overlay')
  if (!overlay) return

  let _lastBlobFrameTs = 0
  function frame(ts) {
    _beatRafId = requestAnimationFrame(frame)

    // ── Blob drift — organic slow movement using randomized layered sin/cos ──
    // The drift is slow (periods of tens of seconds), so rebuilding this gradient
    // string at the full 60fps is wasted work — throttle to ~15fps, which is
    // visually indistinguishable for motion this gradual.
    if (ts - _lastBlobFrameTs < 66) return
    _lastBlobFrameTs = ts
    if (_blobColors.length > 0 && themeAlbumArt && _driftParams.length > 0) {
      const t = Date.now() / 1000
      // Anchor positions and sizes per slot (blobs stay near screen edges)
      const slots = [
        { ox: 78, oy: 16, w: 78, h: 78, a: 0.88 },
        { ox: 18, oy: 82, w: 78, h: 78, a: 0.80 },
        { ox: 12, oy: 18, w: 58, h: 58, a: 0.55 },
      ]
      const drifted = _blobColors.map((c, i) => {
        const s = slots[i] || slots[2]
        const p = _driftParams[i] || _driftParams[0]
        const x = s.ox + Math.sin(t * p.xF1 + p.xP1) * p.xA1 + Math.sin(t * p.xF2 + p.xP2) * p.xA2
        const y = s.oy + Math.cos(t * p.yF1 + p.yP1) * p.yA1 + Math.cos(t * p.yF2 + p.yP2) * p.yA2
        return `radial-gradient(ellipse ${s.w}% ${s.h}% at ${x.toFixed(1)}% ${y.toFixed(1)}%, rgba(${c.r},${c.g},${c.b},${s.a}) 0%, rgba(${c.r},${c.g},${c.b},${s.a}) 42%, transparent 100%)`
      })
      overlay.style.backgroundImage = drifted.join(', ')
    }
  }
  frame()
}

function stopBeatLoop() {
  if (_beatRafId) { cancelAnimationFrame(_beatRafId); _beatRafId = null }
}

function openOverlay() {
  overlayOpen = true
  npOverlay.classList.add('open')
  syncOverlayState()
  renderQueuePanel()
  if (overlayLyricsOpen) renderOverlayLyrics()
  document.getElementById('ov-vol-fill').style.width = `${volume * 100}%`

  console.log('[art] openOverlay — themeAlbumArt:', themeAlbumArt, '_blobColors:', _blobColors.length, 'item:', queue[queueIndex]?.Name)

  // Apply art theme every time the overlay opens — derive the URL from the
  // current queue item directly so we never depend on _currentBgArtUrl being set.
  // If _blobColors is already cached, apply them immediately (no flash), then
  // re-fetch in the background to refresh if the track changed.
  if (themeAlbumArt) {
    if (_blobColors.length > 0) {
      npOverlay.style.backgroundColor = '#0d0d0f'
      npOverlay.style.backgroundImage = buildBlobBackground(_blobColors)
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

  startBeatLoop()
}

function closeOverlay() {
  overlayOpen = false
  npOverlay.classList.remove('open')
  stopBeatLoop()
}

// Only the left NP section (art + info) opens the overlay — everything else is a deadzone
document.querySelector('.statusbar').addEventListener('click', (e) => {
  if (!e.target.closest('.np')) return
  overlayOpen ? closeOverlay() : openOverlay()
})

document.getElementById('np-overlay-close').addEventListener('click', closeOverlay)
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && overlayOpen) closeOverlay() })

// Lyrics toggle — queue slides left out, lyrics slides right in (and vice versa)
document.getElementById('ov-lyrics-toggle').addEventListener('click', () => {
  overlayLyricsOpen = !overlayLyricsOpen
  document.getElementById('ov-panel-lyrics').style.transform = overlayLyricsOpen ? 'translateX(0)' : 'translateX(100%)'
  document.getElementById('ov-panel-queue').style.transform  = overlayLyricsOpen ? 'translateX(-100%)' : 'translateX(0)'
  document.getElementById('ov-lyrics-toggle').classList.toggle('active', overlayLyricsOpen)
  if (overlayLyricsOpen) renderOverlayLyrics()
})

// Overlay controls mirror the main controls
// Overlay more-options inline dropdown
const ovDropdown = document.getElementById('ov-dropdown')

document.getElementById('ov-more-btn').addEventListener('click', (e) => {
  e.stopPropagation()
  const isOpen = ovDropdown.classList.contains('open')
  ovDropdown.classList.toggle('open', !isOpen)
  if (!isOpen) {
    const btn = e.currentTarget.getBoundingClientRect()
    // Position above the button, centered
    ovDropdown.style.left = `${btn.left + btn.width / 2 - ovDropdown.offsetWidth / 2}px`
    ovDropdown.style.top = `${btn.top - ovDropdown.offsetHeight - 8}px`
    // Clamp all four edges
    const r = ovDropdown.getBoundingClientRect()
    if (r.left < 8) ovDropdown.style.left = '8px'
    if (r.right > window.innerWidth - 8) ovDropdown.style.left = `${window.innerWidth - ovDropdown.offsetWidth - 8}px`
    if (r.top < 8) ovDropdown.style.top = `${btn.bottom + 8}px`
    // Clamp bottom — if it still overflows, pin to bottom of screen
    const r2 = ovDropdown.getBoundingClientRect()
    if (r2.bottom > window.innerHeight - 8) ovDropdown.style.top = `${window.innerHeight - ovDropdown.offsetHeight - 8}px`
  }
})

const ctxMap = {
  'stop':        'ctx-stop',        'clear':       'ctx-clear-queue',
  'mix':         'ctx-instant-mix', 'playlist':    'ctx-add-playlist',
  'download':    'ctx-download',    'copy':        'ctx-copy-url',
  'info':        'ctx-media-info',  'refresh':     'ctx-refresh-meta',
  'edit-meta':   'ctx-edit-meta',   'edit-img':    'ctx-edit-images',
  'edit-lyrics': 'ctx-edit-lyrics', 'view-album':  'ctx-view-album',
  'view-artist': 'ctx-view-artist', 'view-lyrics': 'ctx-view-lyrics',
  'delete':      'ctx-delete',
}

ovDropdown.querySelectorAll('.ov-dd-item').forEach(btn => {
  btn.addEventListener('click', (e) => {
    e.stopPropagation()
    ovDropdown.classList.remove('open')
    const ctxId = ctxMap[btn.dataset.action]
    if (ctxId) document.getElementById(ctxId).click()
  })
})

// Close dropdown when clicking outside
document.addEventListener('mousedown', (e) => {
  if (!ovDropdown.contains(e.target) && e.target.id !== 'ov-more-btn') {
    ovDropdown.classList.remove('open')
  }
})

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

// Overlay progress bar — drag to scrub
;(function() {
  const bar = document.getElementById('ov-prog-bar')
  const fill = document.getElementById('ov-prog-fill')
  let dragging = false
  function seek(e) {
    const rect = bar.getBoundingClientRect()
    const ratio = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width))
    if (audio.duration) {
      audio.currentTime = ratio * audio.duration
      fill.style.width = `${ratio * 100}%`
    }
  }
  function onMove(e) { if (dragging) seek(e) }
  function onUp() { dragging = false; document.removeEventListener('mousemove', onMove); document.removeEventListener('mouseup', onUp) }
  bar.addEventListener('mousedown', (e) => {
    dragging = true; seek(e); e.preventDefault()
    document.addEventListener('mousemove', onMove)
    document.addEventListener('mouseup', onUp)
  })
})()

// Overlay volume slider — drag to adjust
;(function() {
  const bar = document.getElementById('ov-vol-bar')
  const fill = document.getElementById('ov-vol-fill')
  let dragging = false
  function setVol(e) {
    const rect = bar.getBoundingClientRect()
    const ratio = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width))
    volume = ratio
    applyVolume()
    fill.style.width = `${ratio * 100}%`
    // Keep main vol bar in sync
    document.getElementById('vol-fill').style.width = `${ratio * 100}%`
    window.cascade.store.set('volume', ratio)
  }
  function onMove(e) { if (dragging) setVol(e) }
  function onUp() { dragging = false; document.removeEventListener('mousemove', onMove); document.removeEventListener('mouseup', onUp) }
  bar.addEventListener('mousedown', (e) => {
    dragging = true; setVol(e); e.preventDefault()
    document.addEventListener('mousemove', onMove)
    document.addEventListener('mouseup', onUp)
  })
})()

// Keep overlay progress in sync
audio.addEventListener('timeupdate', () => {
  if (!overlayOpen) return
  const cur = audio.currentTime
  const dur = audio.duration || 0
  document.getElementById('ov-cur').textContent = fmtTime(cur)
  document.getElementById('ov-dur').textContent = fmtTime(dur)
  document.getElementById('ov-prog-fill').style.width = dur ? `${(cur / dur) * 100}%` : '0%'
})

audio.addEventListener('play', () => {
  document.getElementById('ov-icon-play').style.display = 'none'
  document.getElementById('ov-icon-pause').style.display = ''
})
audio.addEventListener('pause', () => {
  document.getElementById('ov-icon-play').style.display = ''
  document.getElementById('ov-icon-pause').style.display = 'none'
})

function syncOverlayState() {
  const item = queue[queueIndex]
  if (!item) return

  // Art — prefer high-res (iTunes if available, else Jellyfin 600px)
  const art = _currentHighResArtUrl || artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
  const artEl = document.getElementById('ov-art')
  artEl.innerHTML = art ? `<img src="${art}" alt="" onerror="this.innerHTML='♪'">` : '♪'

  // Info
  document.getElementById('ov-track').textContent = item.Name || ''
  document.getElementById('ov-artist').textContent = item.AlbumArtist || item.Artists?.[0] || ''

  // Like state
  document.getElementById('ov-like').classList.toggle('liked', item.UserData?.IsFavorite || false)

  // Shuffle / repeat state
  document.getElementById('ov-shuffle').classList.toggle('active', shuffle)
  updateRepeatButtons()
}

// While a Waterfall session is active, the shared session queue is what's
// actually authoritative for playback (see wfSkip/wfJumpTo in sync.js) — the
// solo `queue`/`queueIndex` sit there unused/stale. Read through this instead
// of the bare variables anywhere this panel needs "the queue" so it never
// shows one queue while skip/next act on another.
function _activeQueue() {
  return wfIsActive() ? wfSession.queue : queue
}
function _activeQueueIndex() {
  return wfIsActive() ? wfSession.index : queueIndex
}

function renderQueuePanel() {
  const container = document.getElementById('ov-queue-rows')
  const panel     = document.getElementById('ov-panel-queue')
  const srcQueue  = _activeQueue()
  if (!srcQueue.length) { container.innerHTML = '<div class="empty-state" style="padding:40px 0">Queue is empty</div>'; return }

  // Bind scroll listener once — shifts the render window as the user scrolls
  if (!_queueScrollBound) {
    _queueScrollBound = true
    panel.addEventListener('scroll', () => {
      const q = _activeQueue()
      if (!q.length) return
      const visStart = Math.floor(panel.scrollTop / QUEUE_ROW_H)
      const visEnd   = visStart + Math.ceil(panel.clientHeight / QUEUE_ROW_H)
      const nearTop  = visStart < _queueWinStart + 3
      const nearBot  = visEnd   > _queueWinStart + QUEUE_WIN - 3
      if (nearTop || nearBot) {
        _queueWinStart = Math.max(0, Math.min(visStart - 3, q.length - QUEUE_WIN))
        _drawQueueRows(container, false)
      }
    }, { passive: true })
  }

  // Re-centre window on the current track
  _queueWinStart = Math.max(0, Math.min(_activeQueueIndex() - QUEUE_BEFORE, srcQueue.length - QUEUE_WIN))
  _drawQueueRows(container, true)
}

function _drawQueueRows(container, scrollToCurrent) {
  const srcQueue  = _activeQueue()
  const srcIndex  = _activeQueueIndex()
  const winEnd = Math.min(srcQueue.length, _queueWinStart + QUEUE_WIN)
  const topH   = _queueWinStart * QUEUE_ROW_H
  const botH   = (srcQueue.length - winEnd) * QUEUE_ROW_H

  const rows = srcQueue.slice(_queueWinStart, winEnd).map((item, idx) => {
    const i     = _queueWinStart + idx
    const art   = artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
    const thumb = art ? `<img src="${art}" alt="" onerror="this.style.display='none'">` : '♪'
    const dur   = fmtTime((item.RunTimeTicks || 0) / 10000000)
    const draggable = !wfIsActive() // reordering a shared session queue isn't supported yet
    return `<div class="queue-row${i === srcIndex ? ' current' : ''}" data-qi="${i}" draggable="${draggable}">
      <div class="queue-row-drag" title="Drag to reorder">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="8" y1="6" x2="16" y2="6"/><line x1="8" y1="12" x2="16" y2="12"/><line x1="8" y1="18" x2="16" y2="18"/></svg>
      </div>
      <div class="queue-row-art">${thumb}</div>
      <div style="min-width:0;flex:1">
        <div class="queue-row-title">${esc(item.Name)}</div>
        <div class="queue-row-artist">${esc(item.AlbumArtist || item.Artists?.[0] || '')}</div>
      </div>
      <div class="queue-row-dur">${dur}</div>
      <button class="queue-row-remove" data-qi="${i}" title="Remove from queue">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
      </button>
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
      if (wfIsActive()) { wfJumpTo(qi); renderQueuePanel(); return }
      queueIndex = qi
      playCurrentTrack()
      renderQueuePanel()
    })

    el.querySelector('.queue-row-remove').addEventListener('click', (e) => {
      e.stopPropagation()
      if (wfIsActive()) { showToast("Removing tracks from a shared Waterfall queue isn't supported yet"); return }
      const idx = parseInt(el.dataset.qi)
      queue.splice(idx, 1)
      if (queueIndex >= idx && queueIndex > 0) queueIndex--
      renderQueuePanel()
    })

    el.addEventListener('dragstart', (e) => {
      if (wfIsActive()) { e.preventDefault(); return }
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
      renderQueuePanel()
    })
  })

  if (scrollToCurrent) {
    const current = container.querySelector('.queue-row.current')
    if (current) current.scrollIntoView({ block: 'nearest' })
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
  // actual current line — no CSS-transition reflow trick needed since jumpTo()
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
// transition, it carries velocity across target changes — when a new line
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
    setPos(p) {   // direct 1:1 tracking (manual drag) — no physics involved
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
// spring animation — used when snap-scrolling right as a karaoke line's last
// word finishes, so the jump isn't a glide disconnected from the vocal.
function _scrollOverlayLyricsTo(idx, instant) {
  const body = document.getElementById('ov-lyrics-body')
  const panel = document.getElementById('ov-panel-lyrics')
  const el = body.querySelector(`.ov-lyric-line[data-idx="${idx}"]`)
  if (!el) return
  const panelMid = panel.clientHeight / 2
  const activeMid = el.offsetTop + el.offsetHeight / 2
  ovLyricsBaseY = panelMid - activeMid
  // While the user is manually scrolling, leave the spring alone — it gets
  // redirected (base + their offset) from the wheel handler instead.
  if (ovLyricsUserScrolling) return
  if (instant) ovLyricsSpring.jumpTo(ovLyricsBaseY)
  else ovLyricsSpring.setTarget(ovLyricsBaseY)
}

// lyricsData is sorted by Start time, and playback only moves forward except on
// seeks — so resume scanning from the last known index instead of rescanning
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

  clearTimeout(ovLyricsScrollTimer)
  ovLyricsScrollTimer = setTimeout(() => {
    ovLyricsUserScrolling = false
    ovLyricsManualOffset = 0
    ovLyricsSpring.setTarget(ovLyricsBaseY)  // spring settles back with a bit of momentum
  }, 2200)
}, { passive: false })

audio.addEventListener('timeupdate', () => {
  if (!overlayOpen || !overlayLyricsOpen || !lyricsData.length) return
  // Same lookahead as word-fill (_wordHighlightFrame) so the last word's fill
  // animation and the line-promotion check complete in lockstep — no gap in
  // either direction (mid-fill cutoff if promotion is earlier, a visible
  // "stick" on the finished word if promotion is later).
  const nowSec = audio.currentTime + 0.225
  const baseIdx = _scanLyricsBaseIdx(nowSec, _ovLyricsScanIdx)
  _ovLyricsScanIdx = baseIdx

  // Karaoke lines: promote to the next line (position AND highlight together)
  // the instant the current line's last word finishes, instead of waiting for
  // the next line's own start — otherwise the view snaps into place early but
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
function hideCtxMenu() { ctxMenu.classList.remove('open') }
// Close when clicking outside the menu — mousedown fires before click so it's reliable
document.addEventListener('mousedown', (e) => {
  if (!ctxMenu.contains(e.target)) hideCtxMenu()
})

document.getElementById('np-art').addEventListener('contextmenu', (e) => {
  e.preventDefault()
  if (!queue[queueIndex]) return
  showCtxMenu(e.clientX, e.clientY)
})
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { hideCtxMenu(); hideLyrics() } })

// Stop playback
document.getElementById('ctx-stop').addEventListener('click', () => {
  audio.pause()
  audio.src = ''
  queue = []; queueIndex = -1
  window.cascade.discord.clear()
  document.getElementById('np-art').innerHTML = '♪'
  document.getElementById('np-info').innerHTML = '<span class="np-empty">Nothing playing</span>'
  document.getElementById('prog-fill').style.width = '0%'
  document.getElementById('prog-cur').textContent = '0:00'
  document.getElementById('prog-dur').textContent = '0:00'
})

// Clear queue
document.getElementById('ctx-clear-queue').addEventListener('click', () => {
  queue = []; queueIndex = -1
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
            const errText = await res.text().catch(() => '')
            showToast(`Failed to add (${res.status}): ${errText.slice(0, 60)}`)
          } else {
            showToast(`Added to "${el.textContent}"`)
          }
        } catch (e) {
          showToast('Failed to add — network error')
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
    // Reload playlists tab if it's already been loaded
    const grid = document.getElementById('playlists-grid')
    if (grid.dataset.loaded) { delete grid.dataset.loaded; loadPlaylists() }
  } catch (e) {
    showToast('Failed to create playlist')
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
  window.cascade.clipboard.write(streamUrl(item.Id))
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
      ['Bitrate', d.MediaStreams?.[0]?.BitRate ? `${Math.round(d.MediaStreams[0].BitRate / 1000)} kbps` : '—'],
      ['Codec', d.MediaStreams?.[0]?.Codec?.toUpperCase() || '—'],
      ['Container', d.Container?.toUpperCase() || '—'],
      ['Sample rate', d.MediaStreams?.[0]?.SampleRate ? `${d.MediaStreams[0].SampleRate} Hz` : '—'],
      ['Channels', d.MediaStreams?.[0]?.Channels],
      ['Size', d.Size ? `${(d.Size / 1048576).toFixed(1)} MB` : '—'],
      ['Added', d.DateCreated ? new Date(d.DateCreated).toLocaleDateString() : '—'],
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
  if (!item) return
  try {
    await fetch(`${jf.url}/Items/${item.Id}/Refresh?MetadataRefreshMode=FullRefresh&ImageRefreshMode=FullRefresh&ReplaceAllMetadata=false`, {
      method: 'POST', headers: { 'X-Emby-Token': jf.token }
    })
  } catch {}
})

// Edit metadata / images / lyrics — open Jellyfin web UI
document.getElementById('ctx-edit-meta').addEventListener('click', () => {
  const item = queue[queueIndex]
  if (item) window.cascade.shell.openExternal(`${jf.url}/web/index.html#!/details?id=${item.Id}&serverId=${item.ServerId || ''}`)
})
document.getElementById('ctx-edit-images').addEventListener('click', () => {
  const item = queue[queueIndex]
  if (item) window.cascade.shell.openExternal(`${jf.url}/web/index.html#!/edititemimages?id=${item.Id}`)
})
document.getElementById('ctx-edit-lyrics').addEventListener('click', () => {
  const item = queue[queueIndex]
  if (item) window.cascade.shell.openExternal(`${jf.url}/web/index.html#!/details?id=${item.Id}`)
})

// View album — navigate to albums view (future: filter by album)
document.getElementById('ctx-view-album').addEventListener('click', () => showView('albums'))

// View album artist — navigate to artists view
document.getElementById('ctx-view-artist').addEventListener('click', () => showView('artists'))

// View lyrics
document.getElementById('ctx-view-lyrics').addEventListener('click', () => showLyrics())

// Delete media
document.getElementById('ctx-delete').addEventListener('click', async () => {
  const item = queue[queueIndex]
  if (!item) return
  if (!confirm(`Delete "${item.Name}" from your server? This cannot be undone.`)) return
  try {
    await fetch(`${jf.url}/Items/${item.Id}`, {
      method: 'DELETE', headers: { 'X-Emby-Token': jf.token }
    })
    audio.pause(); audio.src = ''
    queue.splice(queueIndex, 1)
    queueIndex = Math.min(queueIndex, queue.length - 1)
    if (queue.length) playCurrentTrack()
  } catch (e) { console.error('Delete failed', e) }
})

// ── Lyrics panel ──────────────────────────────────────────────────────────────

let lyricsSource        = null   // source that was actually used: 'Kugou' | 'LRCLIB' | 'LRCLIB (plain)' | 'Jellyfin' | 'Karaoke' | 'Synced'
let lyricsForcedSource  = 'auto' // 'auto' | 'Kugou' | 'LRCLIB' | 'Jellyfin' | 'cascade-karaoke' | 'cascade-synced'
let serverOnlyMode    = false  // fetch exclusively from Cascade plugin when true

// Valid lyrics source keys — any stored value not in this set is stale and gets reset
const VALID_LYRICS_SOURCES = new Set(['auto', 'Kugou', 'LRCLIB', 'Jellyfin', 'cascade-karaoke', 'cascade-synced'])

// Load persisted preferences immediately
;(async () => {
  const stored = (await window.cascade.store.get('lyricsForcedSource')) || 'auto'
  if (!VALID_LYRICS_SOURCES.has(stored)) {
    console.warn(`[Lyrics] Stale lyricsForcedSource "${stored}" — resetting to auto`)
    await window.cascade.store.set('lyricsForcedSource', 'auto')
    lyricsForcedSource = 'auto'
  } else {
    lyricsForcedSource = stored
  }
  serverOnlyMode   = (await window.cascade.store.get('serverOnlyMode')) === true
  _applyServerOnlyMode(serverOnlyMode)
})()

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
    if (tried_names.length) showToast(`No lyrics — ${tried_names.join(', ')} all failed`, 3500)
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

      // Status badge — remove old one first
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
;['lyrics-edit-btn', 'ov-lyrics-edit-btn'].forEach(id => {
  const btn = document.getElementById(id)
  if (!btn) return
  btn.addEventListener('click', async e => {
    e.stopPropagation()
    const item = queue[queueIndex]
    if (!item || !jf) return
    const proceed = await _ensureCascadePluginNotice()
    if (!proceed) return
    window.cascade.lyricsEditor.open({ item, jf, lyricsData: lyricsData || [] })
  })
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
    // Refetch for current track
    if (queue[queueIndex]) {
      _lyricsCache.delete(queue[queueIndex].Id)
      lyricsData = []; lastLyricsIdx = -1; lastOverlayLyricsIdx = -1; _lyricsScanIdx = 0; _ovLyricsScanIdx = 0; fetchLyrics()
    }
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

  // Side panel — CSS scoping (.lyrics-line.active .lyric-word) handles inactive lines.
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

  // Overlay — same: CSS scoping handles inactive lines automatically
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

audio.addEventListener('play',  () => _startWordLoop())
audio.addEventListener('pause', () => _stopWordLoop())
audio.addEventListener('ended', () => _stopWordLoop())

// ── Lyrics panel ─────────────────────────────────────────────────────────────

function showLyrics() {
  document.getElementById('lyrics-panel').classList.add('open')
  fetchLyrics()
}
function hideLyrics() { document.getElementById('lyrics-panel').classList.remove('open') }

document.getElementById('lyrics-close').addEventListener('click', hideLyrics)

// ── Lyrics waterfall helpers ──────────────────────────────────────────────────


function _lrcTimeToTicks(mm, ss) {
  return Math.round((parseInt(mm) * 60 + parseFloat(ss)) * 10_000_000)
}

// Parse standard LRC or Enhanced LRC (karaoke word-level) to internal format
function parseLRC(text) {
  const lines = []
  for (const raw of text.split('\n')) {
    const m = raw.match(/^\[(\d+):(\d+\.\d+)\](.*)$/)
    if (!m) continue
    const startTicks = _lrcTimeToTicks(m[1], m[2])
    const content = m[3]
    if (content.includes('<')) {
      // Enhanced LRC: [mm:ss.xx]<mm:ss.xx>word<mm:ss.xx>word...
      const words = []
      const wordRe = /<(\d+):(\d+\.\d+)>([^<\[]*)/g
      let wm
      while ((wm = wordRe.exec(content)) !== null) {
        const wText = wm[3]
        if (!wText) continue
        // Symbols/punctuation with no letters or digits — attach to previous word
        const isSymbol = !/[\p{L}\p{N}]/u.test(wText)
        if (isSymbol && words.length > 0) {
          words[words.length - 1].Text = words[words.length - 1].Text.trimEnd() + wText.trimStart()
        } else {
          words.push({ Start: _lrcTimeToTicks(wm[1], wm[2]), End: null, Text: wText })
        }
      }
      for (let i = 0; i < words.length - 1; i++) words[i].End = words[i + 1].Start
      // Last word end will be filled in below (needs next line's start)
      const fullText = words.map(w => w.Text).join('').trim()
      if (fullText) lines.push({ Start: startTicks, End: null, Text: fullText, Words: words.length ? words : null })
    } else {
      const t2 = content.trim()
      if (t2) lines.push({ Start: startTicks, End: null, Text: t2, Words: null })
    }
  }
  // Fill in end time for each line's last word using the next line's start
  for (let i = 0; i < lines.length; i++) {
    const ws = lines[i].Words
    if (!ws?.length) continue
    const last = ws[ws.length - 1]
    if (last.End == null) {
      last.End = lines[i + 1]?.Start ?? (last.Start + 20_000_000) // 2s fallback
    }
  }

  return lines
}


// Parse Kugou KRC format (decrypted) to internal format.
// Line: [{line_start_ms},{line_duration_ms}]<word_offset_ms,word_duration_ms,0>text...
// Word offsets are relative to the line start.
function parseKrc(krcText) {
  const MS   = 10_000        // 1ms = 10,000 ticks (100-nanosecond units)
  const lines = []
  for (const rawLine of krcText.split('\n')) {
    const line = rawLine.trim()
    const lineMatch = line.match(/^\[(\d+),(\d+)\](.*)$/)
    if (!lineMatch) continue                       // skip [ti:], [ar:], [offset:] tags

    const lineStartMs = parseInt(lineMatch[1])
    const lineEndMs   = lineStartMs + parseInt(lineMatch[2])
    const content     = lineMatch[3]

    const wordRegex = /<(\d+),(\d+),\d+>([^<]*)/g
    const words = []
    let fullText = ''
    let wm
    while ((wm = wordRegex.exec(content)) !== null) {
      const wOffMs  = parseInt(wm[1])
      const wDurMs  = parseInt(wm[2])
      const wText   = wm[3]
      if (!wText) continue
      fullText += wText
      words.push({
        Start: (lineStartMs + wOffMs) * MS,
        End:   (lineStartMs + wOffMs + wDurMs) * MS,
        Text:  wText,
      })
    }

    fullText = fullText.trim()
    if (!fullText) continue
    lines.push({
      Start: lineStartMs * MS,
      End:   lineEndMs   * MS,
      Text:  fullText,
      Words: words.length > 0 ? words : null,
    })
  }
  return lines
}

// Compare two lyric results by word overlap. Returns false if clearly different songs.
function _lyricsTextMatch(a, b) {
  if (!a || !b) return true
  const words = r => new Set(
    r.lines.map(l => l.Text).join(' ').toLowerCase().match(/[a-z]{3,}/g) || []
  )
  const aw = words(a), bw = words(b)
  // Skip check if either side has too few Latin words (e.g. Japanese songs)
  if (aw.size < 5 || bw.size < 5) return true
  const inter = [...aw].filter(w => bw.has(w)).length
  // At least 25% of the smaller set must appear in the larger
  return inter / Math.min(aw.size, bw.size) >= 0.25
}

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

// Main fetch: LRCLIB · Jellyfin — all fired in parallel,
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
      // Kugou KRC — word-level, no auth required. Main process handles decrypt.
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
    // Detection failed silently — leave bar hidden
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

  // Wrap in a translateY-driven inner div — position is spring-animated in JS
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

audio.addEventListener('timeupdate', () => {
  if (!lyricsData.length) return
  // Same lookahead as word-fill (_wordHighlightFrame) so the last word's fill
  // animation and the line-promotion check complete in lockstep — no gap in
  // either direction (mid-fill cutoff if promotion is earlier, a visible
  // "stick" on the finished word if promotion is later).
  const nowSec = audio.currentTime + 0.225
  const baseIdx = _scanLyricsBaseIdx(nowSec, _lyricsScanIdx)
  _lyricsScanIdx = baseIdx

  // For karaoke lines, promote to the next line (highlight AND scroll together)
  // the instant its last word finishes, instead of waiting for the next line's
  // own start — otherwise the view snaps into place early but sits dim/inactive
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

function updateDiscordPresence(item) {
  if (!discordEnabled || !item) return
  const activity = {
    details:        item.Name?.slice(0, 128) || 'Unknown Track',
    state:          (item.AlbumArtist || item.Artists?.[0] || 'Unknown Artist').slice(0, 128),
    startTimestamp: rpcTrackStart,
  }
  if (jf.url.startsWith('https')) {
    const art = artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
    if (art) {
      activity.largeImageKey  = art
      activity.largeImageText = item.Album?.slice(0, 128) || ''
    }
  }
  window.cascade.discord.update(activity)
}

const DEFAULT_DISCORD_CLIENT_ID = '1512373702522835004'
let _rpcConnected = false

async function initDiscordRpc() {
  const enabled  = await window.cascade.store.get('discordRpcEnabled')
  const clientId = await window.cascade.store.get('discordClientId') || DEFAULT_DISCORD_CLIENT_ID
  discordEnabled = enabled === 'true'
  if (discordEnabled) window.cascade.discord.connect(clientId)

  // Single listener — updates dot + label; tracks state for when settings view opens later
  window.cascade.discord.onStatus((connected) => {
    _rpcConnected = connected
    const dot   = document.getElementById('discord-rpc-dot')
    const label = document.getElementById('discord-rpc-status-label')
    if (dot)   dot.className   = 'ws-dot' + (connected ? ' connected' : '')
    if (label) label.textContent = connected ? 'Connected' : 'Not connected'
  })
}

// ── Search ────────────────────────────────────────────────────────────────────

let searchDebounce = null

document.getElementById('search-input').addEventListener('input', (e) => {
  const q = e.target.value.trim()
  document.getElementById('search-clear').style.display = q ? '' : 'none'
  clearTimeout(searchDebounce)
  if (!q) {
    document.getElementById('search-results').innerHTML = '<div class="search-empty-state">Start typing to search your library</div>'
    return
  }
  searchDebounce = setTimeout(() => runSearch(q), 300)
})

document.getElementById('search-clear').addEventListener('click', () => {
  document.getElementById('search-input').value = ''
  document.getElementById('search-clear').style.display = 'none'
  document.getElementById('search-results').innerHTML = '<div class="search-empty-state">Start typing to search your library</div>'
  document.getElementById('search-input').focus()
})

// Focus the input whenever the search view is opened
const _origShowView = showView
// (hooked below after showView is defined)

async function runSearch(query) {
  const results = document.getElementById('search-results')
  results.innerHTML = '<div class="search-empty-state">Searching…</div>'
  try {
    const [songsRes, albumsRes, artistsRes] = await Promise.allSettled([
      jfGet(`/Users/${jf.userId}/Items`, { SearchTerm: query, Recursive: true, Limit: 10, IncludeItemTypes: 'Audio', Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag' }),
      jfGet(`/Users/${jf.userId}/Items`, { SearchTerm: query, Recursive: true, Limit: 8,  IncludeItemTypes: 'MusicAlbum', Fields: 'PrimaryImageAspectRatio' }),
      jfGet(`/Artists`,                  { SearchTerm: query, UserId: jf.userId, Limit: 8 }),
    ])
    const songs   = songsRes.status   === 'fulfilled' ? songsRes.value   : { Items: [] }
    const albums  = albumsRes.status  === 'fulfilled' ? albumsRes.value  : { Items: [] }
    const artists = artistsRes.status === 'fulfilled' ? artistsRes.value : { Items: [] }

    const hasSongs   = songs.Items?.length
    const hasAlbums  = albums.Items?.length
    const hasArtists = artists.Items?.length

    if (!hasSongs && !hasAlbums && !hasArtists) {
      results.innerHTML = `<div class="search-no-results">No results for "${esc(query)}"</div>`
      return
    }

    let html = ''

    if (hasSongs) {
      html += `<div class="search-section">
        <div class="search-section-title">Songs</div>
        <div class="track-list">
          <div id="search-song-rows">${songs.Items.map((item, i) => {
            const art = artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
            return `<div class="track-row" data-search-song="${i}" data-id="${item.Id}">
              <div class="track-num">${i + 1}</div>
              ${trackThumbHtml(art)}
              <div style="min-width:0">
                <div class="track-title">${esc(item.Name)}</div>
                <div class="track-artist">${esc(item.AlbumArtist || item.Artists?.[0] || '')}</div>
              </div>
              <div class="track-album-name">${esc(item.Album || '')}</div>
              <div class="track-dur">${fmtTime((item.RunTimeTicks || 0) / 10000000)}</div>
            </div>`
          }).join('')}</div>
        </div>
      </div>`
    }

    if (hasAlbums) {
      html += `<div class="search-section">
        <div class="search-section-title">Albums</div>
        <div class="album-grid">${albums.Items.map((item, i) => {
          const art = artUrl(item.Id, item.ImageTags?.Primary)
          const img = art ? `<img src="${art}" alt="" onerror="this.style.display='none'">` : '♪'
          return `<div class="album-card" data-search-album="${item.Id}">
            <div class="album-art">${img}</div>
            <div class="album-body">
              <div class="album-name">${esc(item.Name)}</div>
              <div class="album-artist">${esc(item.AlbumArtist || '')}</div>
            </div>
          </div>`
        }).join('')}</div>
      </div>`
    }

    if (hasArtists) {
      html += `<div class="search-section">
        <div class="search-section-title">Artists</div>
        <div class="artist-grid">${artists.Items.map(item => {
          const art = artistArtUrl(item.Id)
          return `<div class="artist-card" data-search-artist="${item.Id}">
            <div class="artist-avatar"><img src="${art}" alt="" onerror="this.style.display='none'"></div>
            <div class="artist-name">${esc(item.Name)}</div>
          </div>`
        }).join('')}</div>
      </div>`
    }

    results.innerHTML = html

    // Wire up song rows
    if (hasSongs) {
      results.querySelectorAll('[data-search-song]').forEach(el => {
        const idx = parseInt(el.dataset.searchSong)
        wireTrackRow(el, songs.Items[idx], songs.Items, idx)
      })
    }

    // Wire up album cards
    results.querySelectorAll('[data-search-album]').forEach(el => {
      el.addEventListener('click', () => playAlbum(el.dataset.searchAlbum))
    })

    // Wire up artist cards — open artist detail view
    results.querySelectorAll('[data-search-artist]').forEach(el => {
      el.addEventListener('click', () => {
        showView('artists')
        openArtist(el.dataset.searchArtist, el.querySelector('.artist-name')?.textContent || '')
      })
    })
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
}

// Album art dominant color extraction
function extractVibrantColor(img) {
  try {
    const canvas = document.createElement('canvas')
    canvas.width = canvas.height = 80
    const ctx = canvas.getContext('2d')
    ctx.drawImage(img, 0, 0, 80, 80)
    const data = ctx.getImageData(0, 0, 80, 80).data

    // 36 hue buckets of 10° each — track count, rgb sum, and saturation sum
    const buckets = Array.from({ length: 36 }, () => ({ count: 0, r: 0, g: 0, b: 0, satSum: 0 }))

    for (let i = 0; i < data.length; i += 4) {
      const r = data[i] / 255, g = data[i+1] / 255, b = data[i+2] / 255
      const max = Math.max(r, g, b), min = Math.min(r, g, b)
      const l = (max + min) / 2
      if (l < 0.05 || l > 0.88) continue  // skip near-black AND near-white (white bg causes warm-tint false positives)
      const d = max - min
      const s = d === 0 ? 0 : d / (1 - Math.abs(2 * l - 1))
      if (s < 0.12) continue              // skip low-saturation pixels (JPEG noise floor)

      let h = 0
      if (d > 0) {
        if (max === r)      h = ((g - b) / d + (g < b ? 6 : 0)) / 6
        else if (max === g) h = ((b - r) / d + 2) / 6
        else                h = ((r - g) / d + 4) / 6
      }

      const bkt = buckets[Math.floor(h * 36)]
      bkt.count++
      bkt.r += data[i]; bkt.g += data[i+1]; bkt.b += data[i+2]
      bkt.satSum += s
    }

    // Score = avgSat² × √count  — rewards high vibrancy; coverage is a tiebreaker, not the winner
    let best = null, bestScore = 0
    for (const bkt of buckets) {
      if (bkt.count < 3) continue  // ignore singleton noise
      const avgSat = bkt.satSum / bkt.count
      const score = avgSat * avgSat * Math.sqrt(bkt.count)
      if (score > bestScore) { bestScore = score; best = bkt }
    }

    // Log every bucket that has pixels so we can see what the image actually contains
    const bucketDebug = buckets.map((bkt, i) => {
      if (!bkt.count) return null
      return `h${i*10}°: count=${bkt.count} avgSat=${(bkt.satSum/bkt.count).toFixed(2)}`
    }).filter(Boolean)
    console.log('[color] buckets:', bucketDebug.join(' | '))
    console.log('[color] winner:', best ? `h${Math.round(best.r/best.count)},${Math.round(best.g/best.count)},${Math.round(best.b/best.count)} score=${bestScore.toFixed(3)}` : 'none')

    // Require meaningful saturation — low avgSat means JPEG noise, not a real colour.
    // B&W albums max out at ~0.23; real colours are ≥0.35; safe cutoff is 0.28.
    if (!best || (best.satSum / best.count) < 0.28) return null

    return {
      r: Math.round(best.r / best.count),
      g: Math.round(best.g / best.count),
      b: Math.round(best.b / best.count)
    }
  } catch { return null }
}

function rgbToHex(r, g, b) {
  return '#' + [r,g,b].map(v => v.toString(16).padStart(2,'0')).join('')
}

// Extract top N hue-diverse colors from an image element.
// Returns an array of {r,g,b} with saturation boosted for vivid blobs.
function extractTopColors(img, n = 3) {
  try {
    const canvas = document.createElement('canvas')
    canvas.width = canvas.height = 80
    const ctx = canvas.getContext('2d')
    ctx.drawImage(img, 0, 0, 80, 80)
    const { data } = ctx.getImageData(0, 0, 80, 80)

    const BUCKETS = 36, DEG = 360 / BUCKETS
    const counts = new Array(BUCKETS).fill(0)
    const sums = Array.from({ length: BUCKETS }, () => ({ r: 0, g: 0, b: 0 }))

    for (let i = 0; i < data.length; i += 4) {
      const r = data[i] / 255, g = data[i+1] / 255, b = data[i+2] / 255, a = data[i+3]
      if (a < 128) continue
      const max = Math.max(r, g, b), min = Math.min(r, g, b)
      const l = (max + min) / 2
      if (l < 0.04 || l > 0.96) continue       // skip only true-black / true-white
      const s = max === min ? 0 : (max - min) / (1 - Math.abs(2 * l - 1))
      if (s < 0.05) continue                    // skip near-gray (looser — catches dark purples etc)

      const d = max - min
      let h = 0
      if (max === r)      h = ((g - b) / d + (g < b ? 6 : 0)) / 6
      else if (max === g) h = ((b - r) / d + 2) / 6
      else                h = ((r - g) / d + 4) / 6
      const bi = Math.floor(h * BUCKETS) % BUCKETS
      counts[bi]++
      sums[bi].r += data[i]; sums[bi].g += data[i+1]; sums[bi].b += data[i+2]
    }

    // Rank buckets by count × average saturation — vivid colors beat large dull areas
    const ranked = counts
      .map((c, i) => {
        if (!c) return { score: 0, c, i, hue: i * DEG }
        const avgR = sums[i].r / c, avgG = sums[i].g / c, avgB = sums[i].b / c
        const mx = Math.max(avgR, avgG, avgB) / 255, mn = Math.min(avgR, avgG, avgB) / 255
        const l = (mx + mn) / 2
        const sat = mx === mn ? 0 : (mx - mn) / (1 - Math.abs(2 * l - 1))
        return { score: c * sat, c, i, hue: i * DEG }
      })
      .filter(x => x.c > 0)
      .sort((a, b) => b.score - a.score)

    const results = []
    for (const { c, i, hue } of ranked) {
      if (results.length >= n) break
      let r = sums[i].r / c, g = sums[i].g / c, b = sums[i].b / c
      // Moderate saturation boost: push channels away from mid without clamping hue
      const mid = (Math.max(r, g, b) + Math.min(r, g, b)) / 2
      const BOOST = 1.4
      r = Math.min(255, Math.max(0, mid + (r - mid) * BOOST))
      g = Math.min(255, Math.max(0, mid + (g - mid) * BOOST))
      b = Math.min(255, Math.max(0, mid + (b - mid) * BOOST))
      // Normalize to a vivid, visible blob color:
      // Convert to HSL, force L ≥ 0.48 and S ≥ 0.65, then back to RGB.
      // This ensures dark covers (like near-black album art) still produce bright blobs.
      const nr = r/255, ng = g/255, nb = b/255
      const cmax = Math.max(nr,ng,nb), cmin = Math.min(nr,ng,nb)
      const d = cmax - cmin
      let h2 = 0
      if (d > 0) {
        if (cmax === nr)      h2 = ((ng-nb)/d + (ng<nb?6:0))/6
        else if (cmax === ng) h2 = ((nb-nr)/d + 2)/6
        else                  h2 = ((nr-ng)/d + 4)/6
      }
      const tgtL = 0.50, tgtS = Math.max(0.70, d > 0 ? d/(1-Math.abs(2*((cmax+cmin)/2)-1)) : 0)
      const c2 = (1 - Math.abs(2*tgtL - 1)) * tgtS
      const x2 = c2 * (1 - Math.abs((h2*6)%2 - 1))
      const m2 = tgtL - c2/2
      const hi = Math.floor(h2*6) % 6
      const [rr,gg,bb2] = [[c2,x2,0],[x2,c2,0],[0,c2,x2],[0,x2,c2],[x2,0,c2],[c2,0,x2]][hi]
      results.push({
        r: Math.round((rr+m2)*255),
        g: Math.round((gg+m2)*255),
        b: Math.round((bb2+m2)*255),
        hue
      })
    }
    return results
  } catch { return [] }
}

// Build a Cider-style multi-blob gradient background from an array of colors.
// Colors are placed at screen edges so the center stays dark and readable.
function buildBlobBackground(colors) {
  // Edge placements — main colors at opposite corners, third as accent
  const slots = [
    { x: '80%', y: '15%', w: '75%', h: '75%', a: 0.88 },  // top-right
    { x: '15%', y: '85%', w: '75%', h: '75%', a: 0.80 },  // bottom-left
    { x: '10%', y: '15%', w: '55%', h: '55%', a: 0.55 },  // top-left accent
  ]
  return colors.map((c, i) => {
    const { x, y, w, h, a } = slots[i] || { x: '50%', y: '50%', w: '60%', h: '60%', a: 0.5 }
    return `radial-gradient(ellipse ${w} ${h} at ${x} ${y}, rgba(${c.r},${c.g},${c.b},${a}) 0%, transparent 100%)`
  }).join(', ')
  // Note: dark base (#0d0d0f) is set as background-color separately — plain hex is invalid in background-image
}

function applyAlbumArtTheme(imgEl) {
  console.log('[art] applyAlbumArtTheme — themeAlbumArt:', themeAlbumArt, 'imgEl:', !!imgEl)
  if (!themeAlbumArt || !imgEl) return
  const col = extractVibrantColor(imgEl)
  console.log('[art] extractVibrantColor:', col)

  if (!col) {
    // B&W / neutral art — reset gradient to dark neutral so the previous track's
    // colour doesn't bleed through, and use gray blobs on the overlay
    applyGradient('#505050', '#202020')
    _lastAlbumColors = null
    _blobColors = [{ r: 90, g: 90, b: 90, hue: 0 }, { r: 40, g: 40, b: 40, hue: 0 }]
    randomizeDrift()
    const overlay = document.getElementById('np-overlay')
    overlay.style.backgroundColor = '#0d0d0f'
    overlay.style.backgroundImage = buildBlobBackground(_blobColors)
    overlay.classList.add('art-theme')
    return
  }

  // Gradient accent — normalise to a vivid hue so muted album colours still produce
  // distinct, saturated gradients across the full spectrum.
  const _nr = col.r/255, _ng = col.g/255, _nb = col.b/255
  const _mx = Math.max(_nr,_ng,_nb), _mn = Math.min(_nr,_ng,_nb), _d = _mx - _mn
  let _h = 0
  if (_d > 0) {
    if (_mx === _nr)      _h = ((_ng-_nb)/_d + (_ng<_nb?6:0))/6
    else if (_mx === _ng) _h = ((_nb-_nr)/_d + 2)/6
    else                  _h = ((_nr-_ng)/_d + 4)/6
  }
  const _hsl2rgb = (hue, s, l) => {
    const c = (1-Math.abs(2*l-1))*s, x = c*(1-Math.abs((hue*6)%2-1)), m = l-c/2
    const idx = Math.floor(hue*6)%6
    const [r,g,b] = [[c,x,0],[x,c,0],[0,c,x],[0,x,c],[x,0,c],[c,0,x]][idx]
    return [Math.round((r+m)*255), Math.round((g+m)*255), Math.round((b+m)*255)]
  }
  const [sr,sg,sb] = _hsl2rgb(_h, 0.85, 0.62)   // bright vivid
  const [er,eg,eb] = _hsl2rgb(_h, 0.90, 0.36)   // dark vivid
  const startHex = rgbToHex(sr,sg,sb)
  const endHex   = rgbToHex(er,eg,eb)
  _lastAlbumColors = { start: startHex, end: endHex }
  applyGradient(startHex, endHex)

  // Fullscreen overlay: extract top 3 colors for the living blob background
  _blobColors = extractTopColors(imgEl)

  // Fallback: if the cover is too dark/desaturated for bucket extraction,
  // synthesize a palette from the single dominant color we already have
  if (_blobColors.length === 0) {
    // Derive blob palette from the single dominant col — force to L=0.50 S=0.70
    const nr = col.r/255, ng = col.g/255, nb = col.b/255
    const cmax = Math.max(nr,ng,nb), cmin = Math.min(nr,ng,nb), d = cmax - cmin
    // If the image is essentially black & white / neutral, there's no real hue to derive.
    // d < 0.12 means near-gray — normalizing it would default h2=0 → vivid red, which is wrong.
    // In this case skip the art theme entirely rather than inventing a fake color.
    if (d < 0.12) {
      // B&W / neutral art — use monochrome gray blobs instead of inventing a fake hue
      const lum = Math.round(((cmax + cmin) / 2) * 255)
      const gHi = Math.min(255, Math.round(lum * 1.2))
      const gLo = Math.max(0,   Math.round(lum * 0.6))
      _blobColors = [
        { r: gHi, g: gHi, b: gHi, hue: 0 },
        { r: gLo, g: gLo, b: gLo, hue: 0 },
      ]
    } else {
      let h2 = 0
      if (d > 0) {
        if (cmax===nr)      h2 = ((ng-nb)/d+(ng<nb?6:0))/6
        else if (cmax===ng) h2 = ((nb-nr)/d+2)/6
        else                h2 = ((nr-ng)/d+4)/6
      }
      const tgtL = 0.50, tgtS = 0.72
      const c2 = (1-Math.abs(2*tgtL-1))*tgtS, x2 = c2*(1-Math.abs((h2*6)%2-1)), m2 = tgtL-c2/2
      const hIdx = Math.floor(h2*6)%6
      const [rr,gg,bb2] = [[c2,x2,0],[x2,c2,0],[0,c2,x2],[0,x2,c2],[x2,0,c2],[c2,0,x2]][hIdx]
      const pr = Math.round((rr+m2)*255), pg = Math.round((gg+m2)*255), pb = Math.round((bb2+m2)*255)
      _blobColors = [
        { r: pr, g: pg, b: pb, hue: 0 },
        { r: Math.round(pr*0.5), g: Math.round(pg*0.5), b: Math.round(pb*0.5), hue: 180 },
      ]
    }
  }

  randomizeDrift()
  console.log('[art] _blobColors:', _blobColors.length, _blobColors)
  // Set gradient directly on the overlay — no z-index/clipping issues
  const overlay = document.getElementById('np-overlay')
  const bg = buildBlobBackground(_blobColors)
  console.log('[art] setting overlay background, first 120 chars:', bg.slice(0,120))
  overlay.style.backgroundColor = '#0d0d0f'
  overlay.style.backgroundImage = bg
  overlay.classList.add('art-theme')
  console.log('[art] art-theme class added')
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

document.getElementById('toggle-album-art').addEventListener('change', (e) => {
  themeAlbumArt = e.target.checked
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
})

// ── Utility ───────────────────────────────────────────────────────────────────

function esc(str) {
  return String(str || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')
}

init()
