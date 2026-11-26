#!/usr/bin/env bash
# Builds the Flatpak from a release tarball and installs it for this user:
#
#   flutter/packaging/flatpak/build-local.sh <Cascade-Flutter-linux-x64.tar.gz> [bundle.flatpak]
#   flatpak run xyz.chaosinc.cascade
#
# With a second argument it also writes a single-file bundle there, the one
# CI attaches to releases (flutter.yml). A bundle has no update channel: it is
# for trying the app until it is on Flathub. Install one with
# flatpak install --user <file>; the GNOME runtime comes from Flathub.
#
# The tarball comes from a Flutter CI run (dist-flutter-linux) or from
# flutter/packaging/linux/package.sh. Needs flatpak-builder; the GNOME runtime
# and SDK are installed from Flathub on the first run. The first build also
# compiles libass, libplacebo and mpv (a few minutes); later ones reuse them.
# Remove it with: flatpak uninstall --user xyz.chaosinc.cascade
set -euo pipefail

TARBALL=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
BUNDLE=${2:+$(cd "$(dirname "$2")" && pwd)/$(basename "$2")}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/cascade-flatpak"
mkdir -p "$WORK"

# The manifest is Flathub's, which downloads a release: this copy points its
# archive at the local tarball instead (the url line, then the sha256 line after
# it). The sha256 stays, set to the tarball's: flatpak-builder keys its cache on
# it, and without one a new tarball of the same name reused the old app.
SHA=$(sha256sum "$TARBALL" | cut -d' ' -f1)
sed "/url: .*\/Cascade-Flutter-linux-x64\.tar\.gz/{s|url: .*|path: Cascade-Flutter-linux-x64.tar.gz|;n;s|sha256: .*|sha256: $SHA|;}" \
  "$HERE"/xyz.chaosinc.cascade.yml > "$WORK/xyz.chaosinc.cascade.yml"
grep -q "sha256: $SHA" "$WORK/xyz.chaosinc.cascade.yml" || { echo "Could not point the manifest at the tarball"; exit 1; }
cp "$TARBALL" "$WORK/Cascade-Flutter-linux-x64.tar.gz"

flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
cd "$WORK"
flatpak-builder --user --install --force-clean --install-deps-from=flathub \
  --state-dir="$WORK/state" --repo="$WORK/repo" "$WORK/build" xyz.chaosinc.cascade.yml
echo "Installed. Run it with: flatpak run xyz.chaosinc.cascade"

if [ -n "$BUNDLE" ]; then
  flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo \
    "$WORK/repo" "$BUNDLE" xyz.chaosinc.cascade
  ls -la "$BUNDLE"
fi
