/**
 * The magnifier, drawn rather than typed.
 *
 * U+2315 (⌕) is the only monochrome magnifier most system fonts carry, and it
 * renders as a hairline about half the height of the glyphs beside it - fine
 * in a paragraph, wrong as a nav icon next to ⌂ and ♫, and worse on a TV read
 * from across a room. The alternative was react-native-svg, which is a native
 * dependency and a rebuild on four targets for one icon. A ring and a bar cost
 * neither.
 *
 * Geometry: the ring sits in the top-left with radius 0.34, so its outer edge
 * at 45 degrees lands on (0.58, 0.58). The handle is a bar of length 0.48
 * centred on (0.75, 0.75) and rotated 45 degrees, which puts its near end on
 * exactly that point and its far end just inside the box.
 */
import { View } from 'react-native';
import type { ViewStyle } from 'react-native';

interface SearchGlyphProps {
  /** Box size in points - pass the fontSize the sibling glyphs use. */
  size: number;
  color: string;
  style?: ViewStyle;
}

export function SearchGlyph({ size, color, style }: SearchGlyphProps) {
  const ring = Math.round(size * 0.68);
  // Floored so it stays visible at small sizes; the phone nav renders this at
  // 20pt, where a proportional stroke would round to 1.8 and hairline out.
  const stroke = Math.max(1.5, Math.round(size * 0.09));
  const handle = size * 0.48;

  return (
    <View style={[{ width: size, height: size }, style]}>
      <View
        style={{
          position: 'absolute',
          top: 0,
          left: 0,
          width: ring,
          height: ring,
          borderRadius: ring / 2,
          borderWidth: stroke,
          borderColor: color,
        }}
      />
      <View
        style={{
          position: 'absolute',
          left: size * 0.75 - handle / 2,
          top: size * 0.75 - stroke / 2,
          width: handle,
          height: stroke,
          borderRadius: stroke / 2,
          backgroundColor: color,
          transform: [{ rotate: '45deg' }],
        }}
      />
    </View>
  );
}
