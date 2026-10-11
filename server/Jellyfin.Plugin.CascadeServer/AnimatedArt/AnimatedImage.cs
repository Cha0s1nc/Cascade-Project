using System;
using System.Text;

namespace Jellyfin.Plugin.CascadeServer.AnimatedArt;

/// <summary>
/// Animated images as video covers: an animated GIF, WebP or APNG beside an album, which the
/// server turns into an MP4 once (<see cref="ImageToVideo"/>). Pure, so the unit tests compile it.
/// </summary>
public static class AnimatedImage
{
    /// <summary>
    /// The names looked for in an album folder after the configured video names. A fixed list:
    /// the configurable names are videos served as they are.
    /// </summary>
    public static readonly string[] Names = ["cover.gif", "cover.webp", "cover.apng"];

    /// <summary>How much of the start of a file <see cref="IsAnimated"/> needs to see.</summary>
    public const int HeadBytes = 256 * 1024;

    /// <summary>
    /// Whether the start of an image file says it is animated: a GIF with the looping extension, a
    /// WebP whose VP8X header has the animation flag, or a PNG with an acTL chunk before its image
    /// data (APNG). A still image of any of these, which is common for cover.webp, is not.
    /// </summary>
    public static bool IsAnimated(ReadOnlySpan<byte> head)
    {
        if (head.StartsWith("GIF8"u8))
        {
            // ponytail: animated GIFs carry the NETSCAPE2.0 loop extension in practice; one without it plays once anyway.
            return head.IndexOf("NETSCAPE2.0"u8) >= 0 || head.IndexOf("ANIMEXTS1.0"u8) >= 0;
        }

        if (head.Length >= 21 && head.StartsWith("RIFF"u8) && head.Slice(8, 4).SequenceEqual("WEBP"u8))
        {
            return head.Slice(12, 4).SequenceEqual("VP8X"u8) && (head[20] & 0x02) != 0;
        }

        if (head.StartsWith(new byte[] { 0x89, (byte)'P', (byte)'N', (byte)'G', 0x0D, 0x0A, 0x1A, 0x0A }))
        {
            var actl = head.IndexOf("acTL"u8);
            var idat = head.IndexOf("IDAT"u8);
            return actl >= 0 && (idat < 0 || actl < idat);
        }

        return false;
    }

    /// <summary>Whether the file is a WebP, which Jellyfin's ffmpeg cannot decode when animated (Skia does instead).</summary>
    public static bool IsWebP(string path) => path.EndsWith(".webp", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// A frame's display time in milliseconds as browsers show it: 10 ms or less is drawn as 100,
    /// since many GIFs and WebPs were made with 0 and meant "default speed".
    /// </summary>
    public static int FrameMs(int ms) => ms <= 10 ? 100 : ms;

    /// <summary>
    /// The concat demuxer list for decoded frames: each file with its duration in seconds, and the
    /// last file repeated, since ffmpeg ignores the final entry's duration otherwise.
    /// </summary>
    public static string ConcatList(string[] files, int[] durationsMs)
    {
        var sb = new StringBuilder("ffconcat version 1.0\n");
        for (var i = 0; i < files.Length; i++)
        {
            sb.Append("file '").Append(files[i].Replace("'", "'\\''", StringComparison.Ordinal)).Append("'\n");
            sb.Append("duration ").Append((FrameMs(durationsMs[i]) / 1000.0).ToString("0.###", System.Globalization.CultureInfo.InvariantCulture)).Append('\n');
        }

        if (files.Length > 0) sb.Append("file '").Append(files[^1].Replace("'", "'\\''", StringComparison.Ordinal)).Append("'\n");
        return sb.ToString();
    }
}
