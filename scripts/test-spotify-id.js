// One-shot test: is the currently-playing Cascade track resolvable to a
// Spotify track id without hitting Spotify at all? Reads now-playing from
// Cascade's local control server, then asks MusicBrainz for a recording ->
// Spotify URL relationship.
//
// Usage: play a song in Cascade, then `node scripts/test-spotify-id.js`
//
// A title+artist search returns many near-duplicate recordings (album
// version, radio edit, remaster...) and only one of them usually carries the
// Spotify relation - "I Write Sins Not Tragedies" had 10 candidates and the
// link was on the 6th. So this checks the top N and picks by closest
// duration to what Cascade is actually playing, not just the first hit.
//
// ponytail: MusicBrainz only, single track, run-by-hand. If the hit rate
// looks too low across a real library, add the anonymous-token Spotify
// search as a second attempt and a batch mode that loops the Jellyfin queue.

const fs = require('fs')
const os = require('os')
const path = require('path')

const CONTROL_TOKEN_PATH = path.join(os.homedir(), '.cascade-control-token')
const CONTROL_PORT = 47847
// MusicBrainz requires a descriptive User-Agent identifying the app, not a
// person - https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting
const MB_USER_AGENT = 'CascadeSpotifyIdTest/0.1 (+https://github.com/Cha0s1nc/Cascade-Project)'

async function getNowPlaying() {
  const token = fs.readFileSync(CONTROL_TOKEN_PATH, 'utf8').trim()
  const res = await fetch(`http://127.0.0.1:${CONTROL_PORT}/cascade/now-playing`, {
    headers: { 'x-cascade-token': token },
  })
  if (!res.ok) throw new Error(`Cascade control server: HTTP ${res.status}`)
  return res.json()
}

const CANDIDATE_LIMIT = 10
const MB_DELAY_MS = 1100  // MusicBrainz asks for max 1 req/sec

const sleep = ms => new Promise(r => setTimeout(r, ms))

async function findSpotifyId(title, artist, durationMs) {
  const query = `recording:"${title}" AND artist:"${artist}"`
  const searchUrl = `https://musicbrainz.org/ws/2/recording/?query=${encodeURIComponent(query)}&fmt=json&limit=${CANDIDATE_LIMIT}`
  const searchRes = await fetch(searchUrl, { headers: { 'User-Agent': MB_USER_AGENT } })
  if (!searchRes.ok) throw new Error(`MusicBrainz search: HTTP ${searchRes.status}`)
  const searchData = await searchRes.json()
  const candidates = searchData.recordings || []
  if (!candidates.length) return { found: false, reason: 'no MusicBrainz recording matched' }

  const hits = []
  for (const c of candidates) {
    await sleep(MB_DELAY_MS)
    const lookupUrl = `https://musicbrainz.org/ws/2/recording/${c.id}?inc=url-rels&fmt=json`
    const lookupRes = await fetch(lookupUrl, { headers: { 'User-Agent': MB_USER_AGENT } })
    if (!lookupRes.ok) continue  // one bad candidate shouldn't sink the whole run
    const lookupData = await lookupRes.json()
    const spotifyRel = (lookupData.relations || [])
      .find(r => r.url?.resource?.includes('open.spotify.com/track/'))
    if (spotifyRel) {
      const spotifyId = spotifyRel.url.resource.split('/track/')[1].split(/[?/]/)[0]
      hits.push({ mbid: c.id, spotifyId, lengthMs: c.length ?? null })
    }
  }

  if (!hits.length) {
    return { found: false, reason: `checked ${candidates.length} recordings, none had a Spotify relation` }
  }

  // Prefer the candidate whose length is closest to what Cascade is playing.
  // A candidate with no length info sorts last rather than winning by default.
  hits.sort((a, b) => {
    if (a.lengthMs == null) return 1
    if (b.lengthMs == null) return -1
    return Math.abs(a.lengthMs - durationMs) - Math.abs(b.lengthMs - durationMs)
  })
  return { found: true, ...hits[0], allHits: hits.length }
}

async function main() {
  const np = await getNowPlaying()
  if (!np.title) {
    console.log('Nothing playing in Cascade right now.')
    return
  }
  console.log(`Now playing: "${np.title}" - ${np.artist} (${Math.round(np.durationMs / 1000)}s)`)
  console.log(`Checking up to ${CANDIDATE_LIMIT} MusicBrainz recordings, ~${Math.round(CANDIDATE_LIMIT * MB_DELAY_MS / 1000)}s...`)

  const result = await findSpotifyId(np.title, np.artist, np.durationMs)
  if (result.found) {
    console.log(`Spotify track id: ${result.spotifyId}`)
    console.log(`(via MusicBrainz recording ${result.mbid}${result.allHits > 1 ? `, ${result.allHits} candidates had a Spotify link, picked by closest duration` : ''})`)
  } else {
    console.log(`No Spotify id: ${result.reason}`)
  }
}

main().catch(err => {
  console.error(err.message)
  process.exit(1)
})
