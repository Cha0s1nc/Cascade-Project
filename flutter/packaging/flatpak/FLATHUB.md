# Submitting to Flathub

Held until 3.0. Everything Flathub needs lives in this folder: `xyz.chaosinc.cascade.yml` (the manifest Flathub builds) and `flathub.json` (x86_64 only, and the update bot's PRs merge themselves). The metainfo, icon and licenses ship inside the release tarball (`flutter/packaging/linux/package.sh`), so the manifest has one Cascade source.

## Before submitting

1. **Screenshots.** Add a `<screenshots>` block to `xyz.chaosinc.cascade.metainfo.xml` with at least one, default first, hosted at a stable URL (the site Worker or a tagged raw GitHub file). Flathub rejects listings without them. They must not show the Electron app.
2. **Release history.** The listing starts at 3.0.0, and the 2.x Flutter releases stay off it. The tracked metainfo's `<releases>` is empty and package.sh adds the version being built to the tarball's copy, so the 3.0.0 tarball lists exactly 3.0.0. After that, add each published version to the tracked file, newest first, or the listing only ever shows the latest one.
3. **License line.** `project_license` lists `LicenseRef-proprietary` for the icon, which is accurate but may get a Proprietary badge on the listing. Plain `GPL-3.0-only` is the alternative; decide before submitting.
4. **Artwork consent.** The icon is under `shared/assets/LICENSE`, which needs both copyright holders' written permission for uses beyond unmodified official releases. Flathub shows the icon on flathub.org and the Flatpak carries a resized copy, so get Hxney_bun_'s OK in writing.
5. **Point the manifest at the release.** In `xyz.chaosinc.cascade.yml`, set the archive `url` to the 3.0.0 tarball and `sha256` to its hash (`curl -sL <url> | sha256sum`).
6. **Lint.** On Linux, with the tarball built locally:

   ```sh
   flatpak install --user -y flathub org.flatpak.Builder
   flatpak run --command=flatpak-builder-lint org.flatpak.Builder manifest flutter/packaging/flatpak/xyz.chaosinc.cascade.yml
   flutter/packaging/flatpak/build-local.sh Cascade-Flutter-linux-x64.tar.gz
   flatpak run --command=flatpak-builder-lint org.flatpak.Builder repo ~/.cache/cascade-flatpak/repo
   ```

   The repo check complains about screenshots not mirrored into the repo; Flathub's own build does that, ignore it locally.

7. **Names at 3.0.** If 3.0 renames the tarball (dropping "Flutter") or the `flutter` key in versions.json, update `version-query`, `url-query` and the archive `url` in the manifest, or the bot quietly stops opening PRs.

## Submitting

1. Fork https://github.com/flathub/flathub, branch from `new-pr`, add the manifest and `flathub.json` at the top level, and open the PR against `new-pr`.
2. A reviewer may ask why the app repackages a prebuilt binary instead of building Flutter from source. The answer: it is the upstream's own release build, the source is public under GPL-3.0, and Flutter has no offline build path in flatpak-builder. If they insist, flatpak-flutter (github.com/TheAppgineer/flatpak-flutter) generates the offline sources.
3. Once accepted, Flathub makes `flathub/xyz.chaosinc.cascade` and gives you write access.
4. **Verify the app id.** Log in at flathub.org with GitHub, open the app's developer page and take the verification token. Serve it at `https://chaosinc.xyz/.well-known/org.flathub.VerifiedApps.txt`: the apex domain, not `cascade.chaosinc.xyz` where the site Worker runs, so it needs its own route.

## After that

Nothing to do per release. Flathub's bot reads `versions.json` from the latest non-beta release; when its `flutter` version changes, the bot opens a PR on `flathub/xyz.chaosinc.cascade` with the new URL and hash, Flathub test-builds it and it merges itself. A release that only carried the Flutter tarball over keeps the old version, so it opens nothing.

Changes to the manifest itself (permissions, mpv or runtime bumps) go into this folder first, then get copied into the Flathub repo by hand in a PR there.

The CI bundle job in `.github/workflows/flutter.yml` can go once the Flathub listing is live.

`automerge-flathubbot-prs` in `flathub.json` is only granted to verified apps or ones that don't update too often, and it needs a linter exception (`flathub-json-automerge-enabled`) requested in the submission PR. If Flathub says no, drop the key and merge the bot's PRs by hand.

## Beta channel (optional, after 3.0.0 is listed)

Flathub serves a `beta` git branch of `flathub/xyz.chaosinc.cascade` from a separate repo, flathub-beta. People opt in and get both side by side:

```sh
flatpak remote-add --user --if-not-exists flathub-beta https://flathub.org/beta-repo/flathub-beta.flatpakrepo
flatpak install --user flathub-beta xyz.chaosinc.cascade
flatpak make-current --user xyz.chaosinc.cascade beta   # or stable, to switch back
```

Setting it up:

1. Open a PR against the default branch first (Flathub asks for this), then `git checkout -b beta master`, merge that PR's branch and push. The push starts the first beta build, and from then on `beta` is protected: changes land by merged PR only.
2. In the beta branch's manifest, point `x-checker-data` at the newest release of any kind that carries the Flutter tarball. Stable releases count too, so beta users get each stable instead of sitting on an old beta; betas that didn't rebuild Flutter are skipped because they have no tarball:

   ```yaml
   x-checker-data:
     type: json
     url: https://api.github.com/repos/Cha0s1nc/Cascade-Project/releases?per_page=30
     version-query: '[.[] | select(any(.assets[]; .name == "Cascade-Flutter-linux-x64.tar.gz"))][0].tag_name | ltrimstr("v")'
     url-query: '"https://github.com/Cha0s1nc/Cascade-Project/releases/download/v" + $version + "/Cascade-Flutter-linux-x64.tar.gz"'
   ```

3. Flathub's bot only checks the default branch. For `beta`, add `.github/workflows/update.yaml` to the Flathub repo's default branch, following "Custom workflow to run external-data-checker on multiple branches" in https://docs.flathub.org/docs/for-app-authors/maintenance: a weekly schedule, a matrix of `[ beta ]` only (the global bot keeps the default branch, so no `disable-external-data-checker` and no duplicate PRs), checkout of `${{ matrix.branch }}`, and the checker container with `--update --never-fork xyz.chaosinc.cascade.yml`. That repo belongs to the flathub org, so the GitHub-owned-actions rule of this repo doesn't apply there.
4. Manifest changes (permissions, mpv, runtime) now go to both branches, each by PR.

Both channels share `~/.var/app/xyz.chaosinc.cascade`, so a beta that migrates settings or the cache must leave something stable can still read, or switching back breaks. Flathub also expects beta builds to move to stable "after a reasonable period", so the beta channel is for real betas, not a permanent second track.
