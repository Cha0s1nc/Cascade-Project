using System.Text.Json;
using Jellyfin.Plugin.CascadeServer.LyricFetch;
using Xunit;

namespace Jellyfin.Plugin.CascadeServer.Tests;

/// <summary>
/// Fixtures are written by hand to the shapes in SpicyLyrics' OpenAPI spec, never captured
/// from a real response: their terms (sections 5 and 7) do not allow a stored copy.
/// </summary>
public class SpicyIdsTests
{
    private const string Spotify = "4cOdK2wGLETKBW3PvgPWqT";
    private const string Spotify2 = "7GhIk7Il098yCjg4BQjzvb";
    private const string Spotify3 = "1QV6tiMFM6fSOKOGLMHYYg";

    [Theory]
    // Spotify, 22 base62.
    [InlineData(Spotify, Spotify)]
    [InlineData("  " + Spotify + "  ", Spotify)]
    // ISRC, however it is written.
    [InlineData("GBARL9300135", "GBARL9300135")]
    [InlineData("gb-arl-93-00135", "GBARL9300135")]
    [InlineData("GB ARL 93 00135", "GBARL9300135")]
    // Apple Music, digits only.
    [InlineData("1438556832", "1438556832")]
    // 22 digits is a Spotify id: an Apple id stops at 20.
    [InlineData("1111111111111111111111", "1111111111111111111111")]
    // Nothing else, and nothing that could escape the cache folder.
    [InlineData("1111111111111111111", "1111111111111111111")]
    [InlineData("11111111111111111111111", null)]
    [InlineData("GBARL930013", null)]
    [InlineData("GBARL93001356", null)]
    [InlineData("9BARL9300135", null)]
    [InlineData("../etc/passwd", null)]
    [InlineData("GB-ARL/9300135", null)]
    [InlineData("4cOdK2wGLETKBW3PvgPWq.", null)]
    [InlineData("", null)]
    [InlineData("   ", null)]
    [InlineData(null, null)]
    public void NormalizeLookupId(string? input, string? expected)
        => Assert.Equal(expected, SpicyIds.NormalizeLookupId(input));

    [Theory]
    [InlineData("GBARL9300135", "GBARL9300135")]
    [InlineData("gb-arl-93-00135", "GBARL9300135")]
    // Strict, unlike the union: a digits-only tag is not an ISRC, and must not go out as an
    // Apple Music id just because it came from a file.
    [InlineData("1438556832", null)]
    [InlineData(Spotify, null)]
    [InlineData("", null)]
    [InlineData(null, null)]
    public void NormalizeIsrc(string? input, string? expected)
        => Assert.Equal(expected, SpicyIds.NormalizeIsrc(input));

    [Fact]
    public void SearchQuerySendsWhatItHas()
    {
        Assert.Equal(
            "title=Creep&artist=Radiohead&album=Pablo%20Honey&duration=238.64",
            SpicyIds.SearchQuery("Creep", "Radiohead", "Pablo Honey", 238.64));

        // An empty artist or album is left out: the spec gives them a minimum length of one
        // and answers a blank with a 400.
        Assert.Equal("title=Creep&duration=238", SpicyIds.SearchQuery("Creep", "  ", string.Empty, 238));
        Assert.Equal("title=Creep&artist=Radiohead", SpicyIds.SearchQuery("Creep", "Radiohead", string.Empty, null));

        // An unusable length is left out rather than sent as 0 or a year of seconds.
        Assert.Equal("title=A", SpicyIds.SearchQuery("A", string.Empty, string.Empty, 0));
        Assert.Equal("title=A", SpicyIds.SearchQuery("A", string.Empty, string.Empty, 90000));

        // Escaped, and clamped to the 200 the spec allows.
        Assert.Equal("title=A%20%26%20B%2FC", SpicyIds.SearchQuery("A & B/C", string.Empty, string.Empty, null));
        Assert.Equal(200 + "title=".Length, SpicyIds.SearchQuery(new string('a', 300), string.Empty, string.Empty, null).Length);
    }

    private static JsonElement Json(string raw) => JsonDocument.Parse(raw).RootElement;

    [Fact]
    public void ExactIdsTakesOnlyAnExactMatch()
    {
        var body = """
        {"Body": {"results": [
          {"id": "7GhIk7Il098yCjg4BQjzvb", "tier": "version", "duration": 240.0, "variants": []},
          {"id": "4cOdK2wGLETKBW3PvgPWqT", "tier": "exact", "duration": 238.6, "variants": []},
          {"id": "1QV6tiMFM6fSOKOGLMHYYg", "tier": "exact", "duration": 100.0, "variants": []}
        ]}, "Status": 200, "Type": "object"}
        """;
        // The first exact result only: order within a tier is their best guess, and a
        // lower-tier match is a live cut, a remix or a cover whose timings do not fit.
        Assert.Equal([Spotify], SpicyIds.ExactIds(Json(body), 238.6));

        // Nothing exact means nothing to try automatically.
        var noExact = """{"Body": {"results": [{"id": "7GhIk7Il098yCjg4BQjzvb", "tier": "likely", "duration": 1.0, "variants": []}]}}""";
        Assert.Empty(SpicyIds.ExactIds(Json(noExact), 1.0));
    }

    [Fact]
    public void ExactIdsOrdersReleasesByLength()
    {
        var body = """
        {"Body": {"results": [{
          "id": "4cOdK2wGLETKBW3PvgPWqT", "tier": "exact", "duration": 250.0,
          "variants": [
            {"id": "7GhIk7Il098yCjg4BQjzvb", "album": "Single", "duration": 186.5},
            {"id": "1QV6tiMFM6fSOKOGLMHYYg", "album": "Live", "duration": 400.0}
          ]
        }]}}
        """;
        // The file is 186.6s, so the single's release is tried first even though the result's
        // own release leads: that is what stops a longer release's sync drifting.
        Assert.Equal([Spotify2, Spotify, Spotify3], SpicyIds.ExactIds(Json(body), 186.6));

        // With no length known, their order stands.
        Assert.Equal([Spotify, Spotify2, Spotify3], SpicyIds.ExactIds(Json(body), null));
    }

    [Fact]
    public void ExactIdsRefusesAnythingNotASpotifyId()
    {
        // These become cache file names, so a junk or hostile id is dropped, not passed on.
        var body = """
        {"Body": {"results": [{
          "id": "../../etc/passwd", "tier": "exact", "duration": 10.0,
          "variants": [{"id": "4cOdK2wGLETKBW3PvgPWqT", "album": "A", "duration": 11.0}, {"id": 7, "album": "B", "duration": 12.0}]
        }]}}
        """;
        Assert.Equal([Spotify], SpicyIds.ExactIds(Json(body), 11.0));

        // A shape that is not the one documented is not a crash and not a guess.
        Assert.Empty(SpicyIds.ExactIds(Json("""{"Body": {"results": "nope"}}"""), null));
        Assert.Empty(SpicyIds.ExactIds(Json("""{"Body": {}}"""), null));
        Assert.Empty(SpicyIds.ExactIds(Json("""{}"""), null));
        Assert.Empty(SpicyIds.ExactIds(Json("""[]"""), null));
    }

    [Fact]
    public void SpotifyIdOfReadsTheIdWhateverWasAsked()
    {
        // Body.id is always the Spotify id, which is what gets remembered after an ISRC probe.
        Assert.Equal(Spotify, SpicyIds.SpotifyIdOf("""{"Body": {"Type": "Syllable", "id": "4cOdK2wGLETKBW3PvgPWqT"}, "Status": 200}"""));
        Assert.Equal(Spotify, SpicyIds.SpotifyIdOf("""{"Type": "Syllable", "id": "4cOdK2wGLETKBW3PvgPWqT"}"""));

        // Never remember something that is not a Spotify id: it would become a file name.
        Assert.Null(SpicyIds.SpotifyIdOf("""{"Body": {"id": "GBARL9300135"}}"""));
        Assert.Null(SpicyIds.SpotifyIdOf("""{"Body": {"id": "../etc/passwd"}}"""));
        Assert.Null(SpicyIds.SpotifyIdOf("""{"Body": {}}"""));
        Assert.Null(SpicyIds.SpotifyIdOf("not json"));
    }

    [Fact]
    public void ErrorCodeIsReadForDiagnosis()
    {
        // missing_scope is the one that otherwise looks exactly like "no lyrics".
        Assert.Equal("missing_scope", SpicyIds.ErrorCode("""{"Body": {"error": "missing_scope", "message": "x"}, "Status": 403}"""));
        Assert.Equal("lyrics_not_found", SpicyIds.ErrorCode("""{"Body": {"error": "lyrics_not_found"}, "Status": 404}"""));
        Assert.Null(SpicyIds.ErrorCode("""{"Body": {}}"""));
        Assert.Null(SpicyIds.ErrorCode("<html>502</html>"));
    }
}
