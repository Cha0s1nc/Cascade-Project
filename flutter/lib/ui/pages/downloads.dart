// Downloads: what is saved on this device, by album, with what is still
// coming in, the space it takes, and remove.
import 'package:flutter/material.dart';

import 'package:cascade/core/data.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/offline_index.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/widgets.dart';

/// A downloaded song as the app's model, with or without a server.
Song downloadedSong(Jellyfin? j, Item i) =>
    j?.song(i) ??
    Song(
      i['Name'] as String? ?? '',
      i['AlbumArtist'] as String? ?? '',
      i['Album'] as String? ?? '',
      i['ProductionYear'] as int? ?? 0,
      ((i['RunTimeTicks'] as num? ?? 0) / 1e7).round(),
      artFor(i['Id'] as String),
      id: i['Id'] as String,
      albumId: i['AlbumId'] as String?,
      track: i['IndexNumber'] as int? ?? 0,
    );

String _size(int bytes) => bytes >= 1 << 30 ? '${(bytes / (1 << 30)).toStringAsFixed(1)} GB' : '${(bytes / (1 << 20)).round()} MB';

class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final d = DownloadsScope.of(context);
    final j = LibraryScope.of(context).jf;
    final songs = [for (final i in d.items) downloadedSong(j, i)];
    final albums = <String, List<Song>>{};
    for (final s in songs) {
      albums.putIfAbsent(s.album, () => []).add(s);
    }
    for (final l in albums.values) {
      l.sort((a, b) => a.disc != b.disc ? a.disc - b.disc : a.track - b.track);
    }
    final all = [for (final l in albums.values) ...l];
    return PageScroll(
      slivers: [
        SliverToBoxAdapter(
          child: PageHeader(
            'Downloads',
            voice: songs.isEmpty
                ? 'Download albums and songs from their menus to play them anywhere.'
                : '${songs.length} ${songs.length == 1 ? 'song' : 'songs'}, ${_size(d.bytes)} on this device',
            actions: [
              Pill('Play', icon: Icons.play_arrow_rounded, onTap: all.isEmpty ? null : () => playAll(PlayerScope.read(context), all, 'Downloads')),
              Pill(
                'Shuffle',
                icon: Icons.shuffle_rounded,
                primary: false,
                onTap: all.isEmpty ? null : () => playAll(PlayerScope.read(context), all, 'Downloads', shuffle: true),
              ),
            ],
          ),
        ),
        if (d.current != null)
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.only(bottom: 20),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: K.surface, borderRadius: BorderRadius.circular(12)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Downloading ${d.index.tracks[d.current]?.item['Name'] ?? ''}, ${pendingTrackIds(d.index).length} left',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ts(13, w: FontWeight.w600),
                        ),
                      ),
                      // Stops everything still to come; what has landed stays.
                      Pill('Cancel', primary: false, onTap: d.cancelAll),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: d.progress, color: K.accent, backgroundColor: K.line, minHeight: 3),
                ],
              ),
            ),
          ),
        if (d.error != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(d.error!, style: ts(13, c: K.error)),
            ),
          ),
        if (songs.isEmpty)
          SliverToBoxAdapter(
            child: Empty(
              'Nothing downloaded yet. Download albums and playlists from their pages\nto play them without the server.',
              icon: Icons.download_outlined,
              action: ('Browse albums', () => NavScope.read(context).show('albums')),
            ),
          ),
        for (final MapEntry(key: album, value: list) in albums.entries) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 18, bottom: 6),
              child: Row(
                children: [
                  Cover(list.first.art, image: list.first.image, size: 44, radius: 8),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(album.isEmpty ? 'Songs' : album, style: ts(15, w: FontWeight.w600)),
                        Text(list.first.artist, style: ts(12, c: K.text3)),
                      ],
                    ),
                  ),
                  IconBtn(Icons.delete_outline_rounded, 'Remove download', () => d.remove(list.map((s) => s.id))),
                ],
              ),
            ),
          ),
          SliverList.builder(
            itemCount: list.length,
            itemBuilder: (c, i) => TrackRow(list[i], index: i + 1, queue: list, cols: TrackCols.artist, source: album),
          ),
        ],
      ],
    );
  }
}

/// Start downloading [songs], saying so. [collectionId] is the album or
/// playlist they were picked from, kept as one collection.
Future<void> download(BuildContext context, List<Song> songs, {String? collectionId}) async {
  final lib = LibraryScope.read(context);
  final j = lib.jf;
  if (j == null || songs.isEmpty) return;
  if (!lib.mayDownload) return toast(context, 'Your server does not allow downloads for this account.', error: true);
  toast(context, 'Downloading ${songs.length == 1 ? songs.first.title : '${songs.length} songs'}');
  try {
    await DownloadsScope.read(context).add(
      j,
      songs,
      collection: collectionId == null ? null : await lib.item(collectionId),
      views: [...lib.musicLibs, ...lib.movieLibs, ...lib.showLibs],
      user: {'Id': j.userId, 'Name': j.userName, 'Policy': lib.policy},
    );
  } catch (e) {
    if (context.mounted) toast(context, 'Could not download: $e', error: true);
  }
}
