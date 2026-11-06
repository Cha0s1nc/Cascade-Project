// Cascade in Flutter: the redesigned Home for Windows, Linux and Android.
// One codebase; the window width picks the layout. Signed in, Home is the
// server's and songs really play; signed out, there is a demo.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' show MediaKit;
import 'package:path_provider/path_provider.dart';

import 'package:cascade/ui/desktop.dart';
import 'package:cascade/ui/first_run.dart';
import 'package:cascade/core/downloads.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/library.dart';
import 'package:cascade/core/list_cache.dart';
import 'package:cascade/core/settings.dart';
import 'package:cascade/platform/discord.dart';
import 'package:cascade/platform/media_controls.dart';
import 'package:cascade/platform/remote.dart';
import 'package:cascade/platform/waterfall.dart';
import 'package:cascade/ui/panels.dart';
import 'package:cascade/ui/phone.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/ui/sign_in.dart';
import 'package:cascade/ui/lyrics_view.dart';
import 'package:cascade/ui/pages/browse.dart' show videoPlayer;
import 'package:cascade/ui/title_bar.dart';
import 'package:cascade/ui/video_player.dart';
import 'package:cascade/ui/widgets.dart';
import 'package:cascade/ui/scopes.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await setUpWindow();
  await loadTuning();
  videoPlayer = openVideoPlayer;
  final player = Player(settings: await Settings.load());
  await attachMediaControls(player);
  final downloads = Downloads();
  await downloads.load();
  final cacheDir = Directory('${(await getApplicationSupportDirectory()).path}/cache');
  player.localFile = (s) => downloads.fileOf(s.id);
  if (Platform.isWindows || Platform.isLinux) DiscordPresence(player, player.settings);
  runApp(CascadeApp(player: player, session: await Jellyfin.restore(), downloads: downloads, cacheDir: cacheDir));
}

class CascadeApp extends StatefulWidget {
  /// [session] is a saved sign-in; [demo] starts in the demo instead.
  const CascadeApp({super.key, required this.player, this.session, this.demo = false, this.downloads, this.cacheDir});
  final Player player;

  /// Null in tests: a throwaway one is made.
  final Downloads? downloads;

  /// Where the big library lists are kept between launches (null in tests).
  final Directory? cacheDir;
  final Jellyfin? session;
  final bool demo;

  @override
  State<CascadeApp> createState() => _CascadeAppState();
}

class _CascadeAppState extends State<CascadeApp> with WidgetsBindingObserver {
  final _library = Library();
  late final _downloads = widget.downloads ?? Downloads();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  final _navigator = GlobalKey<NavigatorState>();
  RemoteSocket? _remote;

  /// Other apps can control this one while signed in.
  void _remoteFollows() {
    final j = _library.jf;
    if (waterfall.jf != j) {
      if (waterfall.active) waterfall.leave();
      waterfall.jf = j;
    }
    // Not while offline: no requests to the server at all.
    if (j?.token != null && !_library.demo && !_library.offline) {
      if (_remote?.jf == j) return;
      _remote?.close();
      _remote = RemoteSocket(
        j!,
        widget.player,
        onMessage: (m) => _messenger.currentState?.showSnackBar(
          SnackBar(
            content: Text(m.header.isEmpty ? m.text : '${m.header}: ${m.text}', style: ts(13)),
            backgroundColor: K.surface,
            behavior: SnackBarBehavior.floating,
            width: 420,
            duration: Duration(milliseconds: m.timeoutMs ?? 6000),
          ),
        ),
      )..start();
    } else {
      _remote?.close();
      _remote = null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The queue comes back once the library has loaded, so a server that was
    // down at launch still gets it back when it answers.
    _library.downloads = _downloads;
    if (widget.cacheDir != null) _library.disk = ListCache(widget.cacheDir!);
    final artId = RegExp(r'/Items/([A-Za-z0-9]+)/Images/Primary');
    localArt = (url) => _downloads.artOf(artId.firstMatch(url)?.group(1) ?? '');
    widget.player.onStart = (s) => _library.offlinePlay(s.id);
    _library.onLoaded = () {
      widget.player.restore();
      final c = _navigator.currentContext;
      if (c != null) maybeShowFirstRun(c, _library, widget.player.settings);
    };
    // Likes go through the library, so they reach the server.
    widget.player.likedOf = (s) => _library.isFavorite(s.id, s.favorite);
    widget.player.onToggleLike = (s) {
      if (s.id.isNotEmpty && !_library.demo) _library.toggleFavorite(s.id, s.favorite);
    };
    waterfall = Waterfall(widget.player)
      ..onNotice = (t) => _messenger.currentState?.showSnackBar(
        SnackBar(
          content: Text(t, style: ts(13)),
          backgroundColor: K.surface,
          behavior: SnackBarBehavior.floating,
          width: 420,
        ),
      );
    _library.addListener(_remoteFollows);
    final s = widget.session;
    if (s != null) {
      widget.player.jf = s;
      _library.use(s);
    } else if (widget.demo) {
      _library.useDemo();
    }
  }

  /// Back in the app with the server still unreachable: try now, not later.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _library.error != null) _library.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _remote?.close();
    widget.player.dispose();
    _library.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Cascade',
    scaffoldMessengerKey: _messenger,
    navigatorKey: _navigator,
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      fontFamily: 'Inter',
      popupMenuTheme: PopupMenuThemeData(
        color: K.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: K.line),
        ),
        textStyle: ts(13),
      ),
      dialogTheme: const DialogThemeData(backgroundColor: K.panel, surfaceTintColor: Colors.transparent),
      snackBarTheme: const SnackBarThemeData(backgroundColor: K.surface),
      textSelectionTheme: const TextSelectionThemeData(cursorColor: K.accent, selectionColor: K.accentTint),
      colorScheme: ColorScheme.fromSeed(seedColor: K.accent, brightness: Brightness.dark).copyWith(primary: K.accent),
      scaffoldBackgroundColor: K.root,
      tooltipTheme: const TooltipThemeData(
        textStyle: TextStyle(fontSize: 12, color: K.text),
        decoration: BoxDecoration(color: K.surface2, borderRadius: BorderRadius.all(Radius.circular(6))),
      ),
    ),
    home: DownloadsScope(
      downloads: _downloads,
      child: LibraryScope(
        library: _library,
        child: PlayerScope(
          player: widget.player,
          child: ListenableBuilder(
            listenable: Listenable.merge([_library, miniMode]),
            builder: (context, _) => LayoutBuilder(
              builder: (context, c) {
                if (miniMode.value) return const MiniplayerView();
                final desktop = _library.signedIn && c.maxWidth >= 900;
                final page = !_library.signedIn ? const SignIn() : (desktop ? const DesktopShell() : const PhoneShell());
                return desktop
                    ? page
                    : ColoredBox(
                        color: K.root,
                        child: Column(
                          children: [
                            const BareTitleBar(),
                            Expanded(child: page),
                          ],
                        ),
                      );
              },
            ),
          ),
        ),
      ),
    ),
  );
}
