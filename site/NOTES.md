# cascade.chaosinc.xyz

The project's site, as one Cloudflare Worker (`cascade-site`):

- `cascade.chaosinc.xyz` serves `public/` (the landing page), the maintainer login at `/login`, and the announcements panel at `/admin/announcements`.
- `announcements.cascade.chaosinc.xyz` serves only the feed, which every Cascade app fetches at launch. It is `announcements.json` in the `cascade-plugins` R2 bucket, so `plugins.chaosinc.xyz/announcements.json` is the same file.

Login is GitHub OAuth. Only the logins in `ALLOWED_LOGINS` (`wrangler.toml`) get in, checked on every request, so removing a name locks that person out at once. Each saved announcement records the GitHub login that last changed it as `author`. The apps ignore that field. Every save is checked by `validateFeed` (`src/announcements.js`, tested in `desktop/test/announcements.test.ts`), so a malformed entry never reaches anyone.

## The landing page

`public/index.html` is one static page with no build step. It shows the screenshots for the visitor's platform (macOS, Windows, Linux or iPhone, Mac when it can't tell), with a switcher under the hero, and fills the download buttons from `releases.json` on chaosinc.xyz (GitHub's latest release if that fails). Until it loads, every button goes to the latest release on GitHub.

- `assets/<mac|windows|linux>/` holds home, full-screen lyrics and a TV show page, captured at 1440 by 900 at 2x from the desktop app on a jellyfin12 test account, then resized to 1600 wide. The window buttons are drawn over them by the page, since a page capture doesn't include them.
- `assets/ios/` and `assets/video/ios.mp4` came from the iPhone 17 Pro simulator. The other loops in `assets/video/` are 12 seconds of the lyrics view, recorded over the desktop app's debug port.
- The home shots show popular music, not anyone's own listening. Recently played is the test account's real play history, set on jellyfin12 to 20 well-known songs (The Weeknd, Queen, Bruno Mars, The Killers and so on) by writing their last-played dates. Recently added follows the server's add dates, which only an admin can change, so in the test copy that row's query is answered with real library albums by well-known artists. Every cover on screen is a real album in the library.
- `assets/video/fs-<os>.mp4` is the full-screen feature's clip: a drawn cursor clicks the player bar, Now Playing opens on the lyrics, then it closes and the cursor returns, so it loops. All three desktop platforms have one; a platform left out of `FS_CLIPS` in the page script falls back to its lyrics loop. `assets/<os>/fs-poster.jpg` is its first frame.
- `assets/demo/crossfade.mp4` is the app's own cover slice, recorded with `cascadeDebug.artSlice` (6 s fades, 9 s apart, A to B and back, so it loops). The graph's dots read the video's clock: if it is ever re-recorded, `FADES` in the page script holds the fade start times.
- The equalizer demo plays nothing until Try it. Its beat is synthesized in the page with Web Audio, so there is no recording to license, and it runs through five peaking filters (Q 1) with the app's presets and its automatic preamp (minus the largest boost).
- Windows and Linux captures run in an emulated 1440 by 900 viewport while the real VM window is smaller, and the title bar sizes its room for the OS window buttons from the real window (`--caption-reserve`, `desktop/styles/base.css`). Pin it before every capture to the real button width plus the 14 px gap (Linux 127 px, Windows 151 px, measured from `env(titlebar-area-*)`) and call `syncSearchPlacement()`, or the search and icons land in the middle. The page draws each OS's own buttons over the shots: flat Windows 11 glyphs, round Linux ones.
- Retake them all together after a visible UI change, so the platforms keep matching. Block playback reports in every test copy while you do.
- `assets/icon-*.png` are resized copies of the app icon and fall under `shared/assets/LICENSE`, not the GPL. `assets/fonts/` is Bricolage Grotesque under its own `OFL.txt`, self-hosted so the page loads nothing from Google.

## Setting it up

1. Create a GitHub OAuth App (github.com/settings/developers, OAuth Apps, New):
   - Homepage URL: `https://cascade.chaosinc.xyz`
   - Authorization callback URL: `https://cascade.chaosinc.xyz/login/callback`, wildcard matching off
   - Generate a client secret.
2. From this folder, set the three secrets (each prompts for the value):

       npx wrangler secret put GITHUB_CLIENT_ID
       npx wrangler secret put GITHUB_CLIENT_SECRET
       npx wrangler secret put SESSION_SECRET

   For `SESSION_SECRET`, paste the output of `openssl rand -hex 32`. Changing it signs everyone out.
3. Deploy: `npx wrangler deploy`. The two custom domains, their DNS records and certificates are created on the first deploy.

## Running it locally

`npx wrangler dev` runs it at `http://localhost:8787` with a local, empty R2 bucket, never the real one. It reads secrets from `.dev.vars` (gitignored). To sign in locally, add `http://localhost:8787/login/callback` as a second callback URL on the OAuth App.

## Later

- A second maintainer: add their GitHub login to `ALLOWED_LOGINS` and deploy. If the project moves to a GitHub org, switch `allowed()` in `src/index.js` to a team membership check (that needs the `read:org` scope).
- Saves are last-write-wins. Fine for one or two people. Add an R2 etag check (`onlyIf`) if two people ever edit at the same time.
