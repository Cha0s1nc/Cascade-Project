// Now Playing on desktop: a layer over the window body that slides up from
// the player bar, with the art stack on the left and Lyrics or Queue on the
// right. The layout setting picks how much of the window it takes.
import 'package:flutter/material.dart';

import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/widgets.dart';

enum NpPanel { lyrics, queue }

/// Whether Now Playing is open, and which panel it shows.
class NowPlaying extends ChangeNotifier {
  bool open = false;
  NpPanel panel = NpPanel.lyrics;

  void toggle() => open ? close() : show(panel);

  /// Open on [p]; asking for the panel already showing closes it.
  void show(NpPanel p) {
    if (open && panel == p) return close();
    panel = p;
    open = true;
    notifyListeners();
  }

  void close() {
    if (!open) return;
    open = false;
    notifyListeners();
  }
}

/// The window body with Now Playing over it.
class NowPlayingLayer extends StatelessWidget {
  const NowPlayingLayer({super.key, required this.body});
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final np = NowPlayingScope.of(context);
    return Stack(
      children: [
        Positioned.fill(child: body),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !np.open,
            child: AnimatedSlide(
              offset: np.open ? Offset.zero : const Offset(0, 1),
              duration: const Duration(milliseconds: 380),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: np.open ? 1 : 0,
                duration: const Duration(milliseconds: 260),
                child: const ColoredBox(color: K.root, child: NowPlayingView()),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Filled in with the lyrics and queue panels in phase 3.
class NowPlayingView extends StatelessWidget {
  const NowPlayingView({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
