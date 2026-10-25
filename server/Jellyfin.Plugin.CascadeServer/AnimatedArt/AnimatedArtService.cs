using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Plugin.CascadeServer.Explicit;
using Jellyfin.Plugin.CascadeServer.LyricStore;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Controller.Entities.Audio;
using MediaBrowser.Controller.Library;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.CascadeServer.AnimatedArt;

/// <summary>
/// Finds the looping video cover for an album: a sidecar or upload an administrator supplied, or
/// TIDAL, looked up on demand with the administrator's own developer app. TIDAL is only asked when a
/// client asks for an album's art, never in a library-wide pass.
/// </summary>
public sealed class AnimatedArtService
{
    /// <summary>What an album's art resolved to. <c>FilePath</c> is set for anything served from this server.</summary>
    public record Art(string Source, string Url, string ContentType, int? Width, int? Height, DateTime UpdatedUtc, string? FilePath);

    /// <summary>The outcome of asking for an album's art: a result, or nothing with <c>Pending</c> saying a lookup or download is under way.</summary>
    public record Answer(Art? Art, bool Pending);

    /// <summary>A hand link from an album to a TIDAL album. An id an administrator chose, not TIDAL content, so it is kept until removed.</summary>
    public record Link(string TidalAlbumId);

    /// <summary>The links store (tidal-links.json).</summary>
    public static readonly JsonStore<Link> Links = new("tidal-links.json");

    private static readonly TimeSpan LookupBudget = TimeSpan.FromSeconds(5);
    private static readonly RateGate MusicBrainzGate = new(TimeSpan.FromSeconds(1));
    private static readonly ConcurrentDictionary<Guid, Task<LookupOutcome>> Lookups = new();
    private static readonly ConcurrentDictionary<Guid, Task> Downloads = new();

    private enum LookupOutcome { Found, Miss, Failed }

    private record LookupInput(Guid AlbumId, string AlbumName, int TrackCount, string? MusicBrainzReleaseId, string[] TrackPaths);

    private readonly IApplicationPaths _paths;
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly ILogger _logger;
    private readonly string _ffmpeg;

    /// <summary>Initialises a new instance of <see cref="AnimatedArtService"/>.</summary>
    /// <param name="ffmpeg">Jellyfin's ffmpeg, which turns animated images into video.</param>
    public AnimatedArtService(IApplicationPaths paths, IHttpClientFactory httpClientFactory, ILogger logger, string ffmpeg)
    {
        _paths = paths;
        _httpClientFactory = httpClientFactory;
        _logger = logger;
        _ffmpeg = ffmpeg;
    }

    /// <summary>Where a sidecar that could not be put in the album folder is kept.</summary>
    public string UploadPath(Guid albumId, string ext)
    {
        var dir = Path.Combine(DataDir.Root(_paths), "animated-art", "uploads");
        Directory.CreateDirectory(dir);
        return Path.Combine(dir, $"{albumId:N}{ext}");
    }

    /// <summary>The album's tracks in disc and track order.</summary>
    public static List<Audio> Tracks(MusicAlbum album)
        => [.. album.Tracks.OrderBy(t => t.ParentIndexNumber ?? 0).ThenBy(t => t.IndexNumber ?? 0)];

    /// <summary>
    /// The album's folder: its own path when that is a folder holding every track, otherwise the
    /// folder of the first track by disc and track number. Null when neither exists on disk.
    /// </summary>
    public static string? AlbumFolder(MusicAlbum album, List<Audio> tracks)
    {
        var trackDirs = tracks.Where(t => t.Path is not null).Select(t => Path.GetDirectoryName(t.Path)!).ToList();
        if (!string.IsNullOrEmpty(album.Path) && Directory.Exists(album.Path)
            && trackDirs.All(d => d.StartsWith(album.Path, StringComparison.Ordinal)))
        {
            return album.Path;
        }

        var first = trackDirs.FirstOrDefault();
        return first is not null && Directory.Exists(first) ? first : null;
    }

    /// <summary>The configured sidecar names, reduced to bare file names so a setting cannot point out of the folder.</summary>
    public static string[] SidecarNames()
    {
        var names = (Plugin.Config.AnimatedArtSidecarNames ?? [])
            .Select(n => Path.GetFileName((n ?? string.Empty).Trim()))
            .Where(n => n.Length > 0 && TidalParse.VideoContentType(n) is not null)
            .ToArray();
        return names.Length > 0 ? names : ["cover.mp4", "cover.webm"];
    }

    /// <summary>
    /// The sidecar or upload for the album, if there is one: a video in the folder, then an upload,
    /// then an animated GIF, WebP or APNG in the folder, served as the MP4 it was turned into.
    /// <c>Pending</c> while that is being made; <paramref name="convert"/> starts it.
    /// </summary>
    public (Art? Art, bool Pending) FindLocal(MusicAlbum album, List<Audio> tracks, bool convert)
    {
        var folder = AlbumFolder(album, tracks);
        var candidates = new List<string>();
        if (folder is not null) candidates.AddRange(SidecarNames().Select(n => Path.Combine(folder, n)));
        candidates.Add(UploadPath(album.Id, ".mp4"));
        candidates.Add(UploadPath(album.Id, ".webm"));
        foreach (var path in candidates)
        {
            if (!System.IO.File.Exists(path)) continue;
            return (new Art("sidecar", FileUrl(album.Id), TidalParse.VideoContentType(path)!, null, null, System.IO.File.GetLastWriteTimeUtc(path), path), false);
        }

        if (folder is null) return (null, false);
        foreach (var path in AnimatedImage.Names.Select(n => Path.Combine(folder, n)))
        {
            if (!IsAnimatedFile(path)) continue;
            if (ImageToVideo.Ready(_paths, album.Id, path) is { } mp4)
            {
                return (new Art("sidecar", FileUrl(album.Id), "video/mp4", null, null, System.IO.File.GetLastWriteTimeUtc(mp4), mp4), false);
            }

            if (ImageToVideo.Failed(_paths, album.Id, path)) continue;
            if (convert) ImageToVideo.Start(_paths, _ffmpeg, _logger, album.Id, path);
            return (null, true);
        }

        return (null, false);
    }

    /// <summary>Whether the file is there and an animated image (<see cref="AnimatedImage.IsAnimated"/>).</summary>
    public static bool IsAnimatedFile(string path)
    {
        try
        {
            using var f = System.IO.File.OpenRead(path);
            var head = new byte[AnimatedImage.HeadBytes];
            var n = f.ReadAtLeast(head, head.Length, throwOnEndOfStream: false);
            return AnimatedImage.IsAnimated(head.AsSpan(0, n));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>What can be served from this server right now. Asks TIDAL nothing.</summary>
    public Art? ResolveCached(MusicAlbum album, List<Audio> tracks)
    {
        foreach (var source in Sources())
        {
            var art = source == "sidecar" ? FindLocal(album, tracks, convert: false).Art : CachedTidal(album.Id, serveFilesOnly: true);
            if (art is not null) return art;
        }

        return null;
    }

    /// <summary>The answer for the GET route: never waits on a download, and waits at most 5 seconds for a TIDAL lookup.</summary>
    public async Task<Answer> GetAsync(MusicAlbum album, List<Audio> tracks, CancellationToken ct)
    {
        var pending = false;
        foreach (var source in Sources())
        {
            if (source == "sidecar")
            {
                var (local, converting) = FindLocal(album, tracks, convert: true);
                if (local is not null) return new Answer(local, false);
                // An animated image being turned into video wins over TIDAL; ask again shortly.
                if (converting) return new Answer(null, true);
                continue;
            }

            if (!TidalClient.Configured) continue;
            var (art, wait) = await TidalAsync(album, tracks, ct);
            if (art is not null) return new Answer(art, false);
            pending |= wait;
        }

        return new Answer(null, pending);
    }

    private static string FileUrl(Guid albumId) => $"/CascadeServer/AnimatedArt/{albumId:N}/File";

    private static string[] Sources() => (Plugin.Config.AnimatedArtSourceOrder ?? "sidecar-first") switch
    {
        "tidal-first" => ["tidal", "sidecar"],
        "sidecar-only" => ["sidecar"],
        "tidal-only" => ["tidal"],
        _ => ["sidecar", "tidal"],
    };

    private Art? CachedTidal(Guid albumId, bool serveFilesOnly)
    {
        var entry = TidalCache.Get(_paths, albumId);
        if (entry is null) return null;
        var video = TidalCache.VideoPath(_paths, albumId);
        if (System.IO.File.Exists(video))
        {
            return new Art("tidal", FileUrl(albumId), "video/mp4", entry.Width, entry.Width, entry.FetchedUtc, video);
        }

        if (serveFilesOnly || Plugin.Config.TidalArtDelivery != "direct") return null;
        return new Art("tidal", entry.Href, TidalParse.VideoContentType(entry.Href) ?? "video/mp4", entry.Width, entry.Width, entry.FetchedUtc, null);
    }

    private async Task<(Art? Art, bool Pending)> TidalAsync(MusicAlbum album, List<Audio> tracks, CancellationToken ct)
    {
        var id = album.Id;
        var direct = Plugin.Config.TidalArtDelivery == "direct";
        var entry = TidalCache.Get(_paths, id);
        if (entry is null)
        {
            if (TidalCache.HasRecentMiss(_paths, id) || TidalClient.PausedUntil > DateTime.UtcNow) return (null, false);

            var input = new LookupInput(
                id, album.Name, tracks.Count, album.ProviderIds.GetValueOrDefault("MusicBrainzAlbum"),
                [.. tracks.Where(t => t.Path is not null).Take(2).Select(t => t.Path!)]);
            // A finished task left in the dictionary (it can finish before it is added) is not a lookup in flight.
            if (!Lookups.TryGetValue(id, out var lookup) || lookup.IsCompleted) Lookups[id] = lookup = RunLookupAsync(input);
            var done = await Task.WhenAny(lookup, Task.Delay(LookupBudget, ct));
            if (done != lookup) return (null, true);
            if (await lookup != LookupOutcome.Found) return (null, false);
            entry = TidalCache.Get(_paths, id);
            if (entry is null) return (null, false);
        }

        var art = CachedTidal(id, serveFilesOnly: false);
        if (art is not null) return (art, false);
        if (direct) return (null, false);

        // Cache delivery: the lookup is done, the video is not. Start the download and say so.
        StartDownload(id, entry);
        return (null, true);
    }

    private void StartDownload(Guid albumId, TidalCache.Entry entry)
    {
        if (Downloads.TryGetValue(albumId, out var running) && !running.IsCompleted) return;
        Downloads[albumId] = Task.Run(async () =>
        {
            try
            {
                await DownloadAsync(albumId, entry);
            }
            catch (Exception ex) when (ex is HttpRequestException or IOException or TaskCanceledException)
            {
                _logger.LogInformation("TIDAL video download for an album failed: {Message}", ex.Message);
            }
            finally
            {
                Downloads.TryRemove(albumId, out _);
            }
        });
    }

    private async Task DownloadAsync(Guid albumId, TidalCache.Entry entry)
    {
        // The file is TIDAL's own, unaltered. Only its source is checked: https, TIDAL's resource host.
        if (!Uri.TryCreate(entry.Href, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps)
        {
            throw new HttpRequestException("TIDAL sent a file address that is not https.");
        }

        using var client = CreateClient();
        client.Timeout = TimeSpan.FromMinutes(3);
        using var response = await client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead);
        response.EnsureSuccessStatusCode();
        var target = TidalCache.VideoPath(_paths, albumId);
        var tmp = target + ".tmp";
        const long cap = 200L * 1024 * 1024;
        await using (var file = System.IO.File.Create(tmp))
        {
            await using var body = await response.Content.ReadAsStreamAsync();
            var buffer = new byte[81920];
            long total = 0;
            int n;
            while ((n = await body.ReadAsync(buffer)) > 0)
            {
                total += n;
                if (total > cap) throw new IOException("The video is larger than the 200 MB limit.");
                await file.WriteAsync(buffer.AsMemory(0, n));
            }
        }

        System.IO.File.Move(tmp, target, overwrite: true);
    }

    private HttpClient CreateClient()
    {
        var client = _httpClientFactory.CreateClient();
        // MusicBrainz asks for a descriptive agent; the same one goes to TIDAL.
        client.DefaultRequestHeaders.UserAgent.ParseAdd("CascadeServer/1.0 (https://github.com/Cha0s1nc/Cascade-Project)");
        client.Timeout = TimeSpan.FromSeconds(15);
        return client;
    }

    private Task<LookupOutcome> RunLookupAsync(LookupInput input)
        => Task.Run(async () =>
        {
            try
            {
                return await LookupAsync(input);
            }
            catch (TidalRateLimitedException)
            {
                return LookupOutcome.Failed;
            }
            catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException or IOException)
            {
                _logger.LogInformation("TIDAL lookup failed: {Message}", ex.Message);
                return LookupOutcome.Failed;
            }
            finally
            {
                Lookups.TryRemove(input.AlbumId, out _);
            }
        });

    private async Task<LookupOutcome> LookupAsync(LookupInput input)
    {
        var cfg = Plugin.Config;
        var cc = Uri.EscapeDataString(string.IsNullOrWhiteSpace(cfg.TidalCountryCode) ? "US" : cfg.TidalCountryCode.Trim());
        using var client = CreateClient();
        var ct = CancellationToken.None;

        // 1. A link set by hand.
        var link = Links.Get(_paths, input.AlbumId);
        if (link is not null)
        {
            using var doc = await TidalClient.GetAsync(client, $"/albums/{Uri.EscapeDataString(link.TidalAlbumId)}?countryCode={cc}&include=coverArt", ct);
            return Save(input.AlbumId, doc, link.TidalAlbumId);
        }

        // 2. The barcode, exact per edition: a tag on the first track, else MusicBrainz.
        var barcode = input.TrackPaths.Take(1).Select(p => TidalParse.Barcode(TagReader.ReadBarcode(p))).FirstOrDefault(b => b is not null);
        if (barcode is null && input.MusicBrainzReleaseId is { Length: > 0 } mbid) barcode = await MusicBrainzBarcodeAsync(client, mbid, ct);
        if (barcode is not null)
        {
            using var doc = await TidalClient.GetAsync(client, $"/albums?countryCode={cc}&filter%5BbarcodeId%5D={barcode}&include=coverArt", ct);
            if (doc is not null && TidalParse.Albums(doc.RootElement).Length > 0) return Save(input.AlbumId, doc, TidalParse.Albums(doc.RootElement)[0].Id);
        }

        // 3. An ISRC is shared by every release of a recording, so an album is accepted only
        // when its title and track count agree with this one.
        var wanted = TitleMatch.Base(input.AlbumName);
        foreach (var path in input.TrackPaths)
        {
            var isrc = TagReader.Read(path).Isrc;
            if (isrc is null) continue;
            using var tracks = await TidalClient.GetAsync(client, $"/tracks?countryCode={cc}&filter%5Bisrc%5D={Uri.EscapeDataString(isrc)}&include=albums", ct);
            if (tracks is null) continue;
            var match = TidalParse.Albums(tracks.RootElement)
                .FirstOrDefault(a => TitleMatch.Base(a.Title) == wanted && wanted.Length > 0 && a.NumberOfItems == input.TrackCount);
            if (match.Id is null) continue;
            using var doc = await TidalClient.GetAsync(client, $"/albums/{Uri.EscapeDataString(match.Id)}?countryCode={cc}&include=coverArt", ct);
            return Save(input.AlbumId, doc, match.Id);
        }

        // 4. Nothing else: TIDAL's search is not usable with client credentials, and guessing by text picks wrong editions.
        TidalCache.SetMiss(_paths, input.AlbumId);
        return LookupOutcome.Miss;
    }

    private LookupOutcome Save(Guid albumId, JsonDocument? doc, string tidalAlbumId)
    {
        var video = doc is null ? null : TidalParse.PickVideo(doc.RootElement, NearestSize(Plugin.Config.TidalArtSize));
        if (video is null)
        {
            TidalCache.SetMiss(_paths, albumId);
            return LookupOutcome.Miss;
        }

        TidalCache.Set(_paths, albumId, new TidalCache.Entry(tidalAlbumId, video.ArtworkId, video.Width, video.Href, DateTime.UtcNow));
        return LookupOutcome.Found;
    }

    /// <summary>The configured size snapped to one of TIDAL's square sizes.</summary>
    public static int NearestSize(int wanted) => TidalParse.Sizes.OrderBy(s => Math.Abs(s - wanted)).First();

    private static async Task<string?> MusicBrainzBarcodeAsync(HttpClient client, string releaseId, CancellationToken ct)
    {
        if (!Guid.TryParse(releaseId, out var g)) return null;
        await MusicBrainzGate.WaitAsync(ct);
        using var response = await client.GetAsync($"https://musicbrainz.org/ws/2/release/{g}?fmt=json", ct);
        if (!response.IsSuccessStatusCode) return null;
        using var doc = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
        return doc.RootElement.TryGetProperty("barcode", out var b) ? TidalParse.Barcode(b.GetString()) : null;
    }

    /// <summary>Fetches a TIDAL album by id to see whether TIDAL knows it. Null means it does not.</summary>
    public async Task<bool> TidalKnowsAlbumAsync(string tidalAlbumId, CancellationToken ct)
    {
        using var client = CreateClient();
        var cc = Uri.EscapeDataString(string.IsNullOrWhiteSpace(Plugin.Config.TidalCountryCode) ? "US" : Plugin.Config.TidalCountryCode.Trim());
        using var doc = await TidalClient.GetAsync(client, $"/albums/{Uri.EscapeDataString(tidalAlbumId)}?countryCode={cc}", ct);
        return doc is not null;
    }

    /// <summary>The Test button: gets a token and fetches one known album.</summary>
    public async Task<string?> TestAsync(CancellationToken ct)
    {
        if (!TidalClient.Configured) return "Enter a TIDAL client id and secret and save first.";
        try
        {
            // RENAISSANCE (stereo), the album the plugin's own checks use.
            if (await TidalKnowsAlbumAsync("240189283", ct)) return null;
            return "TIDAL accepted the sign-in but did not know the test album. Check the country code.";
        }
        catch (TidalRateLimitedException)
        {
            return "TIDAL says to slow down (429). Try again in a minute.";
        }
        catch (HttpRequestException ex)
        {
            return ex.Message;
        }
        catch (TaskCanceledException)
        {
            return "TIDAL did not answer in time.";
        }
    }
}
