// Queue ordering: song sorting, shuffling, play-next, repeat, and the queue
// panel's time maths. Pure. Ported from desktop/src/core/queue.ts. The saved
// queue (savedQueueOf and friends) already lives in playback.dart.
import 'dart:math';

import 'jellyfin.dart' show Item;

num _ms(Object? iso) => iso is String ? (DateTime.tryParse(iso)?.millisecondsSinceEpoch ?? 0) : 0;

String _lower(Object? v) => v is String ? v.toLowerCase() : '';

/// First non-empty of AlbumArtist or Artists[0], lowercased.
String artistKey(Item item) {
  final aa = item['AlbumArtist'];
  if (aa is String && aa.isNotEmpty) return aa.toLowerCase();
  final a = item['Artists'];
  return a is List && a.isNotEmpty ? _lower(a.first) : '';
}

/// Sort key for a track: a lowercased String or epoch millis. Unknown fields sort by name.
Comparable<Object> songSortValue(Item item, String field) {
  switch (field) {
    case 'artist':
      return artistKey(item);
    case 'album':
      return _lower(item['Album']);
    case 'added':
      return _ms(item['DateCreated']);
    case 'played':
      return _ms((item['UserData'] as Map?)?['LastPlayedDate']);
    default:
      return _lower(item['Name']);
  }
}

int compareSortValues(Comparable<Object> a, Comparable<Object> b) => a is String ? a.compareTo(b as String) : (a as num).compareTo(b as num);

/// Sorts tracks in place and returns the same list. Stable, ties keep their order.
List<Item> sortSongs(List<Item> items, String field, String direction) {
  final dir = direction == 'desc' ? -1 : 1;
  // List.sort is not stable in Dart, so decorate with the index.
  final keyed = [for (var i = 0; i < items.length; i++) (i, items[i], songSortValue(items[i], field))];
  keyed.sort((a, b) {
    final c = compareSortValues(a.$3, b.$3) * dir;
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < keyed.length; i++) {
    items[i] = keyed[i].$2;
  }
  return items;
}

final _rng = Random();

/// Fisher-Yates in place. Returns the same list. Not for anything that must resist prediction.
List<T> shuffleInPlace<T>(List<T> arr, [Random? rng]) {
  final r = rng ?? _rng;
  for (var i = arr.length - 1; i > 0; i--) {
    final j = r.nextInt(i + 1);
    final t = arr[i];
    arr[i] = arr[j];
    arr[j] = t;
  }
  return arr;
}

/// Fisher-Yates on a copy, leaving the input untouched.
List<T> shuffled<T>(Iterable<T> items, [Random? rng]) => shuffleInPlace([...items], rng);

/// A new queue with [items] right after the playing track ("Play next").
List<T> insertAfterCurrent<T>(List<T> queue, int queueIndex, List<T> items) {
  final at = min(queue.length, max(0, queueIndex + 1));
  return [...queue.take(at), ...items, ...queue.skip(at)];
}

/// Index that follows [queueIndex] honoring repeat ('one', 'all', else off), or null.
int? nextQueueIndex(int queueLength, int queueIndex, String repeatMode) {
  if (repeatMode == 'one') return null;
  final next = queueIndex + 1;
  if (next >= queueLength) return repeatMode == 'all' ? 0 : null;
  return next;
}

/// Seconds left in the queue: the rest of the current track plus all after it.
double queueRemainingSec(List<Item> queue, int queueIndex, double positionSec) {
  if (queueIndex < 0 || queueIndex >= queue.length) return 0;
  double len(int i) => ((queue[i]['RunTimeTicks'] as num?) ?? 0) / 10000000;
  var total = max(0.0, len(queueIndex) - max(0.0, positionSec.isNaN ? 0 : positionSec));
  for (var i = queueIndex + 1; i < queue.length; i++) {
    total += len(i);
  }
  return total;
}

/// A long span as the queue panel shows it: "1d 1h", "2h 5m", "34m", "<1m".
String formatQueueSpan(double sec) {
  final m = (max(0.0, sec) / 60).floor();
  if (m < 1) return '<1m';
  final d = m ~/ 1440, h = (m ~/ 60) % 24, min = m % 60;
  if (d > 0) return h > 0 ? '${d}d ${h}h' : '${d}d';
  if (h > 0) return min > 0 ? '${h}h ${min}m' : '${h}h';
  return '${min}m';
}

/// The album's name when every track is from one album, otherwise null.
String? queueSourceFallback(List<Item> items) {
  if (items.isEmpty) return null;
  final first = items.first;
  final id = first['AlbumId'], name = first['Album'];
  if (id is! String || id.isEmpty || name is! String || name.isEmpty) return null;
  return items.every((t) => t['AlbumId'] == id) ? name : null;
}

/// A queue after a clear, and where the playing track sits in it.
typedef TrimmedQueue<T> = ({List<T> queue, int index});

/// "Clear queue": keep only the playing track. Nothing playing empties it.
TrimmedQueue<T> trimToCurrent<T>(List<T> queue, int queueIndex) =>
    queueIndex < 0 || queueIndex >= queue.length ? (queue: <T>[], index: -1) : (queue: [queue[queueIndex]], index: 0);

/// "Clear" on Up Next: drop what follows the playing track, the index stays.
TrimmedQueue<T> clearUpNext<T>(List<T> queue, int queueIndex) =>
    queueIndex < 0 || queueIndex >= queue.length ? (queue: <T>[], index: -1) : (queue: queue.sublist(0, queueIndex + 1), index: queueIndex);
