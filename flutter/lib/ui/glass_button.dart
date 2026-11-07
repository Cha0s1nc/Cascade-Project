// The desktop's glass page buttons: a 34px frosted circle whose name slides
// out on hover. The Style menu's Buttons setting picks how the name shows:
// 'overlay' floats it over the neighbors (the row stays put), 'push' widens
// the button and the row makes room, 'labeled' always shows it. The primary
// one (Play) is always open, in the accent.
import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/widgets.dart';

/// The glass spring, cb(.34,1.35,.64,1): a little overshoot.
const glassSpring = Cubic(.34, 1.35, .64, 1);

class GlassBtn extends StatefulWidget {
  const GlassBtn(this.icon, this.label, this.onTap, {super.key, this.primary = false, this.small = false, this.color});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary, small;
  final Color? color;

  @override
  State<GlassBtn> createState() => _GlassBtnState();
}

class _GlassBtnState extends State<GlassBtn> with SingleTickerProviderStateMixin {
  // Open: the width over 300ms after 60, the name fading in over 180ms
  // after 120. Close: the width over 300ms, the name gone in 110.
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 360), reverseDuration: const Duration(milliseconds: 300));
  late final _width = CurvedAnimation(
    parent: _c,
    curve: const Interval(60 / 360, 1, curve: glassSpring),
    reverseCurve: glassSpring,
  );
  late final _fade = CurvedAnimation(parent: _c, curve: const Interval(120 / 360, 300 / 360), reverseCurve: const Interval(190 / 300, 1));
  final _link = LayerLink();
  final _portal = OverlayPortalController();
  bool _inBase = false, _inFace = false, _pressed = false, _focus = false;
  Timer? _settle;

  @override
  void dispose() {
    _settle?.cancel();
    _c.dispose();
    super.dispose();
  }

  // Overlay mode draws the open button in the overlay over the closed one,
  // so the pointer leaves one as it enters the other: decide a beat later.
  void _hover({bool? base, bool? face}) {
    _inBase = base ?? _inBase;
    _inFace = face ?? _inFace;
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 30), () {
      if (!mounted) return;
      final still = calm(context);
      if (_inBase || _inFace || _focus) {
        if (_overlay) _portal.show();
        still ? _c.value = 1 : _c.forward();
      } else if (still) {
        _c.value = 0;
        if (_portal.isShowing) _portal.hide();
      } else {
        _c.reverse().whenComplete(() {
          if (mounted && !_inBase && !_inFace && !_focus && _portal.isShowing) _portal.hide();
        });
      }
    });
  }

  bool _overlay = true;

  @override
  Widget build(BuildContext context) {
    final s = PlayerScope.read(context).settings;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final style = widget.primary ? 'labeled' : s.buttonStyle;
        _overlay = style == 'overlay';
        if (!_overlay && _portal.isShowing) WidgetsBinding.instance.addPostFrameCallback((_) => _portal.hide());
        final always = style == 'labeled';
        final base = MouseRegion(
          onEnter: (_) => _hover(base: true),
          onExit: (_) => _hover(base: false),
          child: always
              ? _face(1, 1)
              : _overlay
              ? _face(0, 0)
              : AnimatedBuilder(animation: _c, builder: (_, _) => _face(_width.value, _fade.value)),
        );
        // A touch screen has no hover to show the name: a long press does.
        final button = Semantics(
          button: true,
          label: widget.label,
          child: !_overlay
              ? base
              : CompositedTransformTarget(
                  link: _link,
                  child: OverlayPortal(
                    controller: _portal,
                    overlayChildBuilder: (_) => CompositedTransformFollower(
                      link: _link,
                      targetAnchor: Alignment.centerLeft,
                      followerAnchor: Alignment.centerLeft,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: MouseRegion(
                          onEnter: (_) => _hover(face: true),
                          onExit: (_) => _hover(face: false),
                          child: AnimatedBuilder(animation: _c, builder: (_, _) => _face(_width.value, _fade.value)),
                        ),
                      ),
                    ),
                    child: base,
                  ),
                ),
        );
        // The keyboard reaches it too: focus opens the name as hover does.
        final keyed = FocusableActionDetector(
          enabled: widget.onTap != null,
          shortcuts: activateKeys,
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onTap?.call();
                return null;
              },
            ),
          },
          onShowFocusHighlight: (v) {
            _focus = v;
            _hover();
            setState(() {});
          },
          // A touch screen gets a 44 px target round the 34 px button.
          child: focusRing(
            narrow(context)
                ? ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                    child: Center(widthFactor: 1, heightFactor: 1, child: button),
                  )
                : button,
            on: _focus,
            radius: 999,
          ),
        );
        return always || !narrow(context) ? keyed : Tooltip(message: widget.label, child: keyed);
      },
    );
  }

  /// The button with its name [open] (0 shut, 1 out; the spring overshoots)
  /// and the name at [fade].
  Widget _face(double open, double fade) {
    final d = widget.small ? 28.0 : 34.0;
    final off = widget.onTap == null;
    final fg = off ? K.text3 : (widget.primary ? K.ink : (widget.color ?? K.text));
    final hot = _c.value > 0 || _inBase || _inFace;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: MouseRegion(
        cursor: off ? MouseCursor.defer : SystemMouseCursors.click,
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1,
          duration: Motion.fast,
          child: Opacity(
            opacity: off ? 0.4 : 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                boxShadow: [BoxShadow(color: const Color(0x47000000), blurRadius: hot ? 22 : 14, offset: Offset(0, hot ? 8 : 4))],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                  child: Container(
                    height: d,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: widget.primary ? K.accent.withValues(alpha: hot ? 0.85 : 0.72) : K.surface2.withValues(alpha: hot ? 0.75 : 0.55),
                      border: Border.all(color: const Color(0x1FFFFFFF)),
                      gradient: hot && !widget.primary
                          ? const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x14FFFFFF), Color(0x00FFFFFF)])
                          : null,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: d - 2,
                          child: Icon(widget.icon, size: widget.small ? 13 : 15, color: fg),
                        ),
                        ClipRect(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            widthFactor: open.clamp(0, 2),
                            child: Opacity(
                              opacity: fade.clamp(0, 1),
                              child: Padding(
                                padding: const EdgeInsets.only(right: 14),
                                child: Text(
                                  widget.label,
                                  maxLines: 1,
                                  style: ts(widget.small ? 12 : 13, w: FontWeight.w600, c: fg),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
