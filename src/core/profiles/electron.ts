// Device profile for the Electron/Chromium renderer.
//
// A DeviceProfile tells Jellyfin what this client can decode, so the server can
// pick direct play over transcoding. Chromium decodes nearly everything, which
// is why the old hardcoded stream URL worked - but that is a property of THIS
// platform, not of Cascade. See PLATFORM-NOTES.md before writing a TV profile.

import type { DeviceProfile } from '../playback.ts'

/** Matches the container list the old hardcoded /universal URL requested, so
 *  switching to PlaybackInfo does not silently change which files direct-play. */
const DIRECT_PLAY_CONTAINERS = 'opus,mp3,aac,flac,wav,ogg,webm'

// Video containers and codecs Chromium decodes without help.
//
// What is deliberately NOT here is the important half - claiming a codec we
// cannot decode gets us a direct-play URL and a black screen, which is worse
// than transcoding:
//   - HEVC/H.265: only with a system decoder, and we cannot detect that from
//     here. Let the server transcode it.
//   - AC3 / E-AC3 / DTS / TrueHD: Chromium has no decoder. This is why a file
//     that "should" direct play still transcodes - it is the audio track.
//   - MPEG-2, VC-1: no.
const VIDEO_CONTAINERS = 'mp4,webm,mkv'
const VIDEO_CODECS = 'h264,vp8,vp9,av1'
const VIDEO_AUDIO_CODECS = 'aac,mp3,opus,flac,vorbis'

export const ELECTRON_PROFILE: DeviceProfile = {
  Name: 'Cascade Desktop',
  MaxStreamingBitrate: 140_000_000,

  DirectPlayProfiles: [
    { Type: 'Audio', Container: DIRECT_PLAY_CONTAINERS },
    {
      Type: 'Video',
      Container: VIDEO_CONTAINERS,
      VideoCodec: VIDEO_CODECS,
      AudioCodec: VIDEO_AUDIO_CODECS,
    },
  ],

  // Fallback when the server decides it must transcode. HLS/AAC matches what
  // the previous URL asked for.
  //
  // Audio stays first: test/playback.test.ts asserts on index 0, and more to
  // the point, reordering would silently change what music direct-plays.
  TranscodingProfiles: [
    {
      Type: 'Audio',
      Container: 'ts',
      AudioCodec: 'aac',
      Protocol: 'hls',
      Context: 'Streaming',
      MaxAudioChannels: '2',
    },
    // ponytail: progressive http, not hls - Chromium plays an mp4 URL with no
    // player library, and this app has two runtime deps total. The ceiling is
    // seeking: a seek mid-transcode makes the server restart the encode, so
    // scrubbing a transcoded file is slow. Add hls.js if that becomes the
    // complaint - resolveStream() is the only thing that would need to change.
    {
      Type: 'Video',
      Container: 'mp4',
      VideoCodec: 'h264',
      AudioCodec: 'aac',
      Protocol: 'http',
      Context: 'Streaming',
      MaxAudioChannels: '2',
    },
  ],

  ContainerProfiles: [],
  CodecProfiles: [],

  // Text subtitles are rendered by a native <track>, so the server can hand
  // them over as-is. Image subtitles (PGS, VOBSUB) are absent on purpose:
  // nothing here can draw them, so the server must burn them into the video.
  SubtitleProfiles: [
    { Format: 'vtt', Method: 'External' },
    { Format: 'srt', Method: 'External' },
    { Format: 'subrip', Method: 'External' },
    { Format: 'ass', Method: 'External' },
    { Format: 'ssa', Method: 'External' },
  ],
}
