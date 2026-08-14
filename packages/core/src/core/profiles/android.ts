// Device profile for Android via react-native-video, which plays through
// ExoPlayer under the hood.
//
// Same caution as apple.ts: no runtime probe is available here, so this only
// claims codecs ExoPlayer is documented to decode unconditionally, per
// PLATFORM-NOTES.md's rule that a guessed profile is worse than none.

import type { DeviceProfile } from '../playback.ts'

// ExoPlayer's audio floor is AAC and MP3, same as any platform - and on top
// of that it ships software decoders for Opus, Vorbis and FLAC that Apple's
// stack does not have, so unlike apple.ts there is no PLATFORM-NOTES
// prohibition to work around for those three.
//
// ALAC is deliberately NOT carried over from apple.ts. It is Apple's own
// codec, and unlike AAC/MP3/Opus/Vorbis/FLAC it is not one of ExoPlayer's
// documented built-in formats - decoding it on Android needs the separate
// FFmpeg extension, which this app does not ship. Claiming it here would be
// exactly the guess PLATFORM-NOTES warns against: nothing to cite, so nothing
// claimed. The real library is FLAC anyway, so this costs nothing in practice.
//
// AudioCodec is spelled out for the same reason as apple.ts: so the post-check
// in playback.ts has something concrete to verify a direct-play source's
// actual audio codec against, rather than trusting container-implies-codec.
//
// WAV is a separate, codec-unrestricted entry below - same reasoning as
// apple.ts: its codec is PCM under one of several tag spellings, and
// guessing which one is the guess PLATFORM-NOTES warns against.
const CODEC_CHECKED_CONTAINERS = 'aac,mp3,m4a,flac,ogg,opus'
const CODEC_CHECKED_AUDIO_CODECS = 'aac,mp3,flac,vorbis,opus'

/**
 * The profile for Android via react-native-video.
 *
 * MaxStreamingBitrate matches apple.ts - phones and Android TV boxes are on
 * Wi-Fi or cellular, not Electron's assumed wired desktop link.
 */
export const ANDROID_PROFILE: DeviceProfile = {
  Name: 'Cascade Android',
  MaxStreamingBitrate: 20_000_000,

  DirectPlayProfiles: [
    { Type: 'Audio', Container: CODEC_CHECKED_CONTAINERS, AudioCodec: CODEC_CHECKED_AUDIO_CODECS },
    { Type: 'Audio', Container: 'wav' },
  ],

  // Same HLS/AAC fallback as apple.ts - ExoPlayer plays it natively too, and
  // there is no reason for the two mobile platforms to disagree about what
  // the server should transcode to.
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

  // No subtitle support yet - Phase 4a is audio only, same as apple.ts.
  SubtitleProfiles: [],
}
