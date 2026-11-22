using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Jellyfin.Plugin.CascadeServer.LyricFetch;

/// <summary>
/// The pure parts of talking to SpicyLyrics: which ids it takes, how to ask its search, and
/// how to read the answer. Kept apart from <see cref="SpicyLyricsClient"/> so it can be tested
/// without Jellyfin or a logger.
///
/// Spec: https://api.spicylyrics.org/v1/openapi.json (v1.1.0, checked 2026-11-21).
/// </summary>
public static partial class SpicyIds
{
    /// <summary>Longest a text field sent to search may be, as the spec allows.</summary>
    private const int MaxFieldLength = 200;

    /// <summary>
    /// Gets a value indicating whether <paramref name="id"/> is a Spotify track id (22 base62
    /// characters). Still the only shape stored or used as a cache file name automatically, so
    /// third-party values (an id in a search result, <c>Body.id</c>) are checked with this.
    /// </summary>
    public static bool IsValidTrackId(string? id) => id is not null && TrackIdRegex().IsMatch(id);

    /// <summary>
    /// Any id the lyrics route takes, normalized, or <c>null</c>: a Spotify track id, an ISRC
    /// (hyphens out, uppercased, as tags and people write them), or an Apple Music track id.
    /// The three shapes cannot collide, so nothing has to say which kind it is: 22 base62 is
    /// checked first because an Apple id stops at 20 digits.
    ///
    /// This is the trust boundary for a hand link: the result becomes a cache file name, so
    /// normalization happens here, before the check, never after.
    /// </summary>
    public static string? NormalizeLookupId(string? id)
    {
        var s = id?.Trim();
        if (string.IsNullOrEmpty(s)) return null;
        if (TrackIdRegex().IsMatch(s)) return s;              // Spotify
        if (AppleIdRegex().IsMatch(s)) return s;              // Apple Music
        return NormalizeIsrc(s);
    }

    /// <summary>
    /// An ISRC, normalized, or <c>null</c>. Strict: used for the ISRC read off a file's tags,
    /// where the union check would send an all-digit junk tag out as an Apple Music id.
    /// </summary>
    public static string? NormalizeIsrc(string? isrc)
    {
        if (isrc is null) return null;
        var s = IsrcNoiseRegex().Replace(isrc, string.Empty).ToUpperInvariant();
        return IsrcRegex().IsMatch(s) ? s : null;
    }

    /// <summary>
    /// The query for a search. <c>artist</c> and <c>album</c> are left out when empty, since
    /// the spec gives them a minimum length of one and refuses a blank with a 400, and the
    /// duration is formatted invariantly so a comma-decimal host does not send "238,64".
    /// Never <c>q</c> as well as <c>title</c>, which the spec refuses.
    /// </summary>
    public static string SearchQuery(string title, string artist, string album, double? durationSec)
    {
        var q = $"title={Uri.EscapeDataString(Clamp(title))}";
        if (!string.IsNullOrWhiteSpace(artist)) q += $"&artist={Uri.EscapeDataString(Clamp(artist))}";
        if (!string.IsNullOrWhiteSpace(album)) q += $"&album={Uri.EscapeDataString(Clamp(album))}";
        if (durationSec is > 0 and <= 86400)
        {
            q += $"&duration={durationSec.Value.ToString("0.###", CultureInfo.InvariantCulture)}";
        }

        return q;

        static string Clamp(string s)
        {
            s = s.Trim();
            return s.Length > MaxFieldLength ? s[..MaxFieldLength] : s;
        }
    }

    /// <summary>
    /// The Spotify ids of the first <c>exact</c> result and that recording's other releases,
    /// closest to <paramref name="durationSec"/> first, so the caller tries the release whose
    /// length matches the file before the rest.
    ///
    /// Only <c>exact</c> is taken, as the spec says an automated fetcher should: a
    /// <c>version</c>, <c>other_artist</c> or <c>related</c> match is a live cut, a remix or a
    /// cover, whose timings do not fit. Every id is checked against
    /// <see cref="IsValidTrackId"/>, because these came from a third party and become cache
    /// file names.
    /// </summary>
    public static IReadOnlyList<string> ExactIds(JsonElement root, double? durationSec)
    {
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty("Body", out var body) || body.ValueKind != JsonValueKind.Object
            || !body.TryGetProperty("results", out var results) || results.ValueKind != JsonValueKind.Array)
        {
            return [];
        }

        foreach (var result in results.EnumerateArray())
        {
            if (result.ValueKind != JsonValueKind.Object) continue;
            if (!result.TryGetProperty("tier", out var tier) || tier.ValueKind != JsonValueKind.String
                || tier.GetString() != "exact")
            {
                continue;
            }

            var found = new List<(string Id, double? Duration)>();
            Add(result);
            if (result.TryGetProperty("variants", out var variants) && variants.ValueKind == JsonValueKind.Array)
            {
                foreach (var variant in variants.EnumerateArray()) Add(variant);
            }

            // With no length to compare against, their order stands: the result's own release
            // first, as the album asked for picks it, then the rest as they came. A release
            // whose length they did not give sorts last rather than being dropped.
            var ordered = durationSec is > 0
                ? found.OrderBy(f => f.Duration is { } d ? Math.Abs(d - durationSec.Value) : double.MaxValue)
                : found.AsEnumerable();
            return [.. ordered.Select(f => f.Id).Distinct()];

            void Add(JsonElement e)
            {
                if (e.ValueKind != JsonValueKind.Object) return;
                var id = e.TryGetProperty("id", out var i) && i.ValueKind == JsonValueKind.String ? i.GetString() : null;
                if (!IsValidTrackId(id)) return;
                var seconds = e.TryGetProperty("duration", out var d) && d.ValueKind == JsonValueKind.Number
                    ? d.GetDouble() : (double?)null;
                found.Add((id!, seconds));
            }
        }

        return [];
    }

    /// <summary>The Spotify track id a lyrics response carries, or <c>null</c> when unusable.</summary>
    public static string? SpotifyIdOf(string rawJson)
    {
        try
        {
            using var doc = JsonDocument.Parse(rawJson);
            var body = doc.RootElement.ValueKind == JsonValueKind.Object
                && doc.RootElement.TryGetProperty("Body", out var b) && b.ValueKind == JsonValueKind.Object
                ? b : doc.RootElement;
            if (body.ValueKind != JsonValueKind.Object) return null;
            var id = body.TryGetProperty("id", out var i) && i.ValueKind == JsonValueKind.String ? i.GetString() : null;
            return IsValidTrackId(id) ? id : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>Their machine-readable code from an error body, or <c>null</c>.</summary>
    public static string? ErrorCode(string raw)
    {
        try
        {
            using var doc = JsonDocument.Parse(raw);
            return doc.RootElement.ValueKind == JsonValueKind.Object
                && doc.RootElement.TryGetProperty("Body", out var body) && body.ValueKind == JsonValueKind.Object
                && body.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.String
                ? error.GetString()
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    [GeneratedRegex("^[A-Za-z0-9]{22}$")]
    private static partial Regex TrackIdRegex();

    [GeneratedRegex("^[0-9]{1,20}$")]
    private static partial Regex AppleIdRegex();

    [GeneratedRegex("^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$")]
    private static partial Regex IsrcRegex();

    [GeneratedRegex(@"[\s-]")]
    private static partial Regex IsrcNoiseRegex();
}
