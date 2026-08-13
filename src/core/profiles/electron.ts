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
//   - MPEG-2, VC-1: no.
//   - DTS, TrueHD: no.
//
// mkv stays, and it is the one entry here that canPlayType() disagrees with.
//
// `canPlayType('video/x-matroska')` returns '' in this Electron build, and
// dropping mkv on the strength of that was a mistake worth recording: Chromium
// demuxes Matroska through its bundled FFmpeg regardless of what the MIME probe
// admits to. Measured against a real 1080p mkv on the server - readyState 3,
// duration 6112.732, 1920x800, no error.
//
// Removing it cost a great deal. Every mkv - most of a ripped library - became
// ContainerNotSupported, so the server remuxed files it had been sending
// untouched, and a remux is a progressive stream the player cannot seek inside.
// Direct play is what makes scrubbing instant, so a container claim being
// wrong in the *cautious* direction still broke a feature.
//
// The lesson is not "trust canPlayType" or "ignore it" - it is that a container
// and a codec fail differently. A codec Chromium cannot decode gives a black
// screen; a container it does not advertise may still play. So codecs get
// probed (below), and containers get verified by hand.
//
// HEVC and AC3/E-AC3 are absent here because they are conditional, not refused.
// See buildElectronProfile().
const VIDEO_CONTAINERS = 'mp4,webm,mkv'
const VIDEO_CODECS = 'h264,vp8,vp9,av1'
const VIDEO_AUDIO_CODECS = 'aac,mp3,opus,flac,vorbis'

/**
 * Tests whether the host can actually play a MIME/codec string.
 *
 * Injected rather than called directly so this module stays free of the DOM -
 * the host passes its own probe, and the tests pass a fake one.
 */
export type CodecProbe = (mimeType: string) => boolean

/**
 * Codec strings worth asking about, and what claiming them buys.
 *
 * Only codecs that are *conditionally* available belong here. Something the
 * platform either always has or never has should be in the constants above,
 * where it costs no probe.
 */
const PROBES = {
  // Chromium plays HEVC only where the OS provides a decoder - VideoToolbox on
  // macOS, and hardware support on Windows. Both are exactly the cases where
  // direct play is free and a server-side transcode is most wasteful, which is
  // why guessing was never good enough.
  hevc: ['video/mp4; codecs="hvc1.1.6.L93.B0"', 'video/mp4; codecs="hev1.1.6.L93.B0"'],
  // Licensed codecs. Absent from most Chromium builds, present in some. When a
  // file direct-plays except for its audio track, this is usually why.
  ac3:  ['audio/mp4; codecs="ac-3"'],
  eac3: ['audio/mp4; codecs="ec-3"'],
}

/** Comma-joins the truthy parts, so an unsupported codec leaves no stray comma. */
const join = (...parts: (string | false | undefined)[]) => parts.filter(Boolean).join(',')

/**
 * Build the profile for a host whose codec support has been measured.
 *
 * PLATFORM-NOTES.md says a guessed profile is worse than no profile, because
 * the server believes it and hands back a stream the client cannot decode. The
 * answer to that is not to keep guessing conservatively forever - it is to ask.
 * `canPlay` is the asking.
 *
 * Widening the profile is what stops a transcode happening at all, which beats
 * making the transcode faster: no encode, no wait, and seeking a direct-played
 * file is instant rather than a round trip.
 */
export function buildElectronProfile(canPlay: CodecProbe): DeviceProfile {
  // `some`, not `every`: hvc1 and hev1 are two spellings of the same support,
  // and a build that admits to either can decode the stream.
  const hevc = PROBES.hevc.some(canPlay)
  const ac3  = PROBES.ac3.some(canPlay)
  const eac3 = PROBES.eac3.some(canPlay)

  return {
    ...ELECTRON_PROFILE,
    DirectPlayProfiles: [
      { Type: 'Audio', Container: DIRECT_PLAY_CONTAINERS },
      {
        Type: 'Video',
        Container: VIDEO_CONTAINERS,
        VideoCodec: join(VIDEO_CODECS, hevc && 'hevc'),
        AudioCodec: join(VIDEO_AUDIO_CODECS, ac3 && 'ac3', eac3 && 'eac3'),
      },
    ],
  }
}

/**
 * The profile for a host that has told us nothing.
 *
 * Everything Chromium decodes unconditionally, and not one codec more. This is
 * the floor buildElectronProfile() widens from, and what ships if the probe is
 * ever unavailable - degrading to "transcode it" rather than to a black screen.
 */
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
    // player library, and this app has two runtime deps total.
    //
    // The predicted ceiling arrived: a progressive body only exposes the part
    // the server has already encoded, so the scrubber could neither show the
    // real duration nor seek past it. Fixed without hls.js by requesting a new
    // stream at an offset instead - see withStartTicks() in playback.ts. What
    // remains is that a seek costs a request, so it lands in about a second
    // rather than instantly. Revisit hls.js only if that latency is the
    // complaint.
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
