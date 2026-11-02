// Cascade in Flutter: a prototype of the redesigned Home for Windows, Linux
// and Android, on mock data. One codebase; the window width picks the layout.
import 'package:flutter/material.dart';

import 'desktop.dart';
import 'phone.dart';
import 'player.dart';
import 'widgets.dart';

void main() => runApp(const CascadeApp());

class CascadeApp extends StatefulWidget {
  const CascadeApp({super.key});

  @override
  State<CascadeApp> createState() => _CascadeAppState();
}

class _CascadeAppState extends State<CascadeApp> {
  final _player = Player();

  @override
  void dispose() {
    _player.dispose();
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
          tooltipTheme: const TooltipThemeData(textStyle: TextStyle(fontSize: 12, color: K.text), decoration: BoxDecoration(color: K.surface2, borderRadius: BorderRadius.all(Radius.circular(6)))),
        ),
        home: PlayerScope(
          player: _player,
          child: LayoutBuilder(builder: (context, c) => c.maxWidth >= 900 ? const DesktopShell() : const PhoneShell()),
        ),
      );
}
