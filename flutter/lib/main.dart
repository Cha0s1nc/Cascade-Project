// Cascade in Flutter: the redesigned Home for Windows, Linux and Android.
// One codebase; the window width picks the layout. Signed in, Home is the
// server's and songs really play; signed out, there is a demo.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' show MediaKit;
import 'package:path_provider/path_provider.dart';

import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/desktop.dart';
import 'package:cascade/ui/first_run.dart';
import 'package:cascade/core/benchmark.dart';
import 'package:cascade/core/connection_headers.dart';
import 'package:cascade/core/data_move.dart';
import 'package:cascade/core/log.dart';
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

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before anything reads settings: the Linux app id's old folder moves over.
  try {
    final here = await getApplicationSupportDirectory();
    final old = oldLinuxDataDir(here);
    if (old != null && await moveAppData(old, here)) log('moved app data from ${old.path}');
  } catch (e) {
    log('app data move failed: $e');
  }
  await loadConnectionHeaders();
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
  if (benchmarkArgs(args) case final bench?) _autoBenchmark(player, bench);
}

/// Started with --benchmark (core/benchmark.dart): once signed in, run it,
/// write the report, say where and quit (exit code 1 for a run that failed).
Future<void> _autoBenchmark(Player player, BenchmarkArgs a) async {
  Map<String, Object?> report;
  try {
    log('benchmark: waiting for the sign-in');
    for (var i = 0; i < 120 && player.jf?.token == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    report = await runBenchmark(player, track: a.track, settle: a.settle, seconds: a.seconds);
  } catch (e) {
    report = {'app': 'flutter', 'version': appVersion, 'error': '$e'};
  }
  final path = await saveBenchmark(report, out: a.out);
  stdout.writeln('benchmark: $path');
  exit(report.containsKey('error') ? 1 : 0);
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

  /// The theme: the Style menu's Mode, or the system's for System. A change
  /// swaps the palette and rebuilds everything in place.
  void _applyTheme({bool rebuild = true}) {
    final mode = widget.player.settings.themeMode;
    final light = mode == 'light' || (mode == 'system' && WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.light);
    final palette = light ? lightPalette : darkPalette;
    if (identical(palette, K.current)) return;
    K.current = palette;
    if (rebuild) rebuildAll();
  }

  @override
  void didChangePlatformBrightness() => _applyTheme();

  void _applyWindow() => applyMinimumSize(widget.player.settings);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _applyTheme(rebuild: false);
    widget.player.settings.addListener(_applyTheme);
    // The window's narrowest: compact or the phone layout, at the interface size.
    widget.player.settings.addListener(_applyWindow);
    _applyWindow();
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
    widget.player.settings.removeListener(_applyTheme);
    widget.player.settings.removeListener(_applyWindow);
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
    // The interface size (the Style menu, or Ctrl/Cmd +, - and 0) scales the
    // whole app, dialogs and menus too; not the fixed-size miniplayer.
    builder: (context, child) => ListenableBuilder(
      listenable: Listenable.merge([widget.player.settings, miniMode]),
      builder: (context, _) {
        final s = widget.player.settings;
        void by(double d) => s.setUiScale((s.uiScale + d).clamp(0.8, 1.5));
        return CallbackShortcuts(
          bindings: {
            for (final mod in [(control: true, meta: false), (control: false, meta: true)]) ...{
              SingleActivator(LogicalKeyboardKey.equal, control: mod.control, meta: mod.meta): () => by(0.1),
              SingleActivator(LogicalKeyboardKey.equal, control: mod.control, meta: mod.meta, shift: true): () => by(0.1),
              SingleActivator(LogicalKeyboardKey.numpadAdd, control: mod.control, meta: mod.meta): () => by(0.1),
              SingleActivator(LogicalKeyboardKey.minus, control: mod.control, meta: mod.meta): () => by(-0.1),
              SingleActivator(LogicalKeyboardKey.numpadSubtract, control: mod.control, meta: mod.meta): () => by(-0.1),
              SingleActivator(LogicalKeyboardKey.digit0, control: mod.control, meta: mod.meta): () => s.setUiScale(1),
            },
            // ? lists the shortcuts, unless it is being typed into a field. By
            // the character, not Shift and /: Linux sends the key as ?, and
            // other keyboard layouts put it elsewhere.
            const CharacterActivator('?'): () {
              final focus = FocusManager.instance.primaryFocus?.context;
              final typing = focus != null && (focus.widget is EditableText || focus.findAncestorWidgetOfExactType<EditableText>() != null);
              final nav = _navigator.currentContext;
              if (!typing && nav != null) showShortcuts(nav);
            },
          },
          child: RoundedWindow(
            child: UiScale(
              scale: miniMode.value ? 1 : s.uiScale,
              child: SongAnnouncer(player: widget.player, child: child!),
            ),
          ),
        );
      },
    ),
    theme: ThemeData(
      brightness: K.dark ? Brightness.dark : Brightness.light,
      fontFamily: 'Inter',
      // Desktop feedback is a hover tint, not Android's ink ripple.
      splashFactory: NoSplash.splashFactory,
      popupMenuTheme: PopupMenuThemeData(
        color: K.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: K.line),
        ),
        textStyle: ts(13),
      ),
      dialogTheme: DialogThemeData(backgroundColor: K.panel, surfaceTintColor: Colors.transparent),
      snackBarTheme: SnackBarThemeData(backgroundColor: K.surface),
      textSelectionTheme: TextSelectionThemeData(cursorColor: K.accent, selectionColor: K.accentTint),
      colorScheme: ColorScheme.fromSeed(seedColor: K.accent, brightness: K.dark ? Brightness.dark : Brightness.light).copyWith(primary: K.accent),
      scaffoldBackgroundColor: K.root,
      tooltipTheme: TooltipThemeData(
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
            listenable: Listenable.merge([_library, miniMode, widget.player.settings]),
            builder: (context, _) => LayoutBuilder(
              builder: (context, c) {
                if (miniMode.value) return const MiniplayerView();
                // Below 900 px a computer keeps the desktop layout, compact,
                // unless the Style menu picks the phone layout; Android goes
                // by width.
                final computer = !(Platform.isAndroid || Platform.isIOS);
                final desktop = _library.signedIn && (c.maxWidth >= 900 || (computer && widget.player.settings.narrowLayout == 'compact'));
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
