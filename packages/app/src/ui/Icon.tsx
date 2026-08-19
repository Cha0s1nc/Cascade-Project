/**
 * The desktop app's icon set, shared by the phone and TV apps.
 *
 * These are the exact Feather paths apps/desktop/index.html inlines as SVG,
 * copied verbatim rather than redrawn, because the point is that the three
 * apps stop looking like three apps. The unicode glyphs this replaces were
 * never really a match: ⌂, ♫ and ⚙ come from different type designers at
 * different weights and optical sizes, so a nav bar built from them reads as
 * ransom-note lettering next to the desktop's one consistent stroke.
 *
 * react-native-svg is a native dependency, which is the reason this was put
 * off - it means a pod install and a rebuild on every target. It is worth it
 * here and was not worth it for a single magnifier: a gear or the shuffle
 * arrows cannot be drawn out of Views, and thirteen icons is a set, not a
 * one-off.
 *
 * Stroke geometry matches the desktop exactly: a 24x24 viewBox, stroke-width
 * 2, round caps and joins. Only `play` and `pause` are filled, same as there.
 */
import Svg, { Circle, Line, Path, Polygon, Polyline, Rect } from 'react-native-svg';
import type { ReactNode } from 'react';

export type IconName =
  | 'home'
  | 'library'
  | 'search'
  | 'settings'
  | 'shuffle'
  | 'repeat'
  | 'previous'
  | 'next'
  | 'play'
  | 'pause'
  | 'rewind'
  | 'fastForward'
  | 'lyrics'
  | 'volume'
  | 'volumeOff'
  | 'minus'
  | 'plus';

/** Filled rather than stroked - the desktop draws these two solid. */
const SOLID: ReadonlySet<IconName> = new Set<IconName>(['play', 'pause']);

function shapes(name: IconName): ReactNode {
  switch (name) {
    case 'home':
      return (
        <>
          <Path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
          <Polyline points="9 22 9 12 15 12 15 22" />
        </>
      );
    // The desktop's "Songs" note. Library here is Albums/Artists/Songs merged
    // into one tab, and the note is the one of those three that reads as
    // "music" rather than as a specific slice of it.
    case 'library':
      return (
        <>
          <Path d="M9 18V5l12-2v13" />
          <Circle cx={6} cy={18} r={3} />
          <Circle cx={18} cy={16} r={3} />
        </>
      );
    case 'search':
      return (
        <>
          <Circle cx={11} cy={11} r={8} />
          <Line x1={21} y1={21} x2={16.65} y2={16.65} />
        </>
      );
    case 'settings':
      return (
        <>
          <Circle cx={12} cy={12} r={3} />
          <Path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
        </>
      );
    case 'shuffle':
      return (
        <>
          <Polyline points="16 3 21 3 21 8" />
          <Line x1={4} y1={20} x2={21} y2={3} />
          <Polyline points="21 16 21 21 16 21" />
          <Line x1={4} y1={4} x2={9} y2={9} />
        </>
      );
    case 'repeat':
      return (
        <>
          <Polyline points="17 1 21 5 17 9" />
          <Path d="M3 11V9a4 4 0 0 1 4-4h14" />
          <Polyline points="7 23 3 19 7 15" />
          <Path d="M21 13v2a4 4 0 0 1-4 4H3" />
        </>
      );
    case 'previous':
      return (
        <>
          <Polygon points="19 20 9 12 19 4 19 20" />
          <Line x1={5} y1={19} x2={5} y2={5} />
        </>
      );
    case 'next':
      return (
        <>
          <Polygon points="5 4 15 12 5 20 5 4" />
          <Line x1={19} y1={5} x2={19} y2={19} />
        </>
      );
    case 'play':
      return <Polygon points="5 3 19 12 5 21 5 3" />;
    case 'pause':
      return (
        <>
          <Rect x={6} y={4} width={4} height={16} />
          <Rect x={14} y={4} width={4} height={16} />
        </>
      );
    // Feather's rewind/fast-forward. The desktop has no seek-by-10s buttons -
    // it seeks with the arrow keys - but a remote has no equivalent, so these
    // two are the only icons here without a desktop original.
    case 'rewind':
      return (
        <>
          <Polygon points="11 19 2 12 11 5 11 19" />
          <Polygon points="22 19 13 12 22 5 22 19" />
        </>
      );
    case 'fastForward':
      return (
        <>
          <Polygon points="13 19 22 12 13 5 13 19" />
          <Polygon points="2 19 11 12 2 5 2 19" />
        </>
      );
    case 'lyrics':
      return <Path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />;
    // The desktop's mute button, plus Feather's volume-x for the muted state.
    // The desktop toggles a fill instead, but it has a volume bar next to it
    // saying the same thing and the phone does not.
    case 'volume':
      return (
        <>
          <Polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5" />
          <Path d="M19.07 4.93a10 10 0 0 1 0 14.14" />
          <Path d="M15.54 8.46a5 5 0 0 1 0 7.07" />
        </>
      );
    case 'volumeOff':
      return (
        <>
          <Polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5" />
          <Line x1={23} y1={9} x2={17} y2={15} />
          <Line x1={17} y1={9} x2={23} y2={15} />
        </>
      );
    case 'minus':
      return <Line x1={5} y1={12} x2={19} y2={12} />;
    case 'plus':
      return (
        <>
          <Line x1={12} y1={5} x2={12} y2={19} />
          <Line x1={5} y1={12} x2={19} y2={12} />
        </>
      );
  }
}

interface IconProps {
  name: IconName;
  /** Box size in points. The 24-unit viewBox scales to it. */
  size: number;
  color: string;
}

export function Icon({ name, size, color }: IconProps) {
  const solid = SOLID.has(name);
  return (
    <Svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill={solid ? color : 'none'}
      stroke={solid ? 'none' : color}
      strokeWidth={2}
      strokeLinecap="round"
      strokeLinejoin="round">
      {shapes(name)}
    </Svg>
  );
}
