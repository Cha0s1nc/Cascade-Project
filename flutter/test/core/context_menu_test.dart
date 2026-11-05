// Ported from desktop/test/context-menu.test.ts.
import 'package:cascade/core/context_menu.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('album: play family, add to playlist, go to artist, metadata, download, favorite, instant mix', () {
    final v = menuItemsForKind(MenuItemKind.album);
    for (final b in [v.play, v.playNext, v.playLast, v.shuffle, v.instantMix, v.addPlaylist, v.download, v.favorite, v.goArtist, v.refreshMeta, v.editMeta]) {
      expect(b, isTrue);
    }
    expect(v.rename, isFalse);
    expect(v.deleteItem, isFalse);
    expect(v.markPlayed, isFalse);
  });

  test('artist: play all, shuffle all, instant mix, view page, queue actions, favorite', () {
    final v = menuItemsForKind(MenuItemKind.artist);
    for (final b in [v.play, v.shuffle, v.instantMix, v.viewDetail, v.playNext, v.playLast, v.addPlaylist, v.favorite]) {
      expect(b, isTrue);
    }
    expect(v.download, isFalse);
    expect(v.refreshMeta, isFalse);
  });

  test('video (movie/episode): play, detail, and exactly one mark-played row', () {
    final unplayed = menuItemsForKind(MenuItemKind.video, isPlayed: false);
    expect(unplayed.play, isTrue);
    expect(unplayed.viewDetail, isTrue);
    expect(unplayed.markPlayed, isTrue);
    expect(unplayed.markUnplayed, isFalse);
    final played = menuItemsForKind(MenuItemKind.video, isPlayed: true);
    expect(played.markPlayed, isFalse);
    expect(played.markUnplayed, isTrue);
  });

  test('video/series with unknown played state hides both mark rows rather than guessing', () {
    for (final k in [MenuItemKind.video, MenuItemKind.series]) {
      expect(menuItemsForKind(k).markPlayed, isFalse);
      expect(menuItemsForKind(k).markUnplayed, isFalse);
    }
  });

  test('series: no direct play - it is a container, not playable media', () {
    final v = menuItemsForKind(MenuItemKind.series, isPlayed: false);
    expect(v.play, isFalse);
    expect(v.viewDetail, isTrue);
    expect(v.markPlayed, isTrue);
  });

  test('playlist: play, shuffle, rename, delete, queue actions', () {
    final v = menuItemsForKind(MenuItemKind.playlist);
    for (final b in [v.play, v.shuffle, v.rename, v.deleteItem, v.playNext, v.playLast, v.addPlaylist]) {
      expect(b, isTrue);
    }
    expect(v.viewDetail, isFalse);
  });

  test('smart playlist: play, shuffle, queue actions - not a real playlist to rename or delete', () {
    final v = menuItemsForKind(MenuItemKind.smartPlaylist);
    for (final b in [v.play, v.shuffle, v.playNext, v.playLast, v.addPlaylist]) {
      expect(b, isTrue);
    }
    expect(v.rename, isFalse);
    expect(v.deleteItem, isFalse);
  });

  test('user smart playlist reuses rename/delete for its own local definition', () {
    final v = menuItemsForKind(MenuItemKind.userSmartPlaylist);
    for (final b in [v.play, v.shuffle, v.playNext, v.playLast, v.addPlaylist, v.rename, v.deleteItem]) {
      expect(b, isTrue);
    }
    expect(v.viewDetail, isFalse);
  });

  test('clampMenuPosition: fits, flips left, flips up, flips both, never negative', () {
    var p = clampMenuPosition(100, 100, 200, 300, 1920, 1080);
    expect((p.left, p.top), (100, 100));
    p = clampMenuPosition(1850, 100, 200, 300, 1920, 1080);
    expect((p.left, p.top), (1650, 100));
    p = clampMenuPosition(100, 1000, 200, 300, 1920, 1080);
    expect((p.left, p.top), (100, 700));
    p = clampMenuPosition(1850, 1000, 200, 300, 1920, 1080);
    expect((p.left, p.top), (1650, 700));
    p = clampMenuPosition(50, 50, 500, 500, 400, 400);
    expect((p.left, p.top), (0, 0));
  });

  test('only an album and a real playlist offer an offline download', () {
    expect(menuItemsForKind(MenuItemKind.album).offline, isTrue);
    expect(menuItemsForKind(MenuItemKind.playlist).offline, isTrue);
    for (final k in [MenuItemKind.artist, MenuItemKind.video, MenuItemKind.series, MenuItemKind.smartPlaylist, MenuItemKind.userSmartPlaylist]) {
      expect(menuItemsForKind(k).offline, isFalse, reason: '$k');
    }
  });

  test('offline, only rows that need no server stay', () {
    final album = menuItemsForKind(MenuItemKind.album, offline: true);
    expect(album.play, isTrue);
    expect(album.offline, isTrue);
    expect(album.goArtist, isTrue);
    expect([album.instantMix, album.addPlaylist, album.download, album.refreshMeta, album.editMeta], everyElement(isFalse));
    expect(album.favorite, isTrue);
    final playlist = menuItemsForKind(MenuItemKind.playlist, offline: true);
    expect(playlist.rename, isFalse);
    expect(playlist.deleteItem, isFalse);
    final mine = menuItemsForKind(MenuItemKind.userSmartPlaylist, offline: true);
    expect(mine.rename, isTrue);
    expect(mine.deleteItem, isTrue);
    expect(menuItemsForKind(MenuItemKind.video, isPlayed: false, offline: true).markPlayed, isTrue);
    expect(menuItemsForKind(MenuItemKind.album, offline: false).toMap(), menuItemsForKind(MenuItemKind.album).toMap());
  });

  test("in Local mode playlists are Cascade's own, and nothing downloads", () {
    for (final k in MenuItemKind.values) {
      final rows = menuItemsForKind(k, local: true, offline: true, isPlayed: false);
      expect(rows.instantMix, isFalse, reason: '$k');
      expect(rows.download, isFalse, reason: '$k');
      expect(rows.offline, isFalse, reason: '$k');
      expect(rows.refreshMeta, isFalse, reason: '$k');
      expect(rows.editMeta, isFalse, reason: '$k');
      expect(rows.addPlaylist, menuItemsForKind(k).addPlaylist, reason: '$k');
    }
    final playlist = menuItemsForKind(MenuItemKind.playlist, local: true, offline: true);
    expect(playlist.rename, isTrue);
    expect(playlist.deleteItem, isTrue);
    expect(menuItemsForKind(MenuItemKind.video, local: true, offline: true, isPlayed: false).markPlayed, isTrue);
  });
}
