#!/usr/bin/env bash
# Packages a `flutter build linux --release` bundle as a .deb and a .tar.gz:
#
#   flutter/packaging/linux/package.sh <bundle dir> <version> <out dir>
#
# Installs beside the Electron app, never over it: package cascade-flutter,
# /opt/cascade-flutter, the command cascade-flutter. The file names carry no
# version on purpose: see PLATFORM_FILES.flutter in
# desktop/src/core/release-plan.ts.
#
# ponytail: .deb and .tar.gz only. An .rpm or AppImage would have to bundle
# or chase libmpv and WebKitGTK; add one when someone asks for it.
set -euo pipefail

BUNDLE=$(cd "$1" && pwd)
VERSION=$2
OUT=$3
HERE=$(cd "$(dirname "$0")" && pwd)
ICON="$HERE/../../../desktop/assets/linux-icons/512x512.png"
ID=xyz.chaosinc.cascade.flutter
[ -x "$BUNDLE/cascade" ] || { echo "No cascade binary in $BUNDLE"; exit 1; }
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── .deb ──
ROOT="$WORK/deb"
mkdir -p "$ROOT/DEBIAN" "$ROOT/opt/cascade-flutter" "$ROOT/usr/bin" \
  "$ROOT/usr/share/applications" "$ROOT/usr/share/icons/hicolor/512x512/apps"
cp -a "$BUNDLE/." "$ROOT/opt/cascade-flutter/"
# Flutter finds lib/ and data/ from the real path of the binary, so a symlink works.
ln -s /opt/cascade-flutter/cascade "$ROOT/usr/bin/cascade-flutter"
install -m 644 "$HERE/$ID.desktop" "$ROOT/usr/share/applications/"
install -m 644 "$ICON" "$ROOT/usr/share/icons/hicolor/512x512/apps/$ID.png"
# Root-owned files, writable by root alone, whatever the build machine's umask.
chmod -R u+rwX,go+rX,go-w "$ROOT"
# Debian sorts ~ before anything, so a 2.5.0~b1 beta comes before 2.5.0.
cat > "$ROOT/DEBIAN/control" <<EOF
Package: cascade-flutter
Version: ${VERSION//-/\~}
Architecture: amd64
Maintainer: cha0s_1nc <contact@chaosinc.xyz>
Homepage: https://cascade.chaosinc.xyz
Section: sound
Priority: optional
Depends: libgtk-3-0t64 | libgtk-3-0, libmpv2, libwebkit2gtk-4.1-0
Description: Cascade, a Jellyfin music and video client
 The Flutter build of Cascade for Linux.
EOF
dpkg-deb --root-owner-group --build "$ROOT" "$OUT/Cascade-Flutter-amd64.deb"

# ── .tar.gz, for every other distribution ──
TAR="$WORK/cascade-flutter"
mkdir -p "$TAR"
cp -a "$BUNDLE/." "$TAR/"
cp "$HERE/$ID.desktop" "$ICON" "$TAR/"
mv "$TAR/512x512.png" "$TAR/$ID.png"
cat > "$TAR/INSTALL.txt" <<EOF
Cascade $VERSION, Flutter build for Linux (x86_64)

Run ./cascade from this folder. It needs GTK 3, libmpv (mpv's library) and
WebKitGTK 4.1 installed: on Arch, pacman -S gtk3 mpv webkit2gtk-4.1; on
Fedora, dnf install gtk3 mpv-libs webkit2gtk4.1.

For a menu entry, copy $ID.desktop to ~/.local/share/applications/ and
$ID.png to ~/.local/share/icons/hicolor/512x512/apps/, then set Exec= in the
.desktop file to the full path of ./cascade (or link ./cascade into your PATH
as cascade-flutter).
EOF
chmod -R u+rwX,go+rX,go-w "$TAR"
tar -C "$WORK" -czf "$OUT/Cascade-Flutter-linux-x64.tar.gz" cascade-flutter

ls -la "$OUT"
