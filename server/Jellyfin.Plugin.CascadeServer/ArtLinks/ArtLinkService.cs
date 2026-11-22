using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Data.Enums;
using Jellyfin.Plugin.CascadeServer.AnimatedArt;
using Jellyfin.Plugin.CascadeServer.Explicit;
using Jellyfin.Plugin.CascadeServer.LyricStore;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Controller.Entities;
using MediaBrowser.Controller.Entities.Audio;
using MediaBrowser.Controller.Library;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.CascadeServer.ArtLinks;

/// <summary>
/// Finds where an artist's picture (Deezer) or an album's cover (iTunes) lives, for items Jellyfin
/// has no image for. Only the link is kept, for <see cref="ArtMatch.LinkTtl"/>: the picture itself
/// is fetched by the app from the service each time and never stored here or in Jellyfin.
/// </summary>
public sealed class ArtLinkService
{
    /// <summary>A link found (or null for none) and when.</summary>
    public record Entry(string? Url, DateTime FetchedUtc);

    /// <summary>The links store (art-links.json): urls and misses, no images.</summary>
    public static readonly JsonStore<Entry> Store = new("art-links.json");

    // Deezer allows about 50 requests in 5 seconds per address, shared with the explicit lookups
    // (one a second); iTunes about 20 a minute.
    private static readonly RateGate DeezerGate = new(TimeSpan.FromMilliseconds(150));
    private static readonly RateGate ItunesGate = new(TimeSpan.FromSeconds(3));
    private static readonly ConcurrentDictionary<Guid, Task<string?>> Running = new();

    // Trouble at a service says nothing about the item: it is asked again after a while, not
    // remembered as a miss.
    private static readonly ConcurrentDictionary<Guid, DateTime> FailedUntil = new();

    private readonly ILibraryManager _library;
    private readonly IApplicationPaths _paths;
    private readonly IHttpClientFactory _http;
    private readonly ILogger _logger;

    /// <summary>Initialises a new instance of <see cref="ArtLinkService"/>.</summary>
    public ArtLinkService(ILibraryManager library, IApplicationPaths paths, IHttpClientFactory http, ILogger logger)
    {
        _library = library;
        _paths = paths;
        _http = http;
        _logger = logger;
    }

    /// <summary>Whether art links are on: the default, unless the administrator chose stored images only.</summary>
    public static bool Enabled => Plugin.Config.ArtSourceMode != "stored";

    /// <summary>
    /// The link for <paramref name="item"/> (a MusicArtist or MusicAlbum), waiting at most
    /// <paramref name="budget"/>. Done: the url, or null for none. Not done in time: pending, and the
    /// lookup carries on so the next ask has it.
    /// </summary>
    public async Task<(string? Url, bool Pending)> LinkAsync(BaseItem item, TimeSpan budget, CancellationToken ct)
    {
        if (Store.Get(_paths, item.Id) is { } known
            && TidalParse.Fresh(known.FetchedUtc, known.Url is null ? ArtMatch.MissTtl : ArtMatch.LinkTtl, DateTime.UtcNow))
        {
            return (known.Url, false);
        }

        if (FailedUntil.TryGetValue(item.Id, out var until) && until > DateTime.UtcNow) return (null, false);

        var lookup = Running.GetOrAdd(item.Id, _ => Task.Run(() => LookupAsync(item)));
        if (await Task.WhenAny(lookup, Task.Delay(budget, ct)) != lookup) return (null, true);
        return (await lookup, false);
    }

    private async Task<string?> LookupAsync(BaseItem item)
    {
        try
        {
            var url = item switch
            {
                MusicArtist artist => await ArtistAsync(artist),
                MusicAlbum album => await AlbumAsync(album),
                _ => null,
            };
            Store.Set(_paths, item.Id, new Entry(url, DateTime.UtcNow));
            return url;
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException or DeezerBusyException)
        {
            _logger.LogInformation("Art link lookup for {Name} failed: {Message}", item.Name, ex.Message);
            FailedUntil[item.Id] = DateTime.UtcNow.AddMinutes(10);
            return null;
        }
        finally
        {
            Running.TryRemove(item.Id, out _);
        }
    }

    private async Task<string?> ArtistAsync(MusicArtist artist)
    {
        using var client = CreateClient();
        using var search = await GetAsync(client, DeezerGate, $"https://api.deezer.com/search/artist?q={Uri.EscapeDataString(artist.Name)}&limit=5");
        var candidates = ArtMatch.DeezerArtists(search.RootElement)
            .Where(c => c.Picture is not null && ArtMatch.SameName(c.Name, artist.Name))
            .Take(3)
            .ToList();
        var real = new List<ArtMatch.DeezerArtist>();
        foreach (var c in candidates)
        {
            if (await RealPictureAsync(client, c.Picture!)) real.Add(c);
        }

        candidates = real;
        if (candidates.Count == 0) return null;

        var ours = _library.GetItemList(new InternalItemsQuery
        {
            IncludeItemTypes = [BaseItemKind.MusicAlbum],
            ArtistIds = [artist.Id],
            Recursive = true,
        }).Select(a => a.Name).ToList();

        // Only same-named candidates are asked for their albums, and only when the library has some.
        var theirs = new Dictionary<long, IReadOnlyCollection<string>>();
        if (ours.Count > 0)
        {
            foreach (var c in candidates)
            {
                using var albums = await GetAsync(client, DeezerGate, $"https://api.deezer.com/artist/{c.Id}/albums?limit=100");
                theirs[c.Id] = ArtMatch.DeezerAlbumTitles(albums.RootElement);
            }
        }

        return ArtMatch.PickArtistPicture(artist.Name, ours, candidates, c => theirs.TryGetValue(c.Id, out var t) ? t : []);
    }

    private async Task<string?> AlbumAsync(MusicAlbum album)
    {
        var artist = album.AlbumArtists.FirstOrDefault() ?? album.Artists.FirstOrDefault() ?? string.Empty;
        var tracks = album.Tracks.Count();
        using var client = CreateClient();
        var term = Uri.EscapeDataString($"{artist} {album.Name}".Trim());
        using var doc = await GetAsync(client, ItunesGate, $"https://itunes.apple.com/search?entity=album&limit=10&term={term}");
        return ArtMatch.PickAlbumArt(album.Name, artist, tracks > 0 ? tracks : null, ArtMatch.ItunesAlbums(doc.RootElement));
    }

    /// <summary>
    /// Whether a Deezer picture link is a real picture: its CDN redirects artists without one to the
    /// <see cref="ArtMatch.NoImageId"/> silhouette, which nothing in the API marks. Only the headers
    /// are asked for. Trouble other than a 404 throws, so it is retried rather than kept as a miss.
    /// </summary>
    private static async Task<bool> RealPictureAsync(HttpClient client, string url)
    {
        using var request = new HttpRequestMessage(HttpMethod.Head, url);
        using var response = await client.SendAsync(request);
        if (response.StatusCode == HttpStatusCode.NotFound) return false;
        if (response.Headers.Location is { } location) return ArtMatch.HasPicture(location.OriginalString);
        response.EnsureSuccessStatusCode();
        return ArtMatch.HasPicture(response.RequestMessage?.RequestUri?.AbsoluteUri ?? url);
    }

    private static async Task<JsonDocument> GetAsync(HttpClient client, RateGate gate, string url)
    {
        await gate.WaitAsync(CancellationToken.None);
        using var response = await client.GetAsync(url);
        response.EnsureSuccessStatusCode();
        var doc = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync());
        if (ArtMatch.DeezerError(doc.RootElement))
        {
            doc.Dispose();
            throw new DeezerBusyException();
        }

        return doc;
    }

    private HttpClient CreateClient()
    {
        var client = _http.CreateClient();
        client.DefaultRequestHeaders.UserAgent.ParseAdd("CascadeServer/1.0 (https://github.com/Cha0s1nc/Cascade-Project)");
        client.Timeout = TimeSpan.FromSeconds(15);
        return client;
    }

    /// <summary>Deezer answered with an error object (a quota hit among them), which says nothing about the artist.</summary>
    private sealed class DeezerBusyException : Exception
    {
        public DeezerBusyException()
            : base("Deezer answered with an error.")
        {
        }
    }
}
