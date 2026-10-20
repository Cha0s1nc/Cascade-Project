# Customization editor spec

Replaces the paintbrush dropdown's Now Playing and lyrics settings with a full editor inside Now Playing, where every change shows live next to it. Desktop (Electron) first. The native Mac app gets it later from the plan at the end of this document.

Written 2026-10-20 from an interview with Jon. Line numbers and ids are as of `dev` at `0cabfd8`.

## Decisions

| Topic | Decision |
|---|---|
| Opening | The paintbrush in Now Playing opens the editor in place. |
| Left pane | Collapses into a narrow sidebar with a small cover, previous / play-pause / next, and a close button. |
| Menu | Takes the left pane's place. Uses the same pill tab bar as Settings. |
| Tabs | Appearance, Now Playing, Lyrics, Crossfade, Presets. |
| Right pane | Shows the live lyrics on every tab except Crossfade. |
| Crossfade tab | A cover preview slides up into the right pane in place of the lyrics. It cuts from the current cover to the next queued cover, replays on every change, and has a replay button. |
| Nothing to preview | A plain hint, no sample content. |
| Title bar paintbrush | A condensed dropdown (mode, colors, font, share a look) plus a Style button that opens the editor. |
| Settings > Playback > Transitions | The cover settings move into the editor. Settings keeps one row linking to it. |
| Audio crossfade length | Stays in Settings. The Crossfade tab links to it, and following the link highlights that setting. |
| Saving | Live, as today. Each tab gets a reset link, and the editor gets one "Undo changes since opening" button. |
| Closing | The X, Esc, or the paintbrush again. Esc closes only the editor, not Now Playing. |
| Motion | About 350ms for the big moves, 200ms for tab content, one ease-out curve. Reduce Motion turns everything into plain fades. |
| Narrow windows | The preview gives way first, then the menu covers it with a toggle to swap back. |
| Admin-locked settings | Shown greyed out with a "Set by your server admin" note. |
| Scope | Desktop now. Mac later, from the plan below. |

## Entry points

### Now Playing paintbrush

`#np-theme-btn` in the Now Playing header. Opens the editor on the last tab used, or Appearance the first time. Clicking it again closes the editor.

### Title bar paintbrush

`#theme-btn` keeps a dropdown, but a condensed one with only:

- Mode (Dark / Light)
- Colors: the gradient pickers and the color presets only. The album art theme, background dim and light-mode blend move to the editor's Now Playing tab.
- Font
- Share a look (the current Presets page)
- A **Style** button at the bottom that closes the dropdown and opens Now Playing straight into the editor.

When nothing is playing, the Style button is disabled. Hovering or focusing it shows the tooltip "Start playing something to customize Now Playing." The tooltip must also work for keyboard focus, so a native `title` alone is not enough on a disabled button. Wrap it, or use `aria-disabled` and a real tooltip element.

### Settings link

Settings > Playback > Transitions loses its cover controls. It keeps one row: "Cover transitions" with a "Customize in Now Playing" button that opens the editor on the Crossfade tab. It is disabled with the same tooltip when nothing is playing. The color fade toggle and its seconds move too (see the Now Playing tab).

## Layout

Three columns inside the Now Playing overlay:

```
┌──────┬──────────────────────────────┬───────────────────────┐
│[art] │ Appearance  Now Playing  ... │                       │
│      │ ──────────────────────────── │   live lyrics         │
│  ⏮   │ Section                      │   (or the cover       │
│  ⏯   │   control      ────●──       │    preview on the     │
│  ⏭   │   control      ──●───        │    Crossfade tab)     │
│      │ Section                      │                       │
│      │   ...                        │                       │
│  ✕   │        Reset this tab        │                       │
└──────┴──────────────────────────────┴───────────────────────┘
```

- **Sidebar:** about 72px wide. From the top: a 48px cover with rounded corners, then previous, play/pause and next stacked vertically, then the close X at the bottom. It uses the same controls and state as the full player, not copies with their own logic.
- **Menu column:** takes the space the art and controls had, about 420 to 480px. The pill tab bar sits at the top and stays put while the content under it scrolls. Content is grouped into sections with plain titles, using the frameless, sentence-case section style from `ui-polish`. Each tab ends with a "Reset this tab" link. The "Undo changes since opening" button sits at the bottom of the menu column on every tab, and is hidden until something has changed.
- **Right pane:** the existing lyrics panel (`#ov-panel-lyrics`), unchanged and live. If the queue tab was showing when the editor opened, the right pane switches to lyrics and switches back to the queue on close.
- **Background:** the art-theme background and its overlay stay across the whole view, so background, dim and color changes show everywhere at once.

## Tabs

Each tab lists the controls that move into it from the current dropdown (`index.html` around 50 to 215) and from Settings.

### Appearance

- Mode: Dark / Light
- Font
- Colors: the gradient pickers and color presets

The same settings as the condensed title bar dropdown, kept in sync both ways.

### Now Playing

- Album art theme (`#toggle-album-art`)
- Background dim (`#tp-bg-dim`)
- Light mode with album art accent (`#tp-bg-blend`)
- Background color fade between songs, plus its seconds (`#color-fade-toggle`, `#color-fade-seconds`, moved from Settings > Playback > Transitions)

### Lyrics

- Text size (`#tp-lyric-scale`)
- Plain lyrics size (`#plain-lyric-scale`)
- Every knob in `CascadeCore.LYRIC_KNOBS` (`src/core/lyric-style.ts`), grouped by its `section`: Layout, Past lines, Upcoming lines, Karaoke, Motion

The "Reset all lyric settings" button becomes this tab's "Reset this tab". That reset now also covers the plain lyrics size, which today's button does not.

### Crossfade

The cover animation only. Moved from Settings > Playback > Transitions:

- On/off (`coverSlice`)
- Style (slice, fade, push)
- Direction
- Hold
- Easing
- Cut in seconds and slide out seconds
- Seam, glow and shadow

The rows that only matter for some styles keep today's show/hide rules from `_syncDisplayPrefControls()`.

At the top of the tab sits one line: "Crossfade length: 6s. Change in Settings." It reads the current value, or "Crossfade is off" when it is. The link opens Settings > Playback and highlights the setting (see Settings deep link).

### Presets

The current "Share a look" page as it is: include checkboxes, name, export/import, and the admin's server style buttons.

## Crossfade preview

When the Crossfade tab opens, the lyrics in the right pane slide down and fade out while a cover preview card slides up from the bottom into their place. Leaving the tab reverses this.

- **Content:** a large square the size of the Now Playing art. It shows the current song's cover, then runs the configured transition to the next queued song's cover (`queue[queueIndex + 1]`), holds for about 1.5s, then resets to the current cover.
- **Replays:** whenever a Crossfade setting changes. A slider replays when you let go of it, not on every step while dragging. A replay that lands mid-animation restarts from the current cover. A small replay button sits under the card.
- **Timing:** uses the real crossfade length for the hold, so the preview runs as long as the real transition would. If audio crossfade is off, it uses 6s and the card says "Previewing a 6s crossfade."
- **Hints, with no sample content:**
  - Nothing queued after this song: "Queue another song to preview the transition."
  - Next item is a video: "The next item is a video, which doesn't use a cover transition."
  - Next song has the same cover: the preview still runs, with the note "These two share a cover, so this transition won't show between them."
  - Cover transitions switched off: the card shows the current cover with "Cover transitions are off."
  - Reduce Motion on: "Cover transitions are off while Reduce Motion is on."
- **Implementation:** the preview must not use the global `_slice` or the `#ov-art` / `#np-art` hosts. Today's slice code (`prepareArtSlice`, `startArtSlice`, `endArtSlice`, `trailArtSlice`, `_animateLayers`, renderer.js around 12170 to 12340) keeps its state in the single global `_slice` and builds layers from those two hosts. Refactor it so a slice takes its host element and its own state object, then give the preview its own instance. A real crossfade that starts while the preview runs must not touch the preview, and the preview must not touch it.

## Settings deep link

Following "Change in Settings" from the Crossfade tab:

1. Closes the editor and Now Playing, opens Settings, and switches to the Playback tab.
2. Scrolls the target row into the middle of the view.
3. Highlights it the way Chrome highlights a searched setting: an accent-tinted background on the row that fades out over about 2s, plus keyboard focus on its control.

The target is the crossfade length row (`#crossfade-duration-row`, slider `#crossfade-duration`). That row is hidden while crossfade is off, so in that case the link targets the on/off row (`#crossfade-toggle`) instead.

Build this as one small reusable helper, for example `revealSetting(tabName, rowId)`, since nothing like it exists yet. Other links will want it.

## Motion

One ease-out curve for everything, `cubic-bezier(0.2, 0.7, 0.3, 1)`, the one the dropdown already uses. Only transforms and opacity are animated, never width or height, following the compositor rules the slice code already follows.

| Moment | What moves | Time |
|---|---|---|
| Open | The art and controls shrink and slide left into the sidebar, then the menu column slides in from the left and fades in, starting about 100ms later | 350ms |
| Close | The reverse; the menu leaves slightly faster than it came | 300ms |
| Tab switch | The old tab's content fades out and slides 8px down; the new one fades in and slides 8px up; the tab pill slides to the new tab | 200ms |
| To Crossfade | The lyrics slide down and fade; the preview card slides up from below the pane | 350ms |
| From Crossfade | The reverse | 300ms |
| Undo/reset | Controls move to their new values over 150ms rather than jumping | 150ms |

Under Reduce Motion, every row above is a plain opacity crossfade of about 150ms with no movement, and the preview shows the hint from the Crossfade preview section.

For the pane collapse, animate the art with a transform from its full rect to the sidebar thumbnail's rect (FLIP), not by animating its size.

## Saving and undo

- Every control applies and saves the moment it changes, through the same save paths it uses today (`saveNpTuning`, `setDisplayPref`, the theme and lyric-style savers). No Save button.
- **Reset this tab:** sets that tab's controls back to the shipped defaults, after a confirm.
- **Undo changes since opening:** when the editor opens, it snapshots every value it can change. The button puts all of them back across every tab and saves them. It is hidden until something has changed and disappears again after an undo. The snapshot is thrown away when the editor closes.

## Closing

- The sidebar's X, Esc, or the Now Playing paintbrush.
- Esc closes only the editor. A second Esc closes Now Playing as it does today.
- Focus goes back to the paintbrush that opened the editor.
- If the song changes while the editor is open, the editor stays open. The sidebar and the preview follow the new song, and the preview's "next cover" updates with the queue.

## Narrow windows

| Window width | Layout |
|---|---|
| 900px and up | Sidebar, menu and preview side by side. |
| 700 to 900px | The preview pane shrinks first. The menu keeps at least 380px. |
| Under 700px | The menu takes the whole area right of the sidebar. A "Show preview" toggle at the top swaps the menu for the preview and back. On the Crossfade tab, a replay also shows the preview for its length, then swaps back. |

## Admin-locked settings

When the admin's server style enforces part of the look (`_serverStyle`, `src/core/server-style.ts`), the affected controls stay visible but disabled. Each affected section shows one line, "Set by your server admin," instead of a note per control. Reset and undo skip locked values. This matches how the current dropdown disables `#tp-lyric-knobs`, `#tp-lyric-scale` and `#tp-lyric-reset` (renderer.js around 12316) and its `#tp-server-style-note`.

## Keyboard and accessibility

- On open, focus moves to the active tab in the tab bar.
- The tab bar is a real tablist: arrow keys move between tabs, and Home/End jump to the ends.
- Every slider has a visible label and value and is reachable with Tab.
- Sidebar buttons have accessible names (Previous, Play/Pause, Next, Close customization).
- The preview card's hints are text, not just visuals. The replay button is a real button.

## Out of scope

- Audio crossfade settings, which stay in Settings > Playback.
- The side lyrics panel in the main window.
- Video Now Playing. The paintbrush is hidden or disabled while a video plays, the same as the art theme today.
- The native Mac and iPhone apps (see below).

## Things decided without asking

These were not covered in the interview. Change them if they're wrong.

1. The background color fade moves to the Now Playing tab, not Crossfade, since it is about the background.
2. The preview's next cover is the next song in queue order, ignoring shuffle-on-repeat edge cases. With repeat-one on, it previews the same song's cover and shows the same-cover note.
3. "Reset this tab" asks for confirmation. "Undo changes since opening" does not, since it is itself an undo.
4. The editor remembers the last tab between openings for the session only, not across restarts.

## Mac plan (later)

The native Mac app is not close to release, so this is a plan, not a build. When it is picked up:

- **Where it lives:** `apple/App/Mac/NowPlayingOverlay.swift` gets an editing state that swaps its leading pane for a `CustomizationEditor` view. The sidebar becomes a narrow `VStack` reusing the overlay's existing transport buttons and art view.
- **Tabs:** a segmented control styled like `MacSettings.swift`'s tabs, with the same five tabs. The Lyrics tab can reuse `LyricsSettingsSection.swift`. The Crossfade tab reuses the controls `DisplayPrefs.swift` already backs.
- **Preview:** `CoverSlice.swift` (CascadeKit) already models the transition. Give the preview its own `CoverSlice` instance driven by a timer, separate from the one `PlaybackService` runs for real crossfades. That is the same separation the desktop refactor needs.
- **Motion:** `matchedGeometryEffect` for the art moving into the sidebar, and `.transition(.move(edge: .bottom).combined(with: .opacity))` for the preview card. Respect `accessibilityReduceMotion`.
- **Settings deep link:** the Mac Settings window would need a scroll-to-and-highlight helper equivalent to `revealSetting`.
- **Title bar:** the Mac app has no title bar paintbrush, so the Style entry belongs in the View menu ("Customize Now Playing...") and the condensed appearance options in Settings.
- **Settings import:** `MacSettingsImport.swift` and `ElectronSettingsImport.swift` copy desktop settings, so the new `plainLyricScale` key needs adding there.
