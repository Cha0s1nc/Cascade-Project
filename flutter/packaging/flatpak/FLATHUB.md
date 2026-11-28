# Submitting to Flathub

Held until 3.0. Flathub builds open-source apps from source with no network, so the manifest here builds the Flutter app from this repo's git tag, with the Flutter SDK and every Dart package pinned as sources:

- `flatpak-flutter.yml`: the template, edited by hand (permissions, mpv, runtime, build commands).
- `update-sources.sh <tag>`: runs [flatpak-flutter](https://github.com/TheAppgineer/flatpak-flutter) on the template and writes the two below. Linux only; it runs inside `org.flatpak.Builder`.
- `xyz.chaosinc.cascade.yml` and `generated/`: what Flathub builds. Never edit them by hand; change the template and regenerate.
- `flathub.json`: x86_64 only.
- `build-local.sh [bundle]`: builds the generated manifest the way Flathub does (`--sandbox`, offline) and installs it.

The build reads the app's version from the newest `<release>` in `xyz.chaosinc.cascade.metainfo.xml` (0.0.0 when there is none), so that file is the version's source for Flathub.

## Before submitting

1. **Screenshots.** Add a `<screenshots>` block to `xyz.chaosinc.cascade.metainfo.xml` with at least one, default first, hosted at a stable URL (the site Worker or a tagged raw GitHub file). Flathub rejects listings without them. They must not show the Electron app.
2. **Release line.** Before tagging v3.0.0, add `<release version="3.0.0" date="..."/>` to the tracked metainfo's `<releases>` and commit it. The listing starts there; 2.x stays off it. From then on every release Flathub gets needs its line added, newest first, before its tag.
3. **License line.** `project_license` lists `LicenseRef-proprietary` for the icon, which is accurate but may get a Proprietary badge on the listing. Plain `GPL-3.0-only` is the alternative; decide before submitting.
4. **Artwork consent.** The icon is under `shared/assets/LICENSE`, which needs both copyright holders' written permission for uses beyond unmodified official releases. Flathub shows the icon on flathub.org and the Flatpak carries a resized copy, so get Hxney_bun_'s OK in writing.
5. **Generate for the tag.** On Linux, once v3.0.0 is pushed: `flutter/packaging/flatpak/update-sources.sh v3.0.0`, then commit the result.
6. **Build and lint.**

   ```sh
   flatpak install --user -y flathub org.flatpak.Builder
   flutter/packaging/flatpak/build-local.sh
   flatpak run --command=flatpak-builder-lint org.flatpak.Builder manifest flutter/packaging/flatpak/xyz.chaosinc.cascade.yml
   flatpak run --command=flatpak-builder-lint org.flatpak.Builder repo ~/.cache/cascade-flatpak/repo
   ```

   The repo check complains about screenshots not mirrored into the repo; Flathub's own build does that, ignore it locally.

## Submitting

1. Fork https://github.com/flathub/flathub, branch from `new-pr`, add `xyz.chaosinc.cascade.yml`, `generated/` and `flathub.json` at the top level, and open the PR against `new-pr`.
2. Once accepted, Flathub makes `flathub/xyz.chaosinc.cascade` and gives you write access.
3. **Verify the app id.** Log in at flathub.org with GitHub, open the app's developer page and take the verification token. Serve it at `https://chaosinc.xyz/.well-known/org.flathub.VerifiedApps.txt`: the apex domain, not `cascade.chaosinc.xyz` where the site Worker runs, so it needs its own route.

## Each release

Flathub's bot watches this repo's tags matching `vX.Y.Z` (no betas, no `server-v`) and opens a PR on `flathub/xyz.chaosinc.cascade` moving the app source to the new tag and commit. Flathub test-builds it.

- If the release left `flutter/pubspec.lock` and the Flutter version alone, that PR is all it takes; merge it.
- If `pubspec.lock` changed, the bot's PR fails its offline build on the missing packages. Run `update-sources.sh vX.Y.Z`, commit, copy `xyz.chaosinc.cascade.yml` and `generated/` into the Flathub repo in a PR of your own, and close the bot's.
- If the Flutter version changed, regenerate the same way even when the bot's PR builds: with the lock unchanged it builds fine on the old SDK and nothing flags it. Move the tag in `flatpak-flutter.yml` along with `FLUTTER_VERSION` in `.github/workflows/flutter.yml`; flatpak-flutter needs that version in its `releases/flutter/` data first, then move `FF_COMMIT` in `update-sources.sh` to a commit that has it.

Changes to the template (permissions, mpv or runtime bumps) also go to the Flathub repo by regenerating and copying.

`automerge-flathubbot-prs` is left out of `flathub.json` on purpose: the linter fails it (`flathub-json-automerge-enabled`) unless Flathub grants an exception, which it does for verified apps or ones that don't update too often. Without it the bot still opens and test-builds each update PR; merge it by hand.

## Beta channel (optional, after 3.0.0 is listed)

Flathub serves a `beta` git branch of `flathub/xyz.chaosinc.cascade` from a separate repo, flathub-beta. People opt in and get both side by side:

```sh
flatpak remote-add --user --if-not-exists flathub-beta https://flathub.org/beta-repo/flathub-beta.flatpakrepo
flatpak install --user flathub-beta xyz.chaosinc.cascade
flatpak make-current --user xyz.chaosinc.cascade beta   # or stable, to switch back
```

Setting it up:

1. Open a PR against the default branch first (Flathub asks for this), then `git checkout -b beta master`, merge that PR's branch and push. The push starts the first beta build, and from then on `beta` is protected: changes land by merged PR only.
2. In the beta branch's manifest, widen the app source's `tag-pattern` to `^v([0-9]+\.[0-9]+\.[0-9]+(-b[0-9]+)?)$`, so beta users get each beta and each stable. A beta needs its own `<release ... type="development"/>` line in the metainfo before its tag, or it builds as the previous version.
3. Flathub's bot only checks the default branch. For `beta`, add `.github/workflows/update.yaml` to the Flathub repo's default branch, following "Custom workflow to run external-data-checker on multiple branches" in https://docs.flathub.org/docs/for-app-authors/maintenance: a weekly schedule, a matrix of `[ beta ]` only (the global bot keeps the default branch, so no `disable-external-data-checker` and no duplicate PRs), checkout of `${{ matrix.branch }}`, and the checker container with `--update --never-fork xyz.chaosinc.cascade.yml`. That repo belongs to the flathub org, so the GitHub-owned-actions rule of this repo doesn't apply there.
4. Template changes now go to both branches, each by PR.

Both channels share `~/.var/app/xyz.chaosinc.cascade`, so a beta that migrates settings or the cache must leave something stable can still read, or switching back breaks. Flathub also expects beta builds to move to stable "after a reasonable period", so the beta channel is for real betas, not a permanent second track.
