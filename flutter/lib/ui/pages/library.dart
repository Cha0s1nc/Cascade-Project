// The library's tabs: Albums, Artists, Playlists and Genres as card grids
// with sort and filters saved per view (the desktop's LIB_VIEWS, same store
// keys), Songs as a sortable list, and History grouped by day.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cascade/core/browse.dart';
import 'package:cascade/core/data.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/nav.dart';
import 'package:cascade/core/queue.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/pages/smart.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/widgets.dart';

/// One grid view's setup: its store name, sort fields and what it shows.
class GridSpec {
  const GridSpec({
    required this.name,
    required this.title,
    required this.fields,
    required this.load,
    required this.card,
    this.voice,
    this.round = false,
    this.filters = true,
    this.shuffle,
    this.extra,
  });
  final String name, title;
  final Map<String, String> fields;
  final Future<List<Item>> Function(BuildContext) load;
  final Widget Function(BuildContext, Item) card;
  final String Function(List<Item> all)? voice;
  final bool round, filters;
  final Future<void> Function(BuildContext, List<Item> shown)? shuffle;

  /// Shown between the header and the grid.
  final Widget? extra;
}

class GridPage extends StatefulWidget {
  const GridPage(this.spec, {super.key});
  final GridSpec spec;

  @override
  State<GridPage> createState() => _GridPageState();
}

class _GridPageState extends State<GridPage> {
  late Future<List<Item>> _items = widget.spec.load(context);
  LibraryPrefs? _prefs;

  @override
  void initState() {
    super.initState();
    final fields = widget.spec.fields.keys.toList();
    SharedPreferences.getInstance().then(
      (p) => mounted ? setState(() => _prefs = normalizeLibraryPrefs(p.getString('${widget.spec.name}Prefs'), fields)) : null,
      onError: (_) => mounted ? setState(() => _prefs = normalizeLibraryPrefs(null, fields)) : null,
    );
  }

  void _set(LibraryPrefs p) {
    setState(() => _prefs = p);
    SharedPreferences.getInstance().then(
      (s) => s.setString(
        '${widget.spec.name}Prefs',
        jsonEncode({'field': p.field, 'dir': p.dir, 'favorite': p.favorite, 'genre': p.genre, 'decade': p.decade, 'played': p.played}),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final prefs = _prefs;
    LibraryScope.of(context); // a library change reloads
    return Loading<List<Item>>(
      future: _items,
      sliver: false,
      onRetry: () => setState(() => _items = spec.load(context)),
      builder: (context, all) {
        if (prefs == null) return const SizedBox.shrink();
        final filters = LibraryFilters(favorite: prefs.favorite, genre: prefs.genre, decade: prefs.decade, played: prefs.played);
        final shown = sortLibraryItems(filterLibraryItems(all, filters), prefs.field, prefs.dir);
        final options = libraryFilterOptions(all);
        LibraryPrefs copy({String? field, String? dir, bool? favorite, Object? genre = 0, Object? decade = 0, Object? played = 0}) => (
          field: field ?? prefs.field,
          dir: dir ?? prefs.dir,
          favorite: favorite ?? prefs.favorite,
          genre: genre == 0 ? prefs.genre : genre as String?,
          decade: decade == 0 ? prefs.decade : decade as int?,
          played: played == 0 ? prefs.played : played as String?,
        );
        final sortKey = '${prefs.field}:${prefs.dir}';
        return PageScroll(
          slivers: [
            SliverToBoxAdapter(
              child: PageHeader(
                spec.title,
                voice: spec.voice?.call(all),
                actions: [
                  MenuButton<String>(
                    icon: Icons.sort_rounded,
                    label:
                        '${spec.fields[prefs.field]}${prefs.field == 'random'
                            ? ''
                            : prefs.dir == 'desc'
                            ? ', newest'
                            : ''}',
                    selected: sortKey,
                    options: [
                      for (final MapEntry(key: f, value: l) in spec.fields.entries) ...[
                        ('$f:asc', l),
                        if (f == 'year' || f == 'added' || f == 'count') ('$f:desc', '$l, newest first'),
                      ],
                    ],
                    onSelected: (v) => _set(copy(field: v.split(':')[0], dir: v.split(':')[1])),
                  ),
                  if (spec.shuffle != null) Pill('Shuffle', icon: Icons.shuffle_rounded, onTap: shown.isEmpty ? null : () => spec.shuffle!(context, shown)),
                ],
                below: !spec.filters
                    ? null
                    : Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Chip_(
                            'All',
                            on: !prefs.favorite && prefs.played == null && prefs.genre == null && prefs.decade == null,
                            onTap: () => _set(copy(favorite: false, played: null, genre: null, decade: null)),
                          ),
                          Chip_(
                            'Favorites',
                            on: prefs.favorite,
                            onTap: () => _set(copy(favorite: !prefs.favorite)),
                          ),
                          Chip_(
                            'Not played',
                            on: prefs.played == 'unplayed',
                            onTap: () => _set(copy(played: prefs.played == 'unplayed' ? null : 'unplayed')),
                          ),
                          if (options.genres.isNotEmpty)
                            MenuButton<String>(
                              icon: Icons.sell_outlined,
                              label: prefs.genre ?? 'Genre',
                              selected: prefs.genre ?? '',
                              options: [('', 'Any genre'), for (final g in options.genres) (g, g)],
                              onSelected: (g) => _set(copy(genre: g.isEmpty ? null : g)),
                            ),
                          if (options.decades.isNotEmpty)
                            MenuButton<int>(
                              icon: Icons.calendar_month_outlined,
                              label: prefs.decade == null ? 'Decade' : '${prefs.decade}s',
                              selected: prefs.decade ?? -1,
                              options: [(-1, 'Any decade'), for (final d in options.decades) (d, '${d}s')],
                              onSelected: (d) => _set(copy(decade: d < 0 ? null : d)),
                            ),
                        ],
                      ),
              ),
            ),
            if (spec.extra != null) SliverToBoxAdapter(child: spec.extra),
            if (shown.isEmpty)
              SliverToBoxAdapter(child: Empty(all.isEmpty ? 'Nothing here yet.' : 'Nothing matches these filters.'))
            else
              CardGrid(count: shown.length, textHeight: 52, builder: (context, i) => spec.card(context, shown[i])),
          ],
        );
      },
    );
  }
}

String _count(int n, String one, [String? many]) => '${_thousands(n)} ${n == 1 ? one : (many ?? '${one}s')}';
String _thousands(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

Widget albumCard(BuildContext context, Album a) => MediaCard(
  title: a.title,
  subtitle: a.playlist ? a.subtitle : [if (a.artist.isNotEmpty) a.artist, if (a.year > 0) '${a.year}'].join(' · '),
  art: a.art,
  image: a.image,
  onTap: () => openPage(context, a.playlist ? PageKind.playlist : PageKind.album, [a.id]),
  onPlay: () async {
    final p = PlayerScope.read(context);
    await playAll(p, await LibraryScope.read(context).tracksOf(a), a.title);
  },
  onMenu: (o) => albumMenu(context, a, o),
);

Widget artistCard(BuildContext context, Artist a) => MediaCard(
  title: a.name,
  subtitle: 'Artist',
  art: a.art,
  image: a.image,
  round: true,
  onTap: () => openPage(context, PageKind.artist, [a.id]),
  onMenu: (o) => artistMenu(context, a, o),
);

Jellyfin? _jf(BuildContext context) => LibraryScope.read(context).jf;

GridSpec albumsSpec(BuildContext context) => GridSpec(
  name: 'albums',
  title: 'Albums',
  fields: const {'name': 'Name', 'artist': 'Artist', 'year': 'Year', 'added': 'Date added', 'random': 'Random'},
  load: (c) => LibraryScope.read(c).albumItems(),
  card: (c, i) => albumCard(c, _jf(c)?.album(i) ?? Album(i['Name'] as String? ?? '', i['AlbumArtist'] as String? ?? '', artFor(i['Id'] as String))),
  voice: (all) {
    final unplayed = all.where((i) => (i['UserData'] as Map?)?['Played'] != true).length;
    return '${_count(all.length, 'album')}${unplayed > 0 ? ', $unplayed you haven\'t played yet' : ''}';
  },
  shuffle: (c, shown) async {
    final lib = LibraryScope.read(c);
    final picks = shuffled(shown).take(20).map((i) => lib.jf!.album(i)).toList();
    final songs = [for (final a in picks) ...await lib.tracksOf(a)];
    if (c.mounted) await playAll(PlayerScope.read(c), shuffled(songs), 'Albums');
  },
);

GridSpec artistsSpec(BuildContext context) => GridSpec(
  name: 'artists',
  title: 'Artists',
  fields: const {'name': 'Name', 'added': 'Date added', 'random': 'Random'},
  load: (c) => LibraryScope.read(c).artistItems(),
  card: (c, i) => artistCard(c, _jf(c)!.artist(i)),
  voice: (all) => _count(all.length, 'artist'),
  round: true,
);

GridSpec playlistsSpec(BuildContext context) => GridSpec(
  name: 'playlists',
  title: 'Playlists',
  fields: const {'name': 'Name', 'added': 'Date added', 'count': 'Song count'},
  load: (c) => LibraryScope.read(c).playlistItems(),
  card: (c, i) => albumCard(c, _jf(c)!.album(i)),
  voice: (all) => all.isEmpty ? 'Make one from any song\'s menu.' : _count(all.length, 'playlist'),
  filters: false,
  extra: const SmartPlaylistsRow(),
);

class GenresPage extends StatelessWidget {
  const GenresPage({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);
    return PageScroll(
      slivers: [
        const SliverToBoxAdapter(child: PageHeader('Genres')),
        Loading<List<Item>>(
          future: lib.genreItems(),
          builder: (context, all) => all.isEmpty
              ? const SliverToBoxAdapter(child: Empty('No genres on your server.'))
              : CardGrid(
                  count: all.length,
                  textHeight: 36,
                  aspect: 16 / 9,
                  builder: (context, i) {
                    final g = lib.jf!.genre(all[i]);
                    return MediaCard(
                      title: g.name,
                      subtitle: '',
                      art: g.art,
                      image: g.image,
                      aspect: 16 / 9,
                      onTap: () => openPage(context, PageKind.genre, [g.id, g.name]),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Songs: the whole library as a list, sorted by the column you pick
/// (queue.ts sortSongs, stored under the desktop's songsSortField and songsSortDir).
class SongsPage extends StatefulWidget {
  const SongsPage({super.key});

  @override
  State<SongsPage> createState() => _SongsPageState();
}

class _SongsPageState extends State<SongsPage> {
  String _field = 'name', _dir = 'asc';
  bool _favorites = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      final f = p.getString('songsSortField'), d = p.getString('songsSortDir');
      final v = f == null ? null : [f, d ?? 'asc'];
      if (mounted && v != null && v.length == 2) {
        setState(() {
          _field = v[0];
          _dir = v[1];
        });
      }
    });
  }

  void _sort(String v) {
    final [f, d] = v.split(':');
    setState(() {
      _field = f;
      _dir = d;
    });
    SharedPreferences.getInstance().then((p) {
      p.setString('songsSortField', f);
      p.setString('songsSortDir', d);
    });
  }

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);
    return Loading<List<Item>>(
      future: lib.songItems(),
      sliver: false,
      builder: (context, all) {
        final items = sortSongs(
          _favorites ? all.where((i) => lib.isFavorite(i['Id'] as String, (i['UserData'] as Map?)?['IsFavorite'] == true)).toList() : all,
          _field,
          _dir,
        );
        final songs = items.map(lib.jf!.song).toList();
        final total = all.fold<num>(0, (t, i) => t + ((i['RunTimeTicks'] as num? ?? 0) / 1e7));
        return PageScroll(
          slivers: [
            SliverToBoxAdapter(
              child: PageHeader(
                'Songs',
                voice: '${_count(all.length, 'song')}, ${formatQueueSpan(total.toDouble())} of music',
                actions: [
                  MenuButton<String>(
                    icon: Icons.sort_rounded,
                    label: {'name': 'Title', 'artist': 'Artist', 'album': 'Album', 'added': 'Date added', 'played': 'Last played'}[_field] ?? 'Title',
                    selected: '$_field:$_dir',
                    options: const [
                      ('name:asc', 'Title'),
                      ('artist:asc', 'Artist'),
                      ('album:asc', 'Album'),
                      ('added:desc', 'Date added'),
                      ('played:desc', 'Last played'),
                    ],
                    onSelected: _sort,
                  ),
                  Pill(
                    'Shuffle',
                    icon: Icons.shuffle_rounded,
                    onTap: songs.isEmpty ? null : () => playAll(PlayerScope.read(context), songs, 'Songs', shuffle: true),
                  ),
                ],
                below: Chips([
                  ('All', !_favorites, () => setState(() => _favorites = false)),
                  ('Favorites', _favorites, () => setState(() => _favorites = true)),
                ]),
              ),
            ),
            if (songs.isEmpty)
              const SliverToBoxAdapter(child: Empty('No songs here.'))
            else
              SliverList.builder(
                itemCount: songs.length,
                itemBuilder: (context, i) => TrackRow(songs[i], index: i + 1, queue: songs, cols: TrackCols.playlist, source: 'Songs', showArt: true),
              ),
          ],
        );
      },
    );
  }
}

/// History: what you played, grouped by day (library-browse.ts groupByDay).
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late final _songs = LibraryScope.read(context).history();

  @override
  Widget build(BuildContext context) {
    return PageScroll(
      slivers: [
        const SliverToBoxAdapter(child: PageHeader('History', voice: 'What you played, newest first.')),
        Loading<List<Song>>(
          future: _songs,
          builder: (context, songs) {
            if (songs.isEmpty) return const SliverToBoxAdapter(child: Empty('Nothing played yet.', icon: Icons.history_rounded));
            final groups = groupByDay([
              for (final s in songs)
                {
                  'Id': s.id,
                  'UserData': {'LastPlayedDate': s.lastPlayed},
                },
            ]);
            final pos = {for (var i = 0; i < songs.length; i++) songs[i].id: i};
            return SliverMainAxisGroup(
              slivers: [
                for (final (k, g) in groups.indexed) ...[
                  SliverToBoxAdapter(child: SectionTitle(g.label, top: k == 0 ? 0 : 24)),
                  SliverList.builder(
                    itemCount: g.items.length,
                    itemBuilder: (context, j) {
                      final i = pos[g.items[j]['Id']]!;
                      return TrackRow(songs[i], index: i + 1, queue: songs, cols: TrackCols.playlist, showArt: true, source: 'History');
                    },
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}
