#!/usr/bin/env bash
# Runs CascadeKit's offline catalog and query engine tests on Linux, for a
# session with no Mac (a cloud agent). It is NOT `swift test` in
# apple/CascadeKit: most of CascadeKit needs Apple's frameworks, so this builds
# a scratch package from the few pure files Offline Mode touches (symlinked, so
# the code tested is the repo's), with a stand-in for UniformTypeIdentifiers.
# A Mac's `swift test` and the app schemes are still the real check.
#
# Swift comes from Ubuntu's own swiftlang package (download.swift.org may be
# out of reach), unpacked into the work folder, never installed. 6.0.3 is the
# newest that runs on Ubuntu 24.04's glibc; it needs two newer libraries,
# unpacked beside it.
#
#   scripts/swift-linux-check.sh [work folder]   (default: /tmp/cascade-swift-check)
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
KIT="$REPO/apple/CascadeKit"
WORK=${1:-/tmp/cascade-swift-check}
ROOT="$WORK/toolchain"
PKG="$WORK/package"
POOL=http://archive.ubuntu.com/ubuntu/pool
DEBS=(
  "universe/s/swiftlang/swiftlang_6.0.3-2build1_amd64.deb"
  "universe/s/swiftlang/libswiftlang_6.0.3-2build1_amd64.deb"
  "main/p/python3.13/libpython3.13_3.13.3-1ubuntu0.5_amd64.deb"
  "main/libx/libxml2/libxml2-16_2.15.2+dfsg-0.1_amd64.deb"
)

if [ ! -x "$ROOT/usr/libexec/swift/bin/swift" ]; then
  mkdir -p "$WORK/debs" "$ROOT"
  for deb in "${DEBS[@]}"; do
    file="$WORK/debs/$(basename "$deb")"
    [ -f "$file" ] || curl -sSf -o "$file" "$POOL/$deb"
    dpkg -x "$file" "$ROOT"
  done
fi
export PATH="$ROOT/usr/libexec/swift/bin:$PATH"
export LD_LIBRARY_PATH="$ROOT/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

rm -rf "$PKG/Sources" "$PKG/Tests"
mkdir -p "$PKG/Sources/UniformTypeIdentifiers" "$PKG/Sources/CascadeKit" "$PKG/Tests/CascadeKitTests"

cat > "$PKG/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CascadeKitLinuxCheck",
    targets: [
        .target(name: "UniformTypeIdentifiers"),
        .target(name: "CascadeKit", dependencies: ["UniformTypeIdentifiers"]),
        .testTarget(name: "CascadeKitTests", dependencies: ["CascadeKit"]),
    ]
)
EOF

cat > "$PKG/Sources/UniformTypeIdentifiers/UTType.swift" <<'EOF'
// Just enough of Apple's UTType for OfflineIndex.fileExtension on Linux.
public struct UTType: Sendable, Equatable {
    let id: String
    public let preferredFilenameExtension: String?
    let isMedia: Bool
    public static let audiovisualContent = UTType(id: "public.audiovisual-content", preferredFilenameExtension: nil, isMedia: true)
    static let media: [String: String] = ["flac": "audio/flac", "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac",
                                          "wav": "audio/wav", "ogg": "audio/ogg", "opus": "audio/opus", "mp4": "video/mp4", "mkv": "video/x-matroska"]
    public init?(filenameExtension ext: String) {
        guard Self.media[ext.lowercased()] != nil else { return nil }
        self.init(id: ext, preferredFilenameExtension: ext.lowercased(), isMedia: true)
    }
    public init?(mimeType: String) {
        guard let ext = Self.media.first(where: { $0.value == mimeType.lowercased() })?.key else { return nil }
        self.init(id: mimeType, preferredFilenameExtension: ext, isMedia: true)
    }
    init(id: String, preferredFilenameExtension: String?, isMedia: Bool) {
        self.id = id; self.preferredFilenameExtension = preferredFilenameExtension; self.isMedia = isMedia
    }
    public func conforms(to other: UTType) -> Bool { other == .audiovisualContent ? isMedia : self == other }
}
EOF

# Playback.swift, which defines this, needs AVFoundation.
echo 'public let ticksPerSecond = 10_000_000.0' > "$PKG/Sources/CascadeKit/LinuxShims.swift"

for f in Models.swift JSON.swift OfflineIndex.swift OfflineQuery.swift Chapters.swift; do
  ln -s "$KIT/Sources/CascadeKit/$f" "$PKG/Sources/CascadeKit/$f"
done
for f in OfflineIndexV2Tests.swift OfflineQueryTests.swift; do
  ln -s "$KIT/Tests/CascadeKitTests/$f" "$PKG/Tests/CascadeKitTests/$f"
done

python3 - "$KIT" "$PKG" <<'PY'
import sys
kit, pkg = sys.argv[1], sys.argv[2]
# Lyrics.swift: only the two lyric structs; the rest needs JellyfinClient.
src = open(f'{kit}/Sources/CascadeKit/Lyrics.swift').read()
open(f'{pkg}/Sources/CascadeKit/LyricTypes.swift', 'w').write(src[:src.index('public enum Lyrics {')])
# OfflineIndexTests.swift without the DownloadDelegate test (needs
# FoundationNetworking and OfflineLibrary).
src = open(f'{kit}/Tests/CascadeKitTests/OfflineIndexTests.swift').read()
start = src.index('    @Test func onlyAWholeAudioResponseBecomesATrack()')
end = src.index('    @Test func', start + 10)
open(f'{pkg}/Tests/CascadeKitTests/OfflineIndexTests.swift', 'w').write(src[:start] + src[end:])
PY

cd "$PKG"
swift test 2>&1 | grep -E "error:|warning:|✘|Test run"
