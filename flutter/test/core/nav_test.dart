// Ported from desktop/test/nav-history.test.ts, plus Forward.
import 'package:cascade/core/nav.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('navHost keeps a page in the tab you are in', () {
    expect(navHost('playlists', PageKind.artist), 'playlists');
    expect(navHost('home', PageKind.series), 'home');
    expect(navHost('downloads', PageKind.album), 'downloads');
    expect(navHost('albums', PageKind.album), 'albums');
  });

  test('navHost sends a page to its category from Settings or the other mode', () {
    expect(navHost('settings', PageKind.playlist), 'playlists');
    expect(navHost('albums', PageKind.movie), 'movies');
    expect(navHost('shows', PageKind.artist), 'artists');
    expect(navHost('playlists', PageKind.smart), 'playlists');
  });

  test('Back walks a tab back to its home, and no further', () {
    final n = Nav('playlists');
    expect(n.canBack, isFalse);
    n.open(PageKind.playlist, ['p1']);
    n.open(PageKind.artist, ['a1', 'Artist']);
    expect(n.top.page, PageKind.artist);
    expect(n.back(), isTrue);
    expect(n.top.args, ['p1']);
    expect(n.back(), isTrue);
    expect(n.top.page, isNull);
    expect(n.back(), isFalse);
  });

  test('each tab keeps its own history', () {
    final n = Nav('playlists')..open(PageKind.playlist, ['p1']);
    n
      ..show('albums')
      ..open(PageKind.album, ['al1']);
    expect(n.top.page, PageKind.album);
    n.show('playlists');
    expect(n.top.page, PageKind.playlist);
    n.show('artists');
    expect(n.canBack, isFalse);
  });

  test('clicking the tab you are on goes home, and Back undoes it', () {
    final n = Nav('playlists')..open(PageKind.playlist, ['p1']);
    n.show('playlists');
    expect(n.top.page, isNull);
    expect(n.home(), isFalse); // already home: no extra step
    n.back();
    expect(n.top.args, ['p1']);
  });

  test('history stops growing at navMaxDepth, dropping the oldest steps', () {
    final n = Nav('albums');
    for (var i = 0; i < navMaxDepth + 10; i++) {
      n.open(PageKind.album, [i]);
    }
    expect(n.stack('albums'), hasLength(navMaxDepth));
    expect(n.top.args, [navMaxDepth + 9]);
  });

  test('forget drops a deleted page everywhere and merges the homes it leaves', () {
    final n = Nav('playlists')
      ..open(PageKind.playlist, ['gone'])
      ..home()
      ..open(PageKind.playlist, ['kept'])
      ..open(PageKind.playlist, ['gone'])
      ..show('home')
      ..open(PageKind.album, ['al1']);
    expect(n.forget(PageKind.playlist, 'gone'), ['playlists']);
    expect([for (final e in n.stack('playlists')) e.args.isEmpty ? 'home' : e.args.first], ['home', 'kept']);
    expect(n.top.page, PageKind.album);
  });

  test('Forward redoes what Back undid, until something else opens', () {
    final n = Nav('albums')
      ..open(PageKind.album, ['a'])
      ..open(PageKind.artist, ['b']);
    expect(n.canForward, isFalse);
    n.back();
    expect(n.canForward, isTrue);
    expect(n.forward(), isTrue);
    expect(n.top.args, ['b']);
    n
      ..back()
      ..open(PageKind.album, ['c']);
    expect(n.canForward, isFalse);
  });
}
