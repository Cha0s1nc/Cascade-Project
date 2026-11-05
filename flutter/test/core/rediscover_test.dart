import 'package:flutter_test/flutter_test.dart';

import 'package:cascade/core/rediscover.dart';

void main() {
  final now = DateTime.utc(2026, 11, 4);
  String ago(int days) => now.subtract(Duration(days: days)).toIso8601String();
  Map<String, dynamic> song(String album, int plays, String? last, {bool fav = false, String id = 's'}) => {
    'Id': id,
    'Type': 'Audio',
    'AlbumId': album,
    'UserData': {'PlayCount': plays, 'LastPlayedDate': last, 'IsFavorite': fav},
  };
  Map<String, dynamic> album(String id, {int addedDaysAgo = 1000, bool fav = false}) => {
    'Id': id,
    'Type': 'MusicAlbum',
    'DateCreated': ago(addedDaysAgo),
    'UserData': {'IsFavorite': fav},
  };

  test('plays roll up per album with the latest play', () {
    final p = albumPlays([song('a', 3, ago(10)), song('a', 4, ago(2)), song('b', 0, null)]);
    expect(p['a']!.plays, 7);
    expect(p['a']!.last, DateTime.parse(ago(2)));
    expect(p['b']!.plays, 0);
    expect(p['b']!.last, isNull);
  });

  test('used to love: 20 plays or more, none in a year', () {
    final s = rediscover(
      [album('loved'), album('recent'), album('few')],
      [song('loved', 25, ago(400)), song('recent', 30, ago(20)), song('few', 5, ago(500))],
      now,
    );
    expect(s.usedToLove.map((a) => a['Id']), ['loved']);
  });

  test('never played: no plays and in the library six months', () {
    final s = rediscover([album('old'), album('new', addedDaysAgo: 30), album('heard')], [song('heard', 1, ago(3))], now);
    expect(s.neverPlayed.map((a) => a['Id']), ['old']);
  });

  test('forgotten favorites: liked, idle six months, songs and albums', () {
    final s = rediscover(
      [album('favIdle', fav: true), album('favFresh', fav: true)],
      [song('favFresh', 2, ago(10)), song('x', 1, ago(300), fav: true, id: 'likedSong'), song('y', 1, ago(5), fav: true, id: 'freshSong')],
      now,
    );
    expect(s.forgotten.map((i) => i['Id']).toSet(), {'favIdle', 'likedSong'});
  });

  test('the daily shuffle holds all day and changes the next', () {
    final items = List.generate(30, (i) => i);
    final morning = dailyShuffle(items, DateTime(2026, 11, 4, 8));
    expect(dailyShuffle(items, DateTime(2026, 11, 4, 22)), morning);
    expect(dailyShuffle(items, DateTime(2026, 11, 5, 8)), isNot(morning));
    expect(morning.toSet(), items.toSet());
  });
}
