using System;

namespace Jellyfin.Plugin.CascadeServer.Media;

/// <summary>
/// Checks that an upload's first bytes match the type the client declared, so a PNG sent as
/// <c>image/jpeg</c> or <c>video/mp4</c> is refused. Pure (no Jellyfin types) for the unit tests.
/// </summary>
public static class Sniff
{
    /// <summary>The declared type without parameters (<c>image/png; x=y</c> becomes <c>image/png</c>), lowercase.</summary>
    public static string BaseType(string? contentType)
        => (contentType ?? string.Empty).Split(';')[0].Trim().ToLowerInvariant();

    /// <summary>Whether <paramref name="head"/> (at least the first 12 bytes) is really the declared type.</summary>
    public static bool Matches(string mime, ReadOnlySpan<byte> head)
    {
        switch (mime)
        {
            case "image/jpeg":
                return head.Length >= 3 && head[0] == 0xFF && head[1] == 0xD8 && head[2] == 0xFF;
            case "image/png":
                return head.StartsWith(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });
            case "image/webp":
                return head.Length >= 12 && head[..4].SequenceEqual("RIFF"u8) && head.Slice(8, 4).SequenceEqual("WEBP"u8);
            case "video/mp4":
                return head.Length >= 8 && head.Slice(4, 4).SequenceEqual("ftyp"u8);
            case "video/webm":
                return head.Length >= 4 && head[0] == 0x1A && head[1] == 0x45 && head[2] == 0xDF && head[3] == 0xA3;
            default:
                return false;
        }
    }

    /// <summary>File extension for a type this class accepts, or null.</summary>
    public static string? Extension(string mime) => mime switch
    {
        "image/jpeg" => ".jpg",
        "image/png" => ".png",
        "image/webp" => ".webp",
        "video/mp4" => ".mp4",
        "video/webm" => ".webm",
        _ => null,
    };
}
