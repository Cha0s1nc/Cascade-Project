// Per-tab page history, ported from the desktop's src/core/nav-history.ts.
// Every tab keeps its own stack of pages, so a link opens its page in the tab
// you are in (an artist from a playlist stays under Playlists) and Back walks
// that tab's own way back. Forward is new here: the step Back left, per tab,
// until something else is opened.
import 'package:flutter/foundation.dart';

/// [view] is a whole view opened as a page (the phone's Library rows).
enum PageKind { album, artist, playlist, smart, genre, movie, series, view }

/// Each page's own category, where it opens from Settings or the other mode.
const pageCategory = {
  PageKind.album: 'albums',
  PageKind.artist: 'artists',
  PageKind.playlist: 'playlists',
  PageKind.smart: 'playlists',
  PageKind.genre: 'genres',
  PageKind.movie: 'movies',
  PageKind.series: 'shows',
  PageKind.view: 'library',
};

/// Oldest steps go past this, so a long session can't grow a tab without end.
const navMaxDepth = 50;

const _musicViews = ['albums', 'artists', 'songs', 'playlists', 'genres', 'history', 'radio'];
const _videoViews = ['movies', 'shows'];

/// Which half a view belongs to (the desktop's browse-mode sectionMode).
String? sectionMode(String view) => _musicViews.contains(view)
    ? 'music'
    : _videoViews.contains(view)
    ? 'video'
    : null;

/// The tab a page opens in: the one you're in, unless that is Settings or a
/// tab of the other half (a movie opened from Albums goes to Movies).
String navHost(String current, PageKind page) {
  final own = pageCategory[page]!;
  if (current == 'settings') return own;
  final mode = sectionMode(current);
  return mode != null && mode != sectionMode(own) ? own : current;
}

/// One step in a tab: its home (page null) or a page and what opened it.
class NavEntry {
  NavEntry(this.page, [this.args = const []]);
  final PageKind? page;
  final List<Object?> args;

  /// The tab's scroll position when it was left, put back on return.
  double scroll = 0;
}

class Nav extends ChangeNotifier {
  Nav([this.view = 'home']);

  /// The tab showing.
  String view;
  final _stacks = <String, List<NavEntry>>{};
  final _forward = <String, List<NavEntry>>{};

  List<NavEntry> stack(String tab) => _stacks.putIfAbsent(tab, () => [NavEntry(null)]);
  NavEntry get top => stack(view).last;
  bool get canBack => stack(view).length > 1;
  bool get canForward => _forward[view]?.isNotEmpty ?? false;

  void _push(String tab, NavEntry e) {
    final s = stack(tab)..add(e);
    if (s.length > navMaxDepth) s.removeRange(0, s.length - navMaxDepth);
  }

  /// Switch tabs. Clicking the tab you are on goes to its home, as a step
  /// Back can undo.
  void show(String tab) {
    if (tab == view) {
      home();
      return;
    }
    view = tab;
    notifyListeners();
  }

  /// Open a page in the tab you are in (or its own, see [navHost]).
  void open(PageKind page, [List<Object?> args = const []]) {
    view = navHost(view, page);
    _push(view, NavEntry(page, args));
    _forward[view]?.clear();
    notifyListeners();
  }

  /// The current tab's home, unless it is there already.
  bool home() {
    if (top.page == null) return false;
    _push(view, NavEntry(null));
    _forward[view]?.clear();
    notifyListeners();
    return true;
  }

  /// One step back in this tab; false at its start.
  bool back() {
    final s = stack(view);
    if (s.length < 2) return false;
    _forward.putIfAbsent(view, () => []).add(s.removeLast());
    notifyListeners();
    return true;
  }

  /// Redo the step Back undid in this tab.
  bool forward() {
    final f = _forward[view];
    if (f == null || f.isEmpty) return false;
    _push(view, f.removeLast());
    notifyListeners();
    return true;
  }

  /// A page that no longer exists (a deleted playlist) leaves every tab's
  /// history, with any home step that only separated two copies of it.
  /// Returns the tabs whose current step changed.
  List<String> forget(PageKind page, Object? id) {
    bool gone(NavEntry e) => e.page == page && e.args.isNotEmpty && e.args.first == id;
    final changed = <String>[];
    for (final MapEntry(key: tab, value: s) in _stacks.entries) {
      final top = s.last;
      final kept = [
        for (var i = 0; i < s.length; i++)
          if (i == 0 || !gone(s[i])) s[i],
      ];
      // Two homes in a row are one step.
      final merged = [
        for (var i = 0; i < kept.length; i++)
          if (i == 0 || kept[i].page != null || kept[i - 1].page != null) kept[i],
      ];
      _stacks[tab] = merged;
      if (merged.last != top) changed.add(tab);
    }
    for (final f in _forward.values) {
      f.removeWhere(gone);
    }
    if (changed.contains(view)) notifyListeners();
    return changed;
  }
}
