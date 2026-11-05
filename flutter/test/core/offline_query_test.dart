// Ported from desktop/test/offline-query.test.ts: the engine against the shared
// cases in shared/fixtures/offline-query.json, plus the desktop-only details.
import 'dart:convert';
import 'dart:io';

import 'package:cascade/core/offline_index.dart';
import 'package:cascade/core/offline_query.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every key of [expected] matches in [actual]; lists match element by element and must be the same length.
void partial(Object? actual, Object? expected, String at) {
  if (expected is List) {
    expect(actual, isA<List>(), reason: '$at is not a list');
    final a = actual as List;
    expect(a.length, expected.length, reason: '$at length');
    for (var i = 0; i < expected.length; i++) {
      partial(a[i], expected[i], '$at[$i]');
    }
  } else if (expected is Map) {
    expect(actual, isA<Map>(), reason: '$at is not an object');
    expected.forEach((k, v) => partial((actual as Map)[k], v, '$at.$k'));
  } else {
    expect(actual, expected, reason: at);
  }
}

void main() {
  final fixture = jsonDecode(File('../shared/fixtures/offline-query.json').readAsStringSync()) as Map<String, dynamic>;
  final catalog = parseIndex(fixture['catalog']);

  List<String> idsOf(Object? body) {
    final items = body is List ? body : ((body as Map)['Items'] as List? ?? const []);
    return [for (final i in items) (i as Map)['Id'] as String];
  }

  test('the catalog fixture reads back whole', () {
    expect(catalog.tracks.length, (fixture['catalog']['tracks'] as Map).length);
    expect(catalog.collections.length, (fixture['catalog']['collections'] as List).length);
  });

  for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
    test('shared case: ${c['name']}', () {
      final answer = answerOffline(catalog, c['path'] as String, (c['params'] as Map).cast<String, Object?>(), () => 0);
      expect(answer.status, c['status'] ?? 200);
      expect(answer.unknownRoute, c['unknownRoute'] == true, reason: 'unknownRoute');
      if (c['ids'] != null) expect(idsOf(answer.body), c['ids']);
      if (c['total'] != null) expect((answer.body as Map)['TotalRecordCount'], c['total']);
      if (c['body'] != null) partial(answer.body, c['body'], 'body');
    });
  }

  test('SortBy=Random shuffles with the given source and keeps every item', () {
    List<String> ask(double Function() r) => idsOf(answerOffline(catalog, '/Items', {'IncludeItemTypes': 'Audio', 'SortBy': 'Random'}, r).body);
    final sorted = ask(() => 0)..sort();
    expect(ask(() => 0.999)..sort(), sorted);
    expect(ask(() => 0), isNot(ask(() => 0.999)));
  });

  test('a query string on the path is read like params', () {
    final a = answerOffline(catalog, '/Items?IncludeItemTypes=Playlist').body;
    expect(idsOf(a), ['pls1']);
  });

  test('an empty catalog answers empty lists, not errors', () {
    final empty = parseIndex(null);
    for (final path in ['/Items', '/Artists', '/MusicGenres', '/UserViews', '/Shows/NextUp']) {
      final a = answerOffline(empty, path);
      expect(a.status, 200, reason: path);
      expect((a.body as Map)['Items'], isEmpty, reason: path);
    }
    expect(answerOffline(empty, '/Users/me').status, 404);
  });

  test("the placeholder ids are the catalog's", () {
    expect(placeholderLibraryIds(), placeholderLibraries.values.map((l) => l['Id']).toList());
  });

  test('one engine answers many requests over the same catalog', () {
    final engine = offlineQuery(catalog);
    final a = engine.answer('/Items', {'IncludeItemTypes': 'Audio'}, () => 0);
    final b = engine.answer('/Items', {'IncludeItemTypes': 'Audio'}, () => 0);
    expect(idsOf(a.body), idsOf(b.body));
  });
}
