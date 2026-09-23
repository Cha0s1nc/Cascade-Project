// Font family choices for the global --font setting (styles/base.css :root).
//
// Store values are untrusted, the same rule that keeps a corrupted setting
// from reaching a filter gain or a bitrate as NaN applies here too: whatever
// is stored gets written straight into a CSS custom property with no
// downstream validation, so an unsanitized custom name containing a stray
// quote would make every `font-family: var(--font)` on the page invalid at
// computed-value time - there is no fallback once --font itself holds a
// broken value, only var()'s own fallback, which this never reaches.
// resolveUiFont() is the one place that turns a stored (preset, custom name)
// pair into a safe value, so nothing downstream has to sanitize again.

export const FONT_PRESETS: Record<string, string> = {
  system: "-apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif",
  sans:   'Helvetica, Arial, sans-serif',
  serif:  "Georgia, 'Times New Roman', serif",
  mono:   "'SF Mono', 'Cascadia Code', 'Fira Code', monospace",
}

const SYSTEM_STACK = FONT_PRESETS.system

/** Restricts a user-typed font family name to a safe charset and length
 *  before it can ever reach a CSS value. Anything not a plain word of
 *  letters/digits/spaces/hyphens is dropped rather than escaped - a font
 *  name never legitimately needs quotes, semicolons or braces, and escaping
 *  is more code than a family name is worth. */
export function sanitizeFontName(input: unknown): string {
  if (typeof input !== 'string') return ''
  return input.trim().slice(0, 60).replace(/[^A-Za-z0-9 \-]/g, '')
}

/** Resolves a stored (preset, custom name) pair to the value `--font` should
 *  hold. An unknown preset id (a stale value from a build with different
 *  presets) and an empty/all-stripped custom name both fall back to the
 *  system stack rather than producing an empty or invalid property. */
export function resolveUiFont(preset: unknown, custom?: unknown): string {
  if (preset === 'custom') {
    const name = sanitizeFontName(custom)
    return name ? `"${name}", ${SYSTEM_STACK}` : SYSTEM_STACK
  }
  if (typeof preset === 'string' && Object.prototype.hasOwnProperty.call(FONT_PRESETS, preset)) {
    return FONT_PRESETS[preset]
  }
  return SYSTEM_STACK
}
