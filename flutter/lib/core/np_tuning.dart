// Now Playing overlay knobs: lyric size, background dim, background blend.
// Clamp and guard logic only; stored values are untrusted. Ported from
// desktop/src/core/np-tuning.ts.

/// Multiplier on the lyric line size. 1 is the shipped size.
const lyricScaleMin = 0.8;
const lyricScaleMax = 1.4;
const lyricScaleDefault = 1.0;

/// Background dim, one knob for all three scrims.
const bgDimMin = 0.0;
const bgDimMax = 1.0;
const bgDimDefault = 0.16;

double _clampTo(Object? n, double min, double max, double fallback) => n is num && n.isFinite ? n.toDouble().clamp(min, max) : fallback;

/// A stored lyric scale clamped to range; anything not a finite number is the default.
double clampLyricScale(Object? n) => _clampTo(n, lyricScaleMin, lyricScaleMax, lyricScaleDefault);

/// A stored background dim clamped to range; anything not a finite number is the default.
double clampBgDim(Object? n) => _clampTo(n, bgDimMin, bgDimMax, bgDimDefault);

/// The background blend has two real values; only an explicit false turns multiply off.
bool clampBgBlend(Object? v) => v != false;
