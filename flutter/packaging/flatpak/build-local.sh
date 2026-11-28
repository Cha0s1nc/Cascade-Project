#!/usr/bin/env bash
# Builds the Flathub manifest the way Flathub does, offline, and installs it
# for this user:
#
#   flutter/packaging/flatpak/build-local.sh [bundle.flatpak]
#   flatpak run xyz.chaosinc.cascade
#
# It builds the commit update-sources.sh last pinned, from GitHub, so push
# first and regenerate to test other code. --sandbox cuts the network after
# the sources are downloaded: if the build tries to fetch anything, it fails
# here the same as on Flathub. With an argument it also writes a single-file
# bundle there, for trying the app on a machine (flatpak install --user <file>).
#
# Needs flatpak-builder. The first run installs the GNOME SDK and llvm
# extension from Flathub and compiles libass, libplacebo and mpv (a few
# minutes); later ones reuse them. Remove the app with:
# flatpak uninstall --user xyz.chaosinc.cascade
set -euo pipefail

BUNDLE=${1:+$(cd "$(dirname "$1")" && pwd)/$(basename "$1")}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/cascade-flatpak"
mkdir -p "$WORK"

flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
cd "$HERE"
flatpak-builder --user --install --force-clean --sandbox --install-deps-from=flathub \
  --state-dir="$WORK/state" --repo="$WORK/repo" "$WORK/build" xyz.chaosinc.cascade.yml
echo "Installed. Run it with: flatpak run xyz.chaosinc.cascade"

if [ -n "$BUNDLE" ]; then
  flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo \
    "$WORK/repo" "$BUNDLE" xyz.chaosinc.cascade
  ls -la "$BUNDLE"
fi
