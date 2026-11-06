import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cascade/core/list_cache.dart';

void main() {
  test('changed items replace their copies, new ones are added and counted', () {
    final r = mergeChanged(
      [
        {'Id': 'a', 'Name': 'old'},
        {'Id': 'b', 'Name': 'B'},
      ],
      [
        {'Id': 'a', 'Name': 'new'},
        {'Id': 'c', 'Name': 'C'},
      ],
    );
    expect(r.items.map((i) => i['Name']), ['new', 'B', 'C']);
    expect(r.added, 1);
  });

  test('a list round-trips through disk, keyed by its whole key', () async {
    final dir = await Directory.systemTemp.createTemp('cascade-cache');
    addTearDown(() => dir.delete(recursive: true));
    final c = ListCache(dir);
    final at = DateTime.utc(2026, 11, 6, 12);
    await c.write('server|user|albums|lib1', [
      {'Id': 'a'},
    ], 1, at);
    final back = await c.read('server|user|albums|lib1');
    expect(back!.items, [
      {'Id': 'a'},
    ]);
    expect(back.total, 1);
    expect(back.fetchedAt, at);
    expect(await c.read('server|user|albums|lib2'), isNull);
  });
}
