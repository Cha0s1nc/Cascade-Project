// Now Playing on phones: a full-screen view from the mini player, closed by
// the back gesture or a swipe down. Controls sit in the thumb zone; Lyrics
// and Queue take the screen above them; More holds the rest.
import 'package:flutter/material.dart';

import 'package:cascade/core/nav.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/ui/now_playing.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/settings_panel.dart';
import 'package:cascade/ui/widgets.dart';

class PhoneNowPlaying extends StatefulWidget {
  const PhoneNowPlaying({super.key});

  @override
  State<PhoneNowPlaying> createState() => _PhoneNowPlayingState();
}

class _PhoneNowPlayingState extends State<PhoneNowPlaying> {
  /// null: the art; else that panel fills the space above the controls.
  NpPanel? _panel;

  @override
  Widget build(BuildContext context) {
    final p = PlayerScope.of(context);
    final np = NowPlayingScope.of(context);
    final song = p.song;
    if (song == null) return const SizedBox.shrink();
    return GestureDetector(
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 300) np.close();
      },
      child: Material(
        color: K.root,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ArtBackground(song: song, dim: 0.55),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        IconButton(
                          onPressed: np.close,
                          tooltip: 'Close',
                          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30, color: K.text),
                        ),
                        Expanded(
                          child: Column(
                            children: [
                              Text('PLAYING FROM', style: Txt.caps()),
                              Text(
                                p.source ?? song.album,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ts(13, w: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => _more(context, p),
                          tooltip: 'More',
                          icon: const Icon(Icons.more_vert_rounded, color: K.text),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: switch (_panel) {
                        NpPanel.lyrics => LyricsPanel(key: ValueKey(song.id), song: song, size: 26, phone: true),
                        NpPanel.queue => const QueuePanel(phone: true),
                        null => Center(
                          child: LayoutBuilder(
                            builder: (context, c) => ArtStack(song, next: p.upNext, size: (c.maxWidth * 0.82).clamp(0, c.maxHeight)),
                          ),
                        ),
                      },
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ds(24)),
                              Text(
                                song.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ts(15, c: K.text2),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: p.toggleLike,
                          icon: Icon(p.isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: p.isLiked ? K.like : K.text2),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ThinBar(value: p.length > 0 ? p.position / p.length : 0, onChanged: p.length > 0 ? (v) => p.seek(v * p.length) : null),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(fmt(p.position), style: ts(12, c: K.text3)),
                          Text(fmt(p.length), style: ts(12, c: K.text3)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          onPressed: p.toggleShuffle,
                          icon: Icon(Icons.shuffle_rounded, color: p.shuffle ? K.accent : K.text2),
                        ),
                        IconButton(
                          onPressed: p.prev,
                          iconSize: 38,
                          icon: const Icon(Icons.skip_previous_rounded, color: K.text),
                        ),
                        PlayCircle(playing: p.playing, onTap: p.toggle, size: 72),
                        IconButton(
                          onPressed: p.next,
                          iconSize: 38,
                          icon: const Icon(Icons.skip_next_rounded, color: K.text),
                        ),
                        IconButton(
                          onPressed: p.toggleRepeat,
                          icon: Icon(
                            p.repeat == Repeat.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                            color: p.repeat == Repeat.off ? K.text2 : K.accent,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _tab(Icons.lyrics_outlined, 'Lyrics', NpPanel.lyrics),
                        _tab(Icons.queue_music_rounded, 'Queue', NpPanel.queue),
                        const SleepTimerButton(),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tab(IconData icon, String label, NpPanel panel) => TextButton.icon(
    onPressed: () => setState(() => _panel = _panel == panel ? null : panel),
    icon: Icon(icon, size: 20, color: _panel == panel ? K.accent : K.text2),
    label: Text(
      label,
      style: ts(13, w: FontWeight.w500, c: _panel == panel ? K.accent : K.text2),
    ),
  );

  void _more(BuildContext context, Player p) {
    final song = p.song!;
    final lib = LibraryScope.read(context);
    final np = NowPlayingScope.read(context);
    final nav = NavScope.read(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: K.panel,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Cover(song.art, image: song.image, size: 44, radius: 6),
              title: Text(song.title, style: ts(15, w: FontWeight.w600)),
              subtitle: Text('${song.artist} · ${song.album}', style: ts(13, c: K.text2)),
            ),
            const Divider(color: K.line),
            if (!lib.demo) _item(ctx, Icons.playlist_add_rounded, 'Add to playlist', () => addToPlaylistDialog(context, [song])),
            if (song.albumId != null)
              _item(ctx, Icons.album_outlined, 'Go to album', () {
                np.close();
                nav.open(PageKind.album, [song.albumId]);
              }),
            if (song.artistId != null)
              _item(ctx, Icons.person_outline_rounded, 'Go to artist', () {
                np.close();
                nav.open(PageKind.artist, [song.artistId]);
              }),
            _item(ctx, Icons.tune_rounded, 'Equalizer', () {
              np.close();
              nav.show('settings');
            }),
          ],
        ),
      ),
    );
  }

  Widget _item(BuildContext ctx, IconData icon, String label, VoidCallback onTap) => ListTile(
    leading: Icon(icon, color: K.text2),
    title: Text(label, style: ts(15)),
    onTap: () {
      Navigator.pop(ctx);
      onTap();
    },
  );
}
