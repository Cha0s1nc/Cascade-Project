import { test } from 'node:test'
import assert from 'node:assert/strict'
import { buildMiniplayerState, miniplayerProgressPct, isMiniplayerAction,
  miniplayerLyricTail, parseMiniplayerCommand,
  MINIPLAYER_LYRIC_LINES, MINIPLAYER_MAX_VOLUME_STEP,
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

test('miniplayerLyricTail starts at the active line', () => {
  const lines = [{ Text: 'one' }, { Text: 'two' }, { Text: 'three' }]
  assert.deepEqual(miniplayerLyricTail(lines, 1), ['two', 'three'])
  assert.deepEqual(miniplayerLyricTail(lines, 0), ['one', 'two', 'three'])
})

test('miniplayerLyricTail keeps interior blanks but trims trailing ones', () => {
  // An instrumental gap is real spacing; collapsing it would make the next
  // line arrive early against the music.
  const lines = [{ Text: 'a' }, { Text: '' }, { Text: 'b' }, { Text: '' }, { Text: '  ' }]
  assert.deepEqual(miniplayerLyricTail(lines, 0), ['a', '', 'b'])
})

test('miniplayerLyricTail survives junk input and out of range indexes', () => {
  assert.deepEqual(miniplayerLyricTail(null, 0), [])
  assert.deepEqual(miniplayerLyricTail([], 5), [])
  assert.deepEqual(miniplayerLyricTail([{ Text: 'x' }], 99), ['x'])
  assert.deepEqual(miniplayerLyricTail([{ Text: 'x' }], -3), ['x'])
  assert.deepEqual(miniplayerLyricTail([{ Text: null }], 0), [])
})

test('miniplayerLyricTail caps the payload', () => {
  const many = Array.from({ length: 200 }, (_, i) => ({ Text: `line ${i}` }))
  assert.equal(miniplayerLyricTail(many, 0).length, MINIPLAYER_LYRIC_LINES)
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
