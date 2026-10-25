using System;
using System.Collections.Generic;
using System.Linq;

namespace Jellyfin.Plugin.CascadeServer.Explicit;

/// <summary>
/// The pure rules of explicit marking: reading tag values, reading what Deezer and iTunes
/// say, and choosing among search results. No Jellyfin types, so the unit tests compile it.
/// </summary>
public static class ExplicitRules
{
    /// <summary>Marked explicit.</summary>
    public const string Explicit = "explicit";

    /// <summary>A marked clean or edited version, not merely "not known to be explicit".</summary>
    public const string Clean = "clean";

    /// <summary>Known not to be explicit. Answers as unknown in the Query route.</summary>
    public const string NotExplicit = "notexplicit";

    /// <summary>One search result: who, what, how long, and what the service says about it.</summary>
    public record Candidate(string? Artist, string? Title, double? Seconds, string? Rating);

    /// <summary>
    /// A tag value to a rating: <c>1</c> or <c>4</c> is explicit, <c>2</c> is clean, <c>0</c>,
    /// absent or anything unrecognized is unknown. "true" and "yes" count as explicit, for an
    /// <c>EXPLICIT</c> comment written by taggers that use words.
    /// </summary>
    public static string? ParseTag(string? value)
    {
        var v = (value ?? string.Empty).Trim();
        if (v.Length == 0) return null;
        if (v is "1" or "4") return Explicit;
        if (v == "2") return Clean;
        if (v.Equals("true", StringComparison.OrdinalIgnoreCase) || v.Equals("yes", StringComparison.OrdinalIgnoreCase)) return Explicit;
        return null;
    }

    /// <summary>
    /// Deezer's <c>explicit_content_lyrics</c>: 1 and 5 explicit, 3 and 4 edited or clean, 0 and 6
    /// not explicit, 2 unknown. Confirmed live: HUMBLE. is 1, a track with no advice data is 2
    /// (with <c>explicit_lyrics</c> false), a plainly clean one is 0.
    /// </summary>
    public static string? FromDeezer(int? contentLyrics) => contentLyrics switch
    {
        1 or 5 => Explicit,
        3 or 4 => Clean,
        0 or 6 => NotExplicit,
        _ => null,
    };

    /// <summary>iTunes' <c>trackExplicitness</c>: explicit, cleaned, notExplicit.</summary>
    public static string? FromItunes(string? trackExplicitness) => trackExplicitness switch
    {
        "explicit" => Explicit,
        "cleaned" => Clean,
        "notExplicit" => NotExplicit,
        _ => null,
    };

    /// <summary>
    /// The rating of the confident match among <paramref name="candidates"/>, or null. When
    /// matching results disagree (an explicit and a cleaned edition of one song), the closest
    /// in length decides, and a tie there is unknown rather than a guess.
    /// </summary>
    public static string? Pick(string[] localArtists, string localTitle, double? localSeconds, IEnumerable<Candidate> candidates)
    {
        var matches = candidates
            .Where(c => c.Rating is not null && TitleMatch.IsMatch(localArtists, localTitle, localSeconds, c.Artist, c.Title, c.Seconds))
            .ToList();
        if (matches.Count == 0) return null;
        if (matches.Select(m => m.Rating).Distinct().Count() == 1) return matches[0].Rating;

        var closest = matches.Min(m => Math.Abs(m.Seconds!.Value - localSeconds!.Value));
        var nearest = matches.Where(m => Math.Abs(m.Seconds!.Value - localSeconds!.Value) - closest < 0.5).Select(m => m.Rating).Distinct().ToList();
        return nearest.Count == 1 ? nearest[0] : null;
    }
}
