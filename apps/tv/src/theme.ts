// The same palette the desktop app uses, lifted from the CSS custom properties
// at the top of apps/desktop/index.html. Kept as one module so a screen never
// hardcodes a hex value - when the desktop tokens move, this is the only place
// that has to follow.
//
// Dark only, deliberately. Cascade has a light mode on desktop, but it is a
// per-user toggle there, not a system one, and no mobile screen reads that
// preference yet. Shipping a half-wired light mode would be worse than one
// theme that is right.

export const colors = {
  bg: '#111113',
  surface: '#1c1c1e',
  surface2: '#2c2c2e',
  border: '#3a3a3c',

  accent: '#6e4ff6',
  accentGlow: 'rgba(110,79,246,0.25)',

  text: '#f5f5f7',
  text2: '#aeaeb2',
  text3: '#636366',

  green: '#32d74b',
  red: '#ff453a',
  yellow: '#ffd60a',

  // The gradient ends, for the places a real gradient is overkill and one of
  // its stops reads fine on its own.
  gradFrom: '#4ade80',
  gradTo: '#7c3aed',
} as const

import { Platform } from 'react-native'

/**
 * Type scale. The TV column is not a preference - a 10-foot UI is read from
 * roughly ten times the distance of a phone, and React Native's default sizes
 * land somewhere near 14pt, which is unreadable on a 3840-wide screen. Apple's
 * own guidance puts TV body text around 29pt.
 *
 * Every screen should take its sizes from here. A screen that hardcodes a
 * fontSize will be wrong on one of the two platforms, and it will be the TV.
 */
export const type = Platform.isTV
  ? { heading: 38, label: 22, body: 26, button: 26, code: 72, hint: 22 }
  : { heading: 22, label: 13, body: 16, button: 16, code: 40, hint: 14 }

// tvOS is watched from across a room, so type has to be bigger there than on a
// phone held at arm's length. Everything else is shared.
export const spacing = { xs: 4, sm: 8, md: 12, lg: 16, xl: 24, xxl: 32 } as const

/**
 * Horizontal breathing room for a screen's content.
 *
 * The app renders full-bleed on tvOS rather than inside the safe-area insets,
 * so a grid gets the whole 1920 instead of 1760 and backgrounds reach the edge
 * of the panel. That trade needs this in return: a real TV can overscan and
 * clip the outer few percent, so content is inset here instead of at the root.
 * Apple's title-safe margin at 1080p is 60pt, and 48 lands just inside it.
 */
export const gutter = Platform.isTV ? 48 : spacing.lg

export const radius = { sm: 6, md: 10, lg: 14, pill: 999 } as const
