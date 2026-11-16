// The Equalizer as the Electron app draws it (index.html eq-panels): Music
// and Video side by side, each with its switch, a preset menu, a 260x140
// response curve whose five points drag up and down (+-12 dB, 0.5 dB steps),
// the bands' values under it, and the preamp with Auto (headroom for the
// biggest boost, so nothing clips). The master switch dims everything.
import 'dart:math';

import 'package:flutter/material.dart';

import 'package:cascade/core/playback.dart';
import 'package:cascade/core/settings.dart';
import 'package:cascade/ui/controls.dart';
import 'package:cascade/ui/widgets.dart';

class EqPanels extends StatelessWidget {
  const EqPanels(this.s, {super.key});
  final Settings s;

  @override
  Widget build(BuildContext context) => _Dim(
    on: s.eqEnabled,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: K.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: K.line),
        ),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 28,
          runSpacing: 12,
          children: [_EqPanel('Music', s.eqMusic, (p) => s.setEqProfile(p)), _EqPanel('Video', s.eqVideo, (p) => s.setEqProfile(p, video: true))],
        ),
      ),
    ),
  );
}

/// Electron's off look: 40% and grey.
class _Dim extends StatelessWidget {
  const _Dim({required this.on, required this.child});
  final bool on;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    duration: Motion.base,
    opacity: on ? 1 : 0.4,
    child: IgnorePointer(
      ignoring: !on,
      child: ColorFiltered(colorFilter: on ? const ColorFilter.mode(Colors.transparent, BlendMode.dst) : const ColorFilter.matrix(_grey), child: child),
    ),
  );

  static const _grey = <double>[0.33, 0.59, 0.11, 0, 0, 0.33, 0.59, 0.11, 0, 0, 0.33, 0.59, 0.11, 0, 0, 0, 0, 0, 1, 0];
}

class _EqPanel extends StatelessWidget {
  const _EqPanel(this.title, this.p, this.onChanged);
  final String title;
  final EqProfile p;
  final ValueChanged<EqProfile> onChanged;

  EqProfile _with({bool? enabled, double? preamp, bool autoPre = false, List<double>? bands}) =>
      (enabled: enabled ?? p.enabled, preamp: autoPre ? null : (preamp ?? p.preamp), bands: bands ?? p.bands);

  @override
  Widget build(BuildContext context) {
    final preset = eqPresets.entries.where((e) => [for (var i = 0; i < 5; i++) e.value[i] == p.bands[i]].every((x) => x)).firstOrNull?.key;
    final auto = p.preamp == null;
    final pre = p.preamp ?? autoPreamp(p.bands);
    return SizedBox(
      width: 260,
      child: Column(
        spacing: 10,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 10,
            children: [
              Text(title, style: ts(13, w: FontWeight.w600)),
              Toggle(
                value: p.enabled,
                onChanged: (v) => onChanged(_with(enabled: v)),
              ),
            ],
          ),
          _Dim(
            on: p.enabled,
            child: Column(
              spacing: 10,
              children: [
                SelectBox<String>(
                  value: preset ?? 'Custom',
                  fill: K.panel,
                  items: {for (final k in eqPresets.keys) k: k, if (preset == null) 'Custom': 'Custom'},
                  onChanged: (k) => eqPresets[k] == null ? null : onChanged(_with(bands: [...eqPresets[k]!])),
                ),
                _Curve(
                  bands: p.bands,
                  onChanged: (b) => onChanged(_with(bands: b)),
                ),
                Row(
                  children: [
                    for (var i = 0; i < eqBands.length; i++)
                      Expanded(
                        child: Column(
                          children: [
                            Text(eqBands[i] >= 1000 ? '${eqBands[i] ~/ 1000}k' : '${eqBands[i]}', style: ts(11, c: K.text3)),
                            Text('${p.bands[i] > 0 ? '+' : ''}${p.bands[i].toStringAsFixed(1)}', style: ts(11, c: K.text3)),
                          ],
                        ),
                      ),
                  ],
                ),
                Row(
                  spacing: 8,
                  children: [
                    Text('Preamp', style: ts(12, c: K.text2)),
                    Expanded(
                      child: SliderTheme(
                        data: const SliderThemeData(
                          trackHeight: 3,
                          thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape: RoundSliderOverlayShape(overlayRadius: 10),
                        ),
                        child: safeSlider(
                          Slider(
                            value: pre.clamp(-eqGainLimit, eqGainLimit),
                            min: -eqGainLimit,
                            max: eqGainLimit,
                            divisions: 48,
                            onChanged: auto ? null : (v) => onChanged(_with(preamp: v)),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 46,
                      child: Text(
                        '${pre.toStringAsFixed(1)} dB',
                        textAlign: TextAlign.right,
                        style: ts(11, c: K.text3),
                      ),
                    ),
                    Text('Auto', style: ts(11, c: K.text3)),
                    Toggle(
                      value: auto,
                      onChanged: (v) => onChanged(v ? _with(autoPre: true) : _with(preamp: autoPreamp(p.bands))),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The response curve: five points, evenly spaced 8% in from each side,
/// joined by a Catmull-Rom curve; drag a point to set its band.
class _Curve extends StatefulWidget {
  const _Curve({required this.bands, required this.onChanged});
  final List<double> bands;
  final ValueChanged<List<double>> onChanged;

  @override
  State<_Curve> createState() => _CurveState();
}

class _CurveState extends State<_Curve> {
  static const w = 260.0, h = 140.0;
  int? _drag;

  static double xOf(int i) => w * 0.08 + (w * 0.84) * i / (eqBands.length - 1);
  static double yOf(double db) => h * (1 - (db + eqGainLimit) / (2 * eqGainLimit));
  static double dbOf(double y) => ((1 - y / h) * 2 * eqGainLimit - eqGainLimit).clamp(-eqGainLimit, eqGainLimit);

  void _set(double y) {
    final i = _drag;
    if (i == null) return;
    final db = (dbOf(y) * 2).round() / 2; // 0.5 dB steps
    if (db == widget.bands[i]) return;
    widget.onChanged([...widget.bands]..[i] = db);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onPanStart: (d) {
      final x = d.localPosition.dx;
      var best = 0;
      for (var i = 1; i < eqBands.length; i++) {
        if ((xOf(i) - x).abs() < (xOf(best) - x).abs()) best = i;
      }
      setState(() => _drag = best);
      _set(d.localPosition.dy);
    },
    onPanUpdate: (d) => _set(d.localPosition.dy),
    onPanEnd: (_) => setState(() => _drag = null),
    child: MouseRegion(
      cursor: _drag == null ? SystemMouseCursors.grab : SystemMouseCursors.grabbing,
      child: CustomPaint(size: const Size(w, h), painter: _CurvePainter(widget.bands, _drag)),
    ),
  );
}

class _CurvePainter extends CustomPainter {
  _CurvePainter(this.bands, this.active);
  final List<double> bands;
  final int? active;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), Paint()..color = K.line);
    final pts = [for (var i = 0; i < bands.length; i++) Offset(_CurveState.xOf(i), _CurveState.yOf(bands[i]))];
    // Catmull-Rom to cubic Bezier, tangent factor 1/6, as the desktop.
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 0; i < pts.length - 1; i++) {
      final p0 = pts[max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(pts.length - 1, i + 2)];
      final c1 = p1 + (p2 - p0) / 6, c2 = p2 - (p3 - p1) / 6;
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = K.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    for (final (i, p) in pts.indexed) {
      canvas.drawCircle(p, 6, Paint()..color = i == active ? K.text : K.accent);
      canvas.drawCircle(
        p,
        6,
        Paint()
          ..color = K.surface
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_CurvePainter old) => old.active != active || [for (var i = 0; i < bands.length; i++) old.bands[i] != bands[i]].any((x) => x);
}
