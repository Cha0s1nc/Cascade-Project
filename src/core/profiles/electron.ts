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

export const ELECTRON_PROFILE: DeviceProfile = {
  Name: 'Cascade Desktop',
  MaxStreamingBitrate: 140_000_000,

  DirectPlayProfiles: [
    { Type: 'Audio', Container: DIRECT_PLAY_CONTAINERS },
  ],

  // Fallback when the server decides it must transcode. HLS/AAC matches what
  // the previous URL asked for.
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
  SubtitleProfiles: [],
}
