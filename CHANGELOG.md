# Changelog

Every stable release of Cascade, newest first. Betas are not listed.

Each version is a heading like `## 2.3.0 (2026-10-05)`, dated the day the
release was published (UTC), followed by a `### Desktop`, `### Apple` or
`### Android` section for each platform the release changed. Use `####` for
headings inside a section. The release workflow reads this file, so it has to
keep to that format; `npm test` checks it, and
`node scripts/changelog-section.mjs 2.3.0` prints one version's notes.

## 2.2.0 (2026-09-27)

### Desktop

The macOS updater in 2.1.0 and 2.2.0 cannot install updates. Mac users have
to download and install 2.2.0 by hand, and the release after it too.

#### Major changes

- Jellyfin 12 support.
  - Older versions of Cascade cannot connect to Jellyfin 12 servers.
- Karaoke lyrics from Spicy Lyrics.
  - Only through the [CascadeServer plugin](https://github.com/Cha0s1nc/CascadeServer)
    (renamed from CascadeSLRC, and now released). Server owners need their own
    Spicy Lyrics API key.
  - Lyrics rendering was reworked for Spicy Lyrics.
- Lyrics translation.
  - On macOS 26 and later, uses the translation languages that come with
    macOS's language packs, and says so.
  - Translations are saved on the device for 25 days.
  - Translation is progressive, starting from the current line.
- Video player rework.
  - A more traditional design.
  - Chapter support.
  - Streams over HLS, which is lighter on the Jellyfin server.
  - Keyboard shortcuts; press ? to list them.
- Settings redesign.
- Now Playing.
  - The queue is split into History, Now Playing and Up Next.
  - Hovering the album art shows Favorite, Add to Playlist and View Album.
  - Controls scale with the window.
- Miniplayer polish (still only in development builds).

#### Minor changes

- Font settings.
- Unified context menus.
- Small visual changes throughout, such as the Songs table.
- Sign-in keeps a session token, the way Quick Connect does, instead of
  storing the password.
- Discord Rich Presence reconnects when Cascade was opened before Discord.
- Continue Watching absorbs Recently Watched and shows the next episode of
  shows in progress.
- The sleep timer and a few other Now Playing options moved into the More
  menu.
- The window buttons on Windows and Linux match the colors on screen.

#### Fixes

- Favorites did not save on Jellyfin 10.11.
- Other Jellyfin apps could not control Cascade remotely.
- Context menus did not open in fullscreen.
- Lyrics were looked up while watching a movie.
- The queue filled only half of a tall window.
- The same lyrics were searched for more than once.
- An orange box appeared after clicking something and then pressing a key.

## 2.1.0 (2026-09-17)

### Desktop

#### Lyrics

- Redesigned in the style of Apple Music.
  - A new side panel.
  - Full screen lyrics are aligned left instead of centered.
  - Karaoke highlighting works in the side panel.
  - Translations appear under the original lines.

#### Translation

- Translation and language detection run on the device instead of through
  MyMemory.
- Japanese, Korean, Chinese and Spanish, with Mozilla's translation models,
  downloaded from Cascade's own release with Mozilla's servers as a fallback.
  Much more accurate than before.
- On macOS, Apple's on-device models are used when installed, and Mozilla's
  can be chosen instead.
- Once turned on, translations stay on.

#### Discord

- A full progress bar in Rich Presence instead of a timer.
- Album art and album name appear more reliably.
- Pausing clears the status instead of showing something stale.
- Seeking and resuming display correctly.

#### Look

- A real app icon, art by Hxney_bun_.
- New hover highlights.
- macOS 27 style traffic lights.

#### Updates

- The Windows installer was redesigned in Cascade's style.
- Windows updates install in place instead of walking through the installer
  every time.
- macOS updates install in place instead of opening the DMG.

#### Fixes

- Shuffling all songs disturbed the sorting of the Songs table.
- Turning shuffle off did not fully turn it off.
- Covers edited in Cascade kept showing the old image in grids.
- Album Art Accent mode did not take effect until the next song.
- Songs without lyrics kept repeating every lyrics lookup.

#### Performance

- Translation memory is released after five minutes without translating.

#### Cha0s Stream

- Now playing info reaches Stream properly, telling apart who requested each
  song.

#### Platforms

- Mac builds are Apple Silicon only, and need macOS 13 or later.
- Windows 10 or 11 on x64, and Linux on x64.
- Jellyfin 10.10 or newer (tested against 10.11).
- Apple Translation needs macOS 26; earlier versions use Mozilla's models.

#### Licensing

- The artwork is not GPL. It belongs to Hxney_bun_ and cha0s under its own
  license: unmodified builds may be redistributed, but forks and modified
  versions must use different art. The source code stays GPL-3.0.
- The translation models are Mozilla's, under the Mozilla Public License 2.0.

## 2.0.1 (2026-08-30)

### Desktop

- Fixes for [Cha0s Stream](https://github.com/cha0s1nc/cha0s-stream).
- The last release to support Intel Macs.

## 2.0.0 (2026-08-28)

### Desktop

Cascade is now a full Jellyfin streaming app, with movies and TV shows as well
as music. Changes since 1.1.0:

#### Music and lyrics

- Karaoke-style lyrics and a lyrics editor, with Kugou as a lyrics source and
  `.slrc` sidecar files for word-timed lyrics.
- Easier to read lyrics.
- Crossfade rebuilt from scratch.
- An equalizer.

#### Video

- A video player, with Movies and TV Shows.
- Separate Music and Video modes, switched from the top left.
- Refined video media menus.

#### Library and server

- Quick Connect sign-in.
- Playlist editing.
- Refreshing Jellyfin libraries from Cascade (administrators only).
- A metadata editor like the one in Jellyfin's web interface (administrators
  only).

#### Look and feel

- Background colors are computed in Oklab.
- A polished Now Playing view and Home.
- First-run setup.
- Settings consolidated.
- Windows and Linux lose the separate title bar and match the macOS style.
- Many light mode fixes.
- Animations throughout.
- Right-click menus in most places.
- A debug panel.

#### Fixes

- The heart button in the player bar opened Now Playing instead of marking a
  favorite.
- Some tooltips did not work.

#### Updates

- Windows users on 1.1 have to install 2.0.0 by hand once: the old update
  window waited for an event Windows never sends.
- Beta builds can be chosen for updates.

## 1.1.0 (2026-06-06)

### Desktop

- Search across songs, albums and artists, and artist pages.
- Shuffle plays every song once before repeating, and turning it off restores
  the original order. Repeat all and repeat one have their own icons.
- Long titles scroll in the player bar, lyrics translate to English in one
  tap, and the queue and lyrics panels slide between each other.
- Discord Rich Presence.
- Fixes for adding tracks to playlists, the version number in Settings and in
  Jellyfin's devices panel, and title bar padding on Windows and Linux.
