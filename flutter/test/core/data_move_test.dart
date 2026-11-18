import 'dart:io';

import 'package:cascade/core/data_move.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root, from, to;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('cascade-move');
    from = Directory('${root.path}/xyz.chaosinc.cascade');
    to = Directory('${root.path}/xyz.chaosinc.cascade.flutter');
    await Directory('${from.path}/downloads').create(recursive: true);
    await File('${from.path}/downloads/song.flac').writeAsString('audio');
    await File('${from.path}/shared_preferences.json').writeAsString('{"flutter.token":"t"}');
  });
  tearDown(() => root.delete(recursive: true));

  test('moves everything over, past an empty folder a first launch made', () async {
    await Directory('${to.path}/downloads/covers').create(recursive: true);
    expect(await moveAppData(from, to), isTrue);
    expect(await File('${to.path}/shared_preferences.json').readAsString(), contains('token'));
    expect(await File('${to.path}/downloads/song.flac').readAsString(), 'audio');
    expect(await from.exists(), isFalse, reason: 'the old folder goes once empty');
  });

  test('leaves things alone once the new folder has settings', () async {
    await to.create(recursive: true);
    await File('${to.path}/shared_preferences.json').writeAsString('{}');
    expect(await moveAppData(from, to), isFalse);
    expect(await File('${from.path}/downloads/song.flac').exists(), isTrue);
  });

  test('keeps anything with content already in the new folder', () async {
    await Directory('${to.path}/downloads').create(recursive: true);
    await File('${to.path}/downloads/new.flac').writeAsString('new');
    await moveAppData(from, to);
    expect(await File('${to.path}/downloads/new.flac').exists(), isTrue);
    expect(await File('${from.path}/downloads/song.flac').exists(), isTrue, reason: 'not overwritten, left where it was');
    expect(await File('${to.path}/shared_preferences.json').exists(), isTrue);
  });
}
