#!/usr/bin/env bash
# Makes a small folder for trying Local mode (docs/local-mode-testing.md):
# tagged songs in the formats Chromium plays and two it does not (ALAC, and
# HEVC and DTS in MKV), an .lrc beside a song, a compilation whose cover is
# embedded, a movie with an .srt, a two-episode show, an .m3u8 playlist.
# Everything is generated with ffmpeg (tones and test patterns), so nothing
# copyrighted goes in. Needs ffmpeg with libx264, libx265, libvpx and libopus.
#
#   scripts/make-local-test-library.sh /tmp/cascade-local-test
set -euo pipefail

out="${1:?usage: make-local-test-library.sh <folder>}"
mkdir -p "$out"
cd "$out"
f() { ffmpeg -hide_banner -loglevel error -y "$@"; }

a="Music/Artist A/Album One (2019)"
b="Music/Artist B/Second"
c="Music/Compilation/Hits"
mkdir -p "$a" "$b" "$c" "Movies/Test Movie (2010)" "Movies/Hevc Film (2021)" "Movies/Dts Film (2022)" "Shows/Test Show/Season 01"

f -f lavfi -i "color=c=red:s=320x320" -frames:v 1 "$a/cover.jpg"
f -f lavfi -i "color=c=blue:s=320x320" -frames:v 1 "/tmp/cascade-embedded-cover.jpg"

f -f lavfi -i "sine=frequency=440:duration=20" -metadata title="First Song" -metadata artist="Artist A" \
  -metadata album_artist="Artist A" -metadata album="Album One" -metadata track=1 -metadata date=2019 -metadata genre="Rock" \
  "$a/01 First Song.mp3"
f -f lavfi -i "sine=frequency=550:duration=20" -metadata title="Second Song" -metadata artist="Artist A feat. C" \
  -metadata album_artist="Artist A" -metadata album="Album One" -metadata track=2 -metadata date=2019 -metadata genre="Rock" \
  -metadata REPLAYGAIN_TRACK_GAIN="-6.5 dB" "$a/02 Second Song.flac"
printf '[00:00.50]Line one, from the .lrc file\n[00:05.00]Line two\n[00:10.00]Line three\n[00:15.00]Line four\n' > "$a/01 First Song.lrc"

f -f lavfi -i "sine=frequency=660:duration=20" -c:a aac -metadata title="Aac Song" -metadata artist="Artist B" \
  -metadata album="Second" -metadata track=1 -metadata genre="Jazz" "$b/01 Aac Song.m4a"
f -f lavfi -i "sine=frequency=770:duration=20" -c:a alac -metadata title="Alac Song" -metadata artist="Artist B" \
  -metadata album="Second" -metadata track=2 "$b/02 Alac Song.m4a"
f -f lavfi -i "sine=frequency=880:duration=20" -c:a aac -vn -metadata title="Audio Only" -metadata artist="Artist B" \
  -metadata album="Second" -metadata track=3 "$b/03 Audio Only.mp4"

# A compilation: no album artist, a different artist per track, the cover inside the first file.
f -f lavfi -i "sine=frequency=330:duration=20" -i /tmp/cascade-embedded-cover.jpg -map 0 -map 1 -c:a libmp3lame -c:v copy \
  -id3v2_version 3 -metadata title="One" -metadata artist="X" -metadata album="Hits" -metadata track=1 "$c/01 One.mp3"
f -f lavfi -i "sine=frequency=360:duration=20" -metadata title="Two" -metadata artist="Y" -metadata album="Hits" -metadata track=2 "$c/02 Two.mp3"
rm -f /tmp/cascade-embedded-cover.jpg

f -f lavfi -i "testsrc=size=640x360:rate=24:duration=30" -f lavfi -i "sine=duration=30" -c:v libx264 -c:a aac -shortest \
  "Movies/Test Movie (2010)/Test Movie (2010).mkv"
printf '1\n00:00:01,000 --> 00:00:04,000\nHello <i>there</i>\n\n2\n00:00:05,000 --> 00:00:09,000\nA second subtitle\n' \
  > "Movies/Test Movie (2010)/Test Movie (2010).en.srt"
f -f lavfi -i "color=c=green:s=400x600" -frames:v 1 "Movies/Test Movie (2010)/poster.jpg"
f -f lavfi -i "testsrc=size=640x360:rate=24:duration=10" -f lavfi -i "sine=duration=10" -c:v libx265 -c:a aac -shortest \
  "Movies/Hevc Film (2021)/Hevc Film (2021).mkv"
f -f lavfi -i "testsrc=size=640x360:rate=24:duration=10" -f lavfi -i "sine=duration=10" -c:v libx264 -c:a dca -strict -2 -ac 2 -shortest \
  "Movies/Dts Film (2022)/Dts Film (2022).mkv"

f -f lavfi -i "testsrc=size=640x360:rate=24:duration=20" -f lavfi -i "sine=duration=20" -c:v libx264 -c:a aac -shortest \
  "Shows/Test Show/Season 01/Test Show S01E01.mp4"
f -f lavfi -i "testsrc=size=640x360:rate=24:duration=20" -f lavfi -i "sine=duration=20" -c:v libvpx-vp9 -c:a libopus -shortest \
  "Shows/Test Show/Season 01/Test Show S01E02 The Second.webm"
f -f lavfi -i "color=c=yellow:s=400x600" -frames:v 1 "Shows/Test Show/folder.jpg"

printf '#EXTM3U\n#EXTINF:20,Artist A - First Song\nMusic/Artist A/Album One (2019)/01 First Song.mp3\nMusic/Artist B/Second/01 Aac Song.m4a\nmissing.mp3\n' \
  > "Road Trip.m3u8"

echo "Made $(find . -type f | wc -l) files in $out"
