// The phone app's design tokens: the shared palette and scale, plus the two
// things a hand-held UI must set for itself.
//
// Re-exported rather than imported directly by each screen so a component keeps
// one import for all of them, and so the TV app can offer the same surface with
// different numbers.

export { colors, spacing, radius } from '@cascade/app';
import { spacing } from '@cascade/app';

/**
 * Type scale for a screen held at arm's length.
 *
 * Roughly React Native's own defaults. The TV app's equivalent is far larger
 * for a reason - see apps/tv/src/theme.ts - and the two are meant to diverge.
 */
export const type = { heading: 22, label: 13, body: 16, button: 16, code: 40, hint: 14 };

/**
 * Horizontal breathing room for a screen's content.
 *
 * A phone has no overscan to defend against, so this is ordinary padding rather
 * than the title-safe inset the TV app needs.
 */
export const gutter = spacing.lg;
