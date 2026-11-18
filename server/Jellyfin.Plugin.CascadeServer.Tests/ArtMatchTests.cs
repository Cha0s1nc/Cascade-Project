using System.Text.Json;
using Jellyfin.Plugin.CascadeServer.ArtLinks;
using Xunit;

namespace Jellyfin.Plugin.CascadeServer.Tests;

public class ArtMatchTests
{
    // The shapes Deezer and iTunes sent on 2026-11-18.
    private const string DeezerSearch = """
    { "data": [
      { "id": 111, "name": "$atori Zoom", "picture_xl": "https://cdn-images.dzcdn.net/images/artist/aaa/1000x1000-000000-80-0-0.jpg" },
      { "id": 222, "name": "$atori Zoom", "picture_xl": "https://cdn-images.dzcdn.net/images/artist/bbb/1000x1000-000000-80-0-0.jpg" },
      { "id": 333, "name": "Satori", "picture_xl": "https://cdn-images.dzcdn.net/images/artist//1000x1000-000000-80-0-0.jpg" }
    ], "total": 3 }
    """;

    private const string ItunesSearch = """
    { "resultCount": 3, "results": [
      { "collectionName": "Direct Hits (Deluxe)", "artistName": "The Killers", "trackCount": 18, "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/a/100x100bb.jpg" },
      { "collectionName": "Hot Fuss", "artistName": "The Killers", "trackCount": 12, "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/b/100x100bb.jpg" },
      { "collectionName": "Hot Fuss", "artistName": "Hot Fuss Tribute Band", "trackCount": 12, "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/c/100x100bb.jpg" }
    ] }
    """;

    private static JsonElement Json(string s) => JsonDocument.Parse(s).RootElement;

    [Fact]
    public void ReadsDeezerArtistsAndDropsThePlaceholderPicture()
    {
        var list = ArtMatch.DeezerArtists(Json(DeezerSearch));
        Assert.Equal(3, list.Count);
        Assert.NotNull(list[0].Picture);
        Assert.Null(list[2].Picture);
        Assert.True(ArtMatch.DeezerError(Json("""{ "error": { "code": 4, "message": "Quota limit exceeded" } }""")));
        Assert.Empty(ArtMatch.DeezerArtists(Json("""{ "data": [], "total": 0 }""")));
    }

    [Fact]
    public void TwoSameNamedArtistsAreToldApartByTheirAlbums()
    {
        var candidates = ArtMatch.DeezerArtists(Json(DeezerSearch));
        IReadOnlyCollection<string> AlbumsOf(ArtMatch.DeezerArtist a) => a.Id == 222 ? ["NIGHTMARE", "zoom zoom (Deluxe)"] : ["Something Else"];
        var pic = ArtMatch.PickArtistPicture("$atori Zoom", ["Zoom Zoom"], candidates, AlbumsOf);
        Assert.Contains("/bbb/", pic);
    }

    [Fact]
    public void ANameAloneIsNotEnough()
    {
        var candidates = ArtMatch.DeezerArtists(Json(DeezerSearch));
        Assert.Null(ArtMatch.PickArtistPicture("$atori Zoom", ["An Album Deezer Lacks"], candidates, _ => ["Other"]));
        Assert.Null(ArtMatch.PickArtistPicture("$atori Zoom", [], candidates, _ => []));
        var single = new List<ArtMatch.DeezerArtist> { new(1, "2hollis", "https://x/pic.jpg") };
        Assert.Equal("https://x/pic.jpg", ArtMatch.PickArtistPicture("2hollis", [], single, _ => []));
        Assert.Null(ArtMatch.PickArtistPicture("Satori", [], ArtMatch.DeezerArtists(Json(DeezerSearch)), _ => []));
    }

    [Fact]
    public void PicksTheAlbumByNameArtistAndTrackCountAtTheAskedSize()
    {
        var results = ArtMatch.ItunesAlbums(Json(ItunesSearch));
        Assert.Equal("https://is1-ssl.mzstatic.com/image/thumb/b/1200x1200bb.jpg", ArtMatch.PickAlbumArt("Hot Fuss", "The Killers", 12, results));
        Assert.Null(ArtMatch.PickAlbumArt("Hot Fuss", "The Killers", 20, results));
        Assert.Null(ArtMatch.PickAlbumArt("Sam's Town", "The Killers", 12, results));
        Assert.Equal("https://is1-ssl.mzstatic.com/image/thumb/a/1200x1200bb.jpg", ArtMatch.PickAlbumArt("Direct Hits", "The Killers", null, results));
    }

    [Fact]
    public void ACompilationTakesAnyArtist()
    {
        var results = ArtMatch.ItunesAlbums(Json(ItunesSearch));
        Assert.NotNull(ArtMatch.PickAlbumArt("Hot Fuss", "Various Artists", 12, results));
    }
}
