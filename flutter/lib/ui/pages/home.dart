// Desktop Home: the greeting and voice line, Recently played with the Home
// card, Continue watching, the Rediscover shelf, and Recently added.
import 'dart:math';

import 'package:flutter/material.dart';

import 'package:cascade/core/data.dart';
import 'package:cascade/core/nav.dart';
import 'package:cascade/core/rediscover.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/pages/library.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/widgets.dart';

String _thousands(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// "4,212 songs on your server. 61 of them played this week."
String homeVoice(({int songs, int week}) s) {
  if (s.songs == 0) return 'Your server has no songs yet.';
  final first = '${_thousands(s.songs)} ${s.songs == 1 ? 'song' : 'songs'} on your server.';
  return s.week == 0 ? '$first Nothing played this week yet.' : '$first ${s.week} of them played this week.';
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Future<Shelves>? _shelves;

  Future<Shelves> _loadShelves() async {
    final lib = LibraryScope.read(context);
    final [albums, songs] = await Future.wait([lib.albumItems(), lib.songItems()]);
    return rediscover(albums, songs, DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);
    final nav = NavScope.read(context);
    final played = lib.recentlyPlayed;
    final tiles = played.skip(1).take(8).toList();
    if (!lib.demo && lib.jf != null) _shelves ??= _loadShelves();
    return SingleChildScrollView(
      padding: pagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(greeting(lib.jf?.userName ?? 'Cha0s'), style: Txt.hero()),
          const SizedBox(height: 6),
          FutureBuilder(
            future: lib.stats(),
            builder: (context, snap) => Text(snap.hasData ? homeVoice(snap.data!) : today(), style: Txt.voice()),
          ),
          LoadError(padding: const EdgeInsets.only(top: 12)),
          if (lib.loading && played.isEmpty)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
            ),
          if (played.isNotEmpty) ...[
            SectionTitle('Recently played', link: 'See all', onLink: () => nav.show('history')),
            LayoutBuilder(
              builder: (context, c) {
                final grid = Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 12,
                  children: [
                    for (final half in [tiles.take(4), tiles.skip(4)])
                      Expanded(
                        child: Column(spacing: 8, children: [for (final s in half) SongTile(s, queue: played)]),
                      ),
                  ],
                );
                final hero = HeroCard(played.first, played, compact: false);
                return c.maxWidth >= 900
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 16,
                        children: [
                          SizedBox(width: c.maxWidth >= 1150 ? 440 : 380, child: hero),
                          Expanded(child: grid),
                        ],
                      )
                    : Column(spacing: 16, children: [hero, grid]);
              },
            ),
          ],
          if (lib.continueWatching.isNotEmpty) ...[
            SectionTitle('Continue watching', link: 'See all', onLink: () => nav.show(lib.showIds.isNotEmpty ? 'shows' : 'movies')),
            LayoutBuilder(
              builder: (context, c) {
                final w = (c.maxWidth - 32) / 3;
                return Row(
                  spacing: 16,
                  children: [for (final v in lib.continueWatching.take(3)) SizedBox(width: w, child: VideoCard(v))],
                );
              },
            ),
          ],
          if (_shelves != null)
            FutureBuilder<Shelves>(
              future: _shelves,
              builder: (context, snap) {
                final loved = snap.data?.usedToLove ?? const [];
                if (loved.isEmpty) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SectionTitle('Rediscover', link: 'Not played in a year', onLink: () => nav.show('rediscover')),
                    _Shelf([for (final a in loved) lib.jf!.album(a)]),
                  ],
                );
              },
            ),
          if (lib.recentlyAdded.isNotEmpty) ...[
            SectionTitle('Recently added', link: 'See all', onLink: () => nav.show('albums')),
            _Shelf(lib.recentlyAdded),
          ],
        ],
      ),
    );
  }
}

/// One row of album cards, as many as fit.
class _Shelf extends StatelessWidget {
  const _Shelf(this.albums);
  final List<Album> albums;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final n = max(3, ((c.maxWidth + 18) / 160).floor());
      final w = (c.maxWidth - 18 * (n - 1)) / n;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 18,
        children: [for (final a in albums.take(n)) SizedBox(width: w, height: w + 52, child: albumCard(context, a))],
      );
    },
  );
}

class VideoCard extends StatelessWidget {
  const VideoCard(this.video, {super.key});
  final Video video;

  @override
  Widget build(BuildContext context) => Hover(
    onTap: () => openVideo(context, video),
    builder: (_, on) => Row(
      children: [
        AnimatedScale(scale: on ? 1.03 : 1, duration: const Duration(milliseconds: 150), child: VideoThumb(video, width: 160)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(video.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(14, w: FontWeight.w600)),
              const SizedBox(height: 3),
              Text(video.episode, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(12, c: K.text2)),
              const SizedBox(height: 3),
              Text(video.left, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(12, c: K.text3)),
            ],
          ),
        ),
      ],
    ),
  );
}

/// A movie opens its page; an episode opens its series.
void openVideo(BuildContext context, Video v) {
  if (v.id.isEmpty) return;
  if (v.type == 'Episode' && v.seriesId != null) {
    openPage(context, PageKind.series, [v.seriesId]);
  } else {
    openPage(context, v.type == 'Series' ? PageKind.series : PageKind.movie, [v.id]);
  }
}
