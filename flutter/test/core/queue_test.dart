// Ported from desktop/test/queue.test.ts.
import 'dart:math';

import 'package:cascade/core/queue.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> item(String id, [Map<String, dynamic> over = const {}]) => {'Id': id, ...over};

void main() {
  test('songSortValue: falls back through artist sources', () {
    expect(songSortValue(item('1', {'AlbumArtist': 'Boards'}), 'artist'), 'boards');
    expect(songSortValue(item('2', {'Artists': ['Aphex']}), 'artist'), 'aphex');
    expect(songSortValue(item('3'), 'artist'), '');
  });

  test('songSortValue: dates become epoch millis, junk becomes 0', () {
    expect(songSortValue(item('1', {'DateCreated': '2020-01-01T00:00:00Z'}), 'added'), DateTime.parse('2020-01-01T00:00:00Z').millisecondsSinceEpoch);
    expect(songSortValue(item('2', {'DateCreated': 'not-a-date'}), 'added'), 0);
    expect(songSortValue(item('3'), 'added'), 0);
  });

  test('songSortValue: unknown field sorts by name', () {
    expect(songSortValue(item('1', {'Name': 'Zebra'}), 'nonsense'), 'zebra');
  });

  test('sortSongs: ascending and descending by name', () {
    final items = [item('1', {'Name': 'Charlie'}), item('2', {'Name': 'alpha'}), item('3', {'Name': 'Bravo'})];
    sortSongs(items, 'name', 'asc');
    expect(items.map((i) => i['Id']), ['2', '3', '1']);
    sortSongs(items, 'name', 'desc');
    expect(items.map((i) => i['Id']), ['1', '3', '2']);
  });

  test('sortSongs: sorts in place and returns the same list', () {
    final items = [item('1', {'Name': 'b'}), item('2', {'Name': 'a'})];
    expect(identical(sortSongs(items, 'name', 'asc'), items), isTrue);
    expect(items[0]['Id'], '2');
  });

  test('shuffleInPlace: keeps every element, mutates the original', () {
    final arr = List.generate(50, (i) => i);
    expect(identical(shuffleInPlace(arr), arr), isTrue);
    expect([...arr]..sort(), List.generate(50, (i) => i));
  });

  test('shuffled: leaves the input untouched', () {
    final original = [1, 2, 3, 4, 5];
    final out = shuffled(original);
    expect(original, [1, 2, 3, 4, 5]);
    expect(identical(out, original), isFalse);
    expect([...out]..sort(), [1, 2, 3, 4, 5]);
  });

  test('shuffled: actually reorders (not a no-op)', () {
    final src = List.generate(40, (i) => i);
    final rng = Random(1);
    final anyDifferent = List.generate(20, (_) => shuffled(src, rng)).any((s) {
      for (var i = 0; i < s.length; i++) {
        if (s[i] != src[i]) return true;
      }
      return false;
    });
    expect(anyDifferent, isTrue);
  });

  test('shuffleInPlace: handles empty and single-element lists', () {
    expect(shuffleInPlace<int>([]), isEmpty);
    expect(shuffleInPlace([7]), [7]);
  });

  test('nextQueueIndex', () {
    expect(nextQueueIndex(5, 0, 'none'), 1);
    expect(nextQueueIndex(5, 3, 'none'), 4);
    expect(nextQueueIndex(5, 4, 'none'), isNull);
    expect(nextQueueIndex(5, 4, 'all'), 0);
    expect(nextQueueIndex(5, 2, 'one'), isNull);
    expect(nextQueueIndex(5, 4, 'one'), isNull);
    expect(nextQueueIndex(0, -1, 'none'), isNull);
  });

  test('insertAfterCurrent', () {
    expect(insertAfterCurrent(['a', 'b', 'c'], 0, ['x']), ['a', 'x', 'b', 'c']);
    expect(insertAfterCurrent(['a', 'b', 'c'], 1, ['x']), ['a', 'b', 'x', 'c']);
    expect(insertAfterCurrent(['a', 'b'], 1, ['x']), ['a', 'b', 'x']);
    expect(insertAfterCurrent(['a', 'b'], -1, ['x']), ['x', 'a', 'b']);
    expect(insertAfterCurrent(['a', 'b'], 0, ['x', 'y', 'z']), ['a', 'x', 'y', 'z', 'b']);
    final original = ['a', 'b', 'c'];
    insertAfterCurrent(original, 0, ['x']);
    expect(original, ['a', 'b', 'c']);
  });

  test('queue remaining: rest of the current track plus everything after it', () {
    Map<String, dynamic> t(int sec) => {'Id': '$sec', 'Name': '', 'RunTimeTicks': sec * 10000000};
    final q = [t(100), t(200), t(300), {'Id': 'x', 'Name': ''}];
    expect(queueRemainingSec(q, 1, 50), 150 + 300);
    expect(queueRemainingSec(q, 1, 999), 300);
    expect(queueRemainingSec(q, 3, 0), 0);
    expect(queueRemainingSec(q, -1, 0), 0);
    expect(queueRemainingSec([], 0, 0), 0);
  });

  test('queue span formatting, up to days', () {
    expect(formatQueueSpan(30), '<1m');
    expect(formatQueueSpan(34 * 60 + 59), '34m');
    expect(formatQueueSpan(2 * 3600 + 5 * 60), '2h 5m');
    expect(formatQueueSpan(3 * 3600), '3h');
    expect(formatQueueSpan(25 * 3600 + 10 * 60), '1d 1h');
    expect(formatQueueSpan(48 * 3600), '2d');
  });

  test('queueSourceFallback', () {
    expect(queueSourceFallback([item('1', {'AlbumId': 'a', 'Album': 'LP'}), item('2', {'AlbumId': 'a', 'Album': 'LP'})]), 'LP');
    expect(queueSourceFallback([item('1', {'AlbumId': 'a', 'Album': 'LP'}), item('2', {'AlbumId': 'b', 'Album': 'LP2'})]), isNull);
    expect(queueSourceFallback([item('1')]), isNull);
    expect(queueSourceFallback([]), isNull);
  });

  test('trimToCurrent and clearUpNext', () {
    final a = trimToCurrent(['a', 'b', 'c'], 1);
    expect(a.queue, ['b']);
    expect(a.index, 0);
    expect(trimToCurrent(['a'], 5).queue, isEmpty);
    expect(trimToCurrent(['a'], 5).index, -1);
    final b = clearUpNext(['a', 'b', 'c'], 1);
    expect(b.queue, ['a', 'b']);
    expect(b.index, 1);
    expect(clearUpNext(['a'], -1).queue, isEmpty);
    expect(clearUpNext(['a'], -1).index, -1);
  });
}
