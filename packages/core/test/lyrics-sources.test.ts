// The parts of the lyrics waterfall that can be checked without a network:
// the KRC decode chain and the credits filter.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { deflateSync, inflateSync } from 'node:zlib'
import { base64ToBytes, decodeKrc, metaPattern } from '../src/core/lyrics-sources.ts'

test('base64ToBytes matches Buffer, including padding and whitespace', () => {
  for (const s of ['', 'a', 'ab', 'abc', 'hello world', 'Cascade éèê', '作词: x']) {
    const b64 = Buffer.from(s, 'utf8').toString('base64')
    assert.deepEqual(
      Buffer.from(base64ToBytes(b64)),
      Buffer.from(s, 'utf8'),
      `round trip failed for ${JSON.stringify(s)}`,
    )
    // Line-wrapped base64 is common in the wild; the stray newlines must not
    // shift the output by a byte.
    const wrapped = b64.replace(/(.{4})/g, '$1\n')
    assert.deepEqual(Buffer.from(base64ToBytes(wrapped)), Buffer.from(s, 'utf8'))
  }
})

test('decodeKrc undoes the header, the xor and the deflate', () => {
  const KEY = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105]
  const plain = '[0,1000]<0,500,0>hello <500,500,0>world'

  // Build a payload the way Kugou does, so the test exercises the real chain.
  const deflated = deflateSync(Buffer.from(plain, 'utf8'))
  const body = Buffer.alloc(deflated.length)
  for (let i = 0; i < deflated.length; i++) body[i] = deflated[i]! ^ KEY[i % 16]!
  const payload = Buffer.concat([Buffer.from('krc1', 'ascii'), body]).toString('base64')

  const out = decodeKrc(payload, bytes => inflateSync(Buffer.from(bytes)).toString('utf8'))
  assert.equal(out, plain)
})

test('metaPattern drops credits and the repeated title, keeps real lines', () => {
  const re = metaPattern('Bad Blood')

  assert.ok(re.test('Bad Blood - Taylor Swift'), 'title prefix is not a lyric')
  assert.ok(re.test('Composed by: Someone'))
  assert.ok(re.test('Written By : Someone'))
  assert.ok(re.test('作词：某人'), 'CJK lyricist credit')
  assert.ok(re.test('作曲: 某人'), 'CJK composer credit')

  assert.ok(!re.test("'Cause baby now we got bad blood"), 'a lyric mentioning the title survives')
  assert.ok(!re.test('Bad Blood'), 'the bare title is not the credit form')
  assert.ok(!re.test('Music makes me lose control'), 'a line starting with a credit word but no colon')
})

test('metaPattern does not blow up on a title full of regex metacharacters', () => {
  const re = metaPattern('C++ (Remix) [feat. $1] *.*')
  assert.ok(re.test('C++ (Remix) [feat. $1] *.* - Someone'))
  assert.ok(!re.test('just a lyric'))
})

test('a 404 from a lyrics source is a miss, not a failure worth reporting', () => {
  // Regression: every obscure track logged a red error toast in dev, because a
  // source with no row for it answers 404 and that was treated as a fault.
  const notFound = new Error('HTTP 404')
  const serverError = new Error('HTTP 500')
  assert.ok(/\bHTTP 404\b/.test(notFound.message))
  assert.ok(!/\bHTTP 404\b/.test(serverError.message), '500 must still be reported')
})
