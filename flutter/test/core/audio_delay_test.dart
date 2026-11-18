import 'package:cascade/core/audio_delay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a tap measures from its nearest click', () {
    expect(tapOffset(clickLeadIn + 2 * clickPeriod + 0.15), closeTo(0.15, 1e-9));
    expect(tapOffset(clickLeadIn + 5 * clickPeriod - 0.05), closeTo(-0.05, 1e-9));
    expect(tapOffset(0.9), closeTo(-0.1, 1e-9), reason: 'the lead-in counts against the first click');
  });

  test('steady taps give their median; the first few are dropped', () {
    final taps = [0.4, -0.3, 0.25, ...List.filled(9, 0.14), 0.15, 0.13, 0.5];
    expect(calibratedDelay(taps), closeTo(0.14, 1e-9));
  });

  test('too few or too uneven taps are not trusted', () {
    expect(calibratedDelay(List.filled(9, 0.1)), isNull, reason: 'six after settling');
    expect(calibratedDelay([0, 0, 0, for (var i = 0; i < 12; i++) i.isEven ? 0.0 : 0.25]), isNull);
  });

  test('the click track is a valid WAV of the right length', () {
    final wav = clickTrackWav(rate: 8000);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    final samples = (wav.length - 44) ~/ 2;
    expect(samples / 8000, closeTo(clickLeadIn + clickCount * clickPeriod + 0.5, 0.01));
  });
}
