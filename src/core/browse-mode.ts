// The persistent Music / Video mode toggle in the titlebar.
//
// This is a browsing filter only - it decides which sidebar sections and
// which Home shelves are shown. It never touches playback, the queue, or
// which libraries exist on the server.

export type BrowseMode = 'music' | 'video'

/** Which view names belong to each mode. Home and Settings are in neither -
 *  they show in both modes, so they are simply absent from both lists. */
export const MODE_VIEWS: Record<BrowseMode, string[]> = {
  music: ['albums', 'artists', 'songs', 'playlists'],
  video: ['movies', 'shows'],
}

/** The mode a given view/nav name belongs to, or null if it is shown in
 *  both (home, settings). Used to auto-switch mode when something (a search
 *  result, a now-playing "view album", a remote command) navigates into a
 *  view the current mode is hiding, so a deep link never lands on a view
 *  that silently does nothing. */
export function sectionMode(viewName: string): BrowseMode | null {
  if (MODE_VIEWS.music.includes(viewName)) return 'music'
  if (MODE_VIEWS.video.includes(viewName)) return 'video'
  return null
}

/**
 * Resolves the persisted mode choice against whether the account actually
 * has a video library configured right now.
 *
 * Defaults to music on a genuinely fresh install (nothing saved yet) and,
 * more importantly, whenever there is no video library: the toggle itself is
 * hidden in that case (nothing to switch to), but a video library removed in
 * Settings after "video" was saved must not leave a now music-only user
 * stranded on a mode with no visible sections. The saved value itself is
 * left alone by the caller so the choice comes back if a video library is
 * added again later.
 */
export function resolveBrowseMode(
  saved: string | null | undefined,
  hasVideoLibrary: boolean,
): BrowseMode {
  if (!hasVideoLibrary) return 'music'
  return saved === 'video' ? 'video' : 'music'
}
