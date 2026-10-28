# Glass buttons spec

Replaces the desktop's flat outlined pills (`.shuffle-all-btn`) with liquid glass buttons that sit as icon circles and expand sideways on hover to show their label. Desktop (Electron) first. The native Mac app follows later with SwiftUI's own glass; the iPhone keeps its touch styling.

Written 2026-10-27 from an interview with Jon, with the values Jon tuned in the prototype: 300ms, overshoot 1.35, blur 16px, fill 55%, rim 0.22, open delay 60ms, close delay 0. Line numbers and ids are as of `dev` at `82c567c`. The live prototype is [glass-buttons-prototype.html](glass-buttons-prototype.html): tune it there before any of this goes into the app.

## Decisions

| Topic | Decision |
|---|---|
| Shape | Every button in scope is a glass circle showing its icon. Hover or keyboard focus expands it sideways into a pill with the icon and its label. |
| Play | Always a labeled pill, accent-tinted glass. It never collapses and never moves: no hover resize, no press shrink, only the hover sheen. |
| Button style | A preference with three choices, picked in the setup wizard and changeable in the customization editor's Appearance tab. Overlay is the default. |
| Overlay (default) | Nothing moves. The open label floats over the buttons beside it, and only the collapsed circle catches the pointer, so moving on to the next circle switches straight to it. |
| Push | The open button widens in the row and its neighbors slide aside. |
| Always labeled | Every button shows its icon and label all the time and never changes size. |
| Glass | Frosted: translucent fill, backdrop blur with saturation, a bright top-edge rim, a darker bottom edge, soft drop shadow. On a flat page background it reads as a lit translucent pill; the blur shows over artwork. |
| Motion | Soft spring, about 300ms with a slight overshoot. The label fades in just after the width starts moving and fades out first on the way back. |
| Download | A progress ring fills around the circle while downloading; a checkmark when done. Hover expands to "Stop" or "Remove" with an X, as now. |
| Sort and Filter | An accent dot on the circle's corner when a filter is on or the sort is not the default. Hover shows the full label, like "Sort: Date added". |
| Season tabs | Only the current season shows, as a labeled glass pill. Hover opens it into a glass segmented control of every season, the active one a raised lit segment that slides between them. |
| Utility buttons | Get icons and collapse like the rest (Edit, Save as a Playlist, Move to top, Move to bottom, Remove, Try again, New playlist). |
| Reduce Motion | No spring, no slide: the width changes at once and the label fades. |
| Scope | Desktop now. Mac later. iPhone unchanged. |

## Scope

The `.shuffle-all-btn` buttons in the groups below plus the season tabs. The ones out of scope (download manager, dialogs, Show more) keep `.shuffle-all-btn` and its plain look.

| Group | Buttons | Where |
|---|---|---|
| Page action rows | Play, Shuffle, Download, Edit, Save as a Playlist | Album (`index.html:430-438`), playlist (`index.html:698-708`), artist discography (`index.html:584`), genre (`index.html:762-766`), movie (`renderer.js:5390`), show (`renderer.js:5461`), Continue on a show |
| Library toolbars | Sort, Filter, Shuffle All, New playlist | Albums, movies, shows, artists, songs, playlists headers (`index.html:393-654`) |
| Utility | Move to top, Move to bottom, Remove, Try again | Playlist edit mode (`index.html:719-721`), offline retry (`index.html:332`) |
| Season tabs | Every season, plus Download season | `renderer.js:5466-5470`, styles `layout.css:181-184` |

Out of scope: the download manager's cards, Settings, modals, the Now Playing overlay, and the episode list's small download icons.

## Anatomy

```html
<button class="gbtn" aria-label="Shuffle">
  <span class="gbtn-face">
    <svg .../>
    <span class="gbtn-label">Shuffle</span>
  </span>
</button>
```

- The `<button>` is only the collapsed circle: a fixed square in the row, and the only thing the pointer can hit. `.gbtn-face` draws the glass, sits absolutely inside it, and grows past it on hover with `pointer-events: none`.
- Glass buttons have their own class, `.gbtn` (`.gbtn-sm` for toolbars and utility), since the out-of-scope buttons still use `.shuffle-all-btn`. Nothing in the JS selects by either class. A right-aligned row carries `.gbtn-row-end`.
- The label stays in the DOM while collapsed (clipped, not `display: none`), so the button keeps its accessible name. `aria-label` is set only where the visible label differs from the full name (Sort's "Sort: Date added").
- `.primary` marks Play: never collapses, so its face is in normal flow and the button takes its full width. Every hover and press rule that changes a label's size or the face's scale excludes `.primary` (`:not(.primary)`). The prototype's first cut didn't, and the hover label rule out-ranked Play's own and nudged it a couple of pixels; in a right-aligned row it flipped the padding to the other side.

### Sizes

| Kind | Height | Collapsed | Icon |
|---|---|---|---|
| Page actions | 34px | 34px circle | 15px |
| Toolbars and utility | 28px | 28px circle | 13px |
| Play | 34px | pill, 16px side padding | 15px |

Label: `var(--font)`, 12px, weight 600, 6px gap after the icon, 14px right padding when open.

### Glass

Dark theme (light theme in the prototype, same structure with white-based fills):

```css
background: color-mix(in srgb, var(--surface2) 55%, transparent);
backdrop-filter: blur(16px) saturate(180%);
border: 1px solid rgba(255,255,255,0.12);
box-shadow:
  inset 0 1px 0 rgba(255,255,255,0.22),   /* top rim */
  inset 0 -1px 0 rgba(0,0,0,0.25),        /* bottom edge */
  0 4px 14px rgba(0,0,0,0.28);            /* lift */
```

Hover brightens the fill a step and the rim to about 0.32. Pressed scales to 0.96 and drops the lift shadow. Play swaps the fill for `color-mix(in srgb, var(--accent) 70%, transparent)` with a white label. Disabled is 0.4 opacity with no hover.

### Expansion

This section describes Overlay, the default. Push and Always labeled are under [Button style](#button-style); the spring, delays and glass values are shared.

- Overlay, not reflow: the row never changes size. The hovered button gets `z-index: 3` so its face floats over its neighbors; their circles show blurred through the glass.
- Hit area: only the collapsed circle. The open label is `pointer-events: none`, so a point over it belongs to whatever circle sits underneath. Sweeping across a row opens one button at a time, each under the pointer, and clicking where a label covers a neighbor clicks the neighbor.
- The label's width animates from 0 to `max-content` with `interpolate-size: allow-keywords` (Electron 44 has it), so no measuring in JS.
- Spring: `cubic-bezier(0.34, 1.35, 0.64, 1)` over 300ms, tuned in the prototype. The label's opacity runs 180ms, starting 60ms after the width.
- Hover intent: opening waits 60ms, closing doesn't wait. With overlay there is nothing to shove around, and a closing label lingering over the next circle would only get in the way.
- Rows aligned to the right (playlist header, `margin-left:auto`) open leftward with the icon on the right, so the icon stays under the pointer and the label never runs off the row's edge.
- Rows aligned to the left open rightward. The last button in a row opens into the empty space after it.
- `:focus-visible` opens exactly like hover.

## Button style

A preference, `buttonStyle`, one of `overlay` (default), `push` or `labeled`, kept in `displayPrefs` with its allowed values in `DISPLAY_PREF_CHOICES`, so it loads, saves and resets like the editor's other settings. `_syncDisplayPrefControls` writes it to `data-button-style` on `<html>`. The styles live in `@scope` blocks that stop at any nearer `[data-button-style]`, which is how each wizard card previews its own style whatever the app is set to.

| | Overlay | Push | Always labeled |
|---|---|---|---|
| Collapsed | icon circle | icon circle | icon + label pill |
| Hover | label floats over neighbors | button widens, neighbors slide aside | sheen only |
| Hit area | the circle | the whole button, open or not | the whole button |
| Hover delays (open / close) | 60ms / 0 | 60ms / 0 | none |
| Download | ring, then check; hover X + Stop or Remove | same | text status ("Downloading 3/10", "Downloaded"), hover X + Stop or Remove in the same width; no ring |
| Seasons | current season pill, opens over its neighbor | current season pill, opens and pushes | every season always showing |
| Play | labeled pill, never moves | same | same |

Push puts `.gbtn-face` in normal flow (`position: relative`) with the button sized to it, and keeps the overlay's spring. With nothing floating, right-aligned rows read icon first in Push and Always labeled, like every other row. Always labeled is push with every label open and no transitions.

### Setup wizard

A new step, `buttons`, right after `theme` in `FIRSTRUN_STEPS` (`renderer.js:2183`), under the heading "How should buttons show their labels?". Three cards stacked, one per style, each holding a live row of small sample buttons (Play, Shuffle, Download) you can hover to feel the difference, with a one-line description under it. Picking a card calls `setButtonStyle`.

- Seeds from the current value, never a default, like every other step (`renderer.js:2156-2159`), so someone clicking through on an update changes nothing.
- Revision: bump `WIZARD_REVISION` to 5 with `buttons: 5` in `FIRSTRUN_STEP_REVISION` (`renderer.js:2187`), so existing users see this one step once after the update that ships it. Telemetry's placeholder revision moves from 5 to 6, and the revision history comment gains a line for 5.

### Customization editor

A "Buttons" seg-control (Overlay, Push, Labeled) in the paintbrush theme picker under Mode, which moves into a new "Buttons" section of the editor's Appearance tab like the other shared controls (`data-home` / `data-slot`). "Reset this tab" puts it back to Overlay.

## Special buttons

### Download

- Idle: download arrow in a circle.
- Downloading: a ring traces the circle's edge by `c.done / c.total`, drawn with a conic-gradient masked to the border, through a `--dl-p` custom property `paintDownloadButton` sets (`renderer.js:8774`). No label.
- Done: checkmark, accent-tinted glass (today's `.on`).
- Hover while downloading: expands to X + "Stop". Hover when done: X + "Remove". The current `.dl-swap` grid trick goes away, since the circle has no status text to keep the width of.
- The title tooltip keeps "Downloading 3 of 10" so the count is still readable.

### Sort and Filter

- Sort's label reads "Sort: Name" open; the dot shows when the sort is not the view's default. Filter's dot replaces today's `.active` look (`renderer.js:2728-2731`).
- The dot: 7px, accent, top-right on the circle's rim, with a 2px ring of the page background so it reads on glass.

### Season tabs

- Collapsed: one glass pill reading the current season ("Season 2") with a small chevron. An invisible copy of that pill holds its width in the row.
- Hover or focus: the capsule opens over whatever is beside it, holding every season. The active season is a raised, lit segment; clicking another slides the segment to it with the same spring.
- The one exception to the hit-area rule: the open capsule keeps the pointer, and stays open while the pointer is anywhere inside it, or the other seasons couldn't be reached.
- Many seasons: the capsule grows to the content area's width, then scrolls sideways inside itself, with the active one scrolled into view.
- The Download season button sits after the slot, a normal glass circle, covered while the capsule is open.

### Utility icons

| Button | Icon |
|---|---|
| Edit | pencil |
| Save as a Playlist | list with a plus |
| New playlist | plus |
| Move to top | arrow up to a line |
| Move to bottom | arrow down to a line |
| Remove (edit mode) | trash |
| Try again | circular arrow |

Edit mode's three buttons are disabled until something is selected; disabled circles don't expand.

## Light theme

Same structure: fill `rgba(255,255,255,0.55)`, rim `rgba(255,255,255,0.9)`, bottom edge `rgba(0,0,0,0.08)`, lift `0 4px 14px rgba(0,0,0,0.12)`, label `var(--text)`. Tuned in the prototype under the light toggle.

## Risks

- Icon-only buttons are less discoverable than labels, especially Save as a Playlist and the edit-mode moves. Hover and focus expansion is the mitigation, and Always labeled is there for anyone who'd rather read than hover.
- `backdrop-filter` on many buttons over large scrolling grids costs GPU time. Toolbars sit over flat backgrounds where the blur shows nothing, so they may drop the blur and keep the rest if scrolling stutters.
- In Overlay, an open label hides the icon under it. That's the point of only the circle being live, but it means you can't read a neighbor while another button is open; moving onto it fixes that at once. Anyone who minds picks Push or Always labeled.
- A face that opens near the window's edge could run past it. The right-aligned rows open leftward for this reason; any other row that ends at the edge gets `.end` too.

## Build order

1. Glass and expansion CSS in `styles/components.css`, replacing `components.css:103-115`, with the light theme in `styles/theme.css`.
2. Wrap every button's content in `.gbtn-face` and its text in `.gbtn-label`, and add the missing icons (`index.html`, `renderer.js` templates).
3. Download ring in `paintDownloadButton`.
4. Sort and Filter dot.
5. Season control in the show page template and `layout.css:181-184`.
6. `buttonStyle`: the setter, the `data-button-style` attribute, and the Push and Always labeled CSS.
7. The wizard's `buttons` step and the revision bump.
8. The editor's Buttons section.
9. Check every page in all three styles, dark and light, with Reduce Motion on, and with keyboard only.

## Mac, later

SwiftUI's `.glassEffect()` and `GlassEffectContainer` on macOS 26 and up do the glass and the morph natively. The same decisions carry over: icon circles that expand on hover (`onHover`), Play always labeled, the progress ring, the season capsule, and the three button styles as one shared preference. Plan it after the desktop ships and settles.
