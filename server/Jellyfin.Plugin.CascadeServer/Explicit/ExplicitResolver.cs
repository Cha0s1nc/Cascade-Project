using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Plugin.CascadeServer.LyricFetch;
using Jellyfin.Plugin.CascadeServer.LyricStore;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Controller.Entities.Audio;
using MediaBrowser.Controller.Library;
using MediaBrowser.Model.Entities;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.CascadeServer.Explicit;

/// <summary>
/// Works out whether a song is explicit, first hit wins: a manual answer, the file's own tag,
/// then Deezer and iTunes Search (each switchable). The answer is kept in explicit.json.
/// </summary>
public sealed class ExplicitResolver
{
    /// <summary>One song's answer. A null <c>Rating</c> is a lookup that found nothing.</summary>
    public record Entry(string? Rating, string? Source, bool Manual, DateTime CheckedUtc, DateTime? FileModifiedUtc);

    /// <summary>How long a lookup that found nothing is trusted before asking again.</summary>
    public static readonly TimeSpan MissRetry = TimeSpan.FromDays(30);

    /// <summary>The store, shared by the routes, the queue and the scheduled task.</summary>
    public static readonly JsonStore<Entry> Store = new("explicit.json");

    private const string MirrorTag = "Explicit";
    private static readonly RateGate DeezerGate = new(TimeSpan.FromSeconds(1));
    private static readonly RateGate ItunesGate = new(TimeSpan.FromSeconds(1));
    private static readonly ConcurrentDictionary<Guid, DateTime> FailedUntil = new();

    private readonly ILogger _logger;
    private readonly IApplicationPaths _appPaths;
    private readonly IHttpClientFactory _httpClientFactory;

    /// <summary>Initialises a new instance of <see cref="ExplicitResolver"/>.</summary>
    public ExplicitResolver(ILogger logger, IApplicationPaths appPaths, IHttpClientFactory httpClientFactory)
    {
        _logger = logger;
        _appPaths = appPaths;
        _httpClientFactory = httpClientFactory;
    }

    /// <summary>Whether a Query for this id should queue a lookup: nothing known yet, or a miss old enough to retry.</summary>
    public static bool NeedsLookup(Entry? entry)
        => entry is null || (entry.Rating is null && !entry.Manual && DateTime.UtcNow - entry.CheckedUtc > MissRetry);

    /// <summary>Whether this song failed (network trouble) recently enough that the queue should leave it alone.</summary>
    public static bool BackedOff(Guid id) => FailedUntil.TryGetValue(id, out var t) && t > DateTime.UtcNow;

    /// <summary>The rating a client sees: only explicit and clean answer; "not explicit" is unknown.</summary>
    public static string? PublicRating(Entry? e) => e?.Rating is ExplicitRules.Explicit or ExplicitRules.Clean ? e.Rating : null;

    /// <summary>Sets or removes (null) the manual answer, then re-resolves the automatic ones if removed.</summary>
    public async Task SetManualAsync(Audio item, string? rating, CancellationToken ct)
    {
        if (rating is null)
        {
            Store.Remove(_appPaths, item.Id);
            await ResolveAsync(item, ct);
            return;
        }

        Store.Set(_appPaths, item.Id, new Entry(rating, "manual", true, DateTime.UtcNow, null));
        await MirrorAsync(item, rating, ct);
    }

    /// <summary>Finds and stores the song's answer, doing only the work that is out of date.</summary>
    public async Task ResolveAsync(Audio item, CancellationToken ct)
    {
        var entry = Store.Get(_appPaths, item.Id);
        // A metadata refresh set to replace everything can drop the mirrored tag; every pass puts it back.
        if (entry is not null) await MirrorAsync(item, entry.Rating, ct);
        if (entry is { Manual: true }) return;

        var path = item.Path;
        DateTime? mtime = path is not null && System.IO.File.Exists(path) ? System.IO.File.GetLastWriteTimeUtc(path) : null;
        var tagStale = entry is null || entry.FileModifiedUtc != mtime;

        TagReader.Result? tag = null;
        if (tagStale && mtime is not null)
        {
            tag = TagReader.Read(path!);
            if (tag.Rating is not null)
            {
                await SaveAsync(item, new Entry(tag.Rating, "tag", false, DateTime.UtcNow, mtime), ct);
                return;
            }
        }

        // An online answer stands until the file changes under it; a miss waits out its 30 days.
        if (entry is { Source: "deezer" or "itunes" })
        {
            if (tagStale) Store.Set(_appPaths, item.Id, entry with { FileModifiedUtc = mtime });
            return;
        }

        if (!tagStale && !NeedsLookup(entry)) return;

        var cfg = Plugin.Config;
        if (!cfg.ExplicitLookupDeezer && !cfg.ExplicitLookupItunes)
        {
            await SaveAsync(item, new Entry(null, null, false, DateTime.UtcNow, mtime), ct);
            return;
        }

        if (mtime is not null) tag ??= TagReader.Read(path!);
        var artists = item.Artists.Concat(item.AlbumArtists).Where(a => !string.IsNullOrWhiteSpace(a)).Distinct().ToArray();
        double? seconds = item.RunTimeTicks is { } ticks ? TimeSpan.FromTicks(ticks).TotalSeconds : null;

        using var client = LyricsFetcher.CreateHttpClient(_httpClientFactory);
        try
        {
            string? rating = null;
            string? source = null;
            if (cfg.ExplicitLookupDeezer)
            {
                rating = await AskDeezerAsync(client, artists, item.Name, seconds, tag?.Isrc, ct);
                source = "deezer";
            }

            if (rating is null && cfg.ExplicitLookupItunes)
            {
                rating = await AskItunesAsync(client, artists, item.Name, seconds, ct);
                source = "itunes";
            }

            FailedUntil.TryRemove(item.Id, out _);
            await SaveAsync(item, new Entry(rating, rating is null ? null : source, false, DateTime.UtcNow, mtime), ct);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException && !ct.IsCancellationRequested)
        {
            // Trouble at the service says nothing about the song, so store no miss; try again later.
            _logger.LogInformation("Explicit lookup for {Title} failed: {Message}", item.Name, ex.Message);
            FailedUntil[item.Id] = DateTime.UtcNow.AddMinutes(10);
        }
    }

    private async Task SaveAsync(Audio item, Entry entry, CancellationToken ct)
    {
        Store.Set(_appPaths, item.Id, entry);
        await MirrorAsync(item, entry.Rating, ct);
    }

    /// <summary>
    /// Adds an "Explicit" tag to explicit songs and removes it when they stop being, when the
    /// MirrorExplicitTag setting is on. Only touches the item when the tag would change.
    /// </summary>
    private async Task MirrorAsync(Audio item, string? rating, CancellationToken ct)
    {
        if (!Plugin.Config.MirrorExplicitTag) return;
        var has = item.Tags.Contains(MirrorTag, StringComparer.OrdinalIgnoreCase);
        var want = rating == ExplicitRules.Explicit;
        if (has == want) return;
        item.Tags = want
            ? [.. item.Tags, MirrorTag]
            : item.Tags.Where(t => !t.Equals(MirrorTag, StringComparison.OrdinalIgnoreCase)).ToArray();
        await item.UpdateToRepositoryAsync(ItemUpdateType.MetadataEdit, ct);
    }

    private async Task<string?> AskDeezerAsync(
        HttpClient client, string[] artists, string title, double? seconds, string? isrc, CancellationToken ct)
    {
        var candidates = new List<ExplicitRules.Candidate>();
        if (isrc is not null)
        {
            using var doc = await GetJsonAsync(client, DeezerGate, $"https://api.deezer.com/track/isrc:{Uri.EscapeDataString(isrc)}", ct);
            if (doc is not null && doc.RootElement.ValueKind == JsonValueKind.Object && !doc.RootElement.TryGetProperty("error", out _))
            {
                candidates.Add(DeezerCandidate(doc.RootElement));
            }
        }

        // The brief asked for artist:"" track:"" syntax, but Deezer answered every such query with
        // an empty list when checked live, while the plain text query below works. Matching is
        // done here against artist, title and length anyway.
        if (ExplicitRules.Pick(artists, title, seconds, candidates) is null)
        {
            var q = Uri.EscapeDataString($"{artists.FirstOrDefault()} {title}");
            using var doc = await GetJsonAsync(client, DeezerGate, $"https://api.deezer.com/search?q={q}&limit=25", ct);
            if (doc is not null && doc.RootElement.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Array)
            {
                candidates.AddRange(data.EnumerateArray().Select(DeezerCandidate));
            }
        }

        return ExplicitRules.Pick(artists, title, seconds, candidates);
    }

    private static ExplicitRules.Candidate DeezerCandidate(JsonElement t)
    {
        int? content = t.TryGetProperty("explicit_content_lyrics", out var c) && c.ValueKind == JsonValueKind.Number ? c.GetInt32() : null;
        string? artist = t.TryGetProperty("artist", out var a) && a.TryGetProperty("name", out var n) ? n.GetString() : null;
        double? seconds = t.TryGetProperty("duration", out var d) && d.ValueKind == JsonValueKind.Number ? d.GetDouble() : null;
        var title = t.TryGetProperty("title", out var ti) ? ti.GetString() : null;
        return new ExplicitRules.Candidate(artist, title, seconds, ExplicitRules.FromDeezer(content));
    }

    private async Task<string?> AskItunesAsync(HttpClient client, string[] artists, string title, double? seconds, CancellationToken ct)
    {
        var term = Uri.EscapeDataString($"{artists.FirstOrDefault()} {title}");
        using var doc = await GetJsonAsync(client, ItunesGate, $"https://itunes.apple.com/search?entity=song&limit=25&term={term}", ct);
        if (doc is null || !doc.RootElement.TryGetProperty("results", out var results) || results.ValueKind != JsonValueKind.Array) return null;
        var candidates = results.EnumerateArray().Select(r => new ExplicitRules.Candidate(
            r.TryGetProperty("artistName", out var a) ? a.GetString() : null,
            r.TryGetProperty("trackName", out var t) ? t.GetString() : null,
            r.TryGetProperty("trackTimeMillis", out var ms) && ms.ValueKind == JsonValueKind.Number ? ms.GetDouble() / 1000 : null,
            ExplicitRules.FromItunes(r.TryGetProperty("trackExplicitness", out var e) ? e.GetString() : null)));
        return ExplicitRules.Pick(artists, title, seconds, candidates);
    }

    /// <summary>The parsed body, or null when the service answered 404. Other failures throw so no miss is stored.</summary>
    private static async Task<JsonDocument?> GetJsonAsync(HttpClient client, RateGate gate, string url, CancellationToken ct)
    {
        await gate.WaitAsync(ct);
        using var response = await client.GetAsync(url, ct);
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound) return null;
        response.EnsureSuccessStatusCode();
        return await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
    }
}

/// <summary>Lets one request through per interval, however many callers ask.</summary>
public sealed class RateGate
{
    private readonly TimeSpan _interval;
    private readonly SemaphoreSlim _lock = new(1, 1);
    private DateTime _next = DateTime.MinValue;

    /// <summary>Initialises a new instance of <see cref="RateGate"/>.</summary>
    public RateGate(TimeSpan interval)
    {
        _interval = interval;
    }

    /// <summary>Waits until the caller's turn.</summary>
    public async Task WaitAsync(CancellationToken ct)
    {
        await _lock.WaitAsync(ct);
        try
        {
            var wait = _next - DateTime.UtcNow;
            if (wait > TimeSpan.Zero) await Task.Delay(wait, ct);
            _next = DateTime.UtcNow + _interval;
        }
        finally
        {
            _lock.Release();
        }
    }
}
