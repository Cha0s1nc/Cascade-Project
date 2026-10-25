# Local mode: testing on a real machine

For an agent (or a person) testing the `local-mode` branch on the maintainer's Mac, or on Windows. The plan and what was built are in `docs/local-mode-plan.md`; the code map is the "Local mode" section of `CODEMAP.md`.

The branch was built in a Linux cloud session. There it passed the unit tests, and the real app was run under Xvfb on a throwaway profile (section 2 says what that covered). What it could not do: run macOS or Windows, play audio through speakers, reach the internet (LRCLIB, Kugou, iTunes, ListenBrainz and Spicy Lyrics were all blocked), or use a real Spicy Lyrics key. Section 3 is mostly those.

Report each check as pass, fail (with what happened, and a screenshot or the console output) or could not test (and why). Do not fix things on this branch while testing. Write a list of findings, and add a line to it for anything that looks wrong even if no check below names it.

## 1. Setup

```bash
git fetch origin local-mode
git worktree add ../cascade-local-mode local-mode   # keeps the main checkout untouched
cd ../cascade-local-mode
npm ci
npm run build:ts && npm run typecheck && npm test   # expect 0 failures
```

Make the test folder (needs ffmpeg with libx264, libx265, libvpx and libopus; `brew install ffmpeg` has them):

```bash
scripts/make-local-test-library.sh ~/cascade-local-test
```

It holds: an album with a `cover.jpg`, an `.lrc` and a ReplayGain tag (mp3 and flac); an album with AAC, ALAC and an audio-only `.mp4`; a compilation with no album artist whose cover is embedded in its first song; a movie with an `.srt` and a `poster.jpg`; an HEVC-in-MKV film; a DTS-in-MKV film; a two-episode show (mp4 and webm) with a `folder.jpg`; and `Road Trip.m3u8` naming two songs and a missing file.

Always run with a throwaway profile, so the real settings, sign-in and downloads are never touched:

```bash
npx electron . --user-data-dir=/tmp/cascade-local-profile
```

Start each section that says "fresh" with `rm -rf /tmp/cascade-local-profile`. Open DevTools with F12 to watch the console and the Network tab.

## 2. Already checked in the cloud session

These passed in the Linux run. Repeat them quickly on the Mac, since the platform can matter, but they are not the focus:
- The setup card's **Use a folder on this computer** (folder picker stubbed) opens the app on the folder; **Settings > Account > Switch to Jellyfin** returns to the sign-in screen.
- Every view draws from the folder: Home, Albums (cover file and embedded cover both shown), Artists, Songs, Genres, Playlists (`Road Trip` with 2 songs), Movies, TV Shows.
- Playback from `cascade-local://`, seeking, lyrics from the `.lrc` (source "Your file"), favorites, play counts and History, a movie with its `.srt` as a WebVTT track whose cues load.
- Playlists: create, add, move, rename, an empty playlist listed, an `.m3u` refused with a reason.
- Favorites, plays and playlists survive a relaunch.
- Settings > Library lists ALAC, HEVC in MKV and DTS as unplayable, with reasons.
- Spicy Lyrics with the network stubbed in main: asks only for the song playing, skips a sync made for a longer version, shows the credit, asks nothing the second time.
- No request to any host but LRCLIB and iTunes (which only failed for lack of network).

## 3. Checks

### A. First run and switching (fresh)
1. Launch. The sign-in card shows "or" and **Use a folder on this computer**. Choose it, pick `~/cascade-local-test`. Expect: the window reloads straight into the library, with no offline pill, no "server isn't answering" banner, and no Downloads in the sidebar.
2. Settings > Library: the folder path, "6 songs, 1 movie, 2 episodes", a scan time, **Rescan**, **Add folder**, the folder with a disabled **Remove** (the last one cannot go), and "Can't play these without ffmpeg" listing 3 files. Expand it: each has a reason. On a Mac, HEVC in MKV must still be listed (Chromium plays HEVC from mp4 only, never MKV).
3. Settings > Account shows only **Library source** with **Switch to Jellyfin**. No server, sign-in, proxy header or Quick Connect rows.
4. Quit and relaunch: it opens on the folder again with no sign-in card.
5. **Switch to Jellyfin**: the sign-in card. Sign in to a real server if one is available. Expect the normal app, unchanged: the server's music and video library choices as they were, the Offline Mode switch back in Settings, and Settings > Account offering **Use a folder**. Then switch back to the folder: the folder's favorites and playlists are still there.
6. With a Jellyfin account signed in, switch to the folder and confirm in the DevTools Network tab (and, if possible, the server's dashboard Activity) that **nothing at all goes to the server's address** while in Local mode, including on launch.

### B. Music
1. Albums: Album One (red cover), Hits by Various Artists (blue embedded cover), Second (no art). Artists include Artist A, Artist A feat. C, Artist B, X, Y.
2. Play Album One. Listen: it plays, seeks by clicking the bar, and Next and Previous work.
3. Turn on **crossfade** (Settings > Playback, a few seconds) and let a song run into the next: a fade, no gap and no restart. Turn on the **equalizer** with Bass Boost: audible, and the overlay's bars move. (The EQ graph needs the CORS header `cascade-local://` sends; silence or still bars would mean it is missing.)
4. Settings > Playback > **Normalization** on, Track mode: "Second Song" (ReplayGain -6.5 dB) is clearly quieter than "First Song".
5. Lyrics on "First Song": the four `.lrc` lines, synced, labelled "Your file". The source picker's third choice reads "Your files". With internet, play a well-known real song (add one to the folder) and check that Kugou or LRCLIB lyrics come through, and that the iTunes cover lookup works for an album with no art.
6. Translation: a Japanese or Spanish song with lyrics shows the Translate button, and translating works (the model downloads in Local mode).
7. Favorite a song, an album and a show. Favorite Songs lists the song. Play a few songs, open History: they are there, newest first. Settings > Library > **Rescan**, then quit and relaunch: favorites, play counts and History are unchanged.
8. Search for "song", "artist a", "test": songs, albums, artists, movies and the show are found.
9. The miniplayer, Discord presence (with Discord running) and the OS media controls show the playing song.

### C. Playlists
1. Right-click a song > **Add to playlist** > New playlist "Mine". Add another song to it from the album page's menu. Open it: both songs, in order.
2. **Edit**: remove one, move one to top, rename. Drag a row to reorder. Each change shows at once and survives a relaunch.
3. Playlists > **New Playlist** > Normal, named "Empty": it shows with 0 songs, opens empty, and accepts songs from Add to playlist.
4. Delete "Mine" from its card's menu: gone, and still gone after a relaunch.
5. `Road Trip`: plays its two songs; **Edit** and dragging a row say the `.m3u` is read-only, and the file on disk is unchanged.
6. A smart playlist (Favorites, Most Played, and one made with the rule builder) works from the folder.

### D. Video
1. Movies: "Test Movie (2010)" with its green poster. Play it: picture, sound, the subtitle picker offers "EN", and turning it on shows "Hello *there*" at about 1 s.
2. TV Shows: "Test Show" with its yellow poster, Season 1, episodes "Episode 1" (mp4) and "The Second" (webm). Both play.
3. Stop a movie halfway, reopen it: it offers to resume. Watch an episode to the end: it is marked played, and Next Up / Continue Watching on Home follow.
4. On a Mac with an HEVC **mp4** in the folder (re-encode one: `ffmpeg -i in.mkv -c:v libx265 -tag:v hvc1 -c:a aac out.mp4`): it is listed as playable and plays (VideoToolbox). A `.mov` is listed as unplayable by design; note whether that is a reasonable call.
5. A file with AC3 sound (`-c:a ac3`): playable only where Chromium claims AC3. Whatever the machine says, it must either play with sound or be listed, never play silently.

### E. The folder changing
1. Add a song to the folder, then **Rescan**: it appears without a relaunch, and the screen is redrawn once (not on every rescan that finds nothing new).
2. Rename a song's file and rescan: it shows under the new name, and loses its plays and favorite. That is the known limit of path-based ids; just confirm it does not break anything.
3. Delete a song and rescan: it is gone everywhere, including from playlists made in Cascade (the entry drops out).
4. Point the folder at a drive, eject it, relaunch: a notice says the folder cannot be opened, Settings says so too, and the app still opens. Reattach and **Rescan**: back to normal.
5. Make a symlink inside the folder that points outside it (`ln -s ~/Documents ~/cascade-local-test/outside`) and rescan: nothing from `~/Documents` appears. Try opening `cascade-local://local/media/..%2F..%2Fetc%2Fpasswd` from the DevTools console with `fetch`: 404.
6. **Add folder** with a real music library, the bigger the better (thousands of songs). Time the first scan, then the launch after it. Check memory in the debug panel if `.cascade-debug` is present. Note any album that split wrongly or merged wrongly, and any file wrongly listed as unplayable. Then favorite a song and note whether the heart takes long to show (it should be instant).
7. Several folders: **Add folder** twice more with sibling folders. Settings > Library lists three libraries named after the folders; turning one off in Music libraries hides its songs, **Single library mode** shows one at a time, and none of it changes the Jellyfin choices after **Switch to Jellyfin**. Adding a folder that holds one already listed is refused. Favorite a song, **Remove** its folder, add it back: the favorite returns.

### F. Spicy Lyrics with a real key
Needs a Spicy Lyrics app made in their dashboard and its secret key (`sl_sk_...`). A public key (`sl_pk_...`) works too if the app has the no-origin option on; test both if you have both.
1. Settings > Lyrics > **Spicy Lyrics key**: a secret key and a public key both save; anything else is refused with a reason.
2. In Local mode, add a well-known real song with correct tags and play it. Expect word-synced lyrics with the Spicy Lyrics credit under them. Record what the DevTools Network tab cannot show: the requests go from the main process. Run with `ELECTRON_ENABLE_LOGGING=1`, or check that `userData/spicy-cache/` gains `ids.json` and a `<spotifyId>.json`.
3. Confirm the **request carries the key the way Spicy Lyrics expects**. The code sends `Authorization: Bearer <key>`, copied from CascadeServer's secret-key client. Their Keys page shows that header for both key types; a 401 or 403 would mean otherwise, so report the status.
4. Expiry: edit the song's `spicy-cache/<spotifyId>.json` so `savedAt` is 26 days ago (`Date.now() - 26*86400000`), restart, play it again: it is asked for again and the file's `savedAt` is fresh. With the network off at that moment, the lyrics fall back to the next source rather than showing the stale ones.
5. Play ten songs quickly in a row and watch for a 429 from ListenBrainz or Spicy Lyrics. If one comes, lyrics should still arrive from Kugou or LRCLIB, and the next songs should not hammer the service. Note ListenBrainz's rate limit headers if seen; the plan asks for them to be checked.
6. With a Jellyfin server that has the Cascade Server plugin and its own key, confirm the plugin is still what answers (the app-side key unused). With a server without the plugin, the app-side key is used.

### G. Packaged build
The tag reader is an ES module loaded with a dynamic import, which has to work from inside `app.asar`.
1. `npm run build:mac` (or `build:win`), install, and repeat A.1, B.2 and B.5 in the packaged app with a fresh profile.
2. Settings > Library must **not** say "Cascade couldn't load its tag reader". If it does, music-metadata did not load from the asar: names come from folders and most videos are listed as unplayable. Report it with the console output.

### H. Nothing else broke (Jellyfin mode)
With a real server: sign in, browse, play, the lyrics waterfall (with and without the plugin), Offline Mode on and off, downloads, an album played from Downloads offline, and Waterfall if a second instance is at hand (`npm run dev:second`). Local mode changed `webFetch` (now independent of `jfFetch`) and the context menu rules, so give lyrics and the item menus a little extra attention.

## 4. Dependency decision

`music-metadata` was added for the tags (its own commit, "Add music-metadata for Local mode's tags"). The maintainer approved it on 2026-10-25. Still report whether it loaded in G.2 on Windows and Linux.
