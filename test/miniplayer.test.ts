import { test } from 'node:test'
import assert from 'node:assert/strict'
import { buildMiniplayerState, miniplayerProgressPct, isMiniplayerAction,
  miniplayerSheet, parseMiniplayerCommand,
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

test('miniplayerSheet keeps timings, blanks inside, and trims trailing blanks', () => {
  const sheet = miniplayerSheet([
    { Start: 10, End: 20, Text: ' Hello ', Words: [{ Start: 10, End: 15, Text: 'Hel' }, { Start: 15, End: null, Text: 'lo' }], Background: [{ Start: 12, End: 18, Text: 'oh' }] },
    { Start: 30, End: null, Text: '', Words: null },
    { Start: 40, End: 50, Text: 'World', Words: null },
    { Start: 60, End: null, Text: '  ', Words: null },
  ], true)
  assert.equal(sheet.emphasis, true)
  assert.equal(sheet.lines.length, 3)
  assert.deepEqual(sheet.lines[0], { Start: 10, End: 20, Text: 'Hello', Words: [{ Start: 10, End: 15, Text: 'Hel' }, { Start: 15, End: null, Text: 'lo' }], Background: [{ Start: 12, End: 18, Text: 'oh' }] })
  assert.equal(sheet.lines[1].Text, '')
})

test('miniplayerSheet drops junk words and caps a huge sheet', () => {
  assert.deepEqual(miniplayerSheet(null, false), { lines: [], emphasis: false })
  const s = miniplayerSheet([{ Start: 1, Text: 'x', Words: [{ Start: NaN, Text: 'a' }, { Start: 2, Text: 5 }, { Start: 3, End: 4, Text: 'ok' }] }], false)
  assert.deepEqual(s.lines[0].Words, [{ Start: 3, End: 4, Text: 'ok' }])
  const huge = Array.from({ length: MINIPLAYER_LYRIC_MAX + 50 }, (_, i) => ({ Start: i, Text: `l${i}` }))
  assert.equal(miniplayerSheet(huge, false).lines.length, MINIPLAYER_LYRIC_MAX)
})

test('sheet asks for the lyric sheet again, only as value 0', () => {
  assert.deepEqual(parseMiniplayerCommand({ type: 'sheet', value: 0 }), { type: 'sheet' })
  assert.equal(parseMiniplayerCommand({ type: 'sheet', value: 1 }), null)
})

test('jump carries a queue position, and nothing that is not one', () => {
  assert.deepEqual(parseMiniplayerCommand({ type: 'jump', value: 7 }), { type: 'jump', index: 7 })
  for (const bad of [-1, 1.5, NaN, Infinity]) assert.equal(parseMiniplayerCommand({ type: 'jump', value: bad }), null)
  assert.equal(parseMiniplayerCommand({ type: 'jump', value: '3' }), null)
})

test('state: the sheet rides along only when given, queue is capped, sentAt is set', () => {
  const t = { itemId: 'x', title: 't', subtitle: 's', artUrl: null }
  const q = Array.from({ length: MINIPLAYER_QUEUE_MAX + 5 }, () => ({ title: 'q', subtitle: '', artUrl: null }))
  const sheet = miniplayerSheet([{ Start: 0, Text: 'a' }], false)
  const withSheet = buildMiniplayerState(t, true, 1, 10, 7, { sheet, queue: q, queueStart: 4, now: 1234 })
  assert.equal(withSheet.sheetId, 7)
  assert.deepEqual(withSheet.sheet, sheet)
  assert.equal(withSheet.sentAt, 1234)
  assert.equal(withSheet.queue.length, MINIPLAYER_QUEUE_MAX)
  assert.equal(withSheet.queueStart, 4)
  const without = buildMiniplayerState(t, true, 1, 10, 7, {})
  assert.equal('sheet' in without, false)
  assert.equal(buildMiniplayerState(t, true, 1, 10, 1.5 as number, { queueStart: -2 }).sheetId, 0)
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
  assert.equal(buildMiniplayerState(track, true, 0, 0, 0, { isFavorite: true }).isFavorite, true)
  assert.equal(buildMiniplayerState(track, true, 0, 0).isFavorite, false)
  assert.equal(buildMiniplayerState(track, true, 0, 0, 0, { volume: 0.4 }).volume, 0.4)
  assert.equal(buildMiniplayerState(track, true, 0, 0, 0, { volume: 3 }).volume, 1)
  assert.equal(buildMiniplayerState(track, true, 0, 0, 0, { volume: NaN }).volume, 1)
})

test('parseMiniplayerCommand: credit takes 0 (uploader) or 1 (maker) only', () => {
  assert.deepEqual(parseMiniplayerCommand({ type: 'credit', value: 0 }), { type: 'credit', who: 'uploader' })
  assert.deepEqual(parseMiniplayerCommand({ type: 'credit', value: 1 }), { type: 'credit', who: 'maker' })
  for (const v of [2, -1, 0.5, NaN]) assert.equal(parseMiniplayerCommand({ type: 'credit', value: v }), null)
})

test('buildMiniplayerState carries the credit as names only', () => {
  const track = { itemId: 'a', title: 'T', subtitle: 'S', artUrl: null }
  const credit = { provider: 'Spicy Lyrics', uploader: { name: 'spikerko', url: 'https://x' }, maker: null }
  assert.deepEqual(buildMiniplayerState(track, true, 0, 0, 0, { credit }).credit,
    { provider: 'Spicy Lyrics', uploader: 'spikerko', maker: null })
  assert.equal(buildMiniplayerState(track, true, 0, 0).credit, null)
  assert.equal(buildMiniplayerState(track, true, 0, 0, 0, { credit: { provider: '' } }).credit, null)
})
