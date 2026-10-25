import { test } from 'node:test'
import assert from 'node:assert/strict'
import { isRadioItem, buildRadioStreamUrl } from '../src/core/radio.ts'
import type { ServerConfig } from '../src/core/types.ts'

const config: ServerConfig = { url: 'http://server', token: 'tok', userId: 'u1', deviceId: 'd1' }

test('isRadioItem is true only for a Live TV channel', () => {
  assert.equal(isRadioItem({ Type: 'TvChannel' }), true)
  assert.equal(isRadioItem({ Type: 'Audio' }), false)
  assert.equal(isRadioItem({ Type: 'Movie' }), false)
  assert.equal(isRadioItem(null), false)
  assert.equal(isRadioItem(undefined), false)
})

test('buildRadioStreamUrl carries the media source and session, never static', () => {
  const url = buildRadioStreamUrl(config, 'chan1', { Id: 'src1', Container: 'mp3', LiveStreamId: 'live1' }, 'sess1')
  assert.equal(url.startsWith('http://server/Audio/chan1/stream.mp3?'), true)
  assert.match(url, /ApiKey=tok/)
  assert.match(url, /mediaSourceId=src1/)
  assert.match(url, /LiveStreamId=live1/)
  assert.match(url, /PlaySessionId=sess1/)
  assert.doesNotMatch(url, /static/i)
})

test('buildRadioStreamUrl tolerates a source with no container or session', () => {
  const url = buildRadioStreamUrl(config, 'chan1', {}, null)
  assert.equal(url, 'http://server/Audio/chan1/stream?ApiKey=tok')
})
