#!/usr/bin/env bash
#
# Remux HEVC/Matroska files so every Cascade client can direct play them.
#
# The video stream is COPIED, never re-encoded - this changes the container and
# the audio track, nothing else, so it is fast and lossless for the picture.
# Only the audio codecs no browser can decode (AC3, E-AC3, DTS, TrueHD) are
# converted, and only to AAC.
#
# Why this exists at all, given the desktop client no longer needs it: a device
# profile only fixes the client it describes. The Roku port and the planned
# React Native TV client each have their own, and HEVC-in-Matroska support on TV
# hardware varies by model year. Converting the files fixes every client at once.
#
# Runs on the Mac, does the work on the server over SSH, so no media crosses the
# network.
#
# Usage:
#   scripts/remux-hevc.sh                 # dry run - lists what it would do
#   scripts/remux-hevc.sh --apply         # actually convert
#   scripts/remux-hevc.sh --apply --limit 1   # convert one, to see it work first
#
# Nothing is deleted. Each original is renamed alongside its replacement:
#   foo.mkv  ->  foo.mkv.original   (Jellyfin ignores the extension)
#   foo.mp4  <-  new file
# To undo one:  mv foo.mkv.original foo.mkv && rm foo.mp4
# To undo all:  scripts/remux-hevc.sh --revert
#
# Env overrides: SSH_HOST, JF_CONTAINER, JELLYFIN_URL, JELLYFIN_TOKEN, JELLYFIN_USER

set -euo pipefail

SSH_HOST="${SSH_HOST:-zima}"
JF_CONTAINER="${JF_CONTAINER:-jellyfin}"
MODE=dry
LIMIT=0
REVERT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)  MODE=apply ;;
    --revert) REVERT=1 ;;
    --limit)  LIMIT="${2:?--limit needs a number}"; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# ── Credentials ───────────────────────────────────────────────────────────────
# Read from Cascade's own store by default, because if you are running this you
# already signed the app in and there is no reason to type it twice.
CONFIG_CANDIDATES=(
  "$HOME/Library/Application Support/Cascade/config.json"
  "/tmp/cascade-second-instance/config.json"
)
JELLYFIN_URL="${JELLYFIN_URL:-}"
JELLYFIN_TOKEN="${JELLYFIN_TOKEN:-}"
JELLYFIN_USER="${JELLYFIN_USER:-}"

if [ -z "$JELLYFIN_URL" ]; then
  for f in "${CONFIG_CANDIDATES[@]}"; do
    [ -f "$f" ] || continue
    JELLYFIN_URL=$(node -p "(require('$f').serverUrl||'').replace(/\/$/,'')" 2>/dev/null || echo '')
    JELLYFIN_TOKEN=$(node -p "require('$f').token||''" 2>/dev/null || echo '')
    JELLYFIN_USER=$(node -p "require('$f').userId||''" 2>/dev/null || echo '')
    [ -n "$JELLYFIN_URL" ] && { echo "Using credentials from: $f"; break; }
  done
fi

if [ -z "$JELLYFIN_URL" ] || [ -z "$JELLYFIN_TOKEN" ]; then
  echo "No Jellyfin credentials found. Set JELLYFIN_URL, JELLYFIN_TOKEN, JELLYFIN_USER." >&2
  exit 1
fi

# ── Revert ────────────────────────────────────────────────────────────────────
if [ "$REVERT" = 1 ]; then
  echo "Restoring every .original found under the library roots..."
  ssh "$SSH_HOST" "docker exec $JF_CONTAINER sh -s" <<'REVERT_EOF'
set -u
found=0
for root in /Media /Drive2; do
  [ -d "$root" ] || continue
  find "$root" -name '*.original' -type f 2>/dev/null | while IFS= read -r orig; do
    src="${orig%.original}"
    new="${src%.*}.mp4"
    mv -f "$orig" "$src" && rm -f "$new"
    echo "restored: $src"
  done
  found=1
done
[ "$found" = 1 ] || echo "no library roots found"
REVERT_EOF
  echo "Done. Run a Jellyfin library scan."
  exit 0
fi

# ── Find candidates ───────────────────────────────────────────────────────────
echo "Querying Jellyfin for HEVC files not already in mp4..."
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT

JELLYFIN_URL="$JELLYFIN_URL" JELLYFIN_TOKEN="$JELLYFIN_TOKEN" JELLYFIN_USER="$JELLYFIN_USER" \
node <<'NODE_EOF' > "$LIST"
const url = process.env.JELLYFIN_URL, token = process.env.JELLYFIN_TOKEN, user = process.env.JELLYFIN_USER
const H = { 'X-Emby-Token': token }
;(async () => {
  const views = await (await fetch(`${url}/Users/${user}/Views`, { headers: H })).json()
  const libs = (views.Items || []).filter(i => ['movies', 'tvshows'].includes(i.CollectionType))
  const seen = new Set()
  for (const lib of libs) {
    const r = await (await fetch(
      `${url}/Users/${user}/Items?ParentId=${lib.Id}&IncludeItemTypes=Episode,Movie` +
      `&Recursive=true&Fields=MediaStreams,MediaSources,Path&Limit=2000`, { headers: H })).json()
    for (const it of r.Items || []) {
      const ms = (it.MediaSources || [])[0] || {}
      const v = (it.MediaStreams || []).find(s => s.Type === 'Video') || {}
      // The exact case this script exists for: HEVC that is not already in mp4.
      if (v.Codec !== 'hevc') continue
      if ((ms.Container || '').toLowerCase() === 'mp4') continue
      const path = it.Path || ms.Path
      if (!path || seen.has(path)) continue
      seen.add(path)
      console.log(path)
    }
  }
})().catch(e => { console.error('query failed:', e.message); process.exit(1) })
NODE_EOF

TOTAL=$(grep -c . "$LIST" || true)
if [ "$TOTAL" = 0 ]; then echo "Nothing to convert."; exit 0; fi

if [ "$LIMIT" != 0 ]; then
  head -n "$LIMIT" "$LIST" > "$LIST.trimmed" && mv "$LIST.trimmed" "$LIST"
  echo "Found $TOTAL candidate(s); limiting to $LIMIT."
else
  echo "Found $TOTAL candidate(s)."
fi

[ "$MODE" = dry ] && echo && echo "DRY RUN - nothing will be written. Re-run with --apply." && echo

# ── Do the work, inside the container where the paths are real ────────────────
ssh "$SSH_HOST" "docker exec -i $JF_CONTAINER sh -c 'cat > /tmp/remux-list.txt'" < "$LIST"
ssh "$SSH_HOST" "docker exec -i $JF_CONTAINER sh -c 'cat > /tmp/remux-worker.sh'" <<'WORKER_EOF'
set -u
FF=/usr/lib/jellyfin-ffmpeg/ffmpeg
FP=/usr/lib/jellyfin-ffmpeg/ffprobe
MODE="${1:-dry}"
ok=0; skipped=0; failed=0

while IFS= read -r src; do
  [ -n "$src" ] || continue
  base="${src%.*}"
  dst="$base.mp4"

  if [ ! -f "$src" ]; then echo "MISSING   $src"; skipped=$((skipped+1)); continue; fi
  if [ -e "$dst" ];  then echo "EXISTS    $dst"; skipped=$((skipped+1)); continue; fi

  # ── Audio: copy what a browser can already decode, convert only the rest.
  aargs=""; i=0; converts=""
  for codec in $("$FP" -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$src" 2>/dev/null); do
    case "$codec" in
      aac|mp3|flac|opus|vorbis) aargs="$aargs -c:a:$i copy" ;;
      *) aargs="$aargs -c:a:$i aac -b:a:$i 256k"; converts="$converts $codec->aac" ;;
    esac
    i=$((i+1))
  done
  [ -n "$aargs" ] || { echo "NOAUDIO   $src"; skipped=$((skipped+1)); continue; }

  # ── Subtitles: mp4 cannot carry PGS, DVDSUB or ASS. Text tracks come out as
  #    sidecar files, which Jellyfin picks up. Bitmap tracks cannot be salvaged
  #    that way - they stay behind in the .original, and are reported.
  subs=""; lost=""; si=0
  "$FP" -v error -select_streams s -show_entries stream=codec_name:stream_tags=language \
        -of csv=p=0 "$src" 2>/dev/null > /tmp/remux-subs.txt || true
  while IFS=, read -r scodec slang; do
    [ -n "${scodec:-}" ] || continue
    slang="${slang:-und}"
    case "$scodec" in
      subrip|srt|text|mov_text) subs="$subs $si:srt:$slang" ;;
      ass|ssa)                  subs="$subs $si:ass:$slang" ;;
      *)                        lost="$lost $scodec" ;;
    esac
    si=$((si+1))
  done < /tmp/remux-subs.txt

  echo "CONVERT   $src"
  [ -n "$converts" ] && echo "            audio:$converts"
  [ -n "$subs" ]     && echo "            subtitles -> sidecar:$(echo "$subs" | tr ' ' '\n' | cut -d: -f2,3 | tr '\n' ' ')"
  [ -n "$lost" ]     && echo "            bitmap subs stay in the original:$lost"

  if [ "$MODE" != apply ]; then ok=$((ok+1)); continue; fi

  # -map 0:v:0 takes the real video stream only; an embedded cover image is also
  # a video stream and would break the mp4.
  # -tag:v hvc1 is not optional: with the hev1 tag VideoToolbox refuses the file.
  # -movflags +faststart puts the index at the front, so seeking works from the
  # first byte instead of after the whole file has arrived.
  # shellcheck disable=SC2086
  if ! "$FF" -nostdin -v error -y -i "$src" \
        -map 0:v:0 -c:v copy -tag:v hvc1 \
        -map 0:a $aargs \
        -sn -map_metadata 0 -map_chapters 0 \
        -movflags +faststart \
        "$dst.partial" 2>/tmp/remux-err.txt; then
    echo "  FAILED  $(tail -2 /tmp/remux-err.txt | tr '\n' ' ')"
    rm -f "$dst.partial"; failed=$((failed+1)); continue
  fi

  # Verify before letting it replace anything: it must have a video stream and a
  # duration within a second of the source.
  sdur=$("$FP" -v error -show_entries format=duration -of csv=p=0 "$src" 2>/dev/null | cut -d. -f1)
  ddur=$("$FP" -v error -show_entries format=duration -of csv=p=0 "$dst.partial" 2>/dev/null | cut -d. -f1)
  dvid=$("$FP" -v error -select_streams v -show_entries stream=codec_name -of csv=p=0 "$dst.partial" 2>/dev/null | head -1)
  diff=$(( ${sdur:-0} - ${ddur:-0} )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
  if [ -z "$dvid" ] || [ "$diff" -gt 2 ]; then
    echo "  FAILED  verification (video='$dvid' source=${sdur:-?}s output=${ddur:-?}s)"
    rm -f "$dst.partial"; failed=$((failed+1)); continue
  fi

  # Sidecars come from the original, which still has every track.
  for spec in $subs; do
    idx=$(echo "$spec" | cut -d: -f1); fmt=$(echo "$spec" | cut -d: -f2); lang=$(echo "$spec" | cut -d: -f3)
    out="$base.$lang.$idx.$fmt"
    [ "$fmt" = srt ] && cargs="srt" || cargs="copy"
    "$FF" -nostdin -v error -y -i "$src" -map "0:s:$idx" -c:s "$cargs" "$out" 2>/dev/null \
      || echo "  (subtitle track $idx could not be extracted)"
  done

  # Swap last, and reversibly. Same filesystem, so both moves are atomic.
  mv "$src" "$src.original" && mv "$dst.partial" "$dst"
  echo "  OK      $dst"
  ok=$((ok+1))
done < /tmp/remux-list.txt

echo
echo "converted=$ok skipped=$skipped failed=$failed"
WORKER_EOF

ssh "$SSH_HOST" "docker exec $JF_CONTAINER sh /tmp/remux-worker.sh $MODE"

if [ "$MODE" = apply ]; then
  echo
  echo "Run a library scan in Jellyfin so it picks up the new files."
  echo "Originals are kept as *.original - revert with: $0 --revert"
fi
