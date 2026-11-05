// Ported from desktop/test/artist-page.test.ts.
import 'package:cascade/core/artist_page.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> item(String id, [String? name, int? plays]) => {'Id': id, 'Name': ?name, if (plays != null) 'UserData': {'PlayCount': plays}};
List ids(List<Map<String, dynamic>> l) => l.map((i) => i['Id']).toList();

void main() {
  test('topSongsOf: orders by PlayCount descending', () {
    expect(ids(topSongsOf([item('a', 'A', 1), item('b', 'B', 5), item('c', 'C', 3)])), ['b', 'c', 'a']);
  });

  test('topSongsOf: a track with no plays is excluded, not crashed on', () {
    expect(ids(topSongsOf([item('a', 'A'), item('b', 'B', 2)])), ['b']);
  });

  test('topSongsOf: nobody has played anything yet - empty', () {
    expect(topSongsOf([item('a', 'A'), item('b', 'B')]), isEmpty);
  });

  test('topSongsOf: ties break alphabetically by name', () {
    expect(ids(topSongsOf([item('z', 'Zebra', 4), item('a', 'Apple', 4)])), ['a', 'z']);
  });

  test('topSongsOf: clamped to max, does not mutate the input', () {
    final songs = List.generate(15, (i) => item('$i', '$i', i));
    final top = topSongsOf(songs);
    expect(top.length, 10);
    expect(top[0]['Id'], '14');
    expect(songs.length, 15);
  });

  test('topSongsOf: custom max is respected', () {
    expect(topSongsOf(List.generate(8, (i) => item('$i', '$i', i)), 5).length, 5);
  });
}
