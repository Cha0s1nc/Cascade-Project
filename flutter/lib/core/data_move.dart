// The Linux app id changed from xyz.chaosinc.cascade to
// xyz.chaosinc.cascade.flutter (apart from the Electron app), and with it the
// folder Flutter keeps everything in: settings and sign-in, saved lists, the
// cover cache, downloads. Moved over once, before anything reads them, so an
// upgrade does not sign the person out or lose their downloads.
import 'dart:io';

/// Moves what is in [from] into [to] when [to] has no settings yet. A folder
/// already in [to] with no files in it (made by a first launch) gives way;
/// anything else there is kept. [from] is removed if it ends up empty. True when
/// something moved.
Future<bool> moveAppData(Directory from, Directory to) async {
  if (!await from.exists()) return false;
  if (await File('${to.path}/shared_preferences.json').exists()) return false;
  await to.create(recursive: true);
  var moved = false;
  await for (final e in from.list()) {
    final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final target = '${to.path}/$name';
    final there = await FileSystemEntity.type(target);
    if (there == FileSystemEntityType.directory && !await _hasFiles(Directory(target))) {
      await Directory(target).delete(recursive: true);
    } else if (there != FileSystemEntityType.notFound) {
      continue;
    }
    await e.rename(target);
    moved = true;
  }
  if (await from.list().isEmpty) await from.delete();
  return moved;
}

/// Whether [d] holds any file, however deep: a first launch makes empty
/// folders inside folders.
Future<bool> _hasFiles(Directory d) => d.list(recursive: true).any((e) => e is File);

/// The old folder beside [current] (the new id's own), on Linux only.
Directory? oldLinuxDataDir(Directory current) {
  if (!Platform.isLinux || !current.path.endsWith('xyz.chaosinc.cascade.flutter')) return null;
  return Directory(current.path.substring(0, current.path.length - '.flutter'.length));
}
