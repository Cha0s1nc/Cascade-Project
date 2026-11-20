// Cascade Server's lyrics editor (a modified AMLL TTML Tool the plugin serves)
// in a window of its own, through desktop_webview_window: WebView2 on Windows,
// WebKit on macOS, WebKitGTK 4.1 on Linux. Desktop only. The plain design is in
// docs/flutter-plan.md, Lyrics editor.
//
// The app starts an editor session with the Jellyfin sign-in it already has and
// hands the page the editor token as the window opens, never in the address or
// the user agent (proxies log both). The window cannot be stopped from closing,
// so the editor has its own Close button that asks about unsaved changes; its
// autosave covers the window's own close button.
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/widgets.dart';

import 'package:cascade/core/data.dart';
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
  final origin = Uri.parse(j.server).origin;
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
  await w.launch('${j.server}/CascadeServer/Editor/?item=${Uri.encodeQueryComponent(song.id)}');
  w.onClose.then((_) {
    lib.lyrics?.forget(song.id);
    lyricsEdited.value = null;
    lyricsEdited.value = song.id;
  });
}
