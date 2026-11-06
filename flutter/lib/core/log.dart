// A plain log for chasing playback problems: Android's system log (adb
// logcat), and on Windows also %TEMP%\cascade-flutter.log, since a release
// build there has no console.
import 'dart:io';

import 'package:flutter/foundation.dart';

final _file = Platform.isWindows ? File('${Directory.systemTemp.path}\\cascade-flutter.log') : null;

/// The last lines logged, for the log viewer in Settings > About.
final recentLog = <String>[];
const _keep = 400;

void log(String message) {
  final line = '${DateTime.now().toIso8601String()} $message';
  recentLog.add(line);
  if (recentLog.length > _keep) recentLog.removeRange(0, recentLog.length - _keep);
  debugPrint(line);
  try {
    _file?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}
