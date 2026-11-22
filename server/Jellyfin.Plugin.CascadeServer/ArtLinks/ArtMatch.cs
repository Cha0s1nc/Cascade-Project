using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using Jellyfin.Plugin.CascadeServer.Explicit;

namespace Jellyfin.Plugin.CascadeServer.ArtLinks;

/// <summary>
/// The pure parts of art links: reading Deezer's and iTunes' answers and deciding which result is
/// the library's artist or album. Pictures are only ever linked to, never stored: Deezer's developer
/// terms forbid keeping its images, and Apple's allow its artwork only as promotional content. No
/// Jellyfin types, so the unit tests compile it.
/// </summary>
public static partial class ArtMatch
{
    /// <summary>How long a found link is reused before it is looked up again (as TIDAL's lookups).</summary>
    public static readonly TimeSpan LinkTtl = TimeSpan.FromDays(25);

    /// <summary>How long "nothing found" is remembered.</summary>
    public static readonly TimeSpan MissTtl = TimeSpan.FromDays(7);

    /// <summary>The cover size asked of iTunes (it renders any square size from the same image).</summary>
    public const int ItunesSize = 1200;

    /// <summary>A Deezer artist from a search.</summary>
    public record DeezerArtist(long Id, string Name, string? Picture);

    /// <summary>An iTunes album from a search.</summary>
    public record ItunesAlbum(string Name, string Artist, int? TrackCount, string? Artwork);

    /// <summary>Album artists that name no act, so they cannot be held against a result.</summary>
    private static readonly HashSet<string> CompilationArtists = ["various artists", "various", "va"];

    /// <summary>The artists in a Deezer <c>/search/artist</c> answer; their picture is null when Deezer has none.</summary>
    public static List<DeezerArtist> DeezerArtists(JsonElement root)
    {
        var list = new List<DeezerArtist>();
        if (!root.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array) return list;
        foreach (var a in data.EnumerateArray())
        {
            if (!a.TryGetProperty("id", out var id) || !id.TryGetInt64(out var n)) continue;
            var name = a.TryGetProperty("name", out var nm) ? nm.GetString() ?? string.Empty : string.Empty;
            var pic = a.TryGetProperty("picture_xl", out var p) ? p.GetString() : null;
            list.Add(new DeezerArtist(n, name, HasPicture(pic) ? pic : null));
        }

        return list;
    }

    /// <summary>The album titles in a Deezer <c>/artist/{id}/albums</c> answer.</summary>
    public static List<string> DeezerAlbumTitles(JsonElement root)
    {
        var list = new List<string>();
        if (!root.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array) return list;
        foreach (var a in data.EnumerateArray())
        {
            if (a.TryGetProperty("title", out var t) && t.GetString() is { Length: > 0 } s) list.Add(s);
        }

        return list;
    }

    /// <summary>
    /// Whether Deezer answered with an error object (it does so with status 200, a quota hit
    /// among them), which says nothing about the artist, so no miss should be stored.
    /// </summary>
    public static bool DeezerError(JsonElement root) => root.ValueKind == JsonValueKind.Object && root.TryGetProperty("error", out _);

    /// <summary>
    /// Deezer's image id for "no picture" (the md5 of an empty string). Its CDN redirects every
    /// artist without a picture here and serves a gray silhouette, even for ids the API hands out
    /// that look ordinary, so only following the picture's link tells them apart.
    /// </summary>
    public const string NoImageId = "d41d8cd98f00b204e9800998ecf8427e";

    /// <summary>
    /// Whether <paramref name="url"/> is a real picture: not Deezer's old placeholder with an empty
    /// image id (<c>.../images/artist//1000x1000-...</c>) nor its <see cref="NoImageId"/> silhouette.
    /// </summary>
    public static bool HasPicture(string? url) =>
        !string.IsNullOrWhiteSpace(url)
        && !url.Contains("/artist//", StringComparison.Ordinal)
        && !url.Contains($"/artist/{NoImageId}/", StringComparison.Ordinal);

    /// <summary>Same act by name: equal after <see cref="TitleMatch.Clean"/>.</summary>
    public static bool SameName(string? a, string? b)
    {
        var x = TitleMatch.Clean(a);
        return x.Length > 0 && x == TitleMatch.Clean(b);
    }

    /// <summary>How many of <paramref name="theirs"/> are among <paramref name="ours"/>, compared without edition words.</summary>
    public static int SharedAlbums(IEnumerable<string> ours, IEnumerable<string> theirs)
    {
        var mine = ours.Select(TitleMatch.Base).Where(s => s.Length > 0).ToHashSet();
        return theirs.Select(TitleMatch.Base).Distinct().Count(mine.Contains);
    }

    /// <summary>
    /// The picture for the library's artist: among same-named candidates with a picture, the one
    /// sharing the most albums with the library, at least one. Names alone are not trusted (two
    /// "$atori Zoom"s, a "Ghost" in every genre), except when the library has no albums by the
    /// artist and only one candidate has the name. <paramref name="albumsOf"/> gives each
    /// candidate's album titles.
    /// </summary>
    public static string? PickArtistPicture(
        string artistName, IReadOnlyCollection<string> libraryAlbums, IEnumerable<DeezerArtist> candidates, Func<DeezerArtist, IReadOnlyCollection<string>> albumsOf)
    {
        var named = candidates.Where(c => c.Picture is not null && SameName(c.Name, artistName)).ToList();
        if (named.Count == 0) return null;
        if (libraryAlbums.Count == 0) return named.Count == 1 ? named[0].Picture : null;

        DeezerArtist? best = null;
        var bestShared = 0;
        foreach (var c in named)
        {
            var shared = SharedAlbums(libraryAlbums, albumsOf(c));
            if (shared > bestShared)
            {
                best = c;
                bestShared = shared;
            }
        }

        return best?.Picture;
    }

    /// <summary>The albums in an iTunes Search answer (<c>entity=album</c>).</summary>
    public static List<ItunesAlbum> ItunesAlbums(JsonElement root)
    {
        var list = new List<ItunesAlbum>();
        if (!root.TryGetProperty("results", out var results) || results.ValueKind != JsonValueKind.Array) return list;
        foreach (var r in results.EnumerateArray())
        {
            string? Str(string k) => r.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            int? count = r.TryGetProperty("trackCount", out var tc) && tc.TryGetInt32(out var n) ? n : null;
            list.Add(new ItunesAlbum(Str("collectionName") ?? string.Empty, Str("collectionArtistName") ?? Str("artistName") ?? string.Empty, count, Str("artworkUrl100")));
        }

        return list;
    }

    /// <summary>
    /// Whether two artist spellings plausibly name the same act (Cascade's itunesArtistMatches:
    /// equal, or one inside the other, after <see cref="TitleMatch.Base"/>).
    /// </summary>
    public static bool ArtistMatches(string? got, string? want)
    {
        var w = TitleMatch.Base(want);
        if (w.Length == 0) return true;
        var g = TitleMatch.Base(got);
        return g.Length > 0 && (g == w || g.Contains(w, StringComparison.Ordinal) || w.Contains(g, StringComparison.Ordinal));
    }

    /// <summary>
    /// The cover for the library's album, ported from Cascade's pickItunesArt: the album name must
    /// match (exact scores above edition-insensitive) and so must the artist, unless the album
    /// artist is a compilation's. A track count further than one from the library's is refused
    /// when both are known. The URL asks for <see cref="ItunesSize"/> pixels.
    /// </summary>
    public static string? PickAlbumArt(string album, string artist, int? trackCount, IEnumerable<ItunesAlbum> results)
    {
        var wantAlbum = TitleMatch.Base(album);
        var wantArtist = TitleMatch.Base(artist);
        var anyArtist = wantArtist.Length == 0 || CompilationArtists.Contains(wantArtist);
        string? best = null;
        var bestScore = 0;
        foreach (var r in results)
        {
            if (string.IsNullOrWhiteSpace(r.Artwork)) continue;
            var byArtist = ArtistMatches(r.Artist, artist);
            if (!byArtist && !anyArtist) continue;
            if (trackCount is > 0 && r.TrackCount is > 0 && Math.Abs(trackCount.Value - r.TrackCount.Value) > 1) continue;
            var albumScore = wantAlbum.Length == 0 ? (byArtist ? 1 : 0)
                : TitleMatch.Clean(r.Name) == TitleMatch.Clean(album) ? 3
                : TitleMatch.Base(r.Name) == wantAlbum ? 2
                : 0;
            if (albumScore == 0) continue;
            // Doubled so an artist tiebreak can never outrank a better album match.
            var score = (albumScore * 2) + (byArtist ? 1 : 0);
            if (score > bestScore)
            {
                bestScore = score;
                best = r.Artwork;
            }
        }

        return best is null ? null : SizeToken().Replace(best, $"{ItunesSize}x{ItunesSize}bb", 1);
    }

    [GeneratedRegex(@"\d+x\d+bb")]
    private static partial Regex SizeToken();
}
