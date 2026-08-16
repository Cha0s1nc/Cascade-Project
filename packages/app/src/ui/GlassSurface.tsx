/**
 * A surface that uses Apple's Liquid Glass where it exists, and looks exactly
 * like it does today everywhere else.
 *
 * The one rendering thing in packages/app, and it earns its place: this is a
 * platform capability wrapper, not layout. Screens and components still belong
 * to each app. Both apps need identical fallback logic, and getting that wrong
 * in one of them means a bar with no background at all on Android - so it lives
 * in one place.
 *
 * Three cases, and only the first is new:
 *   - iOS/tvOS 26+          -> real UIGlassEffect, no solid fill
 *   - iOS/tvOS 15.1 to 25   -> plain View with `fallbackColor`
 *   - Android               -> the library resolves to a plain View, same as above
 *
 * @format
 */
import { StyleSheet, View } from 'react-native';
import { LiquidGlassView, isLiquidGlassSupported } from '@callstack/liquid-glass';
import type { ReactNode } from 'react';
import type { StyleProp, ViewStyle } from 'react-native';

export { isLiquidGlassSupported };

export interface GlassSurfaceProps {
  children?: ReactNode;
  style?: StyleProp<ViewStyle>;
  /**
   * What this surface is filled with when glass is unavailable. Required, not
   * optional: a surface with no fallback is invisible on Android, and that is
   * the kind of thing you only notice on a device.
   */
  fallbackColor: string;
  /**
   * 'clear' lets much more of the background through than 'regular'. Use it
   * only over something worth seeing - the album-art background - and never
   * behind small text.
   */
  glassStyle?: 'regular' | 'clear';
  /** Corner radius. Glass needs it on the effect itself, not just on a parent. */
  radius?: number;
  /**
   * Tint the glass. Defaults to a dark wash, which is not decoration.
   *
   * Both apps are light-text-on-dark. Untinted glass takes its brightness from
   * whatever is behind it, so over a pale album cover it turns bright and the
   * light glyphs sitting on it disappear - measured on tvOS against a pale blue
   * cover, where the transport icons were very nearly invisible. A dark tint
   * keeps the surface in the range our palette was designed for while still
   * letting the colour through.
   *
   * Kept deliberately light. A heavier wash fixes contrast but stops looking
   * like glass and starts looking like smoked plastic, which is the wrong
   * trade - contrast belongs to the text colours, not the surface.
   */
  tintColor?: string;
  pointerEvents?: 'auto' | 'none' | 'box-none' | 'box-only';
}

export function GlassSurface({
  children,
  style,
  fallbackColor,
  glassStyle = 'regular',
  radius,
  tintColor = 'rgba(0,0,0,0.18)',
  pointerEvents,
}: GlassSurfaceProps) {
  if (!isLiquidGlassSupported) {
    return (
      <View
        style={[style, { backgroundColor: fallbackColor }, radius != null && { borderRadius: radius }]}
        pointerEvents={pointerEvents}>
        {children}
      </View>
    );
  }

  return (
    <LiquidGlassView
      style={[style, radius != null && { borderRadius: radius }]}
      interactive={false}
      effect={glassStyle}
      colorScheme="dark"
      tintColor={tintColor}
      pointerEvents={pointerEvents}>
      {children}
    </LiquidGlassView>
  );
}

/** Shared so a caller can hairline-separate a glass bar without guessing. */
export const glassHairline = StyleSheet.hairlineWidth;
