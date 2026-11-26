// Benchmark mode: Settings > About > Run benchmark, or --benchmark on the
// command line, which runs once signed in, writes the report and quits. The
// same run and report as the Electron app's (desktop/renderer.js runBenchmark,
// desktop/main.js 'benchmark-*'), so the two compare on one machine and one
// account: settle on Home, measure idle, play one song with no sound, measure
// playing. No playback report goes out while it runs, so the server's history,
// resume points and play counts stay as they were. It stops what was playing.
//
// Options: --benchmark-track=<item id> (default: the library's first song by
// name), --benchmark-settle=<s> (20), --benchmark-seconds=<s> (30),
// --benchmark-out=<file> (default: benchmarks/ in the app's data folder).
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/log.dart';
import 'package:cascade/engine/player.dart';

typedef BenchmarkArgs = ({String? track, int settle, int seconds, String? out});

/// The --benchmark options, or null when the app was not started with --benchmark.
BenchmarkArgs? benchmarkArgs(List<String> args) {
  if (!args.contains('--benchmark')) return null;
  String? arg(String name) {
    final p = '--$name=';
    for (final a in args) {
      if (a.startsWith(p)) return a.substring(p.length);
    }
    return null;
  }

  int num(String name, int d) => switch (int.tryParse(arg(name) ?? '')) { final n? when n > 0 => n, _ => d };
  final track = arg('benchmark-track');
  return (track: track == null || track.isEmpty ? null : track, settle: num('benchmark-settle', 20), seconds: num('benchmark-seconds', 30), out: arg('benchmark-out'));
}

/// How memory is counted here, as the Electron app counts it on the same OS:
/// PSS on Linux and Android, private bytes on Windows, the working set elsewhere.
String get memoryKind => Platform.isLinux || Platform.isAndroid ? 'pss' : (Platform.isWindows ? 'private' : 'rss');

/// CPU seconds this process has used, or null where it cannot be read.
double? cpuSeconds() {
  if (Platform.isLinux || Platform.isAndroid) {
    // utime and stime, fields 14 and 15, in clock ticks of 1/100 s; the name
    // in field 2 can hold spaces, so count from its closing bracket.
    final stat = File('/proc/self/stat').readAsStringSync();
    final f = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    return (int.parse(f[11]) + int.parse(f[12])) / 100;
  }
  if (Platform.isWindows) {
    final t = calloc<Uint64>(4);
    try {
      if (_getProcessTimes(_getCurrentProcess(), t, t + 1, t + 2, t + 3) == 0) return null;
      return (t[2] + t[3]) / 1e7; // kernel + user, in 100 ns units
    } finally {
      calloc.free(t);
    }
  }
  return null;
}

/// Memory in KB, by [memoryKind].
int memoryKB() {
  if (Platform.isLinux || Platform.isAndroid) {
    final m = RegExp(r'^Pss:\s+(\d+)', multiLine: true).firstMatch(File('/proc/self/smaps_rollup').readAsStringSync());
    if (m != null) return int.parse(m[1]!);
  }
  if (Platform.isWindows) {
    // PROCESS_MEMORY_COUNTERS_EX on 64-bit Windows: 80 bytes, PrivateUsage at 72.
    final c = calloc<Uint8>(80);
    try {
      c.cast<Uint32>().value = 80;
      if (_getProcessMemoryInfo(_getCurrentProcess(), c, 80) != 0) return (c + 72).cast<Uint64>().value ~/ 1024;
    } finally {
      calloc.free(c);
    }
  }
  return ProcessInfo.currentRss ~/ 1024;
}

/// CPU over [seconds] as a percentage of one core, and memory at the end of it.
Future<Map<String, Object?>> measure(int seconds) async {
  final c0 = cpuSeconds(), w = Stopwatch()..start();
  await Future<void>.delayed(Duration(seconds: seconds));
  final c1 = cpuSeconds(), el = w.elapsedMicroseconds / 1e6;
  return {
    'cpuPercent': c0 == null || c1 == null ? null : ((c1 - c0) / el * 1000).round() / 10,
    'memoryMB': (memoryKB() / 1024).round(),
    'processes': 1, // mpv plays inside this process
  };
}

/// The whole run. [goHome] shows Home before it settles.
Future<Map<String, Object?>> runBenchmark(Player player, {String? track, int settle = 20, int seconds = 30, void Function()? goHome}) async {
  final j = player.jf;
  if (j == null || j.token == null) throw StateError('Sign in to a server first.');
  final reports = player.settings.noReports;
  player.settings.noReports = true;
  try {
    log('benchmark: stopping playback');
    await player.stop();
    await player.setSilent(true);
    goHome?.call();
    log('benchmark: settling for $settle s');
    await Future<void>.delayed(Duration(seconds: settle));
    final idle = await measure(seconds);
    log('benchmark: idle $idle');
    // Default: the library's first song by name, which the Electron app picks too.
    const fields = 'AlbumId,AlbumPrimaryImageTag,UserData,MediaStreams,MediaSources';
    final r = await j.get('/Items', {
      'userId': j.userId,
      if (track != null) 'Ids': track else ...{'IncludeItemTypes': 'Audio', 'Recursive': true, 'SortBy': 'SortName', 'SortOrder': 'Ascending', 'Limit': 1},
      'Fields': fields,
    });
    final items = (r is Map ? r['Items'] as List? : null) ?? const [];
    if (items.isEmpty) throw StateError(track != null ? 'No song with id $track.' : 'The library has no songs.');
    final song = j.song(items.first as Map);
    log('benchmark: playing ${song.title}');
    await player.play(song, [song]);
    await Future<void>.delayed(const Duration(seconds: 5));
    if (!player.playing) throw StateError('The song did not start playing.');
    final playing = await measure(seconds);
    log('benchmark: playing $playing');
    return {
      'app': 'flutter',
      'version': appVersion,
      'date': DateTime.now().toUtc().toIso8601String(),
      'track': {'id': song.id, 'name': song.title},
      'settleSeconds': settle,
      'sampleSeconds': seconds,
      'idle': idle,
      'playing': playing,
      'os': Platform.isMacOS ? 'macos' : Platform.operatingSystem,
      'arch': _arch,
      'cpus': Platform.numberOfProcessors,
      'memoryKind': memoryKind,
    };
  } finally {
    await player.stop();
    await player.setSilent(false);
    player.settings.noReports = reports;
  }
}

/// Writes [report] and says where.
Future<String> saveBenchmark(Map<String, Object?> report, {String? out}) async {
  final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
  final path = out ?? '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}benchmarks${Platform.pathSeparator}benchmark-flutter-$stamp.json';
  final f = File(path);
  await f.parent.create(recursive: true);
  await f.writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  return path;
}

/// One line for Settings: CPU and memory, idle then playing.
String benchmarkSummary(Map<String, Object?> r) {
  final unit = r['memoryKind'] == 'private' ? 'MB private' : 'MB';
  String part(String label, Object? p) {
    final m = p as Map;
    return '$label ${m['cpuPercent'] ?? '?'}% CPU, ${m['memoryMB']} $unit.';
  }

  return '${part('Idle', r['idle'])} ${part('Playing', r['playing'])}';
}

// 'x64' and 'arm64' as Electron names them, from the Dart VM's own target.
String get _arch => switch (Abi.current()) {
  Abi.windowsArm64 || Abi.linuxArm64 || Abi.macosArm64 || Abi.androidArm64 => 'arm64',
  Abi.windowsX64 || Abi.linuxX64 || Abi.macosX64 || Abi.androidX64 => 'x64',
  final a => '$a',
};

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
final int Function() _getCurrentProcess = _kernel32.lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
final int Function(int, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>) _getProcessTimes = _kernel32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
      int Function(int, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)
    >('GetProcessTimes');
final int Function(int, Pointer<Uint8>, int) _getProcessMemoryInfo = _kernel32
    .lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>, Uint32), int Function(int, Pointer<Uint8>, int)>('K32GetProcessMemoryInfo');
