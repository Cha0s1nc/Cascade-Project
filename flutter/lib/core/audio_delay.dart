// Measuring the audio delay mpv cannot see (Bluetooth, some receivers): a
// click track plays and the person taps on each click they hear. The gap
// between where the player says the track is at a tap and the click it was
// for is how late sound reaches them; lyrics subtract it. Pure.
import 'dart:math';
import 'dart:typed_data';

/// The click track's timing: a lead-in, then a click every [clickPeriod].
const clickLeadIn = 1.0, clickPeriod = 0.6;
const clickCount = 24;

/// Taps before this many are dropped while the person finds the beat.
const settleTaps = 3;

/// At least this many usable taps, or the result is not trusted.
const minTaps = 8;

/// Taps further apart than this (the middle half's spread) are too uneven.
const maxSpread = 0.08;

/// How far a tap at track position [at] fell after the nearest click, in
/// seconds; negative is before it. Taps in the lead-in count against the
/// first click.
double tapOffset(double at) {
  final k = max(0, ((at - clickLeadIn) / clickPeriod).round());
  return at - (clickLeadIn + k * clickPeriod);
}

/// The delay from the taps' offsets, or null when there are too few or they
/// are too spread out to trust. The median, so one stray tap does not move it.
double? calibratedDelay(List<double> offsets) {
  final use = offsets.skip(settleTaps).toList()..sort();
  if (use.length < minTaps) return null;
  final q1 = use[use.length ~/ 4], q3 = use[(use.length * 3) ~/ 4];
  if (q3 - q1 > maxSpread) return null;
  final mid = use.length ~/ 2;
  return use.length.isOdd ? use[mid] : (use[mid - 1] + use[mid]) / 2;
}

/// The click track as a 16-bit mono WAV: a short 1.5 kHz blip with a fast
/// decay at each click.
Uint8List clickTrackWav({int rate = 44100}) {
  final seconds = clickLeadIn + clickCount * clickPeriod + 0.5;
  final n = (seconds * rate).round();
  final pcm = Int16List(n);
  final blip = (0.03 * rate).round();
  for (var k = 0; k < clickCount; k++) {
    final at = ((clickLeadIn + k * clickPeriod) * rate).round();
    for (var i = 0; i < blip && at + i < n; i++) {
      final t = i / rate;
      pcm[at + i] = (sin(2 * pi * 1500 * t) * exp(-t * 180) * 0.8 * 32767).round();
    }
  }
  final data = pcm.buffer.asUint8List();
  final b = ByteData(44 + data.length);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, 36 + data.length, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // mono
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, data.length, Endian.little);
  final out = b.buffer.asUint8List();
  out.setRange(44, out.length, data);
  return out;
}
