import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  headerNameProblem, headerValueProblem, parseHeaderLines, formatHeaderLines, sanitizeCustomHeaders,
  requestOrigin, headersForRequest, withCustomHeaders, chooseClientCertificate, MAX_CUSTOM_HEADERS,
} from '../src/core/custom-headers.ts'

test('header names must be tokens', () => {
  assert.equal(headerNameProblem('CF-Access-Client-Id'), null)
  assert.equal(headerNameProblem('X_Custom.1~'), null)
  for (const bad of ['', 'Has Space', 'colon:', 'new\nline', 'ünï', '(x)', 'a/b', undefined, 5]) {
    assert.ok(headerNameProblem(bad), `${String(bad)} should be refused`)
  }
})

test('Authorization, Host and Content-Length cannot be overridden, in any case', () => {
  for (const n of ['Authorization', 'AUTHORIZATION', 'host', 'Host', 'Content-Length', 'content-length', 'X-Emby-Authorization', 'Transfer-Encoding']) {
    assert.match(headerNameProblem(n) ?? '', /cannot be overridden/, n)
  }
  assert.equal(headerNameProblem('Authorization-Extra'), null, 'only the exact names')
})

test('header values: present, bounded, no control characters', () => {
  assert.equal(headerValueProblem('abc123'), null)
  assert.equal(headerValueProblem('a b\tc'), null, 'a tab is legal')
  assert.ok(headerValueProblem(''))
  assert.ok(headerValueProblem('x\r\nInjected: 1'))
  assert.ok(headerValueProblem('x\u0000y'))
  assert.ok(headerValueProblem('x'.repeat(5000)))
  assert.ok(headerValueProblem(undefined))
})

test('parseHeaderLines reads Name: Value lines', () => {
  const { headers, errors } = parseHeaderLines('CF-Access-Client-Id: abc.access\r\n\n# a note\nCF-Access-Client-Secret:  s3cret:with:colons  ')
  assert.deepEqual(errors, [])
  assert.deepEqual(headers, [
    { name: 'CF-Access-Client-Id', value: 'abc.access' },
    { name: 'CF-Access-Client-Secret', value: 's3cret:with:colons' },
  ])
})

test('parseHeaderLines reports every bad line and keeps the good ones', () => {
  const { headers, errors } = parseHeaderLines('Good: 1\nno colon here\nAuthorization: Bearer x\nBad Name: 1\nX-Empty:\ngood: 2')
  assert.deepEqual(headers, [{ name: 'Good', value: '1' }])
  assert.equal(errors.length, 5)
  assert.match(errors[0], /^Line 2:/)
  assert.match(errors[1], /^Line 3: Authorization cannot be overridden/)
  assert.match(errors[3], /^Line 5:/)
  assert.match(errors[4], /^Line 6: good is listed twice/)
})

test('parseHeaderLines caps the list', () => {
  const text = Array.from({ length: MAX_CUSTOM_HEADERS + 3 }, (_, i) => `X-H${i}: v`).join('\n')
  const { headers, errors } = parseHeaderLines(text)
  assert.equal(headers.length, MAX_CUSTOM_HEADERS)
  assert.equal(errors.length, 1)
})

test('formatHeaderLines round-trips through parseHeaderLines', () => {
  const list = [{ name: 'A', value: '1' }, { name: 'B-C', value: 'x: y' }]
  assert.deepEqual(parseHeaderLines(formatHeaderLines(list)).headers, list)
  assert.equal(formatHeaderLines([]), '')
})

test('sanitizeCustomHeaders drops what is not trustworthy', () => {
  assert.deepEqual(sanitizeCustomHeaders(null), [])
  assert.deepEqual(sanitizeCustomHeaders('x'), [])
  assert.deepEqual(sanitizeCustomHeaders([
    { name: 'A', value: '1' }, { name: 'a', value: '2' }, { name: 'Host', value: 'evil' },
    { name: 'B', value: 'x\ny' }, { name: 5, value: 'x' }, null, { name: 'C' }, { name: 'D', value: 'ok' },
  ]), [{ name: 'A', value: '1' }, { name: 'D', value: 'ok' }])
})

test('requestOrigin normalizes default ports and WebSockets', () => {
  assert.equal(requestOrigin('https://jf.example.com/web/index.html'), 'https://jf.example.com')
  assert.equal(requestOrigin('https://jf.example.com:443/x'), 'https://jf.example.com')
  assert.equal(requestOrigin('http://192.168.1.10:8096/x'), 'http://192.168.1.10:8096')
  assert.equal(requestOrigin('http://host:80'), 'http://host')
  assert.equal(requestOrigin('wss://jf.example.com/socket'), 'https://jf.example.com')
  assert.equal(requestOrigin('ws://h:8096/socket'), 'http://h:8096')
  assert.equal(requestOrigin('HTTPS://JF.Example.COM/'), 'https://jf.example.com')
  for (const bad of ['file:///x', 'ftp://h', 'not a url', '', undefined, null, 5]) assert.equal(requestOrigin(bad), null)
})

test('headersForRequest only reaches the server origin', () => {
  const h = [{ name: 'X-Token', value: 't' }]
  const server = 'https://jf.example.com/jellyfin'
  assert.deepEqual(headersForRequest('https://jf.example.com/Items/1/Images/Primary', server, h), h)
  assert.deepEqual(headersForRequest('wss://jf.example.com/socket', server, h), h)
  for (const other of [
    'https://lrclib.net/api/get', 'https://api.github.com/repos/x', 'https://jf.example.com.evil.net/',
    'https://other.example.com/', 'http://jf.example.com/', 'https://jf.example.com:8443/', 'https://jf.example.com@evil.net/',
    'file:///index.html', 'not a url',
  ]) assert.deepEqual(headersForRequest(other, server, h), [], other)
})

test('headersForRequest: no headers or no server means nothing is added', () => {
  assert.deepEqual(headersForRequest('https://jf.example.com/', 'https://jf.example.com', []), [])
  assert.deepEqual(headersForRequest('https://jf.example.com/', null, [{ name: 'A', value: '1' }]), [])
  assert.deepEqual(headersForRequest('https://jf.example.com/', 'garbage', [{ name: 'A', value: '1' }]), [])
})

test('withCustomHeaders replaces by any capitalization and leaves the input alone', () => {
  const existing = { accept: '*/*', 'x-token': 'old', Authorization: 'MediaBrowser Token=abc' }
  const out = withCustomHeaders(existing, [{ name: 'X-Token', value: 'new' }, { name: 'CF-Access-Client-Id', value: 'id' }])
  assert.deepEqual(out, { accept: '*/*', Authorization: 'MediaBrowser Token=abc', 'X-Token': 'new', 'CF-Access-Client-Id': 'id' })
  assert.equal(existing['x-token'], 'old')
})

const cert = (fingerprint: string, validExpiry?: number) => ({ fingerprint, subjectName: `CN=${fingerprint}`, issuerName: 'CN=CA', validExpiry })

test('chooseClientCertificate: none, one, remembered, several', () => {
  const now = 1_000
  assert.deepEqual(chooseClientCertificate([], null, now), { kind: 'none' })
  assert.deepEqual(chooseClientCertificate([cert('a', 2_000)], null, now), { kind: 'use', index: 0 })
  assert.deepEqual(chooseClientCertificate([cert('a'), cert('b')], 'b', now), { kind: 'use', index: 1 })
  assert.deepEqual(chooseClientCertificate([cert('a'), cert('b')], null, now), { kind: 'ask', candidates: [0, 1] })
  assert.deepEqual(chooseClientCertificate([cert('a'), cert('b')], 'gone', now), { kind: 'ask', candidates: [0, 1] })
})

test('chooseClientCertificate: an expired certificate is never offered, indexes stay the original ones', () => {
  const now = 1_000
  assert.deepEqual(chooseClientCertificate([cert('old', 500), cert('new', 2_000)], null, now), { kind: 'use', index: 1 })
  assert.deepEqual(chooseClientCertificate([cert('old', 500)], null, now), { kind: 'none' })
  assert.deepEqual(chooseClientCertificate([cert('old', 500), cert('b', 2_000)], 'old', now), { kind: 'use', index: 1 }, 'a remembered but expired choice is ignored')
  assert.deepEqual(chooseClientCertificate([cert('x', 999), cert('y', 5_000), cert('z')], null, now), { kind: 'ask', candidates: [1, 2] })
})
