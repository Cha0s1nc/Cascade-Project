// Rediscover (docs/flutter-plan.md, Design): three shelves built from what
// Jellyfin already keeps per song, its play count and last play, rolled up
// per album. Pure, so every app can share the same rules and tests.
//
// - Used to love: albums played 20 times or more, not played in a year.
// - Never played: albums in the library six months or more, never played.
// - Forgotten favorites: liked songs and albums not played in six months.
//
// Each shelf reshuffles once a day: the order is seeded by the date.
import 'dart:math';

import 'package:cascade/core/jellyfin.dart';

const usedToLovePlays = 20;
const usedToLoveIdle = Duration(days: 365);
const neverPlayedAge = Duration(days: 182);
const forgottenIdle = Duration(days: 182);

typedef AlbumPlays = ({int plays, DateTime? last});

DateTime? _date(Object? s) => s is String ? DateTime.tryParse(s) : null;

/// Each album's plays and last play, summed from its songs.
Map<String, AlbumPlays> albumPlays(List<Item> songs) {
  final out = <String, AlbumPlays>{};
  for (final s in songs) {
    final id = s['AlbumId'] as String?;
    if (id == null) continue;
    final ud = s['UserData'] as Map? ?? const {};
    final plays = ud['PlayCount'] as int? ?? 0;
    final last = _date(ud['LastPlayedDate']);
    final was = out[id];
    final before = was?.last;
    final keep = before == null || (last != null && last.isAfter(before)) ? last : before;
    out[id] = (plays: (was?.plays ?? 0) + plays, last: keep);
  }
  return out;
}

/// The day's order: the same all day, different tomorrow.
List<T> dailyShuffle<T>(List<T> items, DateTime now) {
  final day = DateTime(now.year, now.month, now.day).difference(DateTime(2000)).inDays;
  return [...items]..shuffle(Random(day));
}

typedef Shelves = ({List<Item> usedToLove, List<Item> neverPlayed, List<Item> forgotten});

/// The three shelves from the albums and songs the library already loaded.
Shelves rediscover(List<Item> albums, List<Item> songs, DateTime now) {
  final plays = albumPlays(songs);
  bool idle(DateTime? last, Duration d) => last == null || now.difference(last) >= d;

  final usedToLove = [
    for (final a in albums)
      if ((plays[a['Id']]?.plays ?? 0) >= usedToLovePlays && idle(plays[a['Id']]?.last, usedToLoveIdle)) a,
  ];
  final neverPlayed = [
    for (final a in albums)
      if ((plays[a['Id']]?.plays ?? 0) == 0 && (_date(a['DateCreated']) != null && now.difference(_date(a['DateCreated'])!) >= neverPlayedAge)) a,
  ];
  final forgotten = [
    for (final a in albums)
      if ((a['UserData'] as Map?)?['IsFavorite'] == true && idle(plays[a['Id']]?.last, forgottenIdle)) a,
    for (final s in songs)
      if ((s['UserData'] as Map?)?['IsFavorite'] == true && idle(_date((s['UserData'] as Map?)?['LastPlayedDate']), forgottenIdle)) s,
  ];
  return (usedToLove: dailyShuffle(usedToLove, now), neverPlayed: dailyShuffle(neverPlayed, now), forgotten: dailyShuffle(forgotten, now));
}
