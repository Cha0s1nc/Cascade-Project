// Ported from desktop/test/np-tuning.test.ts.
import 'package:cascade/core/np_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clampLyricScale keeps an in-range value as-is', () {
    expect(clampLyricScale(1), 1);
    expect(clampLyricScale(0.9), 0.9);
    expect(clampLyricScale(1.25), 1.25);
  });

  test('clampLyricScale clamps out-of-range values to the bounds', () {
    expect(clampLyricScale(0.1), lyricScaleMin);
    expect(clampLyricScale(5), lyricScaleMax);
    expect(clampLyricScale(-1), lyricScaleMin);
  });

  test('clampLyricScale on garbage input always yields a finite default', () {
    for (final garbage in [double.nan, double.infinity, double.negativeInfinity, null, 'x', <String, Object?>{}, [], '1.1']) {
      expect(clampLyricScale(garbage), lyricScaleDefault);
    }
  });

  test('clampBgDim keeps an in-range value and clamps out-of-range ones', () {
    expect(clampBgDim(0.35), 0.35);
    expect(clampBgDim(-2), bgDimMin);
    expect(clampBgDim(9), bgDimMax);
  });

  test('clampBgDim on garbage input never reaches NaN', () {
    for (final garbage in [double.nan, null, 'x', <String, Object?>{}]) {
      expect(clampBgDim(garbage), bgDimDefault);
    }
  });

  test('clampBgBlend: only an explicit false turns multiply off', () {
    expect(clampBgBlend(false), false);
    expect(clampBgBlend(true), true);
    expect(clampBgBlend(null), true);
    expect(clampBgBlend('normal'), true);
  });
}
