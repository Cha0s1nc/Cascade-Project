// Ported from the user data cases in desktop/test/local-scan.test.ts.
import 'package:cascade/core/local_user_data.dart';
import 'package:cascade/core/offline_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('favorites, plays and positions are kept as the server would keep them', () {
    final now = DateTime.parse('2026-10-19T12:00:00Z');
    var ud = applyLocalChange(null, {'kind': 'play'}, now);
    expect(ud, {'Played': true, 'PlayCount': 1, 'LastPlayedDate': '2026-10-19T12:00:00.000Z'});
    ud = applyLocalChange(ud, {'kind': 'play'}, now);
    expect(ud['PlayCount'], 2);
    ud = applyLocalChange(ud, {'kind': 'favorite', 'favorite': true}, now);
    expect(ud['IsFavorite'], true);
    ud = applyLocalChange(ud, {'kind': 'position', 'ticks': 5000000}, now);
    expect(ud['PlaybackPositionTicks'], 5000000);
    ud = applyLocalChange(ud, {'kind': 'played', 'played': false}, now);
    expect(ud['Played'], false);
    expect(ud['PlaybackPositionTicks'], 0);
    expect(ud['PlayCount'], 2);
    expect(parseLocalChange({'kind': 'position', 'ticks': 1.6}), {'kind': 'position', 'ticks': 2});
    expect(parseLocalChange({'kind': 'position', 'ticks': -1}), isNull);
    expect(parseLocalChange({'kind': 'favorite'}), isNull);
    expect(parseLocalChange('play'), isNull);
  });

  test('stored user data is checked, and a bad id is dropped', () {
    expect(
      parseUserData({
        'abc123': {'IsFavorite': true, 'PlayCount': -2, 'LastPlayedDate': 'nope'},
        '../x': {'IsFavorite': true},
      }),
      {
        'abc123': {'IsFavorite': true},
      },
    );
    expect(
      parseUserData({
        'abc123': {'PlayCount': 3.7, 'PlaybackPositionTicks': 5.5, 'LastPlayedDate': '2026-10-19T12:00:00Z'},
      }),
      {
        'abc123': {'PlayCount': 3, 'PlaybackPositionTicks': 6, 'LastPlayedDate': '2026-10-19T12:00:00.000Z'},
      },
    );
    expect(parseUserData(null), isEmpty);
  });

  test('user data is written into every copy of an item', () {
    final index = emptyIndex();
    addCollection(
      index,
      {'Id': 'album1', 'Type': 'MusicAlbum'},
      [
        {'Id': 'song1', 'Type': 'Audio', 'AlbumId': 'album1'},
      ],
    );
    setLocalUserData(index, 'album1', {'IsFavorite': true});
    setLocalUserData(index, 'song1', {'IsFavorite': false});
    expect((index.collections[0].item['UserData'] as Map)['IsFavorite'], true);
    expect((index.tracks['song1']!.item['UserData'] as Map)['IsFavorite'], false);
  });
}
