// Settings > Playback > Audio delay > Calibrate: a click track plays through
// the output device in use and the person taps on each click they hear. The
// math is in core/audio_delay.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' as mk;

import 'package:cascade/core/audio_delay.dart';
import 'package:cascade/core/lyric_clock.dart';
import 'package:cascade/core/log.dart';
import 'package:cascade/engine/player.dart';
import 'package:cascade/ui/pages/common.dart';
import 'package:cascade/ui/scopes.dart';
import 'package:cascade/ui/widgets.dart';

Future<void> showAudioCalibration(BuildContext context) => showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const _Calibration());

class _Calibration extends StatefulWidget {
  const _Calibration();

  @override
  State<_Calibration> createState() => _CalibrationState();
}

class _CalibrationState extends State<_Calibration> {
  mk.Player? _click;
  final _subs = <StreamSubscription>[];
  final _clock = LyricClock();
  final _watch = Stopwatch();
  final _offsets = <double>[];
  double _pos = 0;
  bool _running = false, _done = false, _resume = false, _flash = false;
  double? _result;

  /// Kept from the first build: dispose may not look it up.
  late final Player _player = PlayerScope.read(context);

  @override
  void dispose() {
    _stop();
    if (_resume) _player.toggle();
    super.dispose();
  }

  void _stop() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _click?.dispose();
    _click = null;
    _watch.stop();
  }

  Future<void> _start() async {
    final p = _player;
    if (p.playing && !_resume) {
      _resume = true;
      p.toggle();
    }
    setState(() {
      _offsets.clear();
      _running = true;
      _done = false;
      _result = null;
    });
    try {
      final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}cascade-click.wav');
      await file.writeAsBytes(clickTrackWav());
      final click = _click = mk.Player();
      // The same device as the music: its delay is what is being measured.
      final want = p.settings.outputDeviceId;
      final device = p.devices.where((d) => d.name == want).firstOrNull ?? mk.AudioDevice.auto();
      await click.setAudioDevice(device);
      await click.setVolume(80);
      _subs.addAll([
        click.stream.position.listen((d) => _pos = d.inMicroseconds / 1e6),
        click.stream.completed.listen((done) {
          if (done) _finish();
        }),
      ]);
      _watch
        ..reset()
        ..start();
      await click.open(mk.Media(file.uri.toString()));
    } catch (e) {
      log('calibration: $e');
      if (mounted) {
        setState(() => _running = false);
        toast(context, 'Could not play the clicks: $e', error: true);
      }
    }
  }

  void _tap() {
    if (!_running) return;
    final at = _clock.now(_pos, true, _watch.elapsed);
    if (at < clickLeadIn - clickPeriod / 2) return;
    _offsets.add(tapOffset(at));
    setState(() => _flash = true);
    Future.delayed(const Duration(milliseconds: 90), () => mounted ? setState(() => _flash = false) : null);
  }

  void _finish() {
    _stop();
    if (!mounted) return;
    setState(() {
      _running = false;
      _done = true;
      _result = calibratedDelay(_offsets);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _player.settings;
    final heard = _offsets.length;
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) {
        if (e is KeyDownEvent && (e.logicalKey == LogicalKeyboardKey.space || e.logicalKey == LogicalKeyboardKey.enter)) {
          _tap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AlertDialog(
        backgroundColor: K.panel,
        title: Text('Audio delay', style: Txt.section()),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _done
                    ? (_result == null
                          ? 'The taps were too uneven to trust ($heard heard). Try again, tapping right on each click.'
                          : 'Sound reaches you ${(_result! * 1000).round()} ms after the app plays it on this device.')
                    : 'Clicks play through this device. Tap the circle, or press Space, right as you hear each one. It takes about 15 seconds.',
                textAlign: TextAlign.center,
                style: ts(14, c: K.text2, h: 1.5),
              ),
              const SizedBox(height: 22),
              Semantics(
                button: true,
                label: 'Tap',
                child: GestureDetector(
                  onTapDown: (_) => _tap(),
                  child: AnimatedContainer(
                    duration: Motion.fast,
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _flash ? K.accent : (_running ? K.accentTint : K.surface2),
                      border: Border.all(color: K.accent.withValues(alpha: _running ? 0.8 : 0.2), width: 2),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      _running ? '$heard' : 'Tap',
                      style: ts(26, w: FontWeight.w700, c: _flash ? K.ink : K.text, tab: true),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          if (!_running && !(_done && _result != null)) Pill(_done ? 'Try again' : 'Start', onTap: _start),
          if (_done && _result != null) ...[
            Pill('Try again', primary: false, onTap: _start),
            Pill(
              'Save',
              onTap: () {
                s.setAudioDelay(_result!.clamp(-1.0, 1.0));
                Navigator.pop(context);
              },
            ),
          ],
        ],
      ),
    );
  }
}
