// Ported from desktop/test/playlist-edit.test.ts (bytesToBase64 is dart:convert).
import 'dart:convert';
import 'dart:typed_data';

import 'package:cascade/core/playlist_edit.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> item(String id, [String? entry]) => {'Id': id, 'PlaylistItemId': ?entry};
List ids(List<Map<String, dynamic>> l) => l.map((i) => i['Id']).toList();

void main() {
  test('entryIdOf: prefers PlaylistItemId, falls back to Id', () {
    expect(entryIdOf(item('track1', 'entry1')), 'entry1');
    expect(entryIdOf(item('track1')), 'track1');
  });

  test('removeSelected: drops selected rows, keeps the rest in order', () {
    final items = [item('a'), item('b'), item('c'), item('d')];
    expect(ids(removeSelected(items, {'b', 'd'})), ['a', 'c']);
  });

  test('removeSelected: empty selection is a no-op copy', () {
    final items = [item('a'), item('b')];
    final out = removeSelected(items, {});
    expect(ids(out), ['a', 'b']);
    expect(identical(out, items), isFalse);
  });

  test('removeSelected: a duplicate track removes only the selected entry', () {
    final out = removeSelected([item('track', 'e1'), item('track', 'e2')], {'e1'});
    expect(out.map((i) => i['PlaylistItemId']), ['e2']);
  });

  test('moveSelectedToTop: pulls selected rows to the front, relative order preserved', () {
    expect(ids(moveSelectedToTop([item('a'), item('b'), item('c'), item('d')], {'c', 'a'})), ['a', 'c', 'b', 'd']);
  });

  test('moveSelectedToBottom: pushes selected rows to the back, relative order preserved', () {
    expect(ids(moveSelectedToBottom([item('a'), item('b'), item('c'), item('d')], {'a', 'c'})), ['b', 'd', 'a', 'c']);
  });

  test('moveSelectedToTop/Bottom: does not mutate the input', () {
    final items = [item('a'), item('b')];
    moveSelectedToTop(items, {'b'});
    expect(ids(items), ['a', 'b']);
  });

  test('moveSelectedToTop: selecting everything or nothing is a no-op order-wise', () {
    final items = [item('a'), item('b'), item('c')];
    expect(ids(moveSelectedToTop(items, {})), ['a', 'b', 'c']);
    expect(ids(moveSelectedToTop(items, {'a', 'b', 'c'})), ['a', 'b', 'c']);
  });

  test('createPlaylistWriteGate: writes to one playlist wait their turn', () async {
    var clock = 1000;
    final slept = <int>[];
    final wait = createPlaylistWriteGate(now: () => clock, sleep: (ms) async => slept.add(ms));
    await wait('a');
    await wait('a');
    await wait('a');
    expect(slept, [400, 800]);
    clock += 2000;
    await wait('a');
    expect(slept, [400, 800]);
  });

  test('createPlaylistWriteGate: other playlists do not wait', () async {
    final slept = <int>[];
    final wait = createPlaylistWriteGate(now: () => 0, sleep: (ms) async => slept.add(ms));
    await wait('a');
    await wait('b');
    expect(slept, isEmpty);
  });

  test('sniffImageType: JPEG, PNG and WebP by their first bytes, nothing else', () {
    Uint8List b(List<int> v) => Uint8List.fromList(v);
    expect(sniffImageType(b([0xff, 0xd8, 0xff, 0xe0, 0, 0])), 'image/jpeg');
    expect(sniffImageType(b([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0])), 'image/png');
    expect(sniffImageType(b([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 0x57, 0x45, 0x42, 0x50])), 'image/webp');
    expect(sniffImageType(b([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 0x57, 0x41, 0x56, 0x45])), isNull);
    expect(sniffImageType(b([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])), isNull);
    expect(sniffImageType(b(utf8.encode('<svg xmlns='))), isNull);
    expect(sniffImageType(b([0xff, 0xd8])), isNull);
    expect(sniffImageType(Uint8List(0)), isNull);
  });

  test('playlistDetailsRoute: the plugin when it offers it, else admins only', () {
    final caps = {'lyrics-read', 'playlist-edit'};
    expect(playlistDetailsRoute(caps, true, false), 'plugin');
    expect(playlistDetailsRoute(caps, true, true), 'plugin');
    expect(playlistDetailsRoute({'lyrics-read'}, true, false), isNull);
    expect(playlistDetailsRoute({'lyrics-read'}, true, true), 'admin');
    expect(playlistDetailsRoute(caps, false, false), isNull);
    expect(playlistDetailsRoute(caps, false, true), 'admin');
  });
}
