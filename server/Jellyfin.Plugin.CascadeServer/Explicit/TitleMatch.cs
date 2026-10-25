using System;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace Jellyfin.Plugin.CascadeServer.Explicit;

/// <summary>
/// Decides whether a search result is the same recording as a library song. Ported from
/// <c>src/core/itunes-art.ts</c> in Cascade-Project, which exists because taking the first
/// search result picked karaoke and tribute versions. Pure (no Jellyfin types) for the unit tests.
/// </summary>
public static partial class TitleMatch
{
    /// <summary>How far apart two durations may be and still be one recording.</summary>
    public const double MaxDurationDiffSeconds = 3;

    /// <summary>Lowercase, unaccented, words only. "DAMN." and "Damn" are the same.</summary>
    public static string Clean(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return string.Empty;
        var sb = new StringBuilder();
        foreach (var ch in s.Normalize(NormalizationForm.FormD))
        {
            if (CharUnicodeInfo.GetUnicodeCategory(ch) == UnicodeCategory.NonSpacingMark) continue;
            sb.Append(char.IsLetterOrDigit(ch) ? char.ToLowerInvariant(ch) : ' ');
        }

        // Unlike the TypeScript original this keeps non-Latin letters, so a Japanese title
        // still compares as itself instead of reducing to nothing and matching anything.
        return string.Join(' ', sb.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }

    /// <summary><see cref="Clean"/> without bracketed edition words ("(Remastered)") and a trailing "- Single" or "- EP".</summary>
    public static string Base(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return string.Empty;
        var noBrackets = BracketRegex().Replace(s, " ");
        return Clean(SingleEpRegex().Replace(noBrackets, string.Empty));
    }

    /// <summary>The first-named artist of "A feat. B", "A &amp; B", "A, B", "A x B".</summary>
    public static string PrimaryArtist(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return string.Empty;
        return Base(ArtistSplitRegex().Split(s)[0]);
    }

    /// <summary>
    /// Whether a result is a karaoke, tribute or instrumental release of something the library
    /// song is not. A result is refused on these words unless the library song has them too.
    /// </summary>
    public static bool LooksDerived(string? resultTitle, string? resultArtist, string? localTitle, string? localArtist)
    {
        bool Has(string? a, string? b) => DerivedRegex().IsMatch(a ?? string.Empty) || DerivedRegex().IsMatch(b ?? string.Empty);
        return Has(resultTitle, resultArtist) && !Has(localTitle, localArtist);
    }

    /// <summary>
    /// The match rule: the title agrees after <see cref="Base"/>, an artist agrees, the result is
    /// not a derived release, and the durations are within <see cref="MaxDurationDiffSeconds"/>.
    /// Both durations must be known: no confident match means unknown, never clean.
    /// </summary>
    public static bool IsMatch(
        string[] localArtists, string localTitle, double? localSeconds,
        string? resultArtist, string? resultTitle, double? resultSeconds)
    {
        if (localSeconds is null || resultSeconds is null) return false;
        if (Math.Abs(localSeconds.Value - resultSeconds.Value) > MaxDurationDiffSeconds) return false;

        var title = Base(localTitle);
        if (title.Length == 0 || title != Base(resultTitle)) return false;
        if (LooksDerived(resultTitle, resultArtist, localTitle, string.Join(' ', localArtists))) return false;

        var wantArtist = PrimaryArtist(resultArtist);
        if (wantArtist.Length == 0) return false;
        return localArtists.Any(a => PrimaryArtist(a) == wantArtist || Base(a) == Base(resultArtist));
    }

    [GeneratedRegex(@"\s*[(\[][^)\]]*[)\]]")]
    private static partial Regex BracketRegex();

    [GeneratedRegex(@"\s+-\s+(single|ep)\s*$", RegexOptions.IgnoreCase)]
    private static partial Regex SingleEpRegex();

    [GeneratedRegex(@"\s+(?:feat\.?|ft\.?|featuring|with|&|x|and)\s+|\s*[,;/]\s*", RegexOptions.IgnoreCase)]
    private static partial Regex ArtistSplitRegex();

    [GeneratedRegex(@"karaoke|instrumental|tribute|made famous|originally performed|backing track|lullaby|8-bit|cover version", RegexOptions.IgnoreCase)]
    private static partial Regex DerivedRegex();
}
