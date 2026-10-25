using System.Text.Json;
using Jellyfin.Plugin.CascadeServer.AnimatedArt;
using Xunit;

namespace Jellyfin.Plugin.CascadeServer.Tests;

public class TidalParseTests
{
    // The shape the brief describes: an album with its coverArt relationship, and included artworks.
    private const string Album = """
    {
      "data": [{ "id": "240189283", "type": "albums",
        "attributes": { "title": "RENAISSANCE", "numberOfItems": 16 },
        "relationships": { "coverArt": { "data": [ { "id": "still1", "type": "artworks" }, { "id": "vid1", "type": "artworks" } ] } } }],
      "included": [
        { "id": "other", "type": "artworks", "attributes": { "mediaType": "VIDEO", "files": [ { "href": "https://resources.tidal.com/other.mp4", "meta": { "width": 1080, "height": 1080 } } ] } },
        { "id": "still1", "type": "artworks", "attributes": { "mediaType": "IMAGE", "files": [ { "href": "https://resources.tidal.com/s.jpg", "meta": { "width": 1280, "height": 1280 } } ] } },
        { "id": "vid1", "type": "artworks", "attributes": { "mediaType": "VIDEO", "files": [
          { "href": "https://resources.tidal.com/v320.mp4", "meta": { "width": 320, "height": 320 } },
          { "href": "https://resources.tidal.com/v750.mp4", "meta": { "width": 750, "height": 750 } },
          { "href": "https://resources.tidal.com/v1280.mp4", "meta": { "width": 1280, "height": 1280 } } ] } }
      ]
    }
    """;

    [Fact]
    public void PicksTheExactWidthOfTheAlbumsOwnVideo()
    {
        using var doc = JsonDocument.Parse(Album);
        var v = TidalParse.PickVideo(doc.RootElement, 750);
        Assert.Equal("vid1", v!.ArtworkId);
        Assert.Equal(750, v.Width);
        Assert.EndsWith("v750.mp4", v.Href);
    }

    [Theory]
    [InlineData(1080, 1280)]
    [InlineData(1280, 1280)]
    [InlineData(100, 320)]
    public void UsesTheNearestWidthWhenMissing(int wanted, int expected)
    {
        using var doc = JsonDocument.Parse(Album);
        Assert.Equal(expected, TidalParse.PickVideo(doc.RootElement, wanted)!.Width);
    }

    [Fact]
    public void NoVideoIsAMiss()
    {
        using var doc = JsonDocument.Parse("""{"data":[{"id":"1","type":"albums","relationships":{"coverArt":{"data":[{"id":"s","type":"artworks"}]}}}],"included":[{"id":"s","type":"artworks","attributes":{"mediaType":"IMAGE","files":[]}}]}""");
        Assert.Null(TidalParse.PickVideo(doc.RootElement, 1080));
        using var empty = JsonDocument.Parse("""{"data":[]}""");
        Assert.Null(TidalParse.PickVideo(empty.RootElement, 1080));
    }

    [Fact]
    public void ReadsAlbumsFromATracksResponse()
    {
        using var doc = JsonDocument.Parse("""{"data":[{"id":"t1","type":"tracks"}],"included":[{"id":"a1","type":"albums","attributes":{"title":"Album (Deluxe)","numberOfItems":12}}]}""");
        var a = Assert.Single(TidalParse.Albums(doc.RootElement));
        Assert.Equal(("a1", "Album (Deluxe)", 12), a);
    }

    [Theory]
    [InlineData("196589246974", "196589246974")]
    [InlineData("1965 8924-6974", "196589246974")]
    [InlineData("0196589246974", "0196589246974")]
    [InlineData("12345", null)]
    [InlineData("abc196589246974", null)]
    [InlineData(null, null)]
    public void Barcodes(string? raw, string? expected) => Assert.Equal(expected, TidalParse.Barcode(raw));

    [Fact]
    public void CacheLifetimes()
    {
        var now = new DateTime(2026, 10, 1, 0, 0, 0, DateTimeKind.Utc);
        Assert.True(TidalParse.Fresh(now.AddDays(-24), TidalParse.CacheTtl, now));
        Assert.False(TidalParse.Fresh(now.AddDays(-26), TidalParse.CacheTtl, now));
        Assert.False(TidalParse.Fresh(now.AddDays(-8), TidalParse.MissTtl, now));
    }

    [Theory]
    [InlineData("cover.mp4", "video/mp4")]
    [InlineData("https://resources.tidal.com/a/b.MP4?x=1", "video/mp4")]
    [InlineData("cover.webm", "video/webm")]
    [InlineData("cover.png", null)]
    public void VideoTypes(string path, string? expected) => Assert.Equal(expected, TidalParse.VideoContentType(path));
}
