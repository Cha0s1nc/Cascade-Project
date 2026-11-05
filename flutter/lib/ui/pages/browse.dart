// Search, Radio, Rediscover, and the video grids (Movies, TV Shows) with
// their pages.
import 'dart:async';

import 'package:flutter/material.dart';

import 'package:cascade/core/data.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/rediscover.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/pages/detail.dart';
import 'package:cascade/ui/pages/home.dart';
import 'package:cascade/ui/pages/library.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/widgets.dart';

// Search -----------------------------------------------------------------------

typedef _Results = ({List<Song> songs, List<Album> albums, List<Artist> artists, List<Video> movies, List<Video> shows});

/// Results for what is typed in the title bar, 250 ms after typing stops.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  Timer? _wait;
  String _query = '';
  Future<_Results>? _results;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final q = SearchScope.of(context).text.trim();
    if (q == _query) return;
    _query = q;
    _wait?.cancel();
    _wait = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _results = q.isEmpty ? null : LibraryScope.read(context).search(q));
    });
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageScroll(
    slivers: [
      SliverToBoxAdapter(
        child: PageHeader('Search', voice: _query.isEmpty ? 'Type in the bar above. Songs, albums, artists, movies and shows.' : 'Results for "$_query"'),
      ),
      if (_results != null)
        Loading<_Results>(
          future: _results!,
          builder: (context, r) {
            if (r.songs.isEmpty && r.albums.isEmpty && r.artists.isEmpty && r.movies.isEmpty && r.shows.isEmpty) {
              return SliverToBoxAdapter(child: Empty('No results for "$_query".', icon: Icons.search_off_rounded));
            }
            return SliverMainAxisGroup(
              slivers: [
                if (r.songs.isNotEmpty) ...[
                  const SliverToBoxAdapter(child: SectionTitle('Songs', top: 0)),
                  SliverList.builder(
                    itemCount: r.songs.length,
                    itemBuilder: (c, i) => TrackRow(r.songs[i], index: i + 1, queue: [r.songs[i]], cols: TrackCols.playlist, showArt: true),
                  ),
                ],
                if (r.artists.isNotEmpty) ...[
                  const SliverToBoxAdapter(child: SectionTitle('Artists')),
                  CardGrid(count: r.artists.length, minWidth: 130, builder: (c, i) => artistCard(c, r.artists[i])),
                ],
                if (r.albums.isNotEmpty) ...[
                  const SliverToBoxAdapter(child: SectionTitle('Albums')),
                  CardGrid(count: r.albums.length, builder: (c, i) => albumCard(c, r.albums[i])),
                ],
                if (r.movies.isNotEmpty) ...[
                  const SliverToBoxAdapter(child: SectionTitle('Movies')),
                  CardGrid(count: r.movies.length, aspect: 2 / 3, minWidth: 140, builder: (c, i) => posterCard(c, r.movies[i])),
                ],
                if (r.shows.isNotEmpty) ...[
                  const SliverToBoxAdapter(child: SectionTitle('TV Shows')),
                  CardGrid(count: r.shows.length, aspect: 2 / 3, minWidth: 140, builder: (c, i) => posterCard(c, r.shows[i])),
                ],
              ],
            );
          },
        ),
    ],
  );
}

// Radio ------------------------------------------------------------------------

/// Radio: the server's Live TV channels, played as audio.
class RadioPage extends StatefulWidget {
  const RadioPage({super.key});

  @override
  State<RadioPage> createState() => _RadioPageState();
}

class _RadioPageState extends State<RadioPage> {
  late Future<List<Song>> _channels = LibraryScope.read(context).radioChannels();

  @override
  Widget build(BuildContext context) => PageScroll(
    slivers: [
      const SliverToBoxAdapter(child: PageHeader('Radio', voice: 'Live channels from your server.')),
      Loading<List<Song>>(
        future: _channels,
        onRetry: () => setState(() => _channels = LibraryScope.read(context).radioChannels()),
        builder: (context, channels) => channels.isEmpty
            ? const SliverToBoxAdapter(child: Empty('No channels on your server.', icon: Icons.radio_outlined))
            : CardGrid(
                count: channels.length,
                builder: (c, i) => MediaCard(
                  title: channels[i].title,
                  subtitle: channels[i].artist,
                  art: channels[i].art,
                  image: channels[i].image,
                  onTap: () => PlayerScope.read(c).play(channels[i], channels, 'Radio'),
                ),
              ),
      ),
    ],
  );
}

// Rediscover -------------------------------------------------------------------

class RediscoverPage extends StatefulWidget {
  const RediscoverPage({super.key});

  @override
  State<RediscoverPage> createState() => _RediscoverPageState();
}

class _RediscoverPageState extends State<RediscoverPage> {
  late final Future<Shelves> _shelves = () async {
    final lib = LibraryScope.read(context);
    final [albums, songs] = await Future.wait([lib.albumItems(), lib.songItems()]);
    return rediscover(albums, songs, DateTime.now());
  }();

  /// The Rediscover mix: songs from all three shelves, shuffled.
  Future<void> _mix(Shelves s) async {
    final lib = LibraryScope.read(context);
    final j = lib.jf;
    if (j == null) return;
    final albums = [...s.usedToLove.take(8), ...s.neverPlayed.take(8), ...s.forgotten.where((i) => i['Type'] == 'MusicAlbum').take(6)];
    final songs = [
      for (final a in albums) ...(await lib.tracksOf(j.album(a))).take(3),
      for (final i in s.forgotten.where((i) => i['Type'] == 'Audio').take(12)) j.song(i),
    ];
    if (mounted) await playAll(PlayerScope.read(context), songs, 'Rediscover mix', shuffle: true);
  }

  @override
  Widget build(BuildContext context) {
    final j = LibraryScope.of(context).jf;
    return PageScroll(
      slivers: [
        Loading<Shelves>(
          future: _shelves,
          builder: (context, s) {
            Widget shelf(String title, String why, List<Item> items) => SliverMainAxisGroup(
              slivers: [
                SliverToBoxAdapter(child: SectionTitle(title, link: why)),
                if (items.isEmpty)
                  SliverToBoxAdapter(
                    child: Text('Nothing here today.', style: ts(13, c: K.text3)),
                  )
                else
                  CardGrid(
                    count: items.length.clamp(0, 12),
                    builder: (c, i) {
                      final it = items[i];
                      if (it['Type'] == 'Audio') {
                        final song = j!.song(it);
                        return MediaCard(
                          title: song.title,
                          subtitle: song.artist,
                          art: song.art,
                          image: song.image,
                          onTap: () => PlayerScope.read(c).play(song, [song]),
                          onMenu: (o) => songMenu(c, song, o),
                        );
                      }
                      return albumCard(c, j!.album(it));
                    },
                  ),
              ],
            );
            return SliverMainAxisGroup(
              slivers: [
                SliverToBoxAdapter(
                  child: PageHeader(
                    'Rediscover',
                    voice: 'Music you have and forgot about. New picks every day.',
                    actions: [Pill('Rediscover mix', icon: Icons.auto_awesome_rounded, onTap: () => _mix(s))],
                  ),
                ),
                shelf('Used to love', 'Played 20 times or more, not in a year', s.usedToLove),
                shelf('Never played', 'In your library six months or more', s.neverPlayed),
                shelf('Forgotten favorites', 'Liked, not played in six months', s.forgotten),
              ],
            );
          },
        ),
      ],
    );
  }
}

// Video ------------------------------------------------------------------------

Widget posterCard(BuildContext context, Video v) =>
    MediaCard(title: v.title, subtitle: v.episode, art: v.art, image: v.image, aspect: 2 / 3, onTap: () => openVideo(context, v));

/// Movies or TV Shows: the chosen libraries' posters, sorted by name.
class VideoGridPage extends StatefulWidget {
  const VideoGridPage({super.key, required this.shows});
  final bool shows;

  @override
  State<VideoGridPage> createState() => _VideoGridPageState();
}

class _VideoGridPageState extends State<VideoGridPage> {
  late final Future<List<Video>> _items = _load();

  Future<List<Video>> _load() async {
    final lib = LibraryScope.read(context);
    final j = lib.jf;
    if (j == null) return demoContinueWatching;
    final r = await j.getAllPaged('/Items', {
      'userId': j.userId,
      'IncludeItemTypes': widget.shows ? 'Series' : 'Movie',
      'Recursive': true,
      'SortBy': 'SortName',
      'Fields': 'ProductionYear,UserData,SortName,ChildCount',
    }, widget.shows ? lib.showIds : lib.movieIds);
    return [for (final i in r) poster(j, i)];
  }

  @override
  Widget build(BuildContext context) => PageScroll(
    slivers: [
      Loading<List<Video>>(
        future: _items,
        builder: (context, items) => SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: PageHeader(
                widget.shows ? 'TV Shows' : 'Movies',
                voice: '${items.length} ${widget.shows ? (items.length == 1 ? 'show' : 'shows') : (items.length == 1 ? 'movie' : 'movies')}',
              ),
            ),
            if (items.isEmpty)
              const SliverToBoxAdapter(child: Empty('Nothing in the chosen libraries.', icon: Icons.movie_outlined))
            else
              CardGrid(count: items.length, aspect: 2 / 3, minWidth: 150, builder: (c, i) => posterCard(c, items[i])),
          ],
        ),
      ),
    ],
  );
}

/// A movie or series as a poster card (the Primary image, not the backdrop).
Video poster(Jellyfin j, Item i) {
  final id = i['Id'] as String;
  final year = i['ProductionYear'];
  return Video(
    i['Name'] as String? ?? '',
    i['Type'] == 'Series' ? '${year ?? ''}${i['ChildCount'] != null ? ' · ${i['ChildCount']} seasons' : ''}' : '${year ?? ''}',
    '',
    0,
    artFor(id),
    id: id,
    type: i['Type'] as String? ?? '',
    image: j.image(id, (i['ImageTags'] as Map?)?['Primary'] as String?, width: 400),
  );
}

/// A movie's or series' page: backdrop, overview, and for a series its
/// seasons and episodes. Playing them comes with the video player.
class VideoPage extends StatefulWidget {
  const VideoPage(this.id, {super.key});
  final String id;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  late final Future<(Item, List<Item>)> _data = () async {
    final lib = LibraryScope.read(context);
    final j = lib.jf;
    final item = await lib.item(widget.id);
    if (j == null || item == null) throw JellyfinError('This is gone from the server.');
    if (item['Type'] != 'Series') return (item, <Item>[]);
    final eps = await j.get('/Shows/${widget.id}/Episodes', {'userId': j.userId, 'Fields': 'Overview,UserData'});
    return (item, ((eps as Map)['Items'] as List).cast<Item>());
  }();

  @override
  Widget build(BuildContext context) => Loading<(Item, List<Item>)>(
    future: _data,
    sliver: false,
    builder: (context, d) {
      final (item, episodes) = d;
      final j = LibraryScope.read(context).jf!;
      final v = poster(j, item);
      final seasons = <int, List<Item>>{};
      for (final e in episodes) {
        seasons.putIfAbsent(e['ParentIndexNumber'] as int? ?? 0, () => []).add(e);
      }
      return PageScroll(
        slivers: [
          SliverToBoxAdapter(
            child: DetailHeader(
              label: item['Type'] == 'Series' ? 'TV Show' : 'Movie',
              title: v.title,
              art: v.art,
              image: v.image,
              meta: [
                if (item['ProductionYear'] != null) '${item['ProductionYear']}',
                if (item['OfficialRating'] != null) item['OfficialRating'] as String,
                if (item['RunTimeTicks'] != null && item['Type'] != 'Series') '${((item['RunTimeTicks'] as num) / 6e8).round()} min',
              ].join(' · '),
              voice: (item['Taglines'] as List?)?.firstOrNull as String?,
              actions: [playVideoButton(context, item), likeBtn(context, v.id, (item['UserData'] as Map?)?['IsFavorite'] == true)],
            ),
          ),
          if ((item['Overview'] as String? ?? '').isNotEmpty)
            SliverToBoxAdapter(
              child: Text(item['Overview'] as String, style: ts(14, c: K.text2, h: 1.55)),
            ),
          for (final MapEntry(key: n, value: eps) in seasons.entries) ...[
            SliverToBoxAdapter(child: SectionTitle(n == 0 ? 'Specials' : 'Season $n')),
            SliverList.builder(
              itemCount: eps.length,
              itemBuilder: (c, i) {
                final e = eps[i];
                final played = (e['UserData'] as Map?)?['Played'] == true;
                return Hover(
                  onTap: () => playVideo(c, e),
                  builder: (_, on) => Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: on ? K.line : Colors.transparent, borderRadius: BorderRadius.circular(10)),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 34,
                          child: Text('${e['IndexNumber'] ?? ''}', style: ts(13, c: K.text3)),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e['Name'] as String? ?? '', style: ts(14, w: FontWeight.w500)),
                              if ((e['Overview'] as String? ?? '').isNotEmpty)
                                Text(
                                  e['Overview'] as String,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: ts(12, c: K.text3, h: 1.4),
                                ),
                            ],
                          ),
                        ),
                        if (played) const Icon(Icons.check_circle_rounded, size: 16, color: K.accent),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ],
      );
    },
  );
}

/// Set by the video player (phase 5); until then videos say so.
void Function(BuildContext context, Item item)? videoPlayer;

void playVideo(BuildContext context, Item item) {
  final play = videoPlayer;
  if (play == null) return toast(context, 'Video playback is not built yet.');
  play(context, item);
}

Widget playVideoButton(BuildContext context, Item item) => Pill(
  item['Type'] == 'Series' ? 'Play next episode' : 'Play',
  icon: Icons.play_arrow_rounded,
  onTap: () async {
    if (item['Type'] != 'Series') return playVideo(context, item);
    final lib = LibraryScope.read(context);
    final res = await lib.jf!.get('/Shows/NextUp', {'UserId': lib.jf!.userId, 'SeriesId': item['Id']});
    final next = ((res as Map)['Items'] as List).cast<Item>().firstOrNull;
    if (context.mounted && next != null) playVideo(context, next);
  },
);
