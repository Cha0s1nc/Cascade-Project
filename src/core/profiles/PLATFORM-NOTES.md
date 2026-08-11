# Device profiles for non-Electron platforms

Notes, not code. Written down while extracting `streamUrl` into `playback.ts`,
because the reason that extraction mattered is easy to forget later.

**Do not turn these into shipped `.ts` profiles until a port actually starts.**
Codec support on TV platforms varies by model year and firmware, so anything
written here without a device in hand is a guess. Guessed profiles are worse
than no profile: the server trusts them and hands back a stream the device
cannot decode, which presents as silent playback rather than an error.

## Why this file exists

Before B1, Cascade built one hardcoded stream URL:

```
/Audio/{id}/universal?Container=opus,mp3,aac,flac,wav,ogg
  &TranscodingContainer=ts&TranscodingProtocol=hls
  &AudioCodec=aac&MaxStreamingBitrate=140000000
```

That container list is **Chromium's** capability set. It worked because Electron
decodes nearly everything. Moving it unchanged into shared core would have made
it the default for every future client — the specific bug this phase exists to
prevent.

## tvOS (AVPlayer, via react-native-tvos)

- **No Opus.** No Vorbis. Do not put either in DirectPlayProfiles.
- FLAC is supported on iOS/tvOS 11+, but ALAC is the safer native choice.
- Prefers HLS. Transcoding profile should be `hls` / `aac`, which happens to
  match the desktop fallback.
- AAC, MP3, ALAC, WAV are all safe for direct play.

## webOS (LG) and Tizen (Samsung)

- AAC and MP3 are reliable across model years.
- **FLAC support varies by year and panel.** Verify per target device rather
  than assuming.
- **Opus is limited**, especially on older firmware.
- Both run a Chromium-derived browser, but a much older one than Electron ships,
  so the desktop profile is not a safe substitute.

## When writing a real profile

1. Start narrow — AAC and MP3 direct play, everything else transcoded.
2. Widen only after confirming a container actually plays on the device.
3. `MaxStreamingBitrate` should be lower than desktop; TVs are usually on Wi-Fi
   and the default 140 Mbps is meaningless there.
