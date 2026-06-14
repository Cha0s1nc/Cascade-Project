// ── Cascade renderer ──────────────────────────────────────────────────────────

// State
let jf = { url: '', token: '', userId: '' }
let appVersion = '1.0.0'
let queue = []
let queueIndex = -1
let shuffle = false
let repeatMode = 'none' // 'none' | 'all' | 'one'
let _unshuffledQueue = []   // original order saved when shuffle is enabled
let volume = 0.75

const audio = new Audio()
audio.volume = volume

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

function artUrl(itemId, tag) {
  if (!tag) return null
  return `${jf.url}/Items/${itemId}/Images/Primary?fillHeight=200&fillWidth=200&quality=80&api_key=${jf.token}`
}

function artistArtUrl(itemId) {
  return `${jf.url}/Items/${itemId}/Images/Primary?fillHeight=200&fillWidth=200&quality=80&api_key=${jf.token}`
}

function streamUrl(itemId) {
  return `${jf.url}/Audio/${itemId}/universal?UserId=${jf.userId}&api_key=${jf.token}&Container=opus,mp3,aac,flac,wav,ogg&TranscodingContainer=ts&TranscodingProtocol=hls&AudioCodec=aac&MaxStreamingBitrate=140000000`
}

// ── Toast ─────────────────────────────────────────────────────────────────────

function showToast(msg, duration = 2200) {
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
  document.getElementById('artist-detail-meta').textContent = 'Loading…'
  document.getElementById('artist-albums-grid').innerHTML = '<div class="loading-state">Loading…</div>'
  document.getElementById('artist-songs-rows').innerHTML = ''

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
      const thumb = thumbArt ? `<img src="${thumbArt}" alt="" onerror="this.style.display='none'">` : ''
      return `<div class="track-row" data-idx="${i}">
        <div class="track-num">${i + 1}</div>
        <div class="track-thumb">${thumb}</div>
        <div style="min-width:0">
          <div class="track-title">${esc(item.Name)}</div>
          <div class="track-artist">${esc(item.AlbumArtist || item.Artists?.[0] || '')}</div>
        </div>
        <div class="track-album-name">${esc(item.Album || '')}</div>
        <div class="track-dur">${fmtTime((item.RunTimeTicks || 0) / 10000000)}</div>
      </div>`
    }).join('')

    document.getElementById('artist-songs-rows').querySelectorAll('.track-row').forEach(el => {
      el.addEventListener('click', () => playItems(songs, parseInt(el.dataset.idx)))
    })
  } catch (e) {
    document.getElementById('artist-detail-meta').textContent = 'Could not load artist'
  }
}

document.getElementById('artist-back-btn').addEventListener('click', () => {
  document.getElementById('artist-detail').style.display = 'none'
  document.getElementById('artist-index').style.display = ''
})

// ── Songs ─────────────────────────────────────────────────────────────────────

let allSongs = []

async function loadSongs() {
  const rows = document.getElementById('songs-rows')
  rows.dataset.loaded = '1'
  try {
    const params = { SortBy: 'SortName', SortOrder: 'Ascending', IncludeItemTypes: 'Audio', Recursive: true, Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag,UserData', Limit: 500 }
    const data = await jfGetMerged(`/Users/${jf.userId}/Items`, params)
    allSongs = data.Items || []
    renderSongRows()
  } catch (e) {
    rows.innerHTML = `<div class="empty-state">Could not load songs</div>`
  }
}

function renderSongRows() {
  const rows = document.getElementById('songs-rows')
  rows.innerHTML = allSongs.map((item, i) => {
    const art = artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
    const thumb = art ? `<img src="${art}" alt="" onerror="this.style.display='none'">` : ''
    return `
    <div class="track-row" data-idx="${i}">
      <div class="track-num">${i + 1}</div>
      <div class="track-thumb">${thumb}</div>
      <div style="min-width:0">
        <div class="track-title">${esc(item.Name)}</div>
        <div class="track-artist">${esc(item.AlbumArtist || item.Artists?.[0] || '')}</div>
      </div>
      <div class="track-album-name">${esc(item.Album || '')}</div>
      <div class="track-dur">${fmtTime((item.RunTimeTicks || 0) / 10000000)}</div>
    </div>`
  }).join('')
  rows.querySelectorAll('.track-row').forEach(el => {
    el.addEventListener('click', () => {
      const idx = parseInt(el.dataset.idx)
      playItems(allSongs, idx)
    })
  })
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
  document.getElementById('pl-detail-meta').textContent = 'Loading…'
  document.getElementById('pl-detail-rows').innerHTML = '<div class="loading-state">Loading…</div>'

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
      const thumb = art ? `<img src="${art}" alt="" onerror="this.style.display='none'">` : ''
      return `
      <div class="track-row" data-idx="${i}" data-id="${item.Id}" data-entry-id="${item.PlaylistItemId || item.Id}">
        <div class="track-num">${i + 1}</div>
        <div class="track-thumb">${thumb}</div>
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
      el.addEventListener('click', () => playItems(items, parseInt(el.dataset.idx)))
      el.addEventListener('contextmenu', e => {
        e.preventDefault()
        plTrackCtxTarget = el
        showPlTrackCtxMenu(e.clientX, e.clientY)
      })
    })
  } catch (e) {
    document.getElementById('pl-detail-rows').innerHTML = `<div class="empty-state">Could not load playlist</div>`
  }
}

document.getElementById('pl-back-btn').addEventListener('click', () => {
  document.getElementById('playlist-detail').classList.remove('active')
  document.getElementById('playlist-index').style.display = ''
})

// ── Playlist track context menu ────────────────────────────────────────────────

const plTrackCtxMenu = document.getElementById('pl-track-ctx-menu')
let plTrackCtxTarget = null

function showPlTrackCtxMenu(x, y) {
  plTrackCtxMenu.style.left = `${x}px`
  plTrackCtxMenu.style.top = `${y}px`
  plTrackCtxMenu.classList.add('open')
  const r = plTrackCtxMenu.getBoundingClientRect()
  if (r.right > window.innerWidth) plTrackCtxMenu.style.left = `${x - r.width}px`
  if (r.bottom > window.innerHeight) plTrackCtxMenu.style.top = `${y - r.height}px`
}

document.addEventListener('mousedown', e => {
  if (!plTrackCtxMenu.contains(e.target)) plTrackCtxMenu.classList.remove('open')
})

document.getElementById('pl-ctx-play').addEventListener('click', () => {
  if (!plTrackCtxTarget) return
  plTrackCtxTarget.click()
  plTrackCtxMenu.classList.remove('open')
})

document.getElementById('pl-ctx-add-queue').addEventListener('click', () => {
  if (!plTrackCtxTarget) return
  const idx = parseInt(plTrackCtxTarget.dataset.idx)
  const item = currentPlaylistItems[idx]
  if (item) { queue.push(item); showToast(`Added "${item.Name}" to queue`) }
  plTrackCtxMenu.classList.remove('open')
})

document.getElementById('pl-ctx-remove').addEventListener('click', async () => {
  if (!plTrackCtxTarget || !currentPlaylistId) return
  plTrackCtxMenu.classList.remove('open')
  const entryId = plTrackCtxTarget.dataset.entryId
  if (!entryId) { showToast('Cannot remove — missing entry ID'); return }
  try {
    const res = await fetch(`${jf.url}/Playlists/${currentPlaylistId}/Items?EntryIds=${encodeURIComponent(entryId)}`, {
      method: 'DELETE',
      headers: { 'X-Emby-Token': jf.token }
    })
    if (!res.ok) throw new Error(res.status)
    plTrackCtxTarget.remove()
    // Recount
    const remaining = document.getElementById('pl-detail-rows').querySelectorAll('.track-row').length
    document.getElementById('pl-detail-meta').textContent = `${remaining} songs`
    showToast('Removed from playlist')
  } catch (e) {
    console.error('Remove from playlist failed', e)
    showToast(`Failed to remove (${e.message})`)
  }
})

// ── Playback ──────────────────────────────────────────────────────────────────

function playItems(items, startIndex) {
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
  if (queueIndex < 0 || queueIndex >= queue.length) return
  const item = queue[queueIndex]

  audio.src = streamUrl(item.Id)
  audio.play()

  updateNowPlaying(item)
  highlightPlayingRow()
  reportPlaybackStart(item.Id)
}

function updateNowPlaying(item) {
  const art = artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
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

  // Album art accent: fetch through our auth header so canvas isn't tainted by CORS
  if (themeAlbumArt && art) {
    fetch(art, { headers: { 'X-Emby-Token': jf.token } })
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

function highlightPlayingRow() {
  document.querySelectorAll('.track-row').forEach(r => r.classList.remove('playing'))
  const current = queue[queueIndex]
  document.querySelectorAll('.track-row').forEach(r => {
    const idx = parseInt(r.dataset.idx)
    if (allSongs[idx]?.Id === current?.Id) r.classList.add('playing')
  })
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
  if (audio.paused) audio.play()
  else audio.pause()
})

document.getElementById('btn-prev').addEventListener('click', () => {
  if (audio.currentTime > 3) { audio.currentTime = 0; return }
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
    audio.volume = ratio
    fill.style.width = `${ratio * 100}%`
  }

  bar.addEventListener('mousedown', (e) => { dragging = true; setVol(e); e.preventDefault() })
  document.addEventListener('mousemove', (e) => { if (dragging) setVol(e) })
  document.addEventListener('mouseup', () => { dragging = false })
})()

document.getElementById('btn-mute').addEventListener('click', () => {
  audio.muted = !audio.muted
})

// Lyrics open button
document.getElementById('btn-lyrics-open').addEventListener('click', () => showLyrics())

// Like / favourite
const likeBtn = document.getElementById('btn-like')
likeBtn.addEventListener('click', async () => {
  const item = queue[queueIndex]
  if (!item) return
  const isLiked = likeBtn.classList.contains('liked')
  try {
    await fetch(`${jf.url}/Users/${jf.userId}/FavoriteItems/${item.Id}`, {
      method: isLiked ? 'DELETE' : 'POST',
      headers: { 'X-Emby-Token': jf.token }
    })
    likeBtn.classList.toggle('liked', !isLiked)
  } catch (e) { console.error('Like failed', e) }
})

// ── Shuffle All ───────────────────────────────────────────────────────────────

async function shuffleAllSongs() {
  // Load songs if not yet fetched
  if (!allSongs.length) {
    const params = { SortBy: 'SortName', SortOrder: 'Ascending', IncludeItemTypes: 'Audio', Recursive: true, Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag,UserData', Limit: 500 }
    const data = await jfGetMerged(`/Users/${jf.userId}/Items`, params)
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
    volume:   audio.volume,
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
  audio.volume = v
  volume = v
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

  window.cascade.discord.onStatus((connected) => {
    const dot   = document.getElementById('discord-rpc-dot')
    const label = document.getElementById('discord-rpc-status-label')
    if (dot) dot.className = 'ws-dot' + (connected ? ' connected' : '')
    if (label) label.textContent = connected ? 'Connected' : 'Not connected'
  })

  document.getElementById('discord-dev-link').onclick = (e) => {
    e.preventDefault()
    window.cascade.shell.openExternal('https://discord.com/developers/applications')
  }
}

document.getElementById('btn-save-settings').addEventListener('click', async () => {
  const url = document.getElementById('s-url').value.trim()
  const user = document.getElementById('s-user').value.trim()
  const pass = document.getElementById('s-pass').value

  if (!url || !user) return

  try {
    const auth = await jfAuth(url, user, pass || await window.cascade.store.get('password') || '')
    await window.cascade.store.set('serverUrl', url)
    await window.cascade.store.set('username', user)
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

  const serverUrl = await window.cascade.store.get('serverUrl')
  const token = await window.cascade.store.get('token')
  const userId = await window.cascade.store.get('userId')

  if (serverUrl && token && userId) {
    document.getElementById('setup-overlay').classList.add('hidden')
    try {
      await connect(serverUrl, token, userId)
    } catch (e) {
      // Token might be stale — show setup
      document.getElementById('setup-overlay').classList.remove('hidden')
    }
  }
  // else setup overlay stays visible
}

// ── Full-screen now-playing overlay ──────────────────────────────────────────

const npOverlay = document.getElementById('np-overlay')
let overlayOpen = false
let overlayLyricsOpen = false

function openOverlay() {
  overlayOpen = true
  npOverlay.classList.add('open')
  syncOverlayState()
  renderQueuePanel()
  if (overlayLyricsOpen) renderOverlayLyrics()
  // Sync volume slider to current level
  document.getElementById('ov-vol-fill').style.width = `${audio.volume * 100}%`
}

function closeOverlay() {
  overlayOpen = false
  npOverlay.classList.remove('open')
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
document.getElementById('ov-like').addEventListener('click', () => document.getElementById('btn-like').click())

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
  bar.addEventListener('mousedown', (e) => { dragging = true; seek(e); e.preventDefault() })
  document.addEventListener('mousemove', (e) => { if (dragging) seek(e) })
  document.addEventListener('mouseup', () => { dragging = false })
})()

// Overlay volume slider — drag to adjust
;(function() {
  const bar = document.getElementById('ov-vol-bar')
  const fill = document.getElementById('ov-vol-fill')
  let dragging = false
  function setVol(e) {
    const rect = bar.getBoundingClientRect()
    const ratio = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width))
    audio.volume = ratio
    fill.style.width = `${ratio * 100}%`
    // Keep main vol bar in sync
    document.getElementById('vol-fill').style.width = `${ratio * 100}%`
  }
  bar.addEventListener('mousedown', (e) => { dragging = true; setVol(e); e.preventDefault() })
  document.addEventListener('mousemove', (e) => { if (dragging) setVol(e) })
  document.addEventListener('mouseup', () => { dragging = false })
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

  // Art
  const art = artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
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

function renderQueuePanel() {
  const container = document.getElementById('ov-queue-rows')
  if (!queue.length) { container.innerHTML = '<div class="empty-state" style="padding:40px 0">Queue is empty</div>'; return }

  container.innerHTML = queue.map((item, i) => {
    const art = artUrl(item.AlbumId || item.Id, item.AlbumPrimaryImageTag || item.ImageTags?.Primary)
    const thumb = art ? `<img src="${art}" alt="" onerror="this.style.display='none'">` : '♪'
    const dur = fmtTime((item.RunTimeTicks || 0) / 10000000)
    return `<div class="queue-row${i === queueIndex ? ' current' : ''}" data-qi="${i}" draggable="true">
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

  let dragSrc = null

  container.querySelectorAll('.queue-row').forEach(el => {
    const qi = parseInt(el.dataset.qi)

    // Play on click (but not on drag handle or remove button)
    el.addEventListener('click', (e) => {
      if (e.target.closest('.queue-row-drag, .queue-row-remove')) return
      queueIndex = qi
      playCurrentTrack()
      renderQueuePanel()
    })

    // Remove button
    el.querySelector('.queue-row-remove').addEventListener('click', (e) => {
      e.stopPropagation()
      const idx = parseInt(el.dataset.qi)
      queue.splice(idx, 1)
      if (queueIndex >= idx && queueIndex > 0) queueIndex--
      renderQueuePanel()
    })

    // Drag to reorder
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
      const to = parseInt(el.dataset.qi)
      const [moved] = queue.splice(from, 1)
      queue.splice(to, 0, moved)
      // Keep queueIndex pointing at the same track
      if (queueIndex === from) queueIndex = to
      else if (from < queueIndex && to >= queueIndex) queueIndex--
      else if (from > queueIndex && to <= queueIndex) queueIndex++
      renderQueuePanel()
    })
  })

  // Scroll current track into view
  const current = container.querySelector('.queue-row.current')
  if (current) current.scrollIntoView({ block: 'center' })
}

async function renderOverlayLyrics() {
  const body = document.getElementById('ov-lyrics-body')
  const item = queue[queueIndex]
  if (!item) { body.innerHTML = '<div class="lyrics-empty" style="padding:40px 0;text-align:center">Nothing playing</div>'; return }

  if (!lyricsData.length) {
    body.innerHTML = '<div class="lyrics-empty" style="padding:40px 0;text-align:center">Loading…</div>'
    try {
      const res = await fetch(`${jf.url}/Audio/${item.Id}/Lyrics`, { headers: { 'X-Emby-Token': jf.token } })
      if (!res.ok) throw new Error()
      const data = await res.json()
      lyricsData = data.Lyrics || []
    } catch {
      body.innerHTML = '<div class="lyrics-empty" style="padding:40px 0;text-align:center">No lyrics available</div>'
      return
    }
  }

  if (!lyricsData.length) {
    body.innerHTML = '<div class="lyrics-empty" style="padding:40px 0;text-align:center">No lyrics available</div>'
    return
  }

  renderOverlayLyricLines()

  // Reset position instantly then animate to current position
  body.style.transition = 'none'
  body.style.transform = 'translateY(0)'
  requestAnimationFrame(() => {
    body.style.transition = ''
    const nowSec = audio.currentTime + 0.225
    let activeIdx = 0
    for (let i = 0; i < lyricsData.length; i++) {
      if (lyricsData[i].Start != null && lyricsData[i].Start / 10000000 <= nowSec) activeIdx = i
    }
    updateOverlayLyricsActive(activeIdx)
  })

  // Detect language and show translate button if non-English
  detectOverlayLyricsLanguage()
}

let ovLyricsTranslated = false

function renderOverlayLyricLines(translated = false) {
  const body = document.getElementById('ov-lyrics-body')
  body.innerHTML = lyricsData.map((line, i) => {
    const hasTimestamp = line.Start != null
    const text = translated && lyricsTranslated[i] ? lyricsTranslated[i] : (line.Text || '')
    return `<div class="ov-lyric-line${hasTimestamp ? ' seekable' : ''}" data-idx="${i}"${hasTimestamp ? ` data-start="${line.Start}"` : ''}>${esc(text)}</div>`
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

function updateOverlayLyricsActive(activeIdx) {
  const body = document.getElementById('ov-lyrics-body')
  const panel = document.getElementById('ov-panel-lyrics')
  body.querySelectorAll('.ov-lyric-line').forEach(el => {
    const dist = Math.abs(parseInt(el.dataset.idx) - activeIdx)
    el.classList.remove('active', 'near-1', 'near-2')
    if (dist === 0) el.classList.add('active')
    else if (dist === 1) el.classList.add('near-1')
    else if (dist === 2) el.classList.add('near-2')
  })
  // GPU-accelerated: translate the container so active line sits at panel center
  const active = body.querySelector(`.ov-lyric-line[data-idx="${activeIdx}"]`)
  if (active) {
    const panelMid = panel.clientHeight / 2
    const activeMid = active.offsetTop + active.offsetHeight / 2
    body.style.transform = `translateY(${panelMid - activeMid}px)`
  }
}

// Sync overlay lyrics highlight
let lastOverlayLyricsIdx = -1
// Reset when track changes
const _ovLyricsReset = updateNowPlaying
updateNowPlaying = function(item) { _ovLyricsReset(item); lastOverlayLyricsIdx = -1 }

audio.addEventListener('timeupdate', () => {
  if (!overlayOpen || !overlayLyricsOpen || !lyricsData.length) return
  const nowSec = audio.currentTime + 0.225
  let activeIdx = 0
  for (let i = 0; i < lyricsData.length; i++) {
    if (lyricsData[i].Start != null && lyricsData[i].Start / 10000000 <= nowSec) activeIdx = i
  }
  if (activeIdx === lastOverlayLyricsIdx) return
  lastOverlayLyricsIdx = activeIdx
  updateOverlayLyricsActive(activeIdx)
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
async function atpLoadPlaylists() {
  const list = document.getElementById('atp-list')
  list.innerHTML = '<div style="font-size:12px;color:var(--text3);text-align:center;padding:20px 0">Loading…</div>'
  try {
    const data = await jfGet(`/Users/${jf.userId}/Items`, {
      IncludeItemTypes: 'Playlist', Recursive: true, SortBy: 'SortName'
    })
    list.innerHTML = (data.Items || []).map(pl =>
      `<div class="modal-pl-item" data-id="${pl.Id}">${esc(pl.Name)}</div>`
    ).join('') || '<div style="font-size:12px;color:var(--text3);text-align:center;padding:20px 0">No playlists</div>'
    list.querySelectorAll('.modal-pl-item').forEach(el => {
      el.addEventListener('click', async () => {
        const item = queue[queueIndex]
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
  const modal = document.getElementById('atp-modal')
  const createRow = document.getElementById('atp-create-row')
  createRow.classList.remove('visible')
  document.getElementById('atp-new-name').value = ''
  modal.classList.remove('hidden')
  atpLoadPlaylists()
})

document.getElementById('atp-cancel').addEventListener('click', () => document.getElementById('atp-modal').classList.add('hidden'))

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

let lyricsData = []
let lyricsTranslated = []

function showLyrics() {
  document.getElementById('lyrics-panel').classList.add('open')
  fetchLyrics()
}
function hideLyrics() { document.getElementById('lyrics-panel').classList.remove('open') }

document.getElementById('lyrics-close').addEventListener('click', hideLyrics)

async function fetchLyrics() {
  const item = queue[queueIndex]
  const body = document.getElementById('lyrics-body')
  const translateBar = document.getElementById('lyrics-translate-bar')
  if (!item) { body.innerHTML = '<div class="lyrics-empty">Nothing playing</div>'; return }

  body.innerHTML = '<div class="lyrics-empty">Loading…</div>'
  translateBar.classList.remove('visible')
  lyricsData = []
  lyricsTranslated = []
  lastLyricsIdx = -1

  try {
    const res = await fetch(`${jf.url}/Audio/${item.Id}/Lyrics`, {
      headers: { 'X-Emby-Token': jf.token }
    })
    if (!res.ok) throw new Error('No lyrics')
    const data = await res.json()
    lyricsData = data.Lyrics || []
    if (!lyricsData.length) throw new Error('Empty')
    renderLyrics()
    detectAndShowTranslateBar()
  } catch {
    body.innerHTML = '<div class="lyrics-empty">No lyrics available for this track</div>'
  }
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
    const text = esc(line.Text || '')
    const trans = showTranslation && lyricsTranslated[i] ? `<div class="lyrics-line translated">${esc(lyricsTranslated[i])}</div>` : ''
    const hasTimestamp = line.Start != null
    return `<div class="lyrics-line${hasTimestamp ? ' seekable' : ''}" data-idx="${i}"${hasTimestamp ? ` data-start="${line.Start}"` : ''}>${text}</div>${trans}`
  }).join('')

  // Wrap in a translateY-driven inner div so fast lyrics don't queue scroll calls
  body.innerHTML = `<div id="lyrics-inner" style="will-change:transform;transition:transform 0.28s cubic-bezier(0.4,0,0.2,1);padding-bottom:50%">${lines}</div>`

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
    })
  })
}

// Sync lyrics highlight to playback position
let lastLyricsIdx = -1
let lyricsScrollSuppressed = false
let lyricsScrollTimer = null

audio.addEventListener('timeupdate', () => {
  if (!lyricsData.length) return
  const nowSec = audio.currentTime + 0.225
  let activeIdx = 0
  for (let i = 0; i < lyricsData.length; i++) {
    if (lyricsData[i].Start != null && lyricsData[i].Start / 10000000 <= nowSec) activeIdx = i
  }
  if (activeIdx === lastLyricsIdx) return
  lastLyricsIdx = activeIdx

  const body = document.getElementById('lyrics-body')
  const inner = document.getElementById('lyrics-inner')
  body.querySelectorAll('.lyrics-line[data-idx]').forEach(el => {
    el.classList.toggle('active', parseInt(el.dataset.idx) === activeIdx)
  })

  if (!lyricsScrollSuppressed && inner) {
    const active = inner.querySelector(`.lyrics-line[data-idx="${activeIdx}"]`)
    if (active) {
      const panelMid = body.clientHeight / 2
      const activeMid = active.offsetTop + active.offsetHeight / 2
      inner.style.transform = `translateY(${panelMid - activeMid}px)`
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
    state:          `by ${(item.AlbumArtist || item.Artists?.[0] || 'Unknown').slice(0, 128)}`,
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

async function initDiscordRpc() {
  const enabled  = await window.cascade.store.get('discordRpcEnabled')
  const clientId = await window.cascade.store.get('discordClientId') || DEFAULT_DISCORD_CLIENT_ID
  discordEnabled = enabled === 'true'
  updateDiscordRpcStatus(discordEnabled)
  if (discordEnabled) window.cascade.discord.connect(clientId)

  window.cascade.discord.onStatus((connected) => {
    const dot = document.getElementById('discord-rpc-dot')
    if (dot) dot.className = 'ws-dot' + (connected ? ' connected' : '')
  })
}

function updateDiscordRpcStatus(enabled) {
  const dot = document.getElementById('discord-rpc-dot')
  if (dot) dot.className = 'ws-dot' + (enabled ? '' : '')
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
            const thumb = art ? `<img src="${art}" alt="" onerror="this.style.display='none'">` : ''
            return `<div class="track-row" data-search-song="${i}">
              <div class="track-num">${i + 1}</div>
              <div class="track-thumb">${thumb}</div>
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
        el.addEventListener('click', () => {
          const idx = parseInt(el.dataset.searchSong)
          playItems(songs.Items, idx)
        })
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
    canvas.width = canvas.height = 60
    const ctx = canvas.getContext('2d')
    ctx.drawImage(img, 0, 0, 60, 60)
    const data = ctx.getImageData(0, 0, 60, 60).data
    let bestR = 110, bestG = 79, bestB = 246, bestScore = 0
    for (let i = 0; i < data.length; i += 12) {
      const r = data[i], g = data[i+1], b = data[i+2]
      const max = Math.max(r, g, b), min = Math.min(r, g, b)
      const sat = max === 0 ? 0 : (max - min) / max
      const bri = max / 255
      const score = sat * bri * bri  // weight toward bright saturated
      if (score > bestScore) { bestScore = score; bestR = r; bestG = g; bestB = b }
    }
    return { r: bestR, g: bestG, b: bestB }
  } catch { return null }
}

function rgbToHex(r, g, b) {
  return '#' + [r,g,b].map(v => v.toString(16).padStart(2,'0')).join('')
}

function applyAlbumArtTheme(imgEl) {
  if (!themeAlbumArt || !imgEl) return
  const col = extractVibrantColor(imgEl)
  if (!col) return

  // Gradient accent (used everywhere else)
  const startHex = rgbToHex(Math.min(255, col.r + 60), Math.min(255, col.g + 60), Math.min(255, col.b + 60))
  const endHex   = rgbToHex(Math.max(0,   col.r - 30), Math.max(0,   col.g - 30), Math.max(0,   col.b - 30))
  _lastAlbumColors = { start: startHex, end: endHex }
  applyGradient(startHex, endHex)

  // Fullscreen overlay background: rich color at top, fades to near-black
  const { r, g, b } = col
  const overlayBg = `linear-gradient(160deg, rgb(${r},${g},${b}) 0%, rgb(${Math.round(r*0.25)},${Math.round(g*0.25)},${Math.round(b*0.25)}) 55%, #0d0d0f 100%)`
  document.documentElement.style.setProperty('--art-overlay-bg', overlayBg)
  document.getElementById('np-overlay').classList.add('art-theme')
}

function clearAlbumArtTheme() {
  document.getElementById('np-overlay').classList.remove('art-theme')
  document.documentElement.style.removeProperty('--art-overlay-bg')
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
