#!/usr/bin/env bash
# Builds the Flatpak from a release tarball and installs it for this user:
#
#   flutter/packaging/flatpak/build-local.sh <Cascade-Flutter-linux-x64.tar.gz>
#   flatpak run xyz.chaosinc.cascade
#
# The tarball comes from a Flutter CI run (dist-flutter-linux) or from
# flutter/packaging/linux/package.sh. Needs flatpak-builder; the GNOME runtime
# and SDK are installed from Flathub on the first run. The first build also
# compiles libass, libplacebo and mpv (a few minutes); later ones reuse them.
# Remove it with: flatpak uninstall --user xyz.chaosinc.cascade
set -euo pipefail

TARBALL=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
HERE=$(cd "$(dirname "$0")" && pwd)
WORK="${XDG_CACHE_HOME:-$HOME/.cache}/cascade-flatpak"
mkdir -p "$WORK"

# flatpak-builder reads sources beside the manifest, so the build gets its own copy.
cp "$HERE"/xyz.chaosinc.cascade.yml "$HERE"/xyz.chaosinc.cascade.metainfo.xml "$HERE"/xyz.chaosinc.cascade.png "$WORK/"
cp "$TARBALL" "$WORK/Cascade-Flutter-linux-x64.tar.gz"

flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
cd "$WORK"
flatpak-builder --user --install --force-clean --install-deps-from=flathub \
  --state-dir="$WORK/state" "$WORK/build" xyz.chaosinc.cascade.yml
echo "Installed. Run it with: flatpak run xyz.chaosinc.cascade"
