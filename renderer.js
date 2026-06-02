// ── Cascade renderer ──────────────────────────────────────────────────────────

// State
let jf = { url: '', token: '', userId: '' }
let queue = []
let queueIndex = -1
let shuffle = false
let repeat = false  // 'none' | 'all' | 'one'
let repeatMode = 'none'
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
      'X-Emby-Authorization': 'MediaBrowser Client="Cascade", Device="Cascade", DeviceId="cascade-app", Version="0.1.0"'
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
      return `<div class="artist-card" data-id="${item.Id}">
        <div class="artist-avatar">${img}</div>
        <div class="artist-name">${esc(item.Name)}</div>
      </div>`
    }).join('')
  } catch (e) {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">Could not load artists</div>`
  }
}

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

async function openPlaylist(playlistId, name) {
  document.getElementById('playlist-index').style.display = 'none'
  const detail = document.getElementById('playlist-detail')
  detail.classList.add('active')
  document.getElementById('pl-detail-name').textContent = name
  document.getElementById('pl-detail-meta').textContent = 'Loading…'
  document.getElementById('pl-detail-rows').innerHTML = '<div class="loading-state">Loading…</div>'

  try {
    const data = await jfGet(`/Users/${jf.userId}/Items`, {
      ParentId: playlistId,
      Fields: 'PrimaryImageAspectRatio,AlbumId,AlbumPrimaryImageTag',
      SortBy: 'ListItemOrder'
    })
    const items = data.Items || []
    document.getElementById('pl-detail-meta').textContent = `${items.length} songs`

    // Art from first item
    // Use the playlist's own image, not the first track's
    const artEl = document.getElementById('pl-detail-art')
    const plArtUrl = `${jf.url}/Items/${playlistId}/Images/Primary?fillHeight=160&fillWidth=160&quality=80&api_key=${jf.token}`
    artEl.innerHTML = `<img src="${plArtUrl}" alt="" onerror="this.innerHTML='♪'">`

    document.getElementById('pl-detail-rows').innerHTML = items.map((item, i) => {
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

    document.getElementById('pl-detail-rows').querySelectorAll('.track-row').forEach(el => {
      el.addEventListener('click', () => playItems(items, parseInt(el.dataset.idx)))
    })
  } catch (e) {
    document.getElementById('pl-detail-rows').innerHTML = `<div class="empty-state">Could not load playlist</div>`
  }
}

document.getElementById('pl-back-btn').addEventListener('click', () => {
  document.getElementById('playlist-detail').classList.remove('active')
  document.getElementById('playlist-index').style.display = ''
})

// ── Playback ──────────────────────────────────────────────────────────────────

function playItems(items, startIndex) {
  queue = [...items]
  queueIndex = startIndex
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
    <span class="np-title">${esc(item.Name)}</span>
    <span class="np-sep">—</span>
    <span class="np-artist">${esc(item.AlbumArtist || item.Artists?.[0] || '')}</span>
  `
  // Sync like state from Jellyfin user data
  const liked = item.UserData?.IsFavorite || false
  document.getElementById('btn-like').classList.toggle('liked', liked)
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
})

audio.addEventListener('pause', () => {
  document.getElementById('icon-play').style.display = ''
  document.getElementById('icon-pause').style.display = 'none'
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
  if (shuffle) next = Math.floor(Math.random() * queue.length)
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
  if (shuffle) queueIndex = Math.floor(Math.random() * queue.length)
  else queueIndex = Math.min(queue.length - 1, queueIndex + 1)
  playCurrentTrack()
})

document.getElementById('btn-shuffle').addEventListener('click', () => {
  shuffle = !shuffle
  document.getElementById('btn-shuffle').classList.toggle('active', shuffle)
})

document.getElementById('btn-repeat').addEventListener('click', () => {
  const modes = ['none', 'all', 'one']
  repeatMode = modes[(modes.indexOf(repeatMode) + 1) % modes.length]
  document.getElementById('btn-repeat').classList.toggle('active', repeatMode !== 'none')
  document.getElementById('btn-repeat').title = repeatMode === 'one' ? 'Repeat one' : repeatMode === 'all' ? 'Repeat all' : 'Repeat'
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

// ── Settings ──────────────────────────────────────────────────────────────────

async function loadSettingsFields() {
  document.getElementById('s-url').value = await window.cascade.store.get('serverUrl') || ''
  document.getElementById('s-user').value = await window.cascade.store.get('username') || ''
  document.getElementById('s-pass').value = ''
  // Library checkboxes are populated by populateLibraryPicker() on connect
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
    alert(`Could not connect: ${e.message}`)
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
    err.textContent = `Connection failed: ${e.message}`
    btn.disabled = false
    btn.textContent = 'Connect'
  }
})

// Allow Enter key in setup fields
document.getElementById('setup-password').addEventListener('keydown', e => {
  if (e.key === 'Enter') document.getElementById('setup-connect').click()
})

// ── Startup ───────────────────────────────────────────────────────────────────

async function init() {
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

// Click the statusbar background to open (but not the controls)
document.querySelector('.statusbar').addEventListener('click', (e) => {
  // Ignore clicks on actual control elements
  if (e.target.closest('button, .vol-bar, .prog-bar, .np-art, #np-art')) return
  overlayOpen ? closeOverlay() : openOverlay()
})

document.getElementById('np-overlay-close').addEventListener('click', closeOverlay)
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && overlayOpen) closeOverlay() })

// Lyrics toggle button slides the lyrics panel over the queue
document.getElementById('ov-lyrics-toggle').addEventListener('click', () => {
  overlayLyricsOpen = !overlayLyricsOpen
  const lyricsPanel = document.getElementById('ov-panel-lyrics')
  lyricsPanel.style.transform = overlayLyricsOpen ? 'translateX(0)' : 'translateX(100%)'
  document.getElementById('ov-lyrics-toggle').classList.toggle('active', overlayLyricsOpen)
  if (overlayLyricsOpen) renderOverlayLyrics()
})

// Overlay controls mirror the main controls
document.getElementById('ov-more-btn').addEventListener('click', async () => {
  if (!queue[queueIndex]) return
  const item = queue[queueIndex]
  const actions = [
    { id: 'stop', label: 'Stop playback' },
    { id: 'clear', label: 'Clear queue' },
    { id: 'mix', label: 'Instant mix' },
    { type: 'separator' },
    { id: 'playlist', label: 'Add to playlist' },
    { id: 'download', label: 'Download' },
    { id: 'copy', label: 'Copy stream URL' },
    { type: 'separator' },
    { id: 'info', label: 'Media info' },
    { id: 'refresh', label: 'Refresh metadata' },
    { type: 'separator' },
    { id: 'edit-meta', label: 'Edit metadata' },
    { id: 'edit-img', label: 'Edit images' },
    { id: 'edit-lyrics', label: 'Edit lyrics' },
    { type: 'separator' },
    { id: 'view-album', label: 'View album' },
    { id: 'view-artist', label: 'View album artist' },
    { id: 'view-lyrics', label: 'View lyrics' },
    { type: 'separator' },
    { id: 'delete', label: 'Delete media' },
  ]
  const chosen = await window.cascade.showNpMenu(actions)
  if (!chosen) return
  // Re-use the existing ctx handlers by triggering them directly
  const map = {
    'stop':        () => document.getElementById('ctx-stop').click(),
    'clear':       () => document.getElementById('ctx-clear-queue').click(),
    'mix':         () => document.getElementById('ctx-instant-mix').click(),
    'playlist':    () => document.getElementById('ctx-add-playlist').click(),
    'download':    () => document.getElementById('ctx-download').click(),
    'copy':        () => document.getElementById('ctx-copy-url').click(),
    'info':        () => document.getElementById('ctx-media-info').click(),
    'refresh':     () => document.getElementById('ctx-refresh-meta').click(),
    'edit-meta':   () => document.getElementById('ctx-edit-meta').click(),
    'edit-img':    () => document.getElementById('ctx-edit-images').click(),
    'edit-lyrics': () => document.getElementById('ctx-edit-lyrics').click(),
    'view-album':  () => document.getElementById('ctx-view-album').click(),
    'view-artist': () => document.getElementById('ctx-view-artist').click(),
    'view-lyrics': () => document.getElementById('ctx-view-lyrics').click(),
    'delete':      () => document.getElementById('ctx-delete').click(),
  }
  map[chosen]?.()
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
  document.getElementById('ov-repeat').classList.toggle('active', repeatMode !== 'none')
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
  document.getElementById('ov-repeat').classList.toggle('active', repeatMode !== 'none')
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

  body.innerHTML = lyricsData.map((line, i) => {
    const hasTimestamp = line.Start != null
    return `<div class="ov-lyric-line${hasTimestamp ? ' seekable' : ''}" data-idx="${i}"${hasTimestamp ? ` data-start="${line.Start}"` : ''}>${esc(line.Text || '')}</div>`
  }).join('')

  body.querySelectorAll('.ov-lyric-line.seekable').forEach(el => {
    el.addEventListener('click', () => {
      const ticks = parseInt(el.dataset.start)
      if (!isNaN(ticks) && audio.duration) audio.currentTime = ticks / 10000000
    })
  })

  // Reset position instantly (no transition) then let updates animate from there
  body.style.transition = 'none'
  body.style.transform = 'translateY(0)'
  requestAnimationFrame(() => {
    body.style.transition = ''
    // Find current active idx and position immediately
    const nowSec = audio.currentTime
    let activeIdx = 0
    for (let i = 0; i < lyricsData.length; i++) {
      if (lyricsData[i].Start != null && lyricsData[i].Start / 10000000 <= nowSec) activeIdx = i
    }
    updateOverlayLyricsActive(activeIdx)
  })
}

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
  const nowSec = audio.currentTime
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
document.getElementById('ctx-add-playlist').addEventListener('click', async () => {
  const modal = document.getElementById('atp-modal')
  const list = document.getElementById('atp-list')
  modal.classList.remove('hidden')
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
          await fetch(`${jf.url}/Playlists/${el.dataset.id}/Items`, {
            method: 'POST',
            headers: { 'X-Emby-Token': jf.token, 'Content-Type': 'application/json' },
            body: JSON.stringify({ Ids: [item.Id] })
          })
        } catch {}
        modal.classList.add('hidden')
      })
    })
  } catch { list.innerHTML = '<div style="font-size:12px;color:var(--text3);text-align:center;padding:20px 0">Failed to load</div>' }
})
document.getElementById('atp-cancel').addEventListener('click', () => document.getElementById('atp-modal').classList.add('hidden'))

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
  body.innerHTML = lyricsData.map((line, i) => {
    const text = esc(line.Text || '')
    const trans = showTranslation && lyricsTranslated[i] ? `<div class="lyrics-line translated">${esc(lyricsTranslated[i])}</div>` : ''
    const hasTimestamp = line.Start != null
    return `<div class="lyrics-line${hasTimestamp ? ' seekable' : ''}" data-idx="${i}"${hasTimestamp ? ` data-start="${line.Start}"` : ''}>${text}</div>${trans}`
  }).join('')

  // Click a seekable lyric line to jump to that position
  body.querySelectorAll('.lyrics-line.seekable').forEach(el => {
    el.style.cursor = 'pointer'
    el.addEventListener('click', () => {
      const ticks = parseInt(el.dataset.start)
      if (isNaN(ticks) || !audio.duration) return
      lyricsScrollSuppressed = true
      clearTimeout(lyricsScrollTimer)
      lyricsScrollTimer = setTimeout(() => { lyricsScrollSuppressed = false }, 1500)
      audio.currentTime = ticks / 10000000  // ticks → seconds
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
  const nowSec = audio.currentTime
  let activeIdx = 0
  for (let i = 0; i < lyricsData.length; i++) {
    if (lyricsData[i].Start != null && lyricsData[i].Start / 10000000 <= nowSec) activeIdx = i
  }
  if (activeIdx === lastLyricsIdx) return
  lastLyricsIdx = activeIdx

  const container = document.getElementById('lyrics-body')
  container.querySelectorAll('.lyrics-line[data-idx]').forEach(el => {
    el.classList.toggle('active', parseInt(el.dataset.idx) === activeIdx)
  })

  if (!lyricsScrollSuppressed) {
    const active = container.querySelector(`.lyrics-line[data-idx="${activeIdx}"]`)
    if (active) {
      const cRect = container.getBoundingClientRect()
      const aRect = active.getBoundingClientRect()
      const offset = aRect.top - cRect.top - cRect.height / 2 + aRect.height / 2
      container.scrollBy({ top: offset, behavior: 'smooth' })
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
  if (document.getElementById('lyrics-panel').classList.contains('open')) fetchLyrics()
  if (overlayOpen && overlayLyricsOpen) renderOverlayLyrics()
}

// ── Utility ───────────────────────────────────────────────────────────────────

function esc(str) {
  return String(str || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')
}

init()
