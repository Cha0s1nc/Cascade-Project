// Ported from desktop/test/smart-playlist.test.ts.
import 'dart:convert';

import 'package:cascade/core/smart_playlist.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> item(String id, [Map<String, dynamic> over = const {}]) => {'Id': id, ...over};
final now = DateTime.parse('2026-09-27T00:00:00Z').millisecondsSinceEpoch;

SmartPlaylistDef baseDef([Map<String, Object?> over = const {}]) => {
  'id': 'user:1',
  'name': 'Test',
  'match': 'all',
  'rules': <Object?>[],
  'sortBy': 'name',
  'sortDir': 'asc',
  'limit': 100,
  ...over,
};
List ids(List<Map<String, dynamic>> l) => l.map((i) => i['Id']).toList();

void main() {
  test('parseSmartPlaylists: empty/missing input is an empty list, not a crash', () {
    expect(parseSmartPlaylists(null), isEmpty);
    expect(parseSmartPlaylists(''), isEmpty);
  });

  test('parseSmartPlaylists: malformed JSON, or a non-array, is dropped entirely', () {
    expect(parseSmartPlaylists('{not json'), isEmpty);
    expect(parseSmartPlaylists('{"id":"user:1"}'), isEmpty);
  });

  test('parseSmartPlaylists: a def missing name or id is dropped, valid ones kept', () {
    final out = parseSmartPlaylists(
      jsonEncode([
        {'id': 'user:1', 'name': 'Good', 'rules': []},
        {'id': 'user:2', 'rules': []},
        {'name': 'No id', 'rules': []},
      ]),
    );
    expect(out.map((d) => d['id']), ['user:1']);
  });

  test('parseSmartPlaylists: unknown rule fields/ops are dropped, valid rules kept', () {
    final out = parseSmartPlaylists(
      jsonEncode([
        {
          'id': 'user:1',
          'name': 'Mix',
          'rules': [
            {'field': 'genre', 'op': 'is', 'value': 'Rock'},
            {'field': 'genre', 'op': 'contains', 'value': 'Rock'},
            {'field': 'telepathy', 'op': 'is', 'value': true},
            {'field': 'favorite', 'op': 'is', 'value': 'yes'},
          ],
        },
      ]),
    );
    expect(out.length, 1);
    expect(out[0]['rules'], [
      {'field': 'genre', 'op': 'is', 'value': 'Rock'},
    ]);
  });

  test('parseSmartPlaylists: garbage limit/match/sort fall back to safe defaults', () {
    final out = parseSmartPlaylists(
      jsonEncode([
        {'id': 'user:1', 'name': 'Garbage', 'match': 'xyz', 'sortBy': 'xyz', 'sortDir': 'xyz', 'limit': 'a lot please', 'rules': []},
      ]),
    );
    expect(out[0]['match'], 'all');
    expect(out[0]['sortBy'], 'name');
    expect(out[0]['sortDir'], 'asc');
    expect(out[0]['limit'], 100);
  });

  test('parseSmartPlaylists: limit is clamped to the allowed range', () {
    final out = parseSmartPlaylists(
      jsonEncode([
        {'id': 'user:1', 'name': 'Huge', 'limit': 999999, 'rules': []},
        {'id': 'user:2', 'name': 'Negative', 'limit': -5, 'rules': []},
      ]),
    );
    expect(out[0]['limit'], 500);
    expect(out[1]['limit'], 1);
  });

  test('parseSmartPlaylists: year rule min/max are clamped and ordered', () {
    final out = parseSmartPlaylists(
      jsonEncode([
        {
          'id': 'user:1',
          'name': 'Years',
          'rules': [
            {'field': 'year', 'op': 'between', 'min': 3000, 'max': 1},
          ],
        },
      ]),
    );
    final rule = (out[0]['rules'] as List)[0] as Map;
    expect(rule['min'] as int <= (rule['max'] as int), isTrue);
    expect(rule['max'] as int <= 2100, isTrue);
  });

  test('serializeSmartPlaylists round-trips through parseSmartPlaylists', () {
    final defs = [
      baseDef({
        'rules': [
          {'field': 'favorite', 'op': 'is', 'value': true},
        ],
      }),
    ];
    expect(parseSmartPlaylists(serializeSmartPlaylists(defs)), defs);
  });

  test('toItemsQuery: ANY match pushes nothing', () {
    expect(
      toItemsQuery(
        baseDef({
          'match': 'any',
          'rules': [
            {'field': 'genre', 'op': 'is', 'value': 'Rock'},
          ],
        }),
      ),
      isEmpty,
    );
  });

  test('toItemsQuery: ALL match translates favorite/played/genre/artist', () {
    final def = baseDef({
      'rules': [
        {'field': 'genre', 'op': 'is', 'value': 'Rock'},
        {'field': 'artist', 'op': 'is', 'value': 'Aurora Vale'},
        {'field': 'played', 'op': 'is', 'value': true},
        {'field': 'favorite', 'op': 'is', 'value': true},
      ],
    });
    expect(toItemsQuery(def), {'Genres': 'Rock', 'Artists': 'Aurora Vale', 'IsPlayed': true, 'IsFavorite': true});
  });

  test('toItemsQuery: a second genre-is rule in ALL match is not merged in', () {
    final def = baseDef({
      'rules': [
        {'field': 'genre', 'op': 'is', 'value': 'Rock'},
        {'field': 'genre', 'op': 'is', 'value': 'Jazz'},
      ],
    });
    expect(toItemsQuery(def), {'Genres': 'Rock'});
  });

  test('toItemsQuery: genre isNot, addedWithinDays and playCount stay client-side only', () {
    final def = baseDef({
      'rules': [
        {'field': 'genre', 'op': 'isNot', 'value': 'Jazz'},
        {'field': 'addedWithinDays', 'op': 'lte', 'days': 7},
        {'field': 'playCount', 'op': 'gte', 'value': 3},
      ],
    });
    expect(toItemsQuery(def), isEmpty);
  });

  test('toItemsQuery: a narrow year range becomes an explicit Years list, a wide one is left unpushed', () {
    expect(
      toItemsQuery(
        baseDef({
          'rules': [
            {'field': 'year', 'op': 'between', 'min': 1980, 'max': 1982},
          ],
        }),
      ),
      {'Years': '1980,1981,1982'},
    );
    expect(
      toItemsQuery(
        baseDef({
          'rules': [
            {'field': 'year', 'op': 'between', 'min': 1000, 'max': 2100},
          ],
        }),
      ),
      isEmpty,
    );
  });

  test('toItemsQuery invariant: filtering its own query result by the rules gives the same answer as filtering everything', () {
    final library = [
      item('1', {
        'Genres': ['Rock'],
        'UserData': {'IsFavorite': true},
      }),
      item('2', {
        'Genres': ['Rock'],
        'UserData': {'IsFavorite': false},
      }),
      item('3', {
        'Genres': ['Jazz'],
        'UserData': {'IsFavorite': true},
      }),
    ];
    final def = baseDef({
      'rules': [
        {'field': 'genre', 'op': 'is', 'value': 'Rock'},
        {'field': 'favorite', 'op': 'is', 'value': true},
      ],
    });
    final q = toItemsQuery(def);
    final served = library.where(
      (i) =>
          (q['Genres'] == null || (i['Genres'] as List).contains(q['Genres'])) &&
          (q['IsFavorite'] == null || ((i['UserData'] as Map)['IsFavorite'] == true) == q['IsFavorite']),
    );
    expect(ids(served.where((i) => matchesRules(i, def, now)).toList()), ids(library.where((i) => matchesRules(i, def, now)).toList()));
    expect(ids(library.where((i) => matchesRules(i, def, now)).toList()), ['1']);
  });

  test('ruleMatches: genre is/isNot, case-insensitive', () {
    final t = item('1', {
      'Genres': ['rock', 'Blues'],
    });
    expect(ruleMatches(t, {'field': 'genre', 'op': 'is', 'value': 'Rock'}, now), isTrue);
    expect(ruleMatches(t, {'field': 'genre', 'op': 'isNot', 'value': 'Rock'}, now), isFalse);
    expect(ruleMatches(t, {'field': 'genre', 'op': 'is', 'value': 'Jazz'}, now), isFalse);
    expect(ruleMatches(t, {'field': 'genre', 'op': 'isNot', 'value': 'Jazz'}, now), isTrue);
  });

  test('ruleMatches: artist matches either the Artists list or AlbumArtist', () {
    final t = item('1', {
      'Artists': ['Feature Guy'],
      'AlbumArtist': 'Aurora Vale',
    });
    expect(ruleMatches(t, {'field': 'artist', 'op': 'is', 'value': 'Aurora Vale'}, now), isTrue);
    expect(ruleMatches(t, {'field': 'artist', 'op': 'is', 'value': 'Feature Guy'}, now), isTrue);
    expect(ruleMatches(t, {'field': 'artist', 'op': 'is', 'value': 'Nobody'}, now), isFalse);
  });

  test('ruleMatches: year between is inclusive, missing year never matches', () {
    const r = {'field': 'year', 'op': 'between', 'min': 1980, 'max': 1989};
    expect(ruleMatches(item('1', {'ProductionYear': 1985}), r, now), isTrue);
    expect(ruleMatches(item('1', {'ProductionYear': 1990}), r, now), isFalse);
    expect(ruleMatches(item('1'), r, now), isFalse);
  });

  test('ruleMatches: addedWithinDays uses the passed-in clock, and rejects a bad date', () {
    const rule = {'field': 'addedWithinDays', 'op': 'lte', 'days': 7};
    String ago(int days) => DateTime.fromMillisecondsSinceEpoch(now - days * 24 * 60 * 60 * 1000, isUtc: true).toIso8601String();
    expect(ruleMatches(item('1', {'DateCreated': ago(3)}), rule, now), isTrue);
    expect(ruleMatches(item('2', {'DateCreated': ago(30)}), rule, now), isFalse);
    expect(ruleMatches(item('3', {'DateCreated': 'not-a-date'}), rule, now), isFalse);
    expect(ruleMatches(item('4'), rule, now), isFalse);
  });

  test('ruleMatches: played, playCount, favorite with missing UserData', () {
    expect(
      ruleMatches(
        item('1', {
          'UserData': {'Played': true},
        }),
        {'field': 'played', 'op': 'is', 'value': true},
        now,
      ),
      isTrue,
    );
    expect(ruleMatches(item('2'), {'field': 'played', 'op': 'is', 'value': false}, now), isTrue);
    expect(ruleMatches(item('2'), {'field': 'played', 'op': 'is', 'value': true}, now), isFalse);
    expect(
      ruleMatches(
        item('1', {
          'UserData': {'PlayCount': 5},
        }),
        {'field': 'playCount', 'op': 'gte', 'value': 3},
        now,
      ),
      isTrue,
    );
    expect(ruleMatches(item('2'), {'field': 'playCount', 'op': 'gte', 'value': 1}, now), isFalse);
    expect(
      ruleMatches(
        item('1', {
          'UserData': {'IsFavorite': true},
        }),
        {'field': 'favorite', 'op': 'is', 'value': true},
        now,
      ),
      isTrue,
    );
    expect(ruleMatches(item('2'), {'field': 'favorite', 'op': 'is', 'value': false}, now), isTrue);
  });

  test('matchesRules: no rules matches everything; ALL requires every rule, ANY at least one', () {
    expect(matchesRules(item('1'), baseDef(), now), isTrue);
    final rules = [
      {'field': 'genre', 'op': 'is', 'value': 'Rock'},
      {'field': 'favorite', 'op': 'is', 'value': true},
    ];
    final both = item('1', {
      'Genres': ['Rock'],
      'UserData': {'IsFavorite': true},
    });
    final onlyGenre = item('2', {
      'Genres': ['Rock'],
      'UserData': {'IsFavorite': false},
    });
    expect(matchesRules(both, baseDef({'rules': rules}), now), isTrue);
    expect(matchesRules(onlyGenre, baseDef({'rules': rules}), now), isFalse);
    expect(matchesRules(onlyGenre, baseDef({'match': 'any', 'rules': rules}), now), isTrue);
  });

  test('applySmartPlaylistRules: filters, sorts by name ascending, and limits', () {
    final items = [
      item('b', {
        'Name': 'Banana',
        'Genres': ['Rock'],
      }),
      item('a', {
        'Name': 'Apple',
        'Genres': ['Rock'],
      }),
      item('c', {
        'Name': 'Carrot',
        'Genres': ['Jazz'],
      }),
    ];
    final def = baseDef({
      'rules': [
        {'field': 'genre', 'op': 'is', 'value': 'Rock'},
      ],
      'limit': 1,
    });
    expect(ids(applySmartPlaylistRules(items, def, now)), ['a']);
  });

  test('applySmartPlaylistRules: sortDir desc reverses the order', () {
    final items = [
      item('a', {'Name': 'Apple'}),
      item('b', {'Name': 'Banana'}),
    ];
    expect(ids(applySmartPlaylistRules(items, baseDef({'sortDir': 'desc'}), now)), ['b', 'a']);
  });

  test('applySmartPlaylistRules: sortBy name is by title, not the track-numbered SortName', () {
    final items = [
      item('o2', {'Name': 'Overdrive Track 2', 'SortName': '0002 - Overdrive Track 2'}),
      item('u1', {'Name': 'Unplugged Track 1', 'SortName': '0001 - Unplugged Track 1'}),
      item('o10', {'Name': 'Overdrive Track 10', 'SortName': '0010 - Overdrive Track 10'}),
    ];
    expect(ids(applySmartPlaylistRules(items, baseDef(), now)), ['o2', 'o10', 'u1']);
  });

  test('applySmartPlaylistRules: sortBy playCount, and it does not mutate the input', () {
    final items = [
      item('a', {
        'UserData': {'PlayCount': 1},
      }),
      item('b', {
        'UserData': {'PlayCount': 9},
      }),
    ];
    final out = applySmartPlaylistRules(items, baseDef({'sortBy': 'playCount', 'sortDir': 'desc'}), now);
    expect(ids(out), ['b', 'a']);
    expect(items[0]['Id'], 'a');
  });
}
