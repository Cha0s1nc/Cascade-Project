#!/usr/bin/env bash
# Packages a `flutter build linux --release` bundle as a .tar.gz, the build for
# people who manage their own installs:
#
#   flutter/packaging/linux/package.sh <bundle dir> <version> <out dir>
#
# The file name carries no version on purpose: see PLATFORM_FILES.flutter in
# desktop/src/core/release-plan.ts.
#
# It also carries what the Flatpak installs beside the app (metainfo with this
# version's release line, the 512 px icon, the licenses), so the Flathub
# manifest needs this one file as its only Cascade source.
#
# ponytail: a tarball only. The main Linux download is the Flatpak on Flathub;
# a .deb was dropped on 2026-11-23 for that, and an AppImage would have to
# bundle WebKitGTK.
set -euo pipefail

BUNDLE=$(cd "$1" && pwd)
VERSION=$2
OUT=$3
HERE=$(cd "$(dirname "$0")" && pwd)
# The tracked 1024 px icon, the same art as the Electron app's generated
# (and untracked) desktop/assets/linux-icons.
ROOT="$HERE/../../.."
ICON="$ROOT/shared/assets/icon.png"
FLATPAK="$HERE/../flatpak"
ID=xyz.chaosinc.cascade
[ -x "$BUNDLE/cascade" ] || { echo "No cascade binary in $BUNDLE"; exit 1; }
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

TAR="$WORK/cascade-flutter"
mkdir -p "$TAR"
cp -a "$BUNDLE/." "$TAR/"
cp "$HERE/$ID.desktop" "$TAR/"
cp "$ICON" "$TAR/$ID.png"
cp "$FLATPAK/$ID.png" "$TAR/icon-512.png"
cp "$ROOT/LICENSE" "$TAR/LICENSE"
cp "$ROOT/shared/assets/LICENSE" "$TAR/ARTWORK-LICENSE"
# This version's <release> line, unless the tracked metainfo already has one.
META=$(<"$FLATPAK/$ID.metainfo.xml")
if [[ $META != *"version=\"$VERSION\""* ]]; then
  TYPE=; [[ $VERSION == *-b* ]] && TYPE=' type="development"'
  META=${META/<releases>/<releases>$'\n'"    <release version=\"$VERSION\" date=\"$(date -u +%F)\"$TYPE/>"}
fi
printf '%s\n' "$META" > "$TAR/$ID.metainfo.xml"
cat > "$TAR/INSTALL.txt" <<EOF
Cascade $VERSION, Flutter build for Linux (x86_64)

Run ./cascade from this folder. It needs glibc 2.39 or newer, GTK 3, libmpv
(mpv's library) and WebKitGTK 4.1 installed: on Arch, pacman -S gtk3 mpv
webkit2gtk-4.1; on Fedora, dnf install gtk3 mpv-libs webkit2gtk4.1; on Debian
13 or Ubuntu 24.04 and newer, apt install libgtk-3-0t64 libmpv2
libwebkit2gtk-4.1-0.

For a menu entry, link ./cascade into your PATH as cascade-flutter (the
.desktop file runs that), copy $ID.desktop to ~/.local/share/applications/
and $ID.png to ~/.local/share/icons/.
EOF
# Writable by the owner alone, whatever the build machine's umask.
chmod -R u+rwX,go+rX,go-w "$TAR"
tar -C "$WORK" -czf "$OUT/Cascade-Flutter-linux-x64.tar.gz" cascade-flutter

ls -la "$OUT"
