import { test } from 'node:test'
import assert from 'node:assert/strict'
import { playlistOpFor, applyPlaylistOp, localQuery } from '../src/core/local-writes.ts'
import { buildCatalog, fileId, LOCAL_LIBRARIES, type LocalFile } from '../src/core/local-scan.ts'
import { parseIndex } from '../src/core/offline-index.ts'

const P = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
const A = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
const B = 'cccccccccccccccccccccccccccccccc'
const isPlaylist = (id: string) => id === P

test('the playlist writes the screens send become local operations', () => {
  // atpCreatePlaylist, btn-save-as-playlist: name and ids in the query.
  assert.deepEqual(playlistOpFor('POST', `/Playlists?Name=Road%20Trip&Ids=${A},${B}&UserId=local&MediaType=Audio`, undefined, isPlaylist),
    { kind: 'create', name: 'Road Trip', ids: [A, B] })
  // createEmptyPlaylist: the JSON body too.
  assert.deepEqual(playlistOpFor('POST', '/Playlists?Name=Empty&UserId=local&MediaType=Audio', JSON.stringify({ Name: 'Empty', Ids: [], IsPublic: true }), isPlaylist),
    { kind: 'create', name: 'Empty', ids: [] })
  assert.equal(playlistOpFor('POST', '/Playlists?Name=%20', undefined, isPlaylist), null, 'a playlist needs a name')
  // atpLoadPlaylists: add.
  assert.deepEqual(playlistOpFor('POST', `http://x/Playlists/${P}/Items?Ids=${A}&UserId=local`, undefined, isPlaylist), { kind: 'add', id: P, ids: [A] })
  // tctx-pl-remove.
  assert.deepEqual(playlistOpFor('DELETE', `/Playlists/${P}/Items?EntryIds=${B}`, undefined, isPlaylist), { kind: 'removeIds', id: P, ids: [B] })
  // wirePlaylistRowDrag.
  assert.deepEqual(playlistOpFor('POST', `/Playlists/${P}/Items/${A}/Move/3`, undefined, isPlaylist), { kind: 'move', id: P, entryId: A, to: 3 })
  // savePlaylistIds and the details' name.
  assert.deepEqual(playlistOpFor('POST', `/Playlists/${P}`, JSON.stringify({ Ids: [B, A] }), isPlaylist), { kind: 'set', id: P, ids: [B, A] })
  assert.deepEqual(playlistOpFor('POST', `/Playlists/${P}`, JSON.stringify({ Name: 'New name', IsPublic: false }), isPlaylist), { kind: 'set', id: P, name: 'New name' })
  // deleteItemFromServer, only for a playlist.
  assert.deepEqual(playlistOpFor('DELETE', `/Items/${P}`, undefined, isPlaylist), { kind: 'delete', id: P })
  assert.equal(playlistOpFor('DELETE', `/Items/${A}`, undefined, isPlaylist), null, 'never a song')
  // Anything else stays refused.
  assert.equal(playlistOpFor('POST', `/Playlists/${A}/Items?Ids=${B}`, undefined, isPlaylist), null, 'not a playlist the catalog holds')
  assert.equal(playlistOpFor('POST', `/UserFavoriteItems/${A}`, undefined, isPlaylist), null)
  assert.equal(playlistOpFor('POST', `/Items/${P}`, '{}', isPlaylist), null, 'details through the admin route')
  assert.equal(playlistOpFor('POST', `/CascadeServer/Playlists/${P}/Details`, '{}', isPlaylist), null)
  assert.equal(playlistOpFor('GET', `/Playlists/${P}/Items`, undefined, isPlaylist), null)
  assert.equal(playlistOpFor('POST', `/Playlists/${P}/Items/${A}/Move/x`, undefined, isPlaylist), null)
  assert.deepEqual(playlistOpFor('POST', `/Playlists?Name=x&Ids=${A},../etc,`, undefined, isPlaylist), { kind: 'create', name: 'x', ids: [A] }, 'ids are checked')
})

test('operations change a playlist as Jellyfin would', () => {
  const ids = [A, B, A]
  assert.deepEqual(applyPlaylistOp(ids, { kind: 'add', id: P, ids: [B] }, 100), [A, B, A, B])
  assert.deepEqual(applyPlaylistOp(ids, { kind: 'add', id: P, ids: [B, B] }, 4), [A, B, A, B], 'capped')
  assert.deepEqual(applyPlaylistOp(ids, { kind: 'removeIds', id: P, ids: [A] }, 100), [B], 'every entry of the track')
  assert.deepEqual(applyPlaylistOp(ids, { kind: 'move', id: P, entryId: B, to: 0 }, 100), [B, A, A])
  assert.deepEqual(applyPlaylistOp(ids, { kind: 'move', id: P, entryId: A, to: 99 }, 100), [B, A, A], 'past the end is the end')
  assert.deepEqual(applyPlaylistOp(ids, { kind: 'move', id: P, entryId: 'dddddddddddddddddddddddddddddddd', to: 0 }, 100), ids)
  assert.deepEqual(applyPlaylistOp(ids, { kind: 'set', id: P, ids: [B] }, 100), [B])
  assert.deepEqual(applyPlaylistOp(ids, { kind: 'set', id: P, name: 'Renamed' }, 100), ids, 'a rename keeps the entries')
})

test('a playlist made in Cascade shows while it holds nothing', () => {
  const song: LocalFile = { rel: 'a/01 Song.mp3', size: 1, added: '2026-10-01T00:00:00.000Z', probe: { title: 'Song', artists: ['X'], album: 'Y', audioCodec: 'mp3' } }
  const empty = { Id: P, Name: 'Brand new', trackIds: [], createdAt: '2026-10-02T00:00:00.000Z' }
  const full = { Id: A, Name: 'Already', trackIds: [fileId(song.rel)], createdAt: '2026-10-02T00:00:00.000Z' }
  const index = parseIndex(JSON.parse(JSON.stringify(buildCatalog({ files: [song], sidecars: [], m3u: [], playlists: [empty, full], userData: {}, art: new Set() }).index)))
  const q = localQuery(index)
  const list = q.answer('/Items', { IncludeItemTypes: 'Playlist', Recursive: true, SortBy: 'SortName' }).body as { Items: { Name: string, ChildCount: number }[], TotalRecordCount: number }
  assert.deepEqual(list.Items.map(p => [p.Name, p.ChildCount]), [['Already', 1], ['Brand new', 0]])
  assert.equal(list.TotalRecordCount, 2)
  assert.equal((q.answer(`/Items/${P}`).body as { Name: string }).Name, 'Brand new')
  assert.deepEqual(q.answer(`/Playlists/${P}/Items`, {}).body, { Items: [], TotalRecordCount: 0, StartIndex: 0 })
  assert.deepEqual(q.answer(`/Playlists/${P}`).body, { OpenAccess: false, Shares: [], ItemIds: [] })
  // Lists narrowed to something an empty playlist cannot match are left alone.
  const holding = q.answer('/Items', { IncludeItemTypes: 'Playlist', ParentId: LOCAL_LIBRARIES.music.Id }).body as { Items: unknown[] }
  assert.equal(holding.Items.length, 1)
  const songs = q.answer('/Items', { IncludeItemTypes: 'Audio' }).body as { Items: unknown[] }
  assert.equal(songs.Items.length, 1)
  assert.equal(q.answer(`/Items/${B}`).status, 404)
})
