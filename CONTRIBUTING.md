# Contributing to Cascade

Thanks for helping. Cascade is a Jellyfin client for desktop (macOS, Windows, Linux), with iPhone, iPad and Apple TV apps on the way, maintained by one person in their spare time. Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

**Found a security problem?** Don't open an issue; see [SECURITY.md](SECURITY.md).

## Ways to help

- **Report a bug** with the bug report form under Issues. The version, platform and Jellyfin server version matter more than anything else.
- **Suggest a feature** with the feature request form. Say what you are trying to do, not only the button you want.
- **Try betas.** Settings, About, Beta updates. Betas break more often; that's what they're for, and reports from them are the most useful kind.
- **Send code.** For anything bigger than a small fix, open an issue first so nobody spends a weekend on something that won't be merged.

Issues about the Jellyfin server plugin (lyrics sidecars, Spicy Lyrics) go to [CascadeServer](https://github.com/Cha0s1nc/CascadeServer).

## Where things are

| Path | What |
|---|---|
| repo root | The desktop app (Electron): `main.js`, `renderer.js`, `index.html`, `styles/` |
| `src/core/` | Typed, tested logic shared by the desktop app, in TypeScript |
| `test/` | Desktop tests (`node --test`) |
| `apple/` | The native iOS and tvOS app (SwiftUI), with `CascadeKit`, its tested core |
| `docs/` | Plans and setup notes, e.g. the release pipeline |
| `assets/` | Artwork under its own license, see below |

Start with [CODEMAP.md](CODEMAP.md) for the desktop code and [apple/CODEMAP.md](apple/CODEMAP.md) for the Apple app. They say where each feature lives, so you don't have to search the whole tree.

## Setting up

**Desktop** needs Node.js 22.18 or newer (see the README for why) and npm:

```bash
npm install
npm run dev          # build and run with the inspector attached
npm run dev:second   # a second copy with its own profile, e.g. to test Waterfall
```

**Apple** needs a Mac with Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Xcode project is generated, not committed:

```bash
brew install xcodegen
cd apple
xcodegen generate
open Cascade.xcodeproj
```

To run on your own device, pick your team in Xcode's Signing settings, and don't commit that change to `project.yml`.

## Before you open a pull request

Run the checks for what you touched. CI runs the same ones, on every platform.

```bash
npm test                 # desktop unit tests
npm run typecheck        # TypeScript, strict
cd apple/CascadeKit && swift test   # Apple core tests
```

For Apple UI changes, build both the `CascadeiOS` and `CascadetvOS` schemes; most views are shared, and a change for the phone can break the TV.

## How code is written here

- **Match the code around you**: its naming, its comment density, its idioms.
- **Logic that can be tested goes in `src/core/` (or `CascadeKit`) with a test.** Anything decided from data (versions, parsing, queue rules) belongs there, not in the UI.
- **Comments explain why**, not what the next line does.
- **No new dependencies** without asking first in an issue.
- **Say what leaves the machine.** If a change makes Cascade contact a new server, say so in the pull request. The README and the website say which outside services the app talks to, and that has to stay true.
- **Writing:** American English, and no em dashes, in code, comments and docs alike.

## Commits and pull requests

- Open pull requests against `dev`, one change per pull request.
- Explain the why in the commit message, not only the what.
- Don't put `[BETA]` or `Release (...)` in a commit's first line or the pull request's title. Those are release triggers (see below), only the maintainer uses them, and a required check refuses pull requests that carry one.
- Screenshots or a short clip help a lot for anything visual.

## Licensing of contributions

Cascade's source code is under the GNU GPL version 3 with one additional permission for app stores (see the top of [LICENSE](LICENSE)). By opening a pull request you agree that:

- your contribution is licensed under those same terms, the app store permission included, so it can ship in every build of Cascade, the App Store and Google Play ones too; and
- you wrote it, or otherwise have the right to submit it under those terms.

The artwork in `assets/` is not GPL and is not open to contributions; see [assets/LICENSE](assets/LICENSE). Please don't add images there.

## Branches

- `dev` is where work lands. Open pull requests against `dev`.
- `stable` is the release branch. Pushing to it builds a release, so only the maintainer merges into it.

## Releases (maintainer)

Releases are made by `.github/workflows/build.yml`; the rules are in `src/core/release-plan.ts` and `docs/release-pipeline-plan.md`. Markers count only in a commit's **first line**.

- **Stable release:** on `dev`, make an empty commit whose first line is `Release (x.x.X)` (patch), `Release (x.X.0)` (minor) or `Release (X.0.0)` (major), optionally followed by a platform list such as `[desktop, apple]`, then push `dev` to `stable`. The version is the last published release bumped. Without a list, the platforms are those whose folders changed. CI refuses a version with no `CHANGELOG.md` section. The result is a **draft**: check it, then publish it by hand. Publishing runs `.github/workflows/publish.yml`, which copies the new builds to the download mirror and pushes `releases.json` and `changelog.json` to the live website, whose releases page shows each release's notes exactly as written on GitHub. Editing a release's notes later updates the site too. A manual run of Publish writes to the website's `cascade-releases` branch instead, and only works once `publish.yml` is on `stable` (GitHub runs manual workflows from the default branch).
- **Beta:** a commit on `dev` whose first line contains `[BETA]` (and optionally a platform list) publishes a `x.y.z-bN` prerelease. Once the paid Apple account exists, it also goes to TestFlight; see `docs/testflight.md`.
- **Manual run** (Actions, Build, Run workflow): never publishes. No bump makes a test build; a bump or the beta box makes a draft.

Each release holds every platform's newest files: platforms not rebuilt are copied from the last published release under their own version, and `versions.json` records which version each platform really is.
