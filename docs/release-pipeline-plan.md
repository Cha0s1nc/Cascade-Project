# Release pipeline plan

Written 2026-09-30 against `dev` at `2f0882d`. Line numbers are approximate and drift; re-grep before trusting one. This is the working plan for turning Cascade into one repo that builds and releases every platform, and the handoff brief for anyone (human or agent) picking up a phase.

## House rules for anyone working on this

- No em dashes anywhere: code, comments, docs, commit messages. American English.
- Work on a branch off `dev`; open a pull request into `dev`. Never push to `stable` (a push there builds and drafts a release) and never publish a release.
- Run `npm test` and `npm run typecheck` before every commit; both must pass.
- Commit messages explain why, not only what, and end with a `Co-Authored-By:` trailer naming the model. No links to chat sessions.
- Read `CODEMAP.md` before exploring the desktop code.

## Decisions already made (do not reopen)

- **License:** GPLv3 plus an app store additional permission (section 7), at the top of `LICENSE`. Artwork in `assets/` keeps its own license.
- **Repo layout:** the desktop stays at the repo root. The Swift app (iOS, tvOS; currently the private repo `Cha0s1nc/cascade-swift`) moves in under `apple/` with its history; a native Android app will live under `android/`.
- **Versions are shared across platforms.** The first iOS build ships as 2.3 alongside the desktop. A platform with nothing new may skip a version. Store build numbers (iOS `CFBundleVersion`, Android `versionCode`) come from the CI run number.
- **Branches:** `dev` for work, `stable` for releases. Releases stay drafts until the maintainer publishes them by hand.
- **No rolling or continuous builds.** Betas only on request (see below).
- **Downloads live on GitHub Releases** (free, keeps everything). The maintainer's OCI server mirrors the newest 20 distinct versions per platform. No R2. No compression (installers are already compressed: zstd/xz saved 0.3%).

## Phase order

| Phase | What | Where |
|---|---|---|
| 0, 1 | License decision and text, first `CONTRIBUTING.md` | done (`2f0882d`) |
| 2 | Merge cascade-swift into `apple/` with history | done (`b11a780`, `8eb5e9a`) |
| 3 | Swift CI workflow (tests + iOS/tvOS builds) | done (`.github/workflows/apple.yml`, runs on the `xcode-27` image) |
| **4** | **Updater reads `versions.json`** | cloud agent |
| **5** | **`CHANGELOG.md` format, parser, backfill** | cloud agent |
| 6 | `build.yml` rework: markers, platforms, carry-over, Apple job | done (`d520dbb`, `9d979d4`, tested with manual drafts) |
| 7 | Publish workflow: website data, OCI mirror, in-app "what's new" | built (`publish.yml`); website pages on the `cascade-releases` branch of the site |
| 8 | Apple signing, TestFlight | job written and switched off; setup list in `docs/testflight.md` |
| 9 | Android | placeholder `build-android` job in `build.yml`, skipped until `android/` exists; check its Gradle paths and add signing then |
| 10 | Native macOS app, shipped beside the Electron DMG until it reaches parity | planned; see `docs/mac-native-plan.md` |
| 11 | Release tooling for the native Mac DMG: a `mac` platform, `macBuild`, the bridge button, a CI job, mirror and site data | built (`mac/release` branch); see below |

## Phase 4: the updater reads `versions.json`

Must ship in a normal desktop release (planned: 2.3.0, through the current workflow) **before** any release carries over files from an older one. Otherwise desktop users on the old updater loop forever: a release named 2.3.2 that only carries the desktop 2.3.1 installers looks like an update to 2.3.2 every time.

Each release will carry a `versions.json` asset:

```json
{ "desktop": "2.3.1", "apple": "2.3.1", "android": "2.3.2" }
```

Changes:
- `main.js` `checkForUpdates()` (~976) fetches `/releases/latest` and uses `release.tag_name` (~998) as the version. It must instead download the release's `versions.json` asset and use its `desktop` entry, falling back to `tag_name` when the asset is missing (every release before this one). A missing or malformed file must never produce an update offer on its own. Treat its contents as untrusted input.
- The asset picked for download must be the one whose file name carries the desktop version, not the release version (carried-over installers keep their own version in their names, e.g. `Cascade-2.3.1-arm64.dmg` inside release `v2.3.2`).
- `mac-update.js` (~140) throws unless the installed DMG's version equals `expectedVersion`; pass the desktop version from `versions.json`, not the tag.
- `parseVersion()` (~652) orders only `-bN` suffixes; any other suffix is stripped, so it compares equal to stable. Keep `-bN` working (betas use it, see below).
- The beta channel (`betaUpdates`) takes the newest non-draft of the last 10 releases; the same `versions.json` rule applies there.
- Put the pure parts (reading and validating `versions.json`, picking the version and asset) in `src/core/` with tests in `test/`, as the codebase already does for everything testable.

## Phase 5: the changelog

- `CHANGELOG.md` at the repo root, newest first, with fixed headings:

  ```
  ## 2.3.0 (2026-10-05)
  ### Desktop
  - ...
  ### Apple
  - ...
  ### Android
  - ...
  ```

  Platform sections are optional per version. Betas are not listed.
- A parser in `src/core/` (tested) that turns it into JSON: `[{ "version", "date", "platforms": { "desktop": "markdown...", ... } }]`.
- Backfill 2.0.0 through 2.2.0 from the existing GitHub release notes (`gh release view vX.Y.Z`); older releases may be summarized briefly.
- A small script (Node, no new dependencies) that prints one version's section as Markdown, for phase 6 to use as release notes. Phase 6 makes CI refuse to release a version with no changelog section; phase 5 only needs the script and parser to support that.

## Phase 6: release workflow (`.github/workflows/build.yml`)

Current shape: jobs `setup`, `test`, `build-windows`, `build-mac` (`macos-26`), `build-linux`, `release`; triggered by pushes to `stable` and by `workflow_dispatch` (its `prerelease` input makes a `-bN` beta draft).

Target:
- **Release trigger:** the maintainer pushes an empty commit `Release (x.x.X) [android, desktop]` on `dev`, then `dev` to `stable`. Markers count ONLY in a commit's first line (a marker quoted in a body once published a beta by accident). `(X.0.0)`, `(x.X.0)`, `(x.x.X)` bump major, minor, patch. CI scans every commit in `github.event.before..github.event.after` and takes the biggest bump. No marker: build only, no release.
- **Version** = last *published* release bumped by the marker (not `package.json`, which becomes a placeholder). Add a `concurrency` group so two pushes cannot claim the same version. Pass commit messages through `env:`, never `${{ }}` inside a script (injection).
- **Platforms:** the bracket list if present, otherwise the platforms whose folders changed in the range (root desktop files, `apple/`, `android/`; shared data or protocol files mean all; docs only means none). GitHub's `paths` filters act per workflow, not per job, so compute the list in `setup` and gate each job on it.
- **Jobs are independent.** One platform failing must not block the others.
- **Apple job** (`runs-on: xcode-27`; the `macos-26` image has no Xcode 27, see `apple.yml`): archive iOS and tvOS, produce unsigned `.ipa` files, keep the `.xcarchive` too.
- **Release job:** a DRAFT `vX.Y.Z` containing the new builds, the files of platforms not rebuilt copied from the latest *published* release (never a draft; they keep their own version in their names), `versions.json`, and notes from the changelog section.
- **Betas:** a `[BETA]` marker in a pushed `dev` commit (optionally with a platform list) builds a *published* prerelease `x.y.z-bN` for just those platforms. No carry-over, not mirrored. Keep `workflow_dispatch` as the manual way. (Published, because the in-app beta channel cannot see drafts; prerelease keeps it out of `/releases/latest`.)
- Also: once `apple/` exists, desktop builds must ignore changes that only touch `apple/` or `android/`.

## Phase 7: on publish

A separate workflow triggered by `release: published`:
- **Website** (repo `Cha0s1nc/cha0sserverpage`, served at chaosinc.xyz by Cloudflare Pages; a push deploys). Static, no build step, one self-contained HTML file per page; read its `SITE-MAP.md` first. The Cascade page is `/github/projects/cascade/`. Commit `releases.json` and `changelog.json` into `github/projects/cascade/`, using a deploy key that can push to that repo only. New pages `/github/projects/cascade/releases/` and `/changelog/` render the JSON client-side.
- **OCI mirror (set up 2026-09-30, ready for the workflow):**
  - Served at `https://downloads.chaosinc.xyz:47443/<platform>/<version>/<file>` by Caddy in Docker (`/opt/cascade-mirror` on the OCI box), from `/srv/cascade-downloads`. The DNS record is DNS only, not proxied: Cloudflare's free plan discourages serving large files through its proxy, and ports 80 and 443 are taken on that box (443 is headscale), so Caddy gets its certificate through the ACME DNS challenge with a Cloudflare token kept in `/opt/cascade-mirror/.env`. Port 47443 is open in the OCI security list.
  - Uploads: `rsync` over SSH as `cascade-mirror@$MIRROR_HOST`, whose key is locked to `rrsync /srv/cascade-downloads` (no shell, no forwarding, paths anchored in that folder). Paths are relative to the mirror root, e.g. `rsync -rt dist/ cascade-mirror@HOST:` with `dist/desktop/2.3.1/...`. macOS's openrsync is rejected by rrsync; upload from an Ubuntu runner.
  - Pruning is server side: `cascade-mirror-prune.timer` runs daily and keeps the newest 20 `x.y.z` folders per platform. Betas are not mirrored.
  - GitHub: secrets `MIRROR_SSH_KEY`, `MIRROR_KNOWN_HOSTS`, `WEBSITE_DEPLOY_KEY` (write deploy key on `cha0sserverpage`); variables `MIRROR_HOST`, `MIRROR_URL`.
- **In the app:** the update window shows every desktop changelog section after the installed version up to the offered one, from `https://www.chaosinc.xyz/github/projects/cascade/changelog.json`, then `CHANGELOG.md` at the release's tag on GitHub, then the release body (`desktopReleaseNotes` in `main.js`, logic in `src/core/changelog.ts`).
- **Website content:** the releases page shows every release and beta with its GitHub release notes verbatim (from `releases.json`); `changelog.json` feeds the desktop update window. `publish.yml` also runs on `edited`, so fixing a release's notes on GitHub updates the site. Betas that `build.yml` publishes use the Actions token, whose events never start other workflows, so a CI beta reaches the site at the next publish or edit.
- **Built as:** `.github/workflows/publish.yml` (mirror job, then website job), `scripts/site-data.mjs` and `src/core/site-data.ts`. The website's `main` is written only by the `release` event; a manual run writes to `cascade-releases` unless told otherwise. A manual run needs the workflow file on the default branch (`stable`), so it only works once a release has carried it there.

## Phase 11: the native Mac DMG

Written 2026-10-03. The native Mac app (`CascadeMac` in `apple/`) ships beside the Electron DMG, each Mac holding one `Cascade.app` at a time, until it reaches parity. The reasoning is in `docs/mac-native-plan.md`, "Shipping both Mac DMGs"; this is what the pipeline does about it. It must ship before the first native build is published: the bridge Electron release is the only way in.

- **A fourth platform, `mac`.** `src/core/release-plan.ts` gets `mac` with the file pattern `Cascade-Native-*.dmg`. `desktop` stays Electron on every OS. `platformOfFile` tests `mac` first because desktop's `*.dmg` also matches. **`mac` is built only when named** (`[mac]`, `[desktop, mac]`, `[all, mac]`, or a manual run listing it): a lone `Release (x.x.X)`, `[all]`, a manual "all" and changes under `apple/` all leave it out, so a stable release cannot ship the native DMG before the maintainer asks (the plan's "Defaults and sunset" step 1). At parity, flipping that is emptying `EXPLICIT_ONLY` in `release-plan.ts`. It is available when `apple/` exists. Carry-over is per platform: a release that rebuilds only Electron carries over the last published native DMG, and the other way round, with `versions.json` saying so (`{ "desktop": "2.4.0", "mac": "2.4.0", "apple": ..., "android": ... }`).
- **The native DMG is named without `arm64`.** Every updater already in users' hands picks the first `.dmg` containing `arm64` with the desktop version in its name, so none can be handed it. `desktopBuildOf` also no longer counts it as proof of an Electron build: a release holding only the native file must not offer Windows and Linux an update.
- **Four places still treat `*.dmg` as desktop** and drop `Cascade-Native-*` by hand: the release job's copy of built files and its carry-over download in `build.yml`, the mirror download in `publish.yml`, and `desktopBuildOf`. If a fifth ever appears, `test/release-plan.test.ts` is where to teach it.
- **`macBuild`**, `electron` (the default, unset) or `native`, steers `desktopBuildOf` and `pickInstaller` to `versions.json`'s `mac` entry and the `Cascade-Native-` asset. It is passed only on an Apple Silicon Mac. Unset, nothing changes.
- **The bridge release**: Settings, About, "Try the native Mac app" (macOS on Apple Silicon only) sets `macBuild = native` and runs the existing update window: download, sha256, `mac-update.js` in-place swap. It offers the native app whatever its version, looks through the last 10 releases because the native app ships as a beta first, and undoes the choice if no native build exists or the window closes before the swap starts.
- **`build.yml`**: `build-mac-native` on `xcode-27` (xcodegen, `xcodebuild archive -scheme CascadeMac`, ad-hoc `codesign --force --deep --sign -`, `hdiutil create`), then mounts the DMG and checks one app, `codesign --verify --strict`, bundle id `xyz.chaosinc.cascade`, the exact version and an arm64-only binary. `MARKETING_VERSION` is the whole release version including a beta's `-bN`, because `mac-update.js` compares it with what `versions.json` promised. The Electron `build-mac` job is unchanged.
- **Publishing**: `publish.yml` mirrors the native DMG to `mac/<ver>/` (the mirror's daily prune is per platform folder on the server and needs no change if it walks the folders; check it once). `releases.json` lists every file with a `label`, "Mac (native)" or "Mac (Electron)" for the two DMGs, which the website's releases page has to render.
- **Changelog and bug reports**: `### Mac` is a platform section beside `### Desktop`, read by the native updater; the bug report form asks which Mac build it is about.
- **Defaults and sunset** are the plan's: the native DMG ships as a `[BETA]` first (`[BETA] [mac]` on dev, or a `Release` marker that lists `mac`), Electron stays the default download, and only after parity and a few clean stable releases does the site make native primary. Retiring the Electron Mac build later means deleting the `build-mac` job and nothing else here.
- **Not done here**: the Swift side (`UpdateRelease.swift`, `MacUpdateInstaller.swift`, the settings import, "Switch back to the Electron build") belongs to the native app's own agents; the website's rendering of `label`; and the one-time in-app offer to Electron users after parity.

## Reference numbers

- A desktop release is about 557 MB (5 installers, 90 to 131 MB each). All 12 releases so far total about 5.8 GB.
- None of the 31 npm packages shipped in the desktop is copyleft; Bergamot (translation) is MPL-2.0.
