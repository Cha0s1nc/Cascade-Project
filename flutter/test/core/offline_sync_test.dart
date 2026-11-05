// Ported from the shared-fixture cases in desktop/test/offline-sync.test.ts
// (the catalog tests there belong to offline-index.ts, which is not ported).
// Reads the same shared/fixtures/offline-sync.json.
import 'dart:convert';
import 'dart:io';

import 'package:cascade/core/offline_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fx = jsonDecode(File('../shared/fixtures/offline-sync.json').readAsStringSync()) as Map<String, dynamic>;
  List<Map<String, dynamic>> maps(Object? l) => [for (final x in l as List) (x as Map).cast<String, dynamic>()];

  for (final c in maps(fx['coalesce'])) {
    test('coalesce: ${c['name']}', () => expect(coalesceChanges(maps(c['changes'])), c['expected']));
  }
  for (final c in maps(fx['decide'])) {
    test('conflict: ${c['name']}', () => expect(updateToSend((c['update'] as Map).cast<String, Object?>(), (c['server'] as Map?)?.cast<String, dynamic>()), c['expected']));
  }
  for (final c in maps(fx['catchUp'])) {
    test('catch-up: ${c['name']}', () {
      final r = playsCatchUp(maps(c['plays']), (c['history'] as Map?)?.cast<String, dynamic>(), c['playsHeld'] as bool, maps(c['server']));
      expect(r, c['expected']);
    });
  }
  test('plays replay oldest first, ties in queue order', () {
    final r = fx['replayOrder'] as Map;
    expect(playsOldestFirst(maps(r['plays'])).map((p) => p['itemId']), r['expected']);
  });

  test("the history query asks for the snapshot's 200 rows across every library", () {
    expect(historyQuery['Limit'], '200');
    expect(historyQuery['IncludeItemTypes'], 'Audio,Movie,Episode');
    expect(historyQuery.containsKey('ParentId'), isFalse);
  });
}
