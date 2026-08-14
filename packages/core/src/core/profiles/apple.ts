// Device profile for iOS/tvOS via react-native-video, which plays through
// AVPlayer under the hood.
//
// Unlike electron.ts, this is not built from a runtime probe - there is no
// canPlayType() equivalent exposed to JS here, and PLATFORM-NOTES.md is explicit
// that a guessed profile is worse than none: the server trusts DirectPlayProfiles
// and hands back a stream the device cannot decode, which is silent playback,
// not an error. So this profile only claims what AVPlayer is documented to
// decode on every iOS/tvOS version this app supports, and nothing conditional.

import type { DeviceProfile } from '../playback.ts'

// AVPlayer's audio floor. Every one of these is a codec Apple's own docs list
// as supported, not something inferred from Chromium or from Roku's device.
//
// Deliberately absent, with a reason for each:
//   - Opus: PLATFORM-NOTES says so outright. AVPlayer has no Opus decoder;
//     claiming it direct-plays a file that never makes sound.
//   - Vorbis: same story, no AVPlayer decoder.
//   - AAC, MP3, ALAC, WAV: all documented AVPlayer-native formats, safe to
//     direct play without a device in hand to verify - unlike Opus/Vorbis
//     support, which genuinely varies, "does AVPlayer decode AAC" does not.
//
// FLAC is claimed too, despite PLATFORM-NOTES calling ALAC "the safer native
// choice" - that line is a preference between two supported codecs, not a
// warning that FLAC is unsupported. The note says outright a few lines later:
// "FLAC is supported on iOS/tvOS 11+", and this app's tvOS deployment target
// is 15.1. This is not a guess: a survey of the actual Jellyfin server this
// port targets found 1087 of 1087 music tracks are FLAC. Leaving it off this
// list would transcode the entire library on every play - the exact failure
// mode B1 spent a night fixing on desktop, just moved to a new platform.
// WAV is a separate entry below rather than folded into these two lists: its
// codec is PCM under one of several tag spellings Jellyfin reports
// (pcm_s16le and friends), and guessing which one is exactly the kind of
// guess PLATFORM-NOTES warns against. Leaving AudioCodec off the WAV entry
// instead means "any codec in this container", which for a WAV file is PCM
// anyway - the same "container implies codec" trust electron.ts places in
// its own AudioCodec-less audio DirectPlayProfile entry.
const CODEC_CHECKED_CONTAINERS = 'aac,mp3,alac,m4a,flac'
const CODEC_CHECKED_AUDIO_CODECS = 'aac,mp3,alac,flac'

/**
 * The profile for Apple platforms (iOS, tvOS, visionOS) via react-native-video.
 *
 * MaxStreamingBitrate is well under Electron's 140 Mbps default - these are
 * phones and set-top boxes on Wi-Fi or cellular, not a desktop on ethernet, and
 * PLATFORM-NOTES.md calls the desktop number "meaningless" off a wired link.
 */
export const APPLE_PROFILE: DeviceProfile = {
  Name: 'Cascade Apple',
  MaxStreamingBitrate: 20_000_000,

  DirectPlayProfiles: [
    // AudioCodec is spelled out explicitly, not left to the container list to
    // imply, so the post-check in playback.ts (resolveStream's audio-codec
    // verification) has something concrete to check FLAC/AAC/MP3/ALAC
    // against, rather than trusting container-implies-codec the way the WAV
    // entry below does.
    { Type: 'Audio', Container: CODEC_CHECKED_CONTAINERS, AudioCodec: CODEC_CHECKED_AUDIO_CODECS },
    { Type: 'Audio', Container: 'wav' },
  ],

  // HLS/AAC: the format PLATFORM-NOTES.md calls out as what tvOS/AVPlayer
  // prefers, and it happens to match Electron's fallback too.
  TranscodingProfiles: [
    {
      Type: 'Audio',
      Container: 'ts',
      AudioCodec: 'aac',
      Protocol: 'hls',
      Context: 'Streaming',
      MaxAudioChannels: '2',
    },
  ],

  ContainerProfiles: [],
  CodecProfiles: [],

  // No subtitle support yet - Phase 4a is audio only. Video/subtitle profiles
  // for tvOS arrive with a video port, not before.
  SubtitleProfiles: [],
}
