// The pages an item opens: album, artist, playlist and genre. Each has the
// big header (art, caps label, title, a meta line and a voice line, then
// Play, Shuffle and the item's buttons) over its songs.
import 'dart:math';

import 'package:flutter/material.dart';

import 'package:cascade/core/artist_page.dart';
import 'package:cascade/core/data.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/nav.dart';
import 'package:cascade/core/queue.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/pages/downloads.dart';
import 'package:cascade/ui/pages/library.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/widgets.dart';

/// "today", "yesterday", "on Sunday" within the week, else "on March 2".
String whenPlayed(String? iso, [DateTime? now]) {
  final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  final n = now ?? DateTime.now();
  final days = DateTime(n.year, n.month, n.day).difference(DateTime(d.year, d.month, d.day)).inDays;
  const week = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  if (days <= 0) return 'today';
  if (days == 1) return 'yesterday';
  if (days < 7) return 'on ${week[d.weekday - 1]}';
  return 'on ${months[d.month - 1]} ${d.day}${d.year == n.year ? '' : ', ${d.year}'}';
}

String _minutes(Iterable<Song> songs) => formatQueueSpan(songs.fold<int>(0, (t, s) => t + s.seconds).toDouble());

class DetailHeader extends StatelessWidget {
  const DetailHeader({
    super.key,
    required this.label,
    required this.title,
    required this.art,
    this.image,
    this.round = false,
    this.meta = '',
    this.voice,
    required this.actions,
    this.titleWidget,
  });
  final String label, title, meta;
  final List<Color> art;
  final String? image, voice;
  final bool round;
  final List<Widget> actions;
  final Widget? titleWidget;

  @override
  Widget build(BuildContext context) {
    final small = narrow(context);
    final cover = SizedBox(
      width: small ? 200 : 220,
      height: small ? 200 : 220,
      child: round ? ClipOval(child: Cover(art, image: image, radius: 0)) : Cover(art, image: image, radius: 14, shadow: true),
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: Txt.caps(K.text2)),
        const SizedBox(height: 8),
        titleWidget ??
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(title, maxLines: 1, style: ds(small ? 34 : 64, h: 1.05)),
            ),
        const SizedBox(height: 10),
        if (meta.isNotEmpty)
          Text(
            meta,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: ts(13, c: K.text2),
          ),
        if (voice != null && voice!.isNotEmpty) ...[const SizedBox(height: 6), Text(voice!, style: Txt.voice())],
        const SizedBox(height: 18),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: small
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: cover),
                const SizedBox(height: 20),
                text,
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                cover,
                const SizedBox(width: 28),
                Expanded(child: text),
              ],
            ),
    );
  }
}

/// A round button in the header row: like, download, more.
class RoundBtn extends StatelessWidget {
  const RoundBtn(this.icon, this.tip, this.onTap, {super.key, this.color = K.text});
  final IconData icon;
  final String tip;
  final VoidCallback? onTap;
  final Color color;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tip,
    child: Semantics(
      button: true,
      label: tip,
      child: Hover(
        onTap: onTap,
        builder: (_, on) => Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: on ? K.surface2 : K.surface, shape: BoxShape.circle),
          child: Icon(icon, size: 18, color: onTap == null ? K.text3 : color),
        ),
      ),
    ),
  );
}

/// A small label chip in the header (FLAC · 44.1 kHz).
class InfoChip extends StatelessWidget {
  const InfoChip(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(color: K.surface, borderRadius: BorderRadius.circular(99)),
    child: Text(
      text,
      style: ts(12, w: FontWeight.w500, c: K.text2),
    ),
  );
}

List<Widget> playButtons(BuildContext context, List<Song> songs, String source) {
  final p = PlayerScope.read(context);
  return [
    Pill('Play', icon: Icons.play_arrow_rounded, onTap: songs.isEmpty ? null : () => playAll(p, songs, source)),
    Pill('Shuffle', icon: Icons.shuffle_rounded, primary: false, onTap: songs.isEmpty ? null : () => playAll(p, songs, source, shuffle: true)),
  ];
}

Widget likeBtn(BuildContext context, String id, bool fromServer) {
  final lib = LibraryScope.of(context);
  final fav = lib.isFavorite(id, fromServer);
  return RoundBtn(
    fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
    fav ? 'Unlike' : 'Like',
    lib.demo ? null : () => lib.toggleFavorite(id, fromServer),
    color: fav ? K.like : K.accent,
  );
}

/// The codec and sample rate of the first track, when the server says.
String? formatOf(Item? track) {
  final ms = (track?['MediaSources'] as List?)?.firstOrNull as Map?;
  final audio = ((ms?['MediaStreams'] as List?) ?? const []).cast<Map>().where((s) => s['Type'] == 'Audio').firstOrNull;
  if (audio == null) return null;
  final codec = (audio['Codec'] as String? ?? ms?['Container'] as String? ?? '').toUpperCase();
  final rate = audio['SampleRate'] as int?;
  return [if (codec.isNotEmpty) codec, if (rate != null) '${(rate / 1000).toStringAsFixed(rate % 1000 == 0 ? 0 : 1)} kHz'].join(' · ');
}

// Album ------------------------------------------------------------------------

class AlbumPage extends StatefulWidget {
  const AlbumPage(this.id, {super.key});
  final String id;

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  late Future<(Album, List<Song>, String?)> _data = _load();

  Future<(Album, List<Song>, String?)> _load() async {
    final lib = LibraryScope.read(context);
    final j = lib.jf;
    if (j == null) {
      final a = demoRecentlyAdded.firstWhere((a) => a.title == widget.id, orElse: () => demoRecentlyAdded.first);
      return (a, const [reckoner, weirdFishes], null);
    }
    final item = await lib.item(widget.id);
    if (item == null) throw JellyfinError('This album is gone from the server.');
    final album = j.album(item);
    final res = await j.get('/Items', {
      'userId': j.userId,
      'ParentId': album.id,
      'IncludeItemTypes': 'Audio',
      'Recursive': true,
      'SortBy': 'ParentIndexNumber,IndexNumber,SortName',
      'Fields': 'AlbumId,AlbumPrimaryImageTag,UserData,MediaSources',
    });
    final items = ((res as Map)['Items'] as List).cast<Item>();
    return (album, items.map(j.song).toList(), formatOf(items.firstOrNull));
  }

  @override
  Widget build(BuildContext context) => Loading<(Album, List<Song>, String?)>(
    future: _data,
    sliver: false,
    onRetry: () => setState(() => _data = _load()),
    builder: (context, d) {
      final (album, songs, format) = d;
      final plays = songs.fold<int>(0, (t, s) => t + s.playCount);
      final last = songs.map((s) => s.lastPlayed).whereType<String>().fold<String?>(null, (a, b) => a == null || b.compareTo(a) > 0 ? b : a);
      final discs = songs.map((s) => s.disc).toSet();
      return PageScroll(
        slivers: [
          SliverToBoxAdapter(
            child: DetailHeader(
              label: 'Album',
              title: album.title,
              art: album.art,
              image: album.image,
              meta: [
                if (album.artist.isNotEmpty) album.artist,
                if (album.year > 0) '${album.year}',
                '${songs.length} ${songs.length == 1 ? 'song' : 'songs'}, ${_minutes(songs)}',
              ].join(' · '),
              voice: plays == 0 ? 'You haven\'t played it yet.' : 'You\'ve played it $plays ${plays == 1 ? 'time' : 'times'}. Last ${whenPlayed(last)}.',
              actions: [
                ...playButtons(context, songs, album.title),
                likeBtn(context, album.id, album.favorite),
                if (LibraryScope.of(context).mayDownload && !LibraryScope.of(context).demo)
                  RoundBtn(
                    songs.every((s) => DownloadsScope.of(context).has(s.id)) ? Icons.download_done_rounded : Icons.download_outlined,
                    'Download',
                    () => download(context, songs),
                  ),
                if (album.artistId != null) RoundBtn(Icons.person_outline_rounded, 'Go to artist', () => openPage(context, PageKind.artist, [album.artistId])),
                Builder(
                  builder: (c) => RoundBtn(
                    Icons.more_horiz_rounded,
                    'More',
                    () => albumMenu(c, album, (c.findRenderObject() as RenderBox).localToGlobal(const Offset(0, 40))),
                  ),
                ),
                if (format != null && format.isNotEmpty) InfoChip(format),
              ],
            ),
          ),
          SliverList.list(
            children: [
              for (final (i, s) in songs.indexed) ...[
                if (discs.length > 1 && (i == 0 || songs[i - 1].disc != s.disc))
                  Padding(
                    padding: EdgeInsets.fromLTRB(12, i == 0 ? 0 : 18, 0, 8),
                    child: Text('DISC ${s.disc}', style: Txt.caps()),
                  ),
                TrackRow(s, index: s.track > 0 ? s.track : i + 1, queue: songs, cols: TrackCols.artist, source: album.title),
              ],
            ],
          ),
          if (album.overview != null && album.overview!.trim().isNotEmpty) ...[
            const SliverToBoxAdapter(child: SectionTitle('About')),
            SliverToBoxAdapter(
              child: Text(album.overview!.trim(), style: ts(13, c: K.text2, h: 1.5)),
            ),
          ],
        ],
      );
    },
  );
}

// Artist -----------------------------------------------------------------------

class ArtistPage extends StatefulWidget {
  const ArtistPage(this.id, {super.key});
  final String id;

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

typedef _ArtistData = ({Artist artist, List<Song> top, List<Song> all, List<Album> own, List<Album> appearsOn, List<Artist> similar});

class _ArtistPageState extends State<ArtistPage> {
  late Future<_ArtistData> _data = _load();
  bool _bio = false;

  Future<_ArtistData> _load() async {
    final lib = LibraryScope.read(context);
    final j = lib.jf;
    if (j == null) throw JellyfinError('Sign in to see artists.');
    final item = await lib.item(widget.id);
    if (item == null) throw JellyfinError('This artist is gone from the server.');
    final r = await Future.wait([lib.artistSongs(widget.id), lib.artistAlbums(widget.id), lib.similarArtists(widget.id)]);
    final all = r[0] as List<Song>;
    final albums = r[1] as ({List<Album> own, List<Album> appearsOn});
    // Top songs by plays, from the songs already here (artist-page.ts).
    final byId = {for (final s in all) s.id: s};
    final top = topSongsOf([
      for (final s in all)
        {
          'Id': s.id,
          'UserData': {'PlayCount': s.playCount},
        },
    ]).map((i) => byId[i['Id']]!).toList();
    return (artist: j.artist(item), top: top, all: all, own: albums.own, appearsOn: albums.appearsOn, similar: r[2] as List<Artist>);
  }

  @override
  Widget build(BuildContext context) => Loading<_ArtistData>(
    future: _data,
    sliver: false,
    onRetry: () => setState(() => _data = _load()),
    builder: (context, d) {
      final a = d.artist;
      final plays = d.all.fold<int>(0, (t, s) => t + s.playCount);
      final bio = (a.overview ?? '').trim();
      return PageScroll(
        slivers: [
          SliverToBoxAdapter(
            child: DetailHeader(
              label: 'Artist',
              title: a.name,
              art: a.art,
              image: a.image,
              round: true,
              meta: '${d.own.length} ${d.own.length == 1 ? 'album' : 'albums'} · ${d.all.length} ${d.all.length == 1 ? 'song' : 'songs'} in your library',
              voice: plays == 0 ? 'Nothing played yet.' : 'You\'ve played their songs $plays ${plays == 1 ? 'time' : 'times'}.',
              actions: [
                ...playButtons(context, d.all, a.name),
                likeBtn(context, a.id, a.favorite),
                Builder(
                  builder: (c) => RoundBtn(
                    Icons.more_horiz_rounded,
                    'More',
                    () => artistMenu(c, a, (c.findRenderObject() as RenderBox).localToGlobal(const Offset(0, 40))),
                  ),
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: LayoutBuilder(
              builder: (context, c) {
                final top = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionTitle('Your top songs', top: 0),
                    if (d.top.isEmpty) Text('Play something of theirs and it shows here.', style: ts(13, c: K.text3)),
                    for (final (i, s) in d.top.indexed) TrackRow(s, index: i + 1, queue: d.top, cols: TrackCols.artist, showArt: true, source: a.name),
                  ],
                );
                if (c.maxWidth < 900) return top;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: top),
                    const SizedBox(width: 32),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (bio.isNotEmpty) ...[
                            const SectionTitle('About', top: 0),
                            Text(
                              bio,
                              maxLines: _bio ? null : 6,
                              overflow: _bio ? null : TextOverflow.ellipsis,
                              style: ts(13, c: K.text2, h: 1.5),
                            ),
                            if (bio.length > 400)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Hover(
                                  onTap: () => setState(() => _bio = !_bio),
                                  builder: (_, on) => Text(
                                    _bio ? 'Less' : 'More',
                                    style: ts(12, w: FontWeight.w600, c: on ? K.text : K.accent),
                                  ),
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          if (d.own.isNotEmpty) ...[
            const SliverToBoxAdapter(child: SectionTitle('Albums')),
            CardGrid(count: d.own.length, builder: (c, i) => _yearCard(c, d.own[i])),
          ],
          if (d.appearsOn.isNotEmpty) ...[
            const SliverToBoxAdapter(child: SectionTitle('Appears on')),
            CardGrid(count: d.appearsOn.length, builder: (c, i) => albumCard(c, d.appearsOn[i])),
          ],
          if (d.similar.isNotEmpty) ...[
            const SliverToBoxAdapter(child: SectionTitle('Similar artists')),
            CardGrid(count: min(12, d.similar.length), minWidth: 130, builder: (c, i) => artistCard(c, d.similar[i])),
          ],
        ],
      );
    },
  );

  Widget _yearCard(BuildContext context, Album a) => MediaCard(
    title: a.title,
    subtitle: a.year > 0 ? '${a.year}' : '',
    art: a.art,
    image: a.image,
    onTap: () => openPage(context, PageKind.album, [a.id]),
    onPlay: () async {
      final p = PlayerScope.read(context);
      await playAll(p, await LibraryScope.read(context).tracksOf(a), a.title);
    },
    onMenu: (o) => albumMenu(context, a, o),
  );
}

// Playlist ---------------------------------------------------------------------

class PlaylistPage extends StatefulWidget {
  const PlaylistPage(this.id, {super.key});
  final String id;

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  late Future<(Album, List<Song>)> _data = _load();
  bool _editing = false;
  List<Song>? _songs; // the order on screen while editing
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<(Album, List<Song>)> _load() async {
    final lib = LibraryScope.read(context);
    final j = lib.jf;
    if (j == null) return (demoPlaylists.first, const [reckoner, weirdFishes, ...demoRecentlyPlayed]);
    final item = await lib.item(widget.id);
    if (item == null) throw JellyfinError('This playlist is gone from the server.');
    final pl = j.album(item);
    final songs = await lib.tracksOf(pl);
    _songs = songs;
    return (pl, songs);
  }

  Future<void> _save(List<Song> songs, String done) async {
    final lib = LibraryScope.read(context);
    setState(() => _songs = songs);
    try {
      await lib.setPlaylistSongs(widget.id, [for (final s in songs) s.id]);
      if (mounted) toast(context, done);
    } catch (e) {
      if (mounted) toast(context, 'Could not update the playlist: $e', error: true);
    }
    if (mounted) setState(() => _data = _load());
  }

  Future<void> _rename(String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    try {
      await LibraryScope.read(context).renamePlaylist(widget.id, n);
      if (mounted) setState(() => _data = _load());
    } catch (e) {
      if (mounted) toast(context, 'Could not rename it: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) => Loading<(Album, List<Song>)>(
    future: _data,
    sliver: false,
    onRetry: () => setState(() => _data = _load()),
    builder: (context, d) {
      final (pl, loaded) = d;
      final songs = _songs ?? loaded;
      final lib = LibraryScope.of(context);
      return PageScroll(
        slivers: [
          SliverToBoxAdapter(
            child: DetailHeader(
              label: 'Playlist',
              title: pl.title,
              art: songs.isEmpty ? pl.art : songs.first.art,
              image: pl.image ?? songs.firstOrNull?.image,
              meta: '${songs.length} ${songs.length == 1 ? 'song' : 'songs'} · ${_minutes(songs)}',
              titleWidget: _editing
                  ? SizedBox(
                      width: 520,
                      child: TextField(
                        controller: _name..text = _name.text.isEmpty ? pl.title : _name.text,
                        style: ds(44),
                        decoration: const InputDecoration(isDense: true),
                        onSubmitted: _rename,
                      ),
                    )
                  : null,
              actions: [
                ...playButtons(context, songs, pl.title),
                likeBtn(context, pl.id, pl.favorite),
                if (lib.mayDownload && !lib.demo) RoundBtn(Icons.download_outlined, 'Download', () => download(context, songs)),
                Builder(
                  builder: (c) => RoundBtn(
                    Icons.more_horiz_rounded,
                    'More',
                    () => albumMenu(c, pl, (c.findRenderObject() as RenderBox).localToGlobal(const Offset(0, 40))),
                  ),
                ),
                if (!lib.demo)
                  Pill(
                    _editing ? 'Done' : 'Edit',
                    primary: _editing,
                    onTap: () {
                      if (_editing && _name.text.trim().isNotEmpty && _name.text.trim() != pl.title) _rename(_name.text);
                      setState(() => _editing = !_editing);
                    },
                  ),
              ],
            ),
          ),
          if (songs.isEmpty)
            const SliverToBoxAdapter(child: Empty('No songs yet. Add some from any song\'s menu.', icon: Icons.queue_music_rounded))
          else if (_editing)
            SliverReorderableList(
              itemCount: songs.length,
              onReorderItem: (from, to) {
                final list = [...songs];
                list.insert(to, list.removeAt(from));
                _save(list, 'Moved ${songs[from].title}');
              },
              itemBuilder: (context, i) => Row(
                key: ValueKey('${songs[i].playlistItemId ?? songs[i].id}$i'),
                children: [
                  ReorderableDragStartListener(
                    index: i,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.drag_indicator_rounded, size: 18, color: K.text3),
                    ),
                  ),
                  Expanded(
                    child: TrackRow(songs[i], index: i + 1, queue: songs, cols: TrackCols.playlist, showArt: true, source: pl.title),
                  ),
                  IconBtn(Icons.remove_circle_outline_rounded, 'Remove', () => _save([...songs]..removeAt(i), 'Removed ${songs[i].title}')),
                ],
              ),
            )
          else
            SliverList.builder(
              itemCount: songs.length,
              itemBuilder: (context, i) => TrackRow(
                songs[i],
                index: i + 1,
                queue: songs,
                cols: TrackCols.playlist,
                showArt: true,
                source: pl.title,
                onMenu: (o) => songMenu(
                  context,
                  songs[i],
                  o,
                  queue: songs,
                  playlistId: pl.id,
                  onRemoved: () => _save([...songs]..removeAt(i), 'Removed ${songs[i].title}'),
                ),
              ),
            ),
        ],
      );
    },
  );
}

// Genre ------------------------------------------------------------------------

class GenrePage extends StatefulWidget {
  const GenrePage(this.id, this.name, {super.key});
  final String id, name;

  @override
  State<GenrePage> createState() => _GenrePageState();
}

class _GenrePageState extends State<GenrePage> {
  late final _songs = LibraryScope.read(context).genreSongs(widget.id);
  late final _albums = LibraryScope.read(context).genreAlbums(widget.id);

  @override
  Widget build(BuildContext context) {
    final name = widget.name;
    return PageScroll(
      slivers: [
        Loading<List<Song>>(
          future: _songs,
          builder: (context, songs) => SliverToBoxAdapter(
            child: PageHeader(name, voice: '${songs.length} ${songs.length == 1 ? 'song' : 'songs'}', actions: playButtons(context, songs, name)),
          ),
        ),
        const SliverToBoxAdapter(child: SectionTitle('Albums', top: 0)),
        Loading<List<Album>>(
          future: _albums,
          builder: (context, albums) => albums.isEmpty
              ? const SliverToBoxAdapter(child: Empty('No albums in this genre.'))
              : CardGrid(count: albums.length, builder: (c, i) => albumCard(c, albums[i])),
        ),
      ],
    );
  }
}
