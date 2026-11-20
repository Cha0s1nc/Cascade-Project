// Cascade Server's lyrics editor (a modified AMLL TTML Tool the plugin serves)
// in a window of its own, through desktop_webview_window: WebView2 on Windows,
// WebKit on macOS, WebKitGTK 4.1 on Linux. Desktop only. The design is in
// docs/flutter-plan.md, Lyrics editor.
//
// The app starts an editor session with the Jellyfin sign-in it already has and
// hands the page the editor token as the window opens, never in the address or
// the user agent (proxies log both). The page is opened through a proxy on this
// machine (EditorProxy), since its audio decoder needs a secure page and a
// plain-http Jellyfin server is not one. The window cannot be stopped from
// closing, so the editor has its own Close button that asks about unsaved
// changes; its autosave covers the window's own close button.
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/widgets.dart';

import 'package:cascade/core/connection_headers.dart';
import 'package:cascade/core/data.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/ui/pages/common.dart' show toast;
import 'package:cascade/ui/scopes.dart';

/// The song whose lyrics were just edited, so a lyrics panel showing it asks again.
final lyricsEdited = ValueNotifier<String?>(null);

/// Whether the editor can open here: a computer, with the plugin's editor.
bool canEditLyrics(BuildContext context) =>
    (Platform.isLinux || Platform.isWindows || Platform.isMacOS) && LibraryScope.read(context).lyricsEditor && !LibraryScope.read(context).offline;

/// Opens the lyrics editor on [song].
Future<void> openLyricsEditor(BuildContext context, Song song) async {
  final lib = LibraryScope.read(context);
  final j = lib.jf;
  if (j == null || song.id.isEmpty) return;
  final String token;
  try {
    token = ((await j.post('/CascadeServer/EditorApi/Session', null, {'itemId': song.id})) as Map)['token'] as String;
  } catch (e) {
    if (context.mounted) toast(context, 'Could not open the lyrics editor: $e', error: true);
    return;
  }
  final EditorProxy proxy;
  try {
    proxy = await EditorProxy.start(j);
  } catch (e) {
    if (context.mounted) toast(context, 'Could not open the lyrics editor: $e', error: true);
    return;
  }
  final origin = proxy.origin;
  bool ours(String url) {
    try {
      return Uri.parse(url).origin == origin;
    } catch (_) {
      return false;
    }
  }

  final w = await WebviewWindow.create(configuration: CreateConfiguration(title: '${song.title}: lyrics editor', windowWidth: 1280, windowHeight: 820));
  // Only the server's own pages get the token, before their scripts run.
  await w.addScriptToExecuteOnDocumentCreated('if (location.origin === ${jsonEncode(origin)}) window.cascadeEditorToken = ${jsonEncode(token)};');
  // The window stays on the server: the editor's links out are not followed here.
  w.setOnUrlRequestCallback(ours);
  // The editor's own Close button, after it asked about unsaved changes.
  w.addJavaScriptHandler('cascade-close', (_, from) {
    if (from == origin) w.close();
  });
  await w.launch('$origin/CascadeServer/Editor/?item=${Uri.encodeQueryComponent(song.id)}');
  w.onClose.then((_) {
    proxy.close();
    lib.lyrics?.forget(song.id);
    lyricsEdited.value = null;
    lyricsEdited.value = song.id;
  });
}

/// The editor's way to the server, on this machine. Browsers and web views treat
/// only HTTPS and the machine itself as secure, the editor's audio decoder needs a
/// secure page (its threads need cross-origin isolation, which needs one), and
/// many Jellyfin servers are plain http on a home network. So the window opens
/// http://127.0.0.1:port, and this forwards the editor's two paths, and nothing
/// else, to the server, with the app's reverse proxy headers (never its sign-in:
/// the page brings its own editor token).
class EditorProxy {
  EditorProxy._(this._server, this._client);

  /// Where the editor's window opens it: http://127.0.0.1:port.
  String get origin => 'http://127.0.0.1:${_server.port}';
  final HttpServer _server;
  final HttpClient _client;

  void close() {
    _server.close(force: true);
    _client.close(force: true);
  }

  static const _forward = {'content-type', 'x-cascade-editor', 'range', 'if-none-match', 'if-modified-since'};
  static const _hop = {'connection', 'keep-alive', 'transfer-encoding', 'upgrade', 'proxy-connection'};

  static bool _allowed(String path) => path.startsWith('/CascadeServer/Editor/') || path.startsWith('/CascadeServer/EditorApi/');

  static Future<EditorProxy> start(Jellyfin j) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // Bytes as the server sent them, compressed or not, with its own headers.
    final client = HttpClient()..autoUncompress = false;
    server.listen((req) async {
      final res = req.response;
      try {
        if (!_allowed(req.uri.path)) {
          res.statusCode = HttpStatus.notFound;
          return await res.close();
        }
        final target = Uri.parse('${j.server}${req.uri.path}${req.uri.hasQuery ? '?${req.uri.query}' : ''}');
        final out = await client.openUrl(req.method, target)
          ..followRedirects = false;
        req.headers.forEach((name, values) {
          if (_forward.contains(name)) out.headers.set(name, values.join(', '));
        });
        for (final h in connectionHeaders) {
          out.headers.set(h.name, h.value);
        }
        await out.addStream(req);
        final answer = await out.close();
        res.statusCode = answer.statusCode;
        answer.headers.forEach((name, values) {
          if (!_hop.contains(name)) res.headers.set(name, values.join(', '));
        });
        await answer.pipe(res);
      } catch (_) {
        try {
          res.statusCode = HttpStatus.badGateway;
          await res.close();
        } catch (_) {}
      }
    });
    return EditorProxy._(server, client);
  }
}
