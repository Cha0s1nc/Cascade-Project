import { test } from 'node:test'
import assert from 'node:assert/strict'
import { buildMiniplayerState, miniplayerProgressPct, isMiniplayerAction,
  miniplayerLyrics, parseMiniplayerCommand,
  MINIPLAYER_LYRIC_MAX, MINIPLAYER_QUEUE_MAX, MINIPLAYER_MAX_VOLUME_STEP,
} from '../src/core/miniplayer.ts'

test('miniplayerProgressPct is 0 with no duration yet', () => {
  assert.equal(miniplayerProgressPct(0, 0), 0)
  assert.equal(miniplayerProgressPct(5, 0), 0)
})

test('miniplayerProgressPct clamps to 0-100 against garbage input', () => {
  assert.equal(miniplayerProgressPct(NaN, 100), 0)
  assert.equal(miniplayerProgressPct(10, NaN), 0)
  assert.equal(miniplayerProgressPct(-5, 100), 0)
  assert.equal(miniplayerProgressPct(150, 100), 100)
  assert.equal(miniplayerProgressPct(-Infinity, 100), 0)
})

test('miniplayerProgressPct is the plain ratio in the normal case', () => {
  assert.equal(miniplayerProgressPct(30, 120), 25)
})

test('buildMiniplayerState never produces NaN or an out-of-range percentage', () => {
  const track = { itemId: 'abc', title: 'Song', subtitle: 'Artist', artUrl: null }
  for (const [pos, dur] of [[NaN, 100], [10, NaN], [-5, 50], [999, 60], [0, 0]] as const) {
    const s = buildMiniplayerState(track, true, pos, dur)
    assert.ok(Number.isFinite(s.positionSec))
    assert.ok(Number.isFinite(s.durationSec))
    assert.ok(s.progressPct >= 0 && s.progressPct <= 100)
  }
})

test('buildMiniplayerState copies the track fields through untouched', () => {
  const track = { itemId: 'xyz', title: 'Title', subtitle: 'Sub', artUrl: 'http://x/art.jpg' }
  const s = buildMiniplayerState(track, false, 12, 34)
  assert.equal(s.itemId, 'xyz')
  assert.equal(s.title, 'Title')
  assert.equal(s.subtitle, 'Sub')
  assert.equal(s.artUrl, 'http://x/art.jpg')
  assert.equal(s.isPlaying, false)
})

test('isMiniplayerAction accepts only the closed set of control actions', () => {
  assert.ok(isMiniplayerAction('playpause'))
  assert.ok(isMiniplayerAction('next'))
  assert.ok(isMiniplayerAction('prev'))
  assert.ok(!isMiniplayerAction('seek'))
  assert.ok(!isMiniplayerAction(''))
  assert.ok(!isMiniplayerAction(null))
  assert.ok(!isMiniplayerAction(42))
})

test('miniplayerLyrics sends the whole sheet, blanks kept inside, trailing ones trimmed', () => {
  // An interior gap is real spacing, and dropping it would shift every later
  // index off the line the clock says is current.
  const lines = [{ Text: 'a' }, { Text: '' }, { Text: 'b' }, { Text: '' }, { Text: '  ' }]
  assert.deepEqual(miniplayerLyrics(lines), ['a', '', 'b'])
})

test('miniplayerLyrics survives junk input and caps a huge sheet', () => {
  assert.deepEqual(miniplayerLyrics(null), [])
  assert.deepEqual(miniplayerLyrics([{ Text: null }]), [])
  const huge = Array.from({ length: MINIPLAYER_LYRIC_MAX + 50 }, (_, i) => ({ Text: `l${i}` }))
  assert.equal(miniplayerLyrics(huge).length, MINIPLAYER_LYRIC_MAX)
})

test('jump carries a queue position, and nothing that is not one', () => {
  assert.deepEqual(parseMiniplayerCommand({ type: 'jump', value: 7 }), { type: 'jump', index: 7 })
  for (const bad of [-1, 1.5, NaN, Infinity]) assert.equal(parseMiniplayerCommand({ type: 'jump', value: bad }), null)
  assert.equal(parseMiniplayerCommand({ type: 'jump', value: '3' }), null)
})

test('state: the lyric index stays inside the sheet, queue is capped', () => {
  const t = { itemId: 'x', title: 't', subtitle: 's', artUrl: null }
  const q = Array.from({ length: MINIPLAYER_QUEUE_MAX + 5 }, () => ({ title: 'q', subtitle: '', artUrl: null }))
  const st = buildMiniplayerState(t, true, 1, 10, ['a', 'b'], { lyricIndex: 9, queue: q, queueStart: 4 })
  assert.equal(st.lyricIndex, 1)
  assert.equal(st.queue.length, MINIPLAYER_QUEUE_MAX)
  assert.equal(st.queueStart, 4)
  assert.equal(buildMiniplayerState(t, true, 1, 10, [], { lyricIndex: 3 }).lyricIndex, -1)
  assert.equal(buildMiniplayerState(t, true, 1, 10, ['a'], { lyricIndex: 1.5, queueStart: -2 }).lyricIndex, -1)
})

test('parseMiniplayerCommand accepts the bare actions, like included', () => {
  for (const a of ['playpause', 'next', 'prev', 'like']) assert.deepEqual(parseMiniplayerCommand(a), { type: a })
})

test('parseMiniplayerCommand clamps seek to 0-1 and volume to one step', () => {
  assert.deepEqual(parseMiniplayerCommand({ type: 'seek', value: 0.25 }), { type: 'seek', fraction: 0.25 })
  assert.deepEqual(parseMiniplayerCommand({ type: 'seek', value: 7 }), { type: 'seek', fraction: 1 })
  assert.deepEqual(parseMiniplayerCommand({ type: 'seek', value: -1 }), { type: 'seek', fraction: 0 })
  assert.deepEqual(parseMiniplayerCommand({ type: 'volume', value: 0.05 }), { type: 'volume', delta: 0.05 })
  assert.deepEqual(parseMiniplayerCommand({ type: 'volume', value: 5 }), { type: 'volume', delta: MINIPLAYER_MAX_VOLUME_STEP })
  assert.deepEqual(parseMiniplayerCommand({ type: 'volume', value: -5 }), { type: 'volume', delta: -MINIPLAYER_MAX_VOLUME_STEP })
})

test('parseMiniplayerCommand ignores anything else', () => {
  for (const junk of [null, undefined, 42, 'seek', 'rm -rf', {}, { type: 'seek' }, { type: 'seek', value: NaN },
    { type: 'seek', value: '0.5' }, { type: 'volume', value: Infinity }, { type: 'delete', value: 1 }]) {
    assert.equal(parseMiniplayerCommand(junk), null)
  }
})

test('buildMiniplayerState carries favorite and a clamped volume', () => {
  const track = { itemId: 'a', title: 'T', subtitle: 'S', artUrl: null }
  assert.equal(buildMiniplayerState(track, true, 0, 0, [], { isFavorite: true }).isFavorite, true)
  assert.equal(buildMiniplayerState(track, true, 0, 0).isFavorite, false)
  assert.equal(buildMiniplayerState(track, true, 0, 0, [], { volume: 0.4 }).volume, 0.4)
  assert.equal(buildMiniplayerState(track, true, 0, 0, [], { volume: 3 }).volume, 1)
  assert.equal(buildMiniplayerState(track, true, 0, 0, [], { volume: NaN }).volume, 1)
})

test('parseMiniplayerCommand: credit takes 0 (uploader) or 1 (maker) only', () => {
  assert.deepEqual(parseMiniplayerCommand({ type: 'credit', value: 0 }), { type: 'credit', who: 'uploader' })
  assert.deepEqual(parseMiniplayerCommand({ type: 'credit', value: 1 }), { type: 'credit', who: 'maker' })
  for (const v of [2, -1, 0.5, NaN]) assert.equal(parseMiniplayerCommand({ type: 'credit', value: v }), null)
})

test('buildMiniplayerState carries the credit as names only', () => {
  const track = { itemId: 'a', title: 'T', subtitle: 'S', artUrl: null }
  const credit = { provider: 'Spicy Lyrics', uploader: { name: 'spikerko', url: 'https://x' }, maker: null }
  assert.deepEqual(buildMiniplayerState(track, true, 0, 0, [], { credit }).credit,
    { provider: 'Spicy Lyrics', uploader: 'spikerko', maker: null })
  assert.equal(buildMiniplayerState(track, true, 0, 0).credit, null)
  assert.equal(buildMiniplayerState(track, true, 0, 0, [], { credit: { provider: '' } }).credit, null)
})
