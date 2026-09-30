# Contributing to Cascade

Thanks for helping. This file is short on purpose; it grows as the build and
release flow settles.

## Licensing of contributions

Cascade's source code is under the GNU GPL version 3 with one additional
permission for app stores (see the top of [LICENSE](LICENSE)). By opening a
pull request you agree that:

- your contribution is licensed under those same terms, the app store
  permission included, so it can ship in every build of Cascade, the App
  Store and Google Play ones too; and
- you wrote it, or otherwise have the right to submit it under those terms.

The artwork in `assets/` is not GPL and is not open to contributions; see
[assets/LICENSE](assets/LICENSE). Please don't add images there.

## Branches

- `dev` is where work lands. Open pull requests against `dev`.
- `stable` is the release branch. Pushing to it builds a release, so only
  the maintainer merges into it.

## Releases (maintainer)

Releases are made by `.github/workflows/build.yml`; the rules are in
`src/core/release-plan.ts` and `docs/release-pipeline-plan.md`. Markers
count only in a commit's **first line**.

- **Stable release:** on `dev`, make an empty commit whose first line is
  `Release (x.x.X)` (patch), `Release (x.X.0)` (minor) or
  `Release (X.0.0)` (major), optionally followed by a platform list such as
  `[desktop, apple]`, then push `dev` to `stable`. The version is the last
  published release bumped. Without a list, the platforms are those whose
  folders changed. CI refuses a version with no `CHANGELOG.md` section.
  The result is a **draft**: check it, then publish it by hand. Publishing
  runs `.github/workflows/publish.yml`, which copies the new builds to the
  download mirror and pushes `releases.json` and `changelog.json` to the
  live website, whose releases page shows each release's notes exactly as
  written on GitHub. Editing a release's notes later updates the site too.
  A manual run of Publish writes to the website's `cascade-releases`
  branch instead, and only works once `publish.yml` is on `stable` (GitHub
  runs manual workflows from the default branch).
- **Beta:** a commit on `dev` whose first line contains `[BETA]` (and
  optionally a platform list) publishes a `x.y.z-bN` prerelease.
- **Manual run** (Actions, Build, Run workflow): never publishes. No bump
  makes a test build; a bump or the beta box makes a draft.

Each release holds every platform's newest files: platforms not rebuilt
are copied from the last published release under their own version, and
`versions.json` records which version each platform really is.

## Before you open a pull request

```
npm install
npm test            # unit tests
npm run typecheck   # TypeScript, strict
npm run dev         # run the app with the inspector attached
```

Keep changes focused, and explain the why in the commit message, not only
the what.
