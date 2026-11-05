// Ported from desktop/test/custom-headers.test.ts.
import 'package:cascade/core/custom_headers.dart';
import 'package:flutter_test/flutter_test.dart';

CustomHeader h(String n, String v) => (name: n, value: v);
ClientCertificate cert(String fp, [int? exp]) => (fingerprint: fp, subjectName: 'CN=$fp', issuerName: 'CN=CA', validExpiry: exp);

void main() {
  test('header names must be tokens', () {
    expect(headerNameProblem('CF-Access-Client-Id'), isNull);
    expect(headerNameProblem('X_Custom.1~'), isNull);
    for (final bad in ['', 'Has Space', 'colon:', 'new\nline', 'ünï', '(x)', 'a/b', null, 5]) {
      expect(headerNameProblem(bad), isNotNull, reason: '$bad should be refused');
    }
  });

  test('Authorization, Host and Content-Length cannot be overridden, in any case', () {
    for (final n in ['Authorization', 'AUTHORIZATION', 'host', 'Host', 'Content-Length', 'content-length', 'X-Emby-Authorization', 'Transfer-Encoding']) {
      expect(headerNameProblem(n), contains('cannot be overridden'), reason: n);
    }
    expect(headerNameProblem('Authorization-Extra'), isNull);
  });

  test('header values: present, bounded, no control characters', () {
    expect(headerValueProblem('abc123'), isNull);
    expect(headerValueProblem('a b\tc'), isNull);
    expect(headerValueProblem(''), isNotNull);
    expect(headerValueProblem('x\r\nInjected: 1'), isNotNull);
    expect(headerValueProblem('x\u0000y'), isNotNull);
    expect(headerValueProblem('x' * 5000), isNotNull);
    expect(headerValueProblem(null), isNotNull);
  });

  test('parseHeaderLines reads Name: Value lines', () {
    final r = parseHeaderLines('CF-Access-Client-Id: abc.access\r\n\n# a note\nCF-Access-Client-Secret:  s3cret:with:colons  ');
    expect(r.errors, isEmpty);
    expect(r.headers, [h('CF-Access-Client-Id', 'abc.access'), h('CF-Access-Client-Secret', 's3cret:with:colons')]);
  });

  test('parseHeaderLines reports every bad line and keeps the good ones', () {
    final r = parseHeaderLines('Good: 1\nno colon here\nAuthorization: Bearer x\nBad Name: 1\nX-Empty:\ngood: 2');
    expect(r.headers, [h('Good', '1')]);
    expect(r.errors.length, 5);
    expect(r.errors[0], startsWith('Line 2:'));
    expect(r.errors[1], startsWith('Line 3: Authorization cannot be overridden'));
    expect(r.errors[3], startsWith('Line 5:'));
    expect(r.errors[4], startsWith('Line 6: good is listed twice'));
  });

  test('parseHeaderLines caps the list', () {
    final text = List.generate(maxCustomHeaders + 3, (i) => 'X-H$i: v').join('\n');
    final r = parseHeaderLines(text);
    expect(r.headers.length, maxCustomHeaders);
    expect(r.errors.length, 1);
  });

  test('formatHeaderLines round-trips through parseHeaderLines', () {
    final list = [h('A', '1'), h('B-C', 'x: y')];
    expect(parseHeaderLines(formatHeaderLines(list)).headers, list);
    expect(formatHeaderLines([]), '');
  });

  test('sanitizeCustomHeaders drops what is not trustworthy', () {
    expect(sanitizeCustomHeaders(null), isEmpty);
    expect(sanitizeCustomHeaders('x'), isEmpty);
    expect(
      sanitizeCustomHeaders([
        {'name': 'A', 'value': '1'}, {'name': 'a', 'value': '2'}, {'name': 'Host', 'value': 'evil'},
        {'name': 'B', 'value': 'x\ny'}, {'name': 5, 'value': 'x'}, null, {'name': 'C'}, {'name': 'D', 'value': 'ok'},
      ]),
      [h('A', '1'), h('D', 'ok')],
    );
  });

  test('requestOrigin normalizes default ports and WebSockets', () {
    expect(requestOrigin('https://jf.example.com/web/index.html'), 'https://jf.example.com');
    expect(requestOrigin('https://jf.example.com:443/x'), 'https://jf.example.com');
    expect(requestOrigin('http://192.168.1.10:8096/x'), 'http://192.168.1.10:8096');
    expect(requestOrigin('http://host:80'), 'http://host');
    expect(requestOrigin('wss://jf.example.com/socket'), 'https://jf.example.com');
    expect(requestOrigin('ws://h:8096/socket'), 'http://h:8096');
    expect(requestOrigin('HTTPS://JF.Example.COM/'), 'https://jf.example.com');
    for (final bad in ['file:///x', 'ftp://h', 'not a url', '', null, 5]) {
      expect(requestOrigin(bad), isNull, reason: '$bad');
    }
  });

  test('headersForRequest only reaches the server origin', () {
    final hs = [h('X-Token', 't')];
    const server = 'https://jf.example.com/jellyfin';
    expect(headersForRequest('https://jf.example.com/Items/1/Images/Primary', server, hs), hs);
    expect(headersForRequest('wss://jf.example.com/socket', server, hs), hs);
    for (final other in [
      'https://lrclib.net/api/get', 'https://api.github.com/repos/x', 'https://jf.example.com.evil.net/',
      'https://other.example.com/', 'http://jf.example.com/', 'https://jf.example.com:8443/', 'https://jf.example.com@evil.net/',
      'file:///index.html', 'not a url',
    ]) {
      expect(headersForRequest(other, server, hs), isEmpty, reason: other);
    }
  });

  test('headersForRequest: no headers or no server means nothing is added', () {
    expect(headersForRequest('https://jf.example.com/', 'https://jf.example.com', []), isEmpty);
    expect(headersForRequest('https://jf.example.com/', null, [h('A', '1')]), isEmpty);
    expect(headersForRequest('https://jf.example.com/', 'garbage', [h('A', '1')]), isEmpty);
  });

  test('withCustomHeaders replaces by any capitalization and leaves the input alone', () {
    final existing = <String, Object>{'accept': '*/*', 'x-token': 'old', 'Authorization': 'MediaBrowser Token=abc'};
    final out = withCustomHeaders(existing, [h('X-Token', 'new'), h('CF-Access-Client-Id', 'id')]);
    expect(out, {'accept': '*/*', 'Authorization': 'MediaBrowser Token=abc', 'X-Token': 'new', 'CF-Access-Client-Id': 'id'});
    expect(existing['x-token'], 'old');
  });

  test('chooseClientCertificate: none, one, remembered, several', () {
    const now = 1000;
    var c = chooseClientCertificate([], null, now);
    expect(c.kind, 'none');
    c = chooseClientCertificate([cert('a', 2000)], null, now);
    expect((c.kind, c.index), ('use', 0));
    c = chooseClientCertificate([cert('a'), cert('b')], 'b', now);
    expect((c.kind, c.index), ('use', 1));
    c = chooseClientCertificate([cert('a'), cert('b')], null, now);
    expect(c.kind, 'ask');
    expect(c.candidates, [0, 1]);
    c = chooseClientCertificate([cert('a'), cert('b')], 'gone', now);
    expect(c.kind, 'ask');
    expect(c.candidates, [0, 1]);
  });

  test('chooseClientCertificate: an expired certificate is never offered, indexes stay the original ones', () {
    const now = 1000;
    var c = chooseClientCertificate([cert('old', 500), cert('new', 2000)], null, now);
    expect((c.kind, c.index), ('use', 1));
    expect(chooseClientCertificate([cert('old', 500)], null, now).kind, 'none');
    c = chooseClientCertificate([cert('old', 500), cert('b', 2000)], 'old', now);
    expect((c.kind, c.index), ('use', 1));
    c = chooseClientCertificate([cert('x', 999), cert('y', 5000), cert('z')], null, now);
    expect(c.kind, 'ask');
    expect(c.candidates, [1, 2]);
  });

  test('the Quick Connect check sends saved headers only to the server they were saved for', () {
    final saved = [h('CF-Access-Client-Id', 'id')];
    expect(probeHeaders('https://jf.example.com/', 'https://jf.example.com', saved), saved);
    expect(probeHeaders('https://jf.example.co', 'https://jf.example.com', saved), isEmpty);
    expect(probeHeaders('https://jf.example.com:8920', 'https://jf.example.com', saved), isEmpty);
    expect(probeHeaders('https://jf.example.com', null, saved), isEmpty);
    expect(probeHeaders('not a url', 'https://jf.example.com', saved), isEmpty);
  });
}
