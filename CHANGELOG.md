# Changelog

Every stable release of Cascade, newest first. Betas are not listed on their
own; what they added is under the stable release that shipped it.

Each version is a heading like `## 2.3.0 (2026-10-05)`, dated the day the
release was published (UTC), followed by a `### Desktop`, `### Apple` or
`### Android` section for each platform the release changed. Use `####` for
headings inside a section. The release workflow reads this file, so it has to
keep to that format; `npm test` checks it, and
`node scripts/changelog-section.mjs 2.3.0` prints one version's notes.

## 2.3.0 (2026-10-01)

### Desktop

Mac users on 2.1.0 or 2.2.0 have to download and install 2.3.0 by hand: the
updater in those versions cannot install updates. From 2.3.0 on, updates
install themselves again on every platform.

#### Major changes

- Smart playlists you define yourself, with a rule builder.
- Sort and filter Albums, Artists, Playlists, Movies and Shows.
- A Genres tab and a full listening History.
- Internet radio, through Jellyfin's Live TV channels.
- Control other Jellyfin sessions from Cascade, with a device picker.
- Artist pages show a bio, similar artists and top songs.
- Volume normalization from Jellyfin's normalization data, using the album's
  gain, or the track's when the album has none.

#### Minor changes

- An output device setting, to choose which speakers or headphones Cascade
  plays through.
- Approve another device's Quick Connect code from Settings, Account.
- During a crossfade, the next song shows as playing as soon as it starts
  fading in, instead of once the fade ends.
- The update window shows what changed in every version since yours, not
  only the newest one.
- AAC (`.m4a`) files play directly instead of being converted by the server.
- Every release, with its notes and downloads, is listed on
  [chaosinc.xyz](https://www.chaosinc.xyz/github/projects/cascade/releases/).

#### Updates

- Mac updates install in place again.
- Linux AppImage updates replace the AppImage instead of doing nothing.
- Linux .deb and .rpm updates no longer end on "The update did not install"
  while the package installer is open.
- Every step of an update now either finishes, falls back, or says why it
  could not, instead of hanging.
- The download progress shows the real speed.

#### Fixes

- Crossfade could restart the next song partway through the fade.
- Only the first page of albums, artists, movies and shows loaded.
- Smart playlists sorted by the track-numbered name instead of the title.

### Apple

The first release of Cascade for iPhone, iPad and Apple TV. It is a native
app, not a copy of the desktop one.

- Browse your music: Home, Albums, Artists, Songs, playlists, favorites and
  search.
- Sign in with a password or Quick Connect.
- Synced lyrics, from the [CascadeServer plugin](https://github.com/Cha0s1nc/CascadeServer)
  (Spicy Lyrics), Kugou, LRCLIB and Jellyfin, with adjustable lyric motion.
- Gapless playback, crossfade, an equalizer and volume normalization.
- Downloads for listening offline.
- Smart playlists and listening history.
- Waterfall, to listen together with people on the same server.
- Movies and TV shows.
- Lock screen and Control Center controls, and playback that continues with
  the screen off.
- On Apple TV, the remote works the way it does in Apple Music.

Needs iOS 18 or tvOS 18. Until it is on the App Store, the builds are
unsigned `.ipa` files: install them with Sideloadly or Xcode.

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
as music. 1.2.0 never had a stable release, so this covers everything since
1.1.0, including the 1.1.1 and 1.2.0 betas and 2.0.0-b1.

Windows users on 1.1 have to install 2.0.0 by hand once: the old update
window waited for an event Windows never sends. Updates work normally after
that.

#### Video

- Movies and TV Shows: separate libraries, season and episode browsing,
  resume, subtitle and audio track selection, and an ambient blurred backdrop
  behind the picture. Off by default; turn a library on in Settings, Library.
- Separate Music and Video modes, switched from the top left, replacing the
  connection pill. It only changes what you browse, so switching mid-song
  keeps playing, and it is hidden when you have no video libraries.
- Full mode hides the app around the picture and floats the controls over it.
- Recently Watched and Continue Watching shelves on Home. Binged episodes fold
  into one entry under the series.
- Movies and TV shows are searchable.
- Refined video menus.
- Some movies played with no sound: Cascade claimed a codec it could not
  decode. It now notices when audio does not decode, remembers that, and asks
  the server to transcode.
- The ambient backdrop no longer stutters.

#### Waterfall (beta)

- Listen together with people on the same Jellyfin server. The host starts a
  room and shares a code, and everyone else follows along. Nobody sends audio:
  each person streams the track from the server, and the room only passes
  around what is playing and where. It goes through cha0s's Cloudflare relay
  by default, and Settings can point it at your own.
- This replaces the first version, which streamed audio between listeners
  over WebRTC.
- Guests see the host's queue and can add to it, and every song shows who
  added it. The host decides whether guests can add to the queue (on by
  default) and control playback (off by default, since then anyone can pause
  or skip for everybody). Only the host reorders or removes songs.
- Fixed: joining mid-song, or the host skipping, left guests silent at 0:00
  until they paused and resumed.
- Fixed: seeking in a room could make a guest re-seek and stutter in a loop.

#### Music and lyrics

- Karaoke-style lyrics and a built-in lyrics editor, with Kugou as a lyrics
  source and `.slrc` sidecar files for word-timed lyrics. The editor needs the
  CascadeSLRC Jellyfin plugin (now CascadeServer).
- Easier to read lyrics, including on the light theme.
- Crossfade rebuilt from scratch. It no longer collapses into a hard cut when
  the next track is slow to buffer.
- An equalizer, drawn as a curve you drag, with presets and saved profiles.
- Play Next and Play Last replace "Add to queue".
- Smart playlists: Favorites and Most Played, with play counts.
- Playlist editing: rename, select several songs to remove or move to the top
  or bottom, and make a playlist public or private. An "Added (server)" column
  shows the library date, since Jellyfin keeps no date per playlist.
- Streaming quality: Original, 320, 192, 128 or 96 kbps, and the server
  transcodes to fit.
- Cascade asks the server what it can play instead of assuming.
- Stop really stops, from the menu, the media keys and remote control alike,
  and tells Jellyfin.
- Fixed: LRC lyrics timed as [mm:ss] instead of [mm:ss.xx] lost almost every
  line.
- Fixed: some `.slrc` files lost every space.
- Fixed: edited lyrics did not appear until a restart, and Edit Lyrics opened
  a browser instead of the built-in editor.
- Fixes for playlists and Discord Rich Presence.

#### Library, search and Home

- Search is a dropdown instead of taking over the window.
- Single library mode, for servers with one music library.
- Library settings save as soon as they change.
- Home redone: Recently Played and Recently Added fill the window, and shelves
  scroll sideways with arrow buttons, for mice without a horizontal wheel.
- Right-click menus on albums, artists, movies, series and playlists, not only
  tracks.
- Fixed: changing libraries did nothing until a restart.
- Fixed: two songs could both show as now playing.
- Fixed: grouped libraries showed as two narrow columns.
- Fixed: right-click links to Jellyfin pages that no longer exist.

#### Jellyfin and your server

- Quick Connect sign-in: type a code into Jellyfin anywhere you are already
  signed in, and Cascade never stores your password. Shown only when the
  server has Quick Connect turned on, and offered again when a session
  expires.
- Cascade appears in Jellyfin's Play On list, and reports position, pause
  state and volume, so other apps can control it.
- Each install has its own device ID, so two computers on one account show up
  as two devices. Cascade signs in again once, quietly, to switch over, if
  your password is saved.
- Refresh libraries: a server scan (administrators only) and a local refresh
  that works on any account.
- A metadata editor like the one in Jellyfin's web interface (administrators
  only).
- Controls the server would refuse are dimmed, with the reason, instead of
  failing when clicked. Deleting media follows Jellyfin's own deletion
  permission rather than admin status.
- Fixed: several actions reported success when the server refused them, and a
  refused delete still took the track out of the queue.

#### Look and feel

- First-run setup for libraries, crossfade, streaming quality and theme, all
  skippable. It comes back once after an update that adds settings worth a
  look, with your current values filled in.
- Settings consolidated from eight groups into five.
- A polished Now Playing: the "..." menu grows out of its button, the album
  art grows into the space when the controls fade, and the current song sits
  at the top of the queue.
- Background colors are computed in Oklab.
- Windows and Linux use the system window controls and match the macOS style,
  instead of drawing a second title bar.
- Light mode fixes, including a proper album art palette.
- Animations throughout, popups included.
- A debug panel.
- Long song titles scroll instead of pushing the layout sideways.
- Fixed: tooltips hid behind other things, and some did not work.
- Fixed: the heart in the player bar opened Now Playing instead of marking a
  favorite.

#### Windows and Linux

- Fixed: on Windows, the app could fail to open at all, the lyrics editor
  never opened, and media keys did nothing.
- Fixed: Now Playing could not be closed on Windows and Linux, because its
  close button sat under the window controls. There is also a back chevron
  now; Escape always worked.
- Linux gets a .deb alongside the AppImage and the RPM.

#### Updates

- Updates can include beta builds, chosen in Settings.
- Fixed: Intel Macs were offered the Apple Silicon build, and Linux was
  offered no update at all.
- Builds are made by GitHub Actions instead of by hand.

#### Known

- The miniplayer is locked in this release.

## 1.1.0 (2026-06-06)

### Desktop

#### Playback and queue

- Shuffle plays every song once before anything repeats, and turning it off
  restores the original order.
- Repeat all and repeat one have their own icons.

#### Library

- A search view for songs, albums and artists across the whole library.
- Artist pages: clicking an artist opens its albums and songs instead of
  playing it.

#### Now Playing

- Long track and artist names scroll in the player bar instead of stretching
  the window.
- The lyrics panel has a globe button that detects non-English lyrics and
  translates them to English.
- The queue and lyrics panels slide between each other instead of
  overlapping.
- The options menu is no longer cut off in a small window.
- Every overlay button turns white in Album Art Accent mode.

#### Discord

- Discord Rich Presence: "Listening to Cascade" with the track and artist.
  One toggle in Settings, no setup.

#### Fixes

- Adding tracks to playlists works.
- The version number shows correctly in Settings and in Jellyfin's devices
  panel.
- Title bar padding on Windows and Linux.
