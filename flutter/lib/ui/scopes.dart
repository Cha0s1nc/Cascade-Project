// How widgets reach the library and the player: InheritedNotifiers, so a
// widget that reads `of` rebuilds when they change and `read` never does.
import 'package:flutter/widgets.dart';

import 'package:cascade/ui/now_playing.dart';

import 'package:cascade/core/downloads.dart';
import 'package:cascade/core/library.dart';
import 'package:cascade/core/nav.dart';
import 'package:cascade/engine/player.dart';

class LibraryScope extends InheritedNotifier<Library> {
  const LibraryScope({super.key, required Library library, required super.child}) : super(notifier: library);

  static Library of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<LibraryScope>()!.notifier!;
  static Library read(BuildContext context) => context.getInheritedWidgetOfExactType<LibraryScope>()!.notifier!;
}

class PlayerScope extends InheritedNotifier<Player> {
  const PlayerScope({super.key, required Player player, required super.child}) : super(notifier: player);

  /// Rebuilds the caller on every change (once a second while playing).
  static Player of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PlayerScope>()!.notifier!;

  /// For callbacks: no rebuilds.
  static Player read(BuildContext context) => context.getInheritedWidgetOfExactType<PlayerScope>()!.notifier!;
  static Player? maybeRead(BuildContext context) => context.getInheritedWidgetOfExactType<PlayerScope>()?.notifier;
}

/// The shell's page history, for anything that opens a page.
class NavScope extends InheritedNotifier<Nav> {
  const NavScope({super.key, required Nav nav, required super.child}) : super(notifier: nav);

  static Nav of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<NavScope>()!.notifier!;
  static Nav read(BuildContext context) => context.getInheritedWidgetOfExactType<NavScope>()!.notifier!;
  static Nav? maybeRead(BuildContext context) => context.getInheritedWidgetOfExactType<NavScope>()?.notifier;
}

/// Now Playing's open state and panel.
class NowPlayingScope extends InheritedNotifier<NowPlaying> {
  const NowPlayingScope({super.key, required NowPlaying np, required super.child}) : super(notifier: np);

  static NowPlaying of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<NowPlayingScope>()!.notifier!;
  static NowPlaying read(BuildContext context) => context.getInheritedWidgetOfExactType<NowPlayingScope>()!.notifier!;
  static NowPlaying? maybeRead(BuildContext context) => context.getInheritedWidgetOfExactType<NowPlayingScope>()?.notifier;
}

/// The title bar's search text, which the Search page reads.
class SearchScope extends InheritedNotifier<TextEditingController> {
  const SearchScope({super.key, required TextEditingController query, required super.child}) : super(notifier: query);

  static TextEditingController of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SearchScope>()!.notifier!;
}

/// What is downloaded to this device.
class DownloadsScope extends InheritedNotifier<Downloads> {
  const DownloadsScope({super.key, required Downloads downloads, required super.child}) : super(notifier: downloads);

  static Downloads of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<DownloadsScope>()!.notifier!;
  static Downloads read(BuildContext context) => context.getInheritedWidgetOfExactType<DownloadsScope>()!.notifier!;
}
