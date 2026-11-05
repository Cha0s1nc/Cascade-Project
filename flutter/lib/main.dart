// Cascade in Flutter: the redesigned Home for Windows, Linux and Android.
// One codebase; the window width picks the layout. Signed in, Home is the
// server's and songs really play; signed out, there is a demo.
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' show MediaKit;

import 'package:cascade/ui/desktop.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/library.dart';
import 'package:cascade/core/settings.dart';
import 'package:cascade/platform/media_controls.dart';
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
  runApp(CascadeApp(player: player, session: await Jellyfin.restore()));
}

class CascadeApp extends StatefulWidget {
  /// [session] is a saved sign-in; [demo] starts in the demo instead.
  const CascadeApp({super.key, required this.player, this.session, this.demo = false});
  final Player player;
  final Jellyfin? session;
  final bool demo;

  @override
  State<CascadeApp> createState() => _CascadeAppState();
}

class _CascadeAppState extends State<CascadeApp> with WidgetsBindingObserver {
  final _library = Library();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The queue comes back once the library has loaded, so a server that was
    // down at launch still gets it back when it answers.
    _library.onLoaded = widget.player.restore;
    // Likes go through the library, so they reach the server.
    widget.player.likedOf = (s) => _library.isFavorite(s.id, s.favorite);
    widget.player.onToggleLike = (s) {
      if (s.id.isNotEmpty && !_library.demo) _library.toggleFavorite(s.id, s.favorite);
    };
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
    widget.player.dispose();
    _library.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Cascade',
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
    home: LibraryScope(
      library: _library,
      child: PlayerScope(
        player: widget.player,
        child: ListenableBuilder(
          listenable: _library,
          builder: (context, _) =>
              !_library.signedIn ? const SignIn() : LayoutBuilder(builder: (context, c) => c.maxWidth >= 900 ? const DesktopShell() : const PhoneShell()),
        ),
      ),
    ),
  );
}
