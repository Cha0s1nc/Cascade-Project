// The in-line title bar on Windows and Linux, like Electron's
// titleBarOverlay: the OS title bar is hidden (window_manager) and Cascade's
// top bar is the title bar. Empty space drags the window, a double click
// maximizes it, and the window buttons are drawn here in the OS's style.
import 'dart:io';

import 'package:cascade/core/settings.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'package:cascade/ui/widgets.dart';

/// Whether the window is ours to draw (desktop builds, not tests or Android).
bool inlineTitleBar = false;

/// Hide the OS title bar. Called once from main on Windows and Linux.
Future<void> setUpWindow() async {
  if (!(Platform.isWindows || Platform.isLinux)) return;
  await windowManager.ensureInitialized();
  await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
  await windowManager.setMinimumSize(_minSize);
  inlineTitleBar = true;
}

/// The narrowest the window may be, as last applied.
Size _minSize = const Size(420, 520);

/// The narrowest the window may be for [s]: the compact desktop layout stops
/// at 640 px of layout (so wider by the interface size), the phone layout at 420.
Size minimumWindowSize(Settings s) => Size(s.narrowLayout == 'compact' ? 640 * s.uiScale : 420, 520);

/// Applies [minimumWindowSize], widening the window if it is narrower now.
Future<void> applyMinimumSize(Settings s) async {
  final min = minimumWindowSize(s);
  if (min == _minSize) return;
  _minSize = min;
  if (!inlineTitleBar || miniMode.value) return;
  await windowManager.setMinimumSize(min);
  final size = await windowManager.getSize();
  if (size.width < min.width) await windowManager.setSize(Size(min.width, size.height));
}

/// The window's corner radius on Linux, matching GTK's frame (the runner's
/// CSS). Square when maximized or full screen; elsewhere the OS rounds.
const windowRadius = 12.0;

/// Clips the whole app to rounded corners on Linux, where the window itself
/// is see-through; anywhere else it is just [child].
class RoundedWindow extends StatefulWidget {
  const RoundedWindow({super.key, required this.child});
  final Widget child;

  @override
  State<RoundedWindow> createState() => _RoundedWindowState();
}

class _RoundedWindowState extends State<RoundedWindow> with WindowListener {
  bool _square = false;
  final _on = inlineTitleBar && Platform.isLinux;

  @override
  void initState() {
    super.initState();
    if (!_on) return;
    windowManager.addListener(this);
    _check();
  }

  @override
  void dispose() {
    if (_on) windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _check() async {
    final square = await windowManager.isMaximized() || await windowManager.isFullScreen();
    if (mounted && square != _square) setState(() => _square = square);
  }

  @override
  void onWindowMaximize() => _check();
  @override
  void onWindowUnmaximize() => _check();
  @override
  void onWindowEnterFullScreen() => _check();
  @override
  void onWindowLeaveFullScreen() => _check();

  @override
  Widget build(BuildContext context) => !_on || _square ? widget.child : ClipRRect(borderRadius: BorderRadius.circular(windowRadius), child: widget.child);
}

/// Width the window buttons take on the right of the bar.
double get windowButtonsWidth => !inlineTitleBar ? 0 : (Platform.isWindows ? 138 : 108);

/// Drags the window from empty space; double click maximizes.
class TitleBarDrag extends StatelessWidget {
  const TitleBarDrag({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => inlineTitleBar ? DragToMoveArea(child: child) : child;
}

/// Minimize, maximize and close: Windows caption buttons flush right, or
/// GNOME's round ones. ponytail: always on the right in this order; reading
/// gtk-decoration-layout for left-side buttons can come when someone needs it.
class WindowButtons extends StatefulWidget {
  const WindowButtons({super.key});

  @override
  State<WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<WindowButtons> with WindowListener {
  bool _max = false;

  @override
  void initState() {
    super.initState();
    if (!inlineTitleBar) return;
    windowManager.addListener(this);
    windowManager.isMaximized().then((m) => mounted ? setState(() => _max = m) : null);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _max = true);
  @override
  void onWindowUnmaximize() => setState(() => _max = false);

  void _toggleMax() => _max ? windowManager.unmaximize() : windowManager.maximize();

  @override
  Widget build(BuildContext context) {
    if (!inlineTitleBar) return const SizedBox.shrink();
    if (Platform.isWindows) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Caption(Icons.remove_rounded, 'Minimize', windowManager.minimize),
          _Caption(_max ? Icons.filter_none_rounded : Icons.crop_square_rounded, _max ? 'Restore' : 'Maximize', _toggleMax, iconSize: _max ? 13 : 15),
          _CloseTip(child: _Caption(Icons.close_rounded, 'Close', windowManager.close, close: true)),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          _Round(Icons.remove_rounded, 'Minimize', windowManager.minimize),
          _Round(_max ? Icons.filter_none_rounded : Icons.crop_square_rounded, _max ? 'Restore' : 'Maximize', _toggleMax),
          _CloseTip(child: _Round(Icons.close_rounded, 'Close', windowManager.close)),
        ],
      ),
    );
  }
}

/// The window's close button, which closes Cascade. The first time it is
/// hovered while Now Playing is open, it says so and points to the title in
/// the middle of the bar, which closes Now Playing; never again after that.
class _CloseTip extends StatefulWidget {
  const _CloseTip({required this.child});
  final Widget child;

  @override
  State<_CloseTip> createState() => _CloseTipState();
}

class _CloseTipState extends State<_CloseTip> {
  static const _key = 'npCloseTipShown';
  // Shown until the saved answer says otherwise, so it cannot show twice.
  bool _shown = true;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _shown = p.getBool(_key) ?? false);
    }, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) {
    final np = context.dependOnInheritedWidgetOfExactType<NowPlayingScope>()?.notifier;
    final tip = !_shown && (np?.open ?? false);
    // Seen once the pointer leaves after it showed (onTriggered fires for
    // taps and long presses only, not hover).
    return MouseRegion(
      onExit: tip
          ? (_) {
              setState(() => _shown = true);
              SharedPreferences.getInstance().then((p) => p.setBool(_key, true), onError: (_) => false);
            }
          : null,
      child: Tooltip(
        message: tip ? 'This closes Cascade. To close Now Playing, click Now Playing in the middle of this bar.' : 'Close',
        waitDuration: tip ? Duration.zero : const Duration(milliseconds: 500),
        showDuration: tip ? const Duration(seconds: 6) : const Duration(milliseconds: 1500),
        child: widget.child,
      ),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption(this.icon, this.tip, this.onTap, {this.close = false, this.iconSize = 16});
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  final bool close;
  final double iconSize;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: tip,
    child: Hover(
      onTap: onTap,
      builder: (_, on) => Container(
        width: 46,
        height: 48,
        color: on ? (close ? const Color(0xFFC42B1C) : K.tint.withValues(alpha: 0.08)) : Colors.transparent,
        child: Icon(icon, size: iconSize, color: on && close ? Colors.white : K.text2),
      ),
    ),
  );
}

class _Round extends StatelessWidget {
  const _Round(this.icon, this.tip, this.onTap);
  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: tip,
    child: Hover(
      onTap: onTap,
      builder: (_, on) => Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(color: on ? K.surface2 : K.surface, shape: BoxShape.circle),
        child: Icon(icon, size: 14, color: K.text),
      ),
    ),
  );
}

/// Just a drag strip and the window buttons, for screens without Cascade's
/// top bar (sign-in, and the phone layout in a narrow window).
class BareTitleBar extends StatelessWidget {
  const BareTitleBar({super.key});

  @override
  Widget build(BuildContext context) => !inlineTitleBar
      ? const SizedBox.shrink()
      : const SizedBox(
          height: 40,
          child: Stack(
            children: [
              Positioned.fill(child: TitleBarDrag(child: SizedBox.expand())),
              Align(alignment: Alignment.centerRight, child: WindowButtons()),
            ],
          ),
        );
}

/// The miniplayer: the main window shrunk to a small player that stays on
/// top, and put back where it was on the way out. ponytail: one window, not
/// a second one beside the main window as on the desktop; a separate window
/// can come with multi-window support.
final miniMode = ValueNotifier(false);
Rect? _before;

Future<void> setMiniMode(bool on) async {
  if (!inlineTitleBar || on == miniMode.value) return;
  if (on) {
    _before = await windowManager.getBounds();
    await windowManager.setMinimumSize(const Size(320, 104));
    await windowManager.setSize(const Size(420, 112));
    await windowManager.setAlwaysOnTop(true);
  } else {
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setMinimumSize(_minSize);
    if (_before != null) await windowManager.setBounds(_before!);
  }
  miniMode.value = on;
}
