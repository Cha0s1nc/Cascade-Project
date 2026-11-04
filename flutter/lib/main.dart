// Cascade in Flutter: the redesigned Home for Windows, Linux and Android.
// One codebase; the window width picks the layout. Signed in, Home is the
// server's and songs really play; signed out, there is a demo.
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' show MediaKit;

import 'package:cascade/ui/desktop.dart';
import 'package:cascade/core/jellyfin.dart';
import 'package:cascade/core/library.dart';
import 'package:cascade/platform/media_controls.dart';
import 'package:cascade/ui/phone.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/ui/sign_in.dart';
import 'package:cascade/ui/widgets.dart';
import 'package:cascade/ui/scopes.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final player = Player();
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

class _CascadeAppState extends State<CascadeApp> {
  final _library = Library();

  @override
  void initState() {
    super.initState();
    final s = widget.session;
    if (s != null) {
      widget.player.jf = s;
      _library.use(s);
    } else if (widget.demo) {
      _library.useDemo();
    }
  }

  @override
  void dispose() {
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
