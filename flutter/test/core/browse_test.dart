// Ported from desktop/test/library-browse.test.ts.
import 'package:cascade/core/browse.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> item([Map<String, dynamic> over = const {}]) => {'Id': 'x', 'Name': 'x', ...over};
List ids(List<Map<String, dynamic>> l) => l.map((i) => i['Id']).toList();

void main() {
  test('sortLibraryItems: name falls back to SortName then Name', () {
    final items = [
      item({'Id': '1', 'Name': 'The Beta'}),
      item({'Id': '2', 'Name': 'Alpha'}),
    ];
    expect(ids(sortLibraryItems(items, 'name', 'asc')), ['2', '1']);
  });

  test('sortLibraryItems: year, missing sorts as 0 (first ascending)', () {
    final items = [
      item({'Id': '1', 'ProductionYear': 2020}),
      item({'Id': '2'}),
      item({'Id': '3', 'ProductionYear': 1990}),
    ];
    expect(ids(sortLibraryItems(items, 'year', 'asc')), ['2', '3', '1']);
  });

  test('sortLibraryItems: ties break on name regardless of direction', () {
    final items = [
      item({'Id': '1', 'Name': 'Zeta', 'ProductionYear': 2000}),
      item({'Id': '2', 'Name': 'Alpha', 'ProductionYear': 2000}),
    ];
    expect(ids(sortLibraryItems(items, 'year', 'asc')), ['2', '1']);
    expect(ids(sortLibraryItems(items, 'year', 'desc')), ['2', '1']);
  });

  test('sortLibraryItems: random keeps the same items, does not mutate input', () {
    final items = [
      item({'Id': '1'}),
      item({'Id': '2'}),
      item({'Id': '3'}),
    ];
    final before = ids(items);
    final shuffled = sortLibraryItems(items, 'random', 'asc');
    expect(ids(items), before);
    expect(ids(shuffled)..sort((a, b) => '$a'.compareTo('$b')), ['1', '2', '3']);
  });

  test('filterLibraryItems: favorite, genre, decade, played all narrow independently', () {
    final items = [
      item({
        'Id': '1',
        'UserData': {'IsFavorite': true, 'Played': true},
        'Genres': ['Jazz'],
        'ProductionYear': 1994,
      }),
      item({
        'Id': '2',
        'UserData': {'IsFavorite': false, 'Played': false},
        'Genres': ['Rock'],
        'ProductionYear': 2021,
      }),
    ];
    expect(ids(filterLibraryItems(items, const LibraryFilters(favorite: true))), ['1']);
    expect(ids(filterLibraryItems(items, const LibraryFilters(genre: 'Rock'))), ['2']);
    expect(ids(filterLibraryItems(items, const LibraryFilters(decade: 1990))), ['1']);
    expect(ids(filterLibraryItems(items, const LibraryFilters(played: 'unplayed'))), ['2']);
    expect(ids(filterLibraryItems(items, const LibraryFilters())), ['1', '2']);
  });

  test('filterLibraryItems: an item missing ProductionYear never matches a decade filter', () {
    expect(
      filterLibraryItems([
        item({'Id': '1'}),
      ], const LibraryFilters(decade: 1990)),
      isEmpty,
    );
  });

  test('libraryFilterOptions: only genres/decades actually present, deduped and sorted', () {
    final opts = libraryFilterOptions([
      item({
        'Genres': ['Rock', 'Jazz'],
        'ProductionYear': 1994,
      }),
      item({
        'Genres': ['Jazz'],
        'ProductionYear': 2021,
      }),
      item(),
    ]);
    expect(opts.genres, ['Jazz', 'Rock']);
    expect(opts.decades, [2020, 1990]);
  });

  test('normalizeLibraryPrefs: corrupted store values fall back to defaults, never garbage', () {
    const allowed = ['name', 'year'];
    expect(normalizeLibraryPrefs(null, allowed), (field: 'name', dir: 'asc', favorite: false, genre: null, decade: null, played: null));
    expect(normalizeLibraryPrefs('not json', allowed).field, 'name');
    expect(normalizeLibraryPrefs('{"field":"bogus"}', allowed).field, 'name');
    expect(normalizeLibraryPrefs('{"dir":"sideways"}', allowed).dir, 'asc');
    expect(normalizeLibraryPrefs('{"decade":"1990"}', allowed).decade, isNull);
    expect(normalizeLibraryPrefs('{"decade":NaN}', allowed).decade, isNull);
    expect(normalizeLibraryPrefs('[1,2,3]', allowed).field, 'name');
  });

  test('normalizeLibraryPrefs: a valid, allowed value round-trips', () {
    final p = normalizeLibraryPrefs('{"field":"year","dir":"desc","favorite":true,"genre":"Jazz","decade":1990,"played":"played"}', ['name', 'year']);
    expect(p, (field: 'year', dir: 'desc', favorite: true, genre: 'Jazz', decade: 1990, played: 'played'));
  });

  test('groupByDay: local calendar days, not UTC, using Today/Yesterday labels', () {
    final now = DateTime(2026, 9, 27, 10, 0);
    final items = [
      item({
        'Id': '1',
        'UserData': {'LastPlayedDate': DateTime(2026, 9, 27, 23, 0).toUtc().toIso8601String()},
      }),
      item({
        'Id': '2',
        'UserData': {'LastPlayedDate': DateTime(2026, 9, 27, 9, 0).toUtc().toIso8601String()},
      }),
      item({
        'Id': '3',
        'UserData': {'LastPlayedDate': DateTime(2026, 9, 26, 12, 0).toUtc().toIso8601String()},
      }),
      item({
        'Id': '4',
        'UserData': {'LastPlayedDate': DateTime(2026, 9, 20, 12, 0).toUtc().toIso8601String()},
      }),
      item({
        'Id': '5',
        'UserData': {'LastPlayedDate': DateTime(2025, 3, 2, 12, 0).toUtc().toIso8601String()},
      }),
    ];
    final groups = groupByDay(items, now);
    expect(groups.length, 4);
    expect(groups[0].label, 'Today');
    expect(ids(groups[0].items), ['1', '2']);
    expect(groups[1].label, 'Yesterday');
    expect(ids(groups[1].items), ['3']);
    expect(groups[2].label, 'September 20');
    expect(groups[3].label, 'March 2, 2025');
  });

  test('groupByDay: an item with no parseable play date is dropped, not crashed on', () {
    final items = [
      item({'Id': '1', 'UserData': {}}),
      item({
        'Id': '2',
        'UserData': {'LastPlayedDate': 'garbage'},
      }),
    ];
    expect(groupByDay(items), isEmpty);
  });

  test('collapsedLibs: a JSON array of ids; anything else folds nothing', () {
    expect(parseCollapsedLibs('["a","b"]'), {'a', 'b'});
    expect(parseCollapsedLibs('["a",5,null]'), {'a'});
    for (final bad in [null, '', '{"a":1}', 'not json', '"a"']) {
      expect(parseCollapsedLibs(bad), isEmpty, reason: '$bad');
    }
  });
}
