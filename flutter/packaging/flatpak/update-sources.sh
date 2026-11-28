#!/usr/bin/env bash
# Writes the Flathub manifest from flatpak-flutter.yml for one release:
#
#   flutter/packaging/flatpak/update-sources.sh v3.0.0
#
# flatpak-flutter fetches the app at that tag (or a full commit sha, for a test
# build), pins the Flutter SDK and every Dart package as sources, and writes
# xyz.chaosinc.cascade.yml plus generated/ here. Rerun it for any release that
# changes flutter/pubspec.lock or the Flutter version, then copy the results
# into the Flathub repo (FLATHUB.md). Runs on Linux, inside org.flatpak.Builder
# (the linter's Flatpak, which has git and the Python modules it needs).
set -euo pipefail

REF=${1:?usage: update-sources.sh <tag or commit>}
HERE=$(cd "$(dirname "$0")" && pwd)
# Pinned, so a regeneration only changes when we move it.
FF_COMMIT=e59a96fcb0fcf48fcd46e8134cae64c26fdc3290
FF=${XDG_CACHE_HOME:-$HOME/.cache}/cascade-flatpak-flutter
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ ! -d "$FF/.git" ]; then
  git clone -q https://github.com/TheAppgineer/flatpak-flutter.git "$FF"
fi
git -C "$FF" fetch -q origin
git -C "$FF" checkout -q "$FF_COMMIT"

if [[ $REF =~ ^[0-9a-f]{40}$ ]]; then
  sed "s|tag: '@TAG@'|commit: $REF|" "$HERE/flatpak-flutter.yml" > "$WORK/flatpak-flutter.yml"
else
  sed "s|'@TAG@'|$REF|" "$HERE/flatpak-flutter.yml" > "$WORK/flatpak-flutter.yml"
fi
# Sees only the tool's checkout (read-only) and the scratch folder.
flatpak run --share=network --filesystem="$FF":ro --filesystem="$WORK" --cwd="$WORK" \
  --command=python3 org.flatpak.Builder "$FF/flatpak-flutter.py" --app-pubspec flutter flatpak-flutter.yml

rm -rf "$HERE/generated"
cp -r "$WORK/generated" "$HERE/"
cp "$WORK/xyz.chaosinc.cascade.yml" "$HERE/"
echo "Wrote xyz.chaosinc.cascade.yml and generated/ for $REF"
