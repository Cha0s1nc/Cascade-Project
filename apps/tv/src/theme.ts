// The TV app's design tokens: the shared palette and scale, plus the two things
// a 10-foot UI must set for itself.
//
// Re-exported rather than imported directly by each screen so that a component
// keeps one import for all of them, and so the phone app can offer the same
// surface with different numbers.

export { colors, spacing, radius } from '@cascade/app';
import { spacing } from '@cascade/app';

/**
 * Type scale for a screen watched from across a room.
 *
 * These are not a preference. A 10-foot UI is read from roughly ten times the
 * distance of a phone, and React Native's defaults land near 14pt, which is
 * unreadable on a 3840-wide panel. Apple's own guidance puts TV body text
 * around 29pt.
 */
export const type = { heading: 38, label: 22, body: 26, button: 26, code: 72, hint: 22 };

/**
 * Horizontal breathing room for a screen's content.
 *
 * The app renders full-bleed rather than inside the safe-area insets, so a grid
 * gets the whole 1920 and backgrounds reach the edge of the panel. That trade
 * needs this in return: a real TV can overscan and clip the outer few percent,
 * so content is inset here instead of at the root. Apple's title-safe margin at
 * 1080p is 60pt, and 48 lands just inside it.
 */
export const gutter = 48;

export { spacing as _spacing };

/**
 * The app-wide background for the 10-foot UI.
 *
 * Not colors.bg, which is very nearly black. A flat near-black panel is the
 * single biggest thing that made this read as homemade next to tvOS Apple
 * Music, which holds one constant desaturated indigo behind Home, Library,
 * Radio and Settings alike.
 *
 * Deliberately constant rather than derived from the current artwork: the
 * reference only pulls colour from the cover on the now-playing and lyrics
 * screens, and AlbumArtBackground still does exactly that there. This is Apple's
 * indigo pulled toward Cascade's own accent so the app still looks like itself.
 */
export const bgTint = '#22203a';
