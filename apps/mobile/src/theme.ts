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

// tvOS is watched from across a room, so type has to be bigger there than on a
// phone held at arm's length. Everything else is shared.
export const spacing = { xs: 4, sm: 8, md: 12, lg: 16, xl: 24, xxl: 32 } as const

export const radius = { sm: 6, md: 10, lg: 14, pill: 999 } as const
