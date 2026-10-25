using System;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Jellyfin.Plugin.CascadeServer.AnimatedArt;

/// <summary>
/// The pure parts of animated album art: reading TIDAL's JSON:API responses, picking a size,
/// cache lifetimes and file types. No Jellyfin types, so the unit tests compile it.
/// </summary>
public static partial class TidalParse
{
    /// <summary>TIDAL allows temporary caching only; entries older than this are dropped and looked up again.</summary>
    public static readonly TimeSpan CacheTtl = TimeSpan.FromDays(25);

    /// <summary>How long an album TIDAL has no video for is remembered. About 92% of albums have none.</summary>
    public static readonly TimeSpan MissTtl = TimeSpan.FromDays(7);

    /// <summary>TIDAL's ready-made square sizes.</summary>
    public static readonly int[] Sizes = [320, 640, 750, 1080, 1280];

    /// <summary>A video cover TIDAL offers: which artwork, how wide, where.</summary>
    public record Video(string ArtworkId, int Width, string Href);

    /// <summary>Whether something fetched at <paramref name="fetchedUtc"/> is still inside <paramref name="ttl"/>.</summary>
    public static bool Fresh(DateTime fetchedUtc, TimeSpan ttl, DateTime nowUtc) => nowUtc - fetchedUtc < ttl;

    /// <summary>A UPC or EAN: 12 to 14 digits, once spaces and dashes are removed. Null when it is not one.</summary>
    public static string? Barcode(string? raw)
    {
        var digits = DigitsOnly().Replace(raw ?? string.Empty, string.Empty);
        return digits.Length is >= 12 and <= 14 && (raw ?? string.Empty).All(c => char.IsDigit(c) || c is ' ' or '-') ? digits : null;
    }

    /// <summary>The video file type for a path or URL, from its extension; null for anything else.</summary>
    public static string? VideoContentType(string pathOrUrl)
    {
        var clean = pathOrUrl.Split('?')[0];
        if (clean.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase)) return "video/mp4";
        if (clean.EndsWith(".webm", StringComparison.OrdinalIgnoreCase)) return "video/webm";
        return null;
    }

    /// <summary>
    /// The album's video cover from an albums response fetched with <c>include=coverArt</c>: the
    /// artwork whose <c>attributes.mediaType</c> is VIDEO, and from its files the one whose
    /// <c>meta.width</c> is <paramref name="size"/> (the nearest width when that size is missing).
    /// Null when the album has none, which is the answer for most albums.
    /// </summary>
    public static Video? PickVideo(JsonElement root, int size)
    {
        if (!root.TryGetProperty("included", out var included) || included.ValueKind != JsonValueKind.Array) return null;

        // The album's own coverArt relationship narrows the artworks; without one, any included video will do.
        var own = new System.Collections.Generic.HashSet<string>();
        if (root.TryGetProperty("data", out var data))
        {
            var first = data.ValueKind == JsonValueKind.Array ? (data.GetArrayLength() > 0 ? data[0] : default) : data;
            if (first.ValueKind == JsonValueKind.Object
                && first.TryGetProperty("relationships", out var rel) && rel.TryGetProperty("coverArt", out var cover)
                && cover.TryGetProperty("data", out var refs) && refs.ValueKind == JsonValueKind.Array)
            {
                foreach (var r in refs.EnumerateArray())
                {
                    if (r.TryGetProperty("id", out var id) && id.GetString() is { } s) own.Add(s);
                }
            }
        }

        foreach (var art in included.EnumerateArray())
        {
            if (!art.TryGetProperty("type", out var type) || type.GetString() != "artworks") continue;
            var artId = art.TryGetProperty("id", out var idEl) ? idEl.GetString() : null;
            if (artId is null || (own.Count > 0 && !own.Contains(artId))) continue;
            if (!art.TryGetProperty("attributes", out var attrs)
                || !attrs.TryGetProperty("mediaType", out var mt) || mt.GetString() != "VIDEO"
                || !attrs.TryGetProperty("files", out var files) || files.ValueKind != JsonValueKind.Array) continue;

            Video? best = null;
            foreach (var f in files.EnumerateArray())
            {
                if (!f.TryGetProperty("href", out var href) || href.GetString() is not { Length: > 0 } url) continue;
                if (!f.TryGetProperty("meta", out var meta) || !meta.TryGetProperty("width", out var w) || !w.TryGetInt32(out var width)) continue;
                if (best is null || Math.Abs(width - size) < Math.Abs(best.Width - size)) best = new Video(artId, width, url);
            }

            if (best is not null) return best;
        }

        return null;
    }

    /// <summary>The first album's id, title and track count from an albums or tracks (with <c>include=albums</c>) response.</summary>
    public static (string Id, string? Title, int? NumberOfItems)[] Albums(JsonElement root)
    {
        // For an albums response the albums are in data; for tracks they are in included.
        var list = new System.Collections.Generic.List<(string, string?, int?)>();
        void Add(JsonElement e)
        {
            if (e.ValueKind != JsonValueKind.Object || !e.TryGetProperty("type", out var t) || t.GetString() != "albums") return;
            if (!e.TryGetProperty("id", out var id) || id.GetString() is not { } sid) return;
            string? title = null;
            int? count = null;
            if (e.TryGetProperty("attributes", out var a))
            {
                if (a.TryGetProperty("title", out var ti)) title = ti.GetString();
                if (a.TryGetProperty("numberOfItems", out var n) && n.TryGetInt32(out var c)) count = c;
            }

            list.Add((sid, title, count));
        }

        if (root.TryGetProperty("data", out var data))
        {
            if (data.ValueKind == JsonValueKind.Array) foreach (var d in data.EnumerateArray()) Add(d);
            else Add(data);
        }

        if (root.TryGetProperty("included", out var inc) && inc.ValueKind == JsonValueKind.Array)
        {
            foreach (var d in inc.EnumerateArray()) Add(d);
        }

        return [.. list.Select(x => (x.Item1, x.Item2, x.Item3))];
    }

    [GeneratedRegex(@"\D")]
    private static partial Regex DigitsOnly();
}
