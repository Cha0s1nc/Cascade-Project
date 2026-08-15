// Design tokens shared by every Cascade front end.
//
// Only what is genuinely identical everywhere lives here. The type scale and the
// screen gutter are deliberately NOT here: they are the two things that must
// differ between a phone held at arm's length and a TV across a room, and each
// app declares its own in src/theme.ts.

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

export const spacing = { xs: 4, sm: 8, md: 12, lg: 16, xl: 24, xxl: 32 } as const

export const radius = { sm: 6, md: 10, lg: 14, pill: 999 } as const
