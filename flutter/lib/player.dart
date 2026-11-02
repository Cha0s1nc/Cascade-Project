// A pretend player: it keeps time and a queue so the controls do something,
// but makes no sound. ponytail: a 1 s timer, swap for a real engine later.
import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

import 'data.dart';

class Player extends ChangeNotifier {
  Player() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  late final Timer _timer;
  Song song = weirdFishes;
  List<Song> queue = const [weirdFishes, reckoner, ...recentlyPlayed];
  double position = 134;
  bool playing = true, shuffle = false, repeat = true;
  double volume = 0.7;
  final liked = <String>{};

  bool get isLiked => liked.contains(song.title);

  void _tick() {
    if (!playing) return;
    if (++position >= song.seconds) return next();
    notifyListeners();
  }

  void play(Song s, [List<Song>? from]) {
    if (from != null) queue = from;
    song = s;
    position = 0;
    playing = true;
    notifyListeners();
  }

  void toggle() {
    playing = !playing;
    notifyListeners();
  }

  void next() {
    final i = queue.indexOf(song);
    if (!shuffle && !repeat && i == queue.length - 1) {
      position = 0;
      playing = false;
    } else {
      song = queue[shuffle ? Random().nextInt(queue.length) : (i + 1) % queue.length];
      position = 0;
    }
    notifyListeners();
  }

  void prev() {
    if (position < 3) song = queue[(queue.indexOf(song) - 1 + queue.length) % queue.length];
    position = 0;
    notifyListeners();
  }

  void seek(double s) {
    position = s;
    notifyListeners();
  }

  void setVolume(double v) {
    volume = v;
    notifyListeners();
  }

  void toggleShuffle() {
    shuffle = !shuffle;
    notifyListeners();
  }

  void toggleRepeat() {
    repeat = !repeat;
    notifyListeners();
  }

  void toggleLike() {
    if (!liked.remove(song.title)) liked.add(song.title);
    notifyListeners();
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }
}

class PlayerScope extends InheritedNotifier<Player> {
  const PlayerScope({super.key, required Player player, required super.child}) : super(notifier: player);

  /// Rebuilds the caller on every change (once a second while playing).
  static Player of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PlayerScope>()!.notifier!;

  /// For callbacks: no rebuilds.
  static Player read(BuildContext context) => context.getInheritedWidgetOfExactType<PlayerScope>()!.notifier!;
}
