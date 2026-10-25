import { test } from 'node:test'
import assert from 'node:assert/strict'
import { loginDisclaimerText, parseDisplayMessage } from '../src/core/server-messages.ts'

test('a dashboard message reads its header, text and timeout', () => {
  assert.deepEqual(parseDisplayMessage({ Header: 'Maintenance', Text: 'Restarting at 2', TimeoutMs: '5000' }),
    { header: 'Maintenance', text: 'Restarting at 2', timeoutMs: 5000 })
  assert.deepEqual(parseDisplayMessage({ Text: 'hi' }), { header: 'Message from your server', text: 'hi', timeoutMs: null })
  assert.equal(parseDisplayMessage({}), null)
  assert.equal(parseDisplayMessage(null), null)
  assert.equal(parseDisplayMessage({ Header: 'x', TimeoutMs: 'soon' })?.timeoutMs, null)
})

test('the login disclaimer comes out as plain text', () => {
  assert.equal(loginDisclaimerText('<p>Welcome to <b>Chaos</b> &amp; friends.</p><p>Be nice.<br>Thanks</p>'),
    'Welcome to Chaos & friends.\nBe nice.\nThanks')
  assert.equal(loginDisclaimerText('<script>alert(1)</script>ok'), 'alert(1)ok')
  assert.equal(loginDisclaimerText(42), '')
  assert.equal(loginDisclaimerText('caf&#233; &#x2014;'), 'café —')
})

test('the disclaimer is fetched without a sign-in and empty on any failure', async () => {
  const ok = (body: unknown, status = 200) => (async () => new Response(JSON.stringify(body), { status })) as unknown as typeof fetch
  const { fetchLoginDisclaimer } = await import('../src/core/server-messages.ts')
  assert.equal(await fetchLoginDisclaimer('https://s', ok({ LoginDisclaimer: '<b>Hi</b>' })), 'Hi')
  assert.equal(await fetchLoginDisclaimer('https://s', ok({}, 404)), '')
  assert.equal(await fetchLoginDisclaimer('https://s', (async () => { throw new Error('down') }) as unknown as typeof fetch), '')
})
