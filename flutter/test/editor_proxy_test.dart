// The lyrics editor's proxy on this machine: it forwards the editor's two paths,
// and nothing else, to the server, as sent (headers the editor needs, the body,
// the server's isolation headers back), with the app's reverse proxy headers and
// never its sign-in.
import 'dart:convert';
import 'dart:io';

import 'package:cascade/core/connection_headers.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/ui/lyrics_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('forwards only the editor, as sent, with the proxy headers', () async {
    final seen = <HttpRequest>[];
    final bodies = <String>[];
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((req) async {
      seen.add(req);
      bodies.add(await utf8.decodeStream(req));
      req.response.headers.set('Cross-Origin-Embedder-Policy', 'require-corp');
      req.response.write('page ${req.uri}');
      await req.response.close();
    });
    connectionHeaders = [(name: 'CF-Access-Client-Id', value: 'abc')];
    final proxy = await EditorProxy.start(Jellyfin('http://127.0.0.1:${upstream.port}', 'D', token: 'secret-token'));
    final client = HttpClient();
    try {
      final get = await (await client.getUrl(Uri.parse('${proxy.origin}/CascadeServer/Editor/?item=s1'))).close();
      expect(get.statusCode, 200);
      expect(await utf8.decodeStream(get), 'page /CascadeServer/Editor/?item=s1');
      expect(get.headers.value('cross-origin-embedder-policy'), 'require-corp');

      final put = await client.openUrl('PUT', Uri.parse('${proxy.origin}/CascadeServer/EditorApi/Lyrics?everyone=false'));
      put.headers.set('X-Cascade-Editor', 'editor-token');
      put.headers.set('Content-Type', 'text/plain');
      put.write('<tt/>');
      expect((await put.close()).statusCode, 200);
      final r = seen.last;
      expect(bodies.last, '<tt/>');
      expect(r.headers.value('x-cascade-editor'), 'editor-token');
      expect(r.headers.value('cf-access-client-id'), 'abc');
      expect(r.headers.value('authorization'), isNull, reason: "never the app's sign-in");

      final other = await (await client.getUrl(Uri.parse('${proxy.origin}/Users/Me'))).close();
      expect(other.statusCode, 404, reason: 'only the editor goes through');
      expect(seen.length, 2);
    } finally {
      client.close(force: true);
      proxy.close();
      await upstream.close(force: true);
      connectionHeaders = [];
    }
  });
}
