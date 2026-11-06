// The pieces every desktop page is built from: the header with its voice
// line, filter chips, the sort menu, the card grid, track rows, and the
// right-click menus for songs, albums, artists and playlists.
import 'dart:math';

import 'package:flutter/material.dart';

import 'package:cascade/core/data.dart';
import 'package:cascade/core/nav.dart';
import 'package:cascade/ui/pages/downloads.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/widgets.dart';

const pagePadding = EdgeInsets.fromLTRB(32, 30, 32, 32);

/// Phones and narrow windows.
bool narrow(BuildContext context) => MediaQuery.sizeOf(context).width < 600;

EdgeInsets pagePaddingOf(BuildContext context) => narrow(context) ? const EdgeInsets.fromLTRB(16, 12, 16, 24) : pagePadding;

/// A page: its header, then slivers.
class PageScroll extends StatelessWidget {
  const PageScroll({super.key, required this.slivers, this.controller});
  final List<Widget> slivers;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) => CustomScrollView(
    controller: controller,
    slivers: [
      SliverPadding(
        padding: pagePaddingOf(context),
        sliver: SliverMainAxisGroup(slivers: slivers),
      ),
    ],
  );
}

/// The big title, the voice line under it, and the page's buttons.
class PageHeader extends StatelessWidget {
  const PageHeader(this.title, {super.key, this.voice, this.actions = const [], this.below});
  final String title;
  final String? voice;
  final List<Widget> actions;
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    final small = narrow(context);
    final head = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: small ? Txt.title() : Txt.hero()),
        if (voice != null) ...[const SizedBox(height: 6), Text(voice!, style: Txt.voice())],
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (small) ...[
            head,
            if (actions.isNotEmpty) ...[const SizedBox(height: 14), Wrap(spacing: 8, runSpacing: 8, children: actions)],
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: head),
                if (actions.isNotEmpty) Row(spacing: 8, children: actions),
              ],
            ),
          if (below != null) ...[const SizedBox(height: 22), below!],
        ],
      ),
    );
  }
}

/// A row of filter chips; the selected one is accent-tint.
class Chips extends StatelessWidget {
  const Chips(this.items, {super.key});
  final List<(String label, bool on, VoidCallback onTap)> items;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [for (final (label, on, tap) in items) Chip_(label, on: on, onTap: tap)],
  );
}

// ignore: camel_case_types
class Chip_ extends StatelessWidget {
  const Chip_(this.label, {super.key, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: on,
    child: Hover(
      onTap: onTap,
      builder: (_, hover) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: on
              ? K.accentTint
              : hover
              ? K.surface2
              : K.surface,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(
          label,
          style: ts(12, w: FontWeight.w500, c: on ? K.accent : K.text2),
        ),
      ),
    ),
  );
}

/// A quiet button with an icon and label that opens a menu of choices.
class MenuButton<T> extends StatelessWidget {
  const MenuButton({super.key, required this.icon, required this.label, required this.options, required this.selected, required this.onSelected});
  final IconData icon;
  final String label;
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<T>(
    tooltip: '',
    position: PopupMenuPosition.under,
    onSelected: onSelected,
    itemBuilder: (_) => [
      for (final (v, l) in options)
        PopupMenuItem(
          value: v,
          height: 36,
          child: Row(
            children: [
              SizedBox(width: 22, child: v == selected ? const Icon(Icons.check_rounded, size: 16, color: K.accent) : null),
              Text(l, style: ts(13)),
            ],
          ),
        ),
    ],
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: K.surface, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: K.text2),
          const SizedBox(width: 6),
          Text(
            label,
            style: ts(12, w: FontWeight.w500, c: K.text),
          ),
        ],
      ),
    ),
  );
}

/// A responsive grid of cards: as many columns of at least [minWidth] as
/// fit, each card [textHeight] taller than wide for its labels.
class CardGrid extends StatelessWidget {
  const CardGrid({super.key, required this.count, required this.builder, this.minWidth = 160, this.textHeight = 52, this.aspect = 1});
  final int count;
  final Widget Function(BuildContext, int) builder;
  final double minWidth, textHeight, aspect;

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, c) {
      const gap = 22.0;
      final cols = max(2, ((c.crossAxisExtent + gap) / (minWidth + gap)).floor());
      final w = (c.crossAxisExtent - gap * (cols - 1)) / cols;
      return SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          crossAxisSpacing: gap,
          mainAxisSpacing: 18,
          mainAxisExtent: w / aspect + textHeight,
        ),
        delegate: SliverChildBuilderDelegate(builder, childCount: count),
      );
    },
  );
}

/// An album, playlist, artist or genre card: art (round for artists), its
/// name and a line under it. Hovering shows a play button on the art.
class MediaCard extends StatelessWidget {
  const MediaCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.art,
    this.image,
    this.round = false,
    this.aspect = 1,
    required this.onTap,
    this.onPlay,
    this.onMenu,
  });
  final String title, subtitle;
  final List<Color> art;
  final String? image;
  final bool round;
  final double aspect;
  final VoidCallback onTap;
  final VoidCallback? onPlay;
  final void Function(Offset at)? onMenu;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onSecondaryTapUp: onMenu == null ? null : (d) => onMenu!(d.globalPosition),
    onLongPressStart: onMenu == null ? null : (d) => onMenu!(d.globalPosition),
    child: Hover(
      onTap: onTap,
      builder: (_, on) => Column(
        crossAxisAlignment: round ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: aspect,
            child: Stack(
              children: [
                Positioned.fill(
                  child: round ? ClipOval(child: Cover(art, image: image, radius: 0)) : Cover(art, image: image, radius: 10, shadow: on),
                ),
                if (onPlay != null)
                  Positioned(
                    right: 10,
                    bottom: 10,
                    child: AnimatedOpacity(
                      opacity: on ? 1 : 0,
                      duration: const Duration(milliseconds: 140),
                      child: PlayCircle(playing: false, onTap: onPlay!, size: 40),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: round ? TextAlign.center : TextAlign.start,
            style: ts(13, w: FontWeight.w500, c: on ? K.accent : K.text),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ts(12, c: K.text3),
          ),
        ],
      ),
    ),
  );
}

/// Waits for [future]; a spinner while it loads, the error with Try again.
class Loading<T> extends StatelessWidget {
  const Loading({super.key, required this.future, required this.builder, this.onRetry, this.sliver = true});
  final Future<T> future;
  final Widget Function(BuildContext, T) builder;
  final VoidCallback? onRetry;
  final bool sliver;

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
    future: future,
    builder: (context, snap) {
      Widget box(Widget w) => sliver ? SliverToBoxAdapter(child: w) : w;
      if (snap.hasError) {
        return box(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Column(
              children: [
                Text(
                  'Could not load this: ${snap.error}',
                  textAlign: TextAlign.center,
                  style: ts(13, c: K.error),
                ),
                if (onRetry != null) ...[const SizedBox(height: 12), Pill('Try again', onTap: onRetry, primary: false)],
              ],
            ),
          ),
        );
      }
      if (!snap.hasData) {
        return box(
          const Padding(
            padding: EdgeInsets.all(60),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
          ),
        );
      }
      return builder(context, snap.data as T);
    },
  );
}

/// A message where a list would be.
class Empty extends StatelessWidget {
  const Empty(this.text, {super.key, this.icon = Icons.library_music_outlined});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 60),
    child: Column(
      children: [
        Icon(icon, size: 36, color: K.text3),
        const SizedBox(height: 12),
        Text(
          text,
          textAlign: TextAlign.center,
          style: ts(14, c: K.text2),
        ),
      ],
    ),
  );
}

/// A section title inside a page, with an optional link at the right.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.link, this.onLink, this.top = 30});
  final String title;
  final String? link;
  final VoidCallback? onLink;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: top, bottom: 14),
    child: Row(
      children: [
        Expanded(child: Text(title, style: Txt.section())),
        if (link != null)
          Hover(
            onTap: onLink,
            builder: (_, on) => Text(
              link!,
              style: ts(12, w: FontWeight.w500, c: on ? K.text : K.text2),
            ),
          ),
      ],
    ),
  );
}

/// What a track row shows besides the title.
enum TrackCols { album, artist, playlist }

/// One song in a list: number (or the playing bars), title, the artist or
/// album, plays and length. Click plays from here; right-click is its menu.
class TrackRow extends StatelessWidget {
  const TrackRow(this.song, {super.key, required this.index, required this.queue, this.cols = TrackCols.album, this.source, this.onMenu, this.showArt = false});
  final Song song;
  final int index;
  final List<Song> queue;
  final TrackCols cols;
  final String? source;
  final void Function(Offset at)? onMenu;
  final bool showArt;

  @override
  Widget build(BuildContext context) {
    final p = PlayerScope.of(context);
    final current = p.song == song;
    final lib = LibraryScope.of(context);
    final fav = lib.isFavorite(song.id, song.favorite);
    final second = switch (cols) {
      TrackCols.album => song.artist,
      TrackCols.artist => song.album,
      TrackCols.playlist => '${song.artist} · ${song.album}',
    };
    return GestureDetector(
      onSecondaryTapUp: (d) => (onMenu ?? (o) => songMenu(context, song, o, queue: queue))(d.globalPosition),
      onLongPressStart: (d) => (onMenu ?? (o) => songMenu(context, song, o, queue: queue))(d.globalPosition),
      child: Hover(
        onTap: () => current ? p.toggle() : p.play(song, queue, source),
        builder: (_, on) => Container(
          height: showArt ? 56 : 46,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: current
                ? K.surface
                : on
                ? K.line
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 30,
                child: current && p.playing
                    ? const Icon(Icons.equalizer_rounded, size: 16, color: K.accent)
                    : on
                    ? const Icon(Icons.play_arrow_rounded, size: 18, color: K.text)
                    : Text('$index', style: ts(12, c: K.text3)),
              ),
              if (showArt) ...[Cover(song.art, image: song.image, size: 40, radius: 6), const SizedBox(width: 12)] else const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts(13, w: FontWeight.w500, c: current ? K.accent : K.text),
                    ),
                    if (second.isNotEmpty && cols != TrackCols.artist)
                      Text(
                        second,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ts(12, c: K.text3),
                      ),
                  ],
                ),
              ),
              if (cols == TrackCols.artist)
                Expanded(
                  flex: 2,
                  child: Text(
                    second,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts(12, c: K.text3),
                  ),
                ),
              if (on || fav)
                IconBtn(
                  fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  fav ? 'Unlike' : 'Like',
                  () => lib.toggleFavorite(song.id, song.favorite),
                  color: fav ? K.like : K.text3,
                  size: 15,
                ),
              if (song.playCount > 0 && !narrow(context))
                SizedBox(
                  width: 72,
                  child: Text(
                    '${song.playCount} ${song.playCount == 1 ? 'play' : 'plays'}',
                    textAlign: TextAlign.right,
                    style: ts(12, c: K.text3),
                  ),
                ),
              SizedBox(
                width: 52,
                child: Text(
                  song.seconds > 0 ? fmt(song.seconds) : '',
                  textAlign: TextAlign.right,
                  style: ts(12, c: K.text3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Open a page from anywhere.
void openPage(BuildContext context, PageKind kind, List<Object?> args) {
  NowPlayingScope.maybeRead(context)?.close();
  NavScope.read(context).open(kind, args);
}

/// Pick a playlist (or make one) and put [songs] in it.
Future<void> addToPlaylistDialog(BuildContext context, List<Song> songs) async {
  final lib = LibraryScope.read(context);
  final playlists = await lib.playlistItems();
  if (!context.mounted) return;
  final name = TextEditingController();
  final picked = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: K.panel,
      title: Text('Add to playlist', style: Txt.section()),
      content: SizedBox(
        width: 380,
        height: 360,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: name,
                    autofocus: true,
                    style: ts(13),
                    decoration: InputDecoration(
                      hintText: 'New playlist',
                      hintStyle: ts(13, c: K.text3),
                      isDense: true,
                    ),
                    onSubmitted: (v) => v.trim().isEmpty ? null : Navigator.pop(ctx, 'new:${v.trim()}'),
                  ),
                ),
                const SizedBox(width: 8),
                Pill('Create', onTap: () => name.text.trim().isEmpty ? null : Navigator.pop(ctx, 'new:${name.text.trim()}')),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                children: [
                  for (final pl in playlists)
                    Hover(
                      onTap: () => Navigator.pop(ctx, pl['Id'] as String),
                      builder: (_, on) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                        decoration: BoxDecoration(color: on ? K.surface : Colors.transparent, borderRadius: BorderRadius.circular(8)),
                        child: Row(
                          children: [
                            const Icon(Icons.queue_music_rounded, size: 18, color: K.text2),
                            const SizedBox(width: 10),
                            Expanded(child: Text(pl['Name'] as String? ?? '', style: ts(13))),
                            Text('${pl['ChildCount'] ?? ''}', style: ts(12, c: K.text3)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  name.dispose();
  if (picked == null || !context.mounted) return;
  final ids = [for (final s in songs) s.id];
  try {
    if (picked.startsWith('new:')) {
      await lib.createPlaylist(picked.substring(4), ids);
      if (context.mounted) toast(context, 'Made the playlist ${picked.substring(4)}');
    } else {
      await lib.addToPlaylist(picked, ids);
      if (context.mounted) toast(context, 'Added ${songs.length == 1 ? songs.first.title : '${songs.length} songs'}');
    }
  } catch (e) {
    if (context.mounted) toast(context, 'Could not add to the playlist: $e', error: true);
  }
}

void toast(BuildContext context, String text, {bool error = false}) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(
  SnackBar(
    content: Text(text, style: ts(13, c: error ? K.error : K.text)),
    backgroundColor: K.surface,
    behavior: SnackBarBehavior.floating,
    width: 420,
    duration: const Duration(milliseconds: 2400),
  ),
);

/// Ask before something that cannot be undone.
Future<bool> confirm(BuildContext context, String title, String body, String yes) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: K.panel,
        title: Text(title, style: Txt.section()),
        content: Text(body, style: ts(13, c: K.text2)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              yes,
              style: ts(13, w: FontWeight.w600, c: K.error),
            ),
          ),
        ],
      ),
    ) ??
    false;

/// A menu at [at]: (label, icon, action) entries, null for a divider.
Future<void> showItemMenu(BuildContext context, Offset at, List<(String, IconData, VoidCallback)?> entries) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final pick = await showMenu<VoidCallback>(
    context: context,
    position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
    items: [
      for (final e in entries)
        if (e == null)
          const PopupMenuDivider(height: 8)
        else
          PopupMenuItem(
            value: e.$3,
            height: 34,
            child: Row(
              children: [
                Icon(e.$2, size: 16, color: K.text2),
                const SizedBox(width: 10),
                Text(e.$1, style: ts(13)),
              ],
            ),
          ),
    ],
  );
  pick?.call();
}

/// A song's menu (context-menu.ts's song entries).
void songMenu(BuildContext context, Song song, Offset at, {List<Song>? queue, String? playlistId, VoidCallback? onRemoved}) {
  final p = PlayerScope.read(context);
  final lib = LibraryScope.read(context);
  final fav = lib.isFavorite(song.id, song.favorite);
  showItemMenu(context, at, [
    ('Play', Icons.play_arrow_rounded, () => p.play(song, queue ?? [song])),
    ('Play next', Icons.playlist_play_rounded, () => p.playNext([song])),
    ('Add to queue', Icons.queue_music_rounded, () => p.addToQueue([song])),
    if (!lib.demo) ('Add to playlist', Icons.playlist_add_rounded, () => addToPlaylistDialog(context, [song])),
    null,
    if (song.albumId != null) ('Go to album', Icons.album_outlined, () => openPage(context, PageKind.album, [song.albumId])),
    if (song.artistId != null) ('Go to artist', Icons.person_outline_rounded, () => openPage(context, PageKind.artist, [song.artistId])),
    if (!lib.demo) ...[
      (fav ? 'Unlike' : 'Like', fav ? Icons.favorite_rounded : Icons.favorite_border_rounded, () => lib.toggleFavorite(song.id, song.favorite)),
      if (!lib.offline) ('Instant mix', Icons.auto_awesome_outlined, () async => p.play(song, [song, ...await lib.instantMix(song.id)], 'Instant mix')),
      if (lib.mayDownload && !DownloadsScope.read(context).has(song.id)) ('Download', Icons.download_outlined, () => download(context, [song])),
    ],
    if (playlistId != null && song.playlistItemId != null) ...[null, ('Remove from playlist', Icons.remove_circle_outline_rounded, () => onRemoved?.call())],
    if (lib.canDelete) ...[
      null,
      (
        'Delete from server',
        Icons.delete_outline_rounded,
        () async {
          if (await confirm(context, 'Delete ${song.title}?', 'This deletes the file from the server for everyone.', 'Delete') &&
              await lib.deleteItem(song.id) &&
              context.mounted) {
            toast(context, 'Deleted ${song.title}');
          }
        },
      ),
    ],
  ]);
}

/// An album's or playlist's menu.
void albumMenu(BuildContext context, Album a, Offset at) {
  final p = PlayerScope.read(context);
  final lib = LibraryScope.read(context);
  final fav = lib.isFavorite(a.id, a.favorite);
  Future<List<Song>> tracks() => lib.tracksOf(a);
  showItemMenu(context, at, [
    ('Play', Icons.play_arrow_rounded, () async => playAll(p, await tracks(), a.title)),
    ('Shuffle', Icons.shuffle_rounded, () async => playAll(p, await tracks(), a.title, shuffle: true)),
    ('Play next', Icons.playlist_play_rounded, () async => p.playNext(await tracks())),
    ('Add to queue', Icons.queue_music_rounded, () async => p.addToQueue(await tracks())),
    if (!lib.demo && !a.playlist)
      (
        'Add to playlist',
        Icons.playlist_add_rounded,
        () async {
          final t = await tracks();
          if (context.mounted) await addToPlaylistDialog(context, t);
        },
      ),
    null,
    if (a.artistId != null) ('Go to artist', Icons.person_outline_rounded, () => openPage(context, PageKind.artist, [a.artistId])),
    if (!lib.demo) ...[
      (fav ? 'Unlike' : 'Like', fav ? Icons.favorite_rounded : Icons.favorite_border_rounded, () => lib.toggleFavorite(a.id, a.favorite)),
      if (!a.playlist) ('Instant mix', Icons.auto_awesome_outlined, () async => playAll(p, await lib.instantMix(a.id), 'Instant mix')),
      if (lib.mayDownload)
        (
          'Download',
          Icons.download_outlined,
          () async {
            final t = await tracks();
            if (context.mounted) await download(context, t, collectionId: a.id);
          },
        ),
    ],
    if (a.playlist || lib.canDelete) ...[
      null,
      (
        a.playlist ? 'Delete playlist' : 'Delete from server',
        Icons.delete_outline_rounded,
        () async {
          if (await confirm(
                context,
                'Delete ${a.title}?',
                a.playlist ? 'The playlist goes; its songs stay.' : 'This deletes the album from the server for everyone.',
                'Delete',
              ) &&
              await lib.deleteItem(a.id) &&
              context.mounted) {
            NavScope.maybeRead(context)?.forget(a.playlist ? PageKind.playlist : PageKind.album, a.id);
            toast(context, 'Deleted ${a.title}');
          }
        },
      ),
    ],
  ]);
}

void artistMenu(BuildContext context, Artist a, Offset at) {
  final p = PlayerScope.read(context);
  final lib = LibraryScope.read(context);
  final fav = lib.isFavorite(a.id, a.favorite);
  showItemMenu(context, at, [
    ('Play all', Icons.play_arrow_rounded, () async => playAll(p, await lib.artistSongs(a.id), a.name)),
    ('Shuffle all', Icons.shuffle_rounded, () async => playAll(p, await lib.artistSongs(a.id), a.name, shuffle: true)),
    ('Instant mix', Icons.auto_awesome_outlined, () async => playAll(p, await lib.instantMix(a.id), 'Instant mix')),
    null,
    (fav ? 'Unlike' : 'Like', fav ? Icons.favorite_rounded : Icons.favorite_border_rounded, () => lib.toggleFavorite(a.id, a.favorite)),
  ]);
}

/// Play [songs] from the top, or shuffled.
Future<void> playAll(dynamic p, List<Song> songs, String? source, {bool shuffle = false}) async {
  if (songs.isEmpty) return;
  if (shuffle != p.shuffle) await p.toggleShuffle();
  final first = shuffle ? songs[Random().nextInt(songs.length)] : songs.first;
  await p.play(first, songs, source);
}
