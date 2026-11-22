using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Plugin.CascadeServer.Explicit;
using Jellyfin.Plugin.CascadeServer.LyricStore;
using Jellyfin.Plugin.CascadeServer.Status;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Controller.Entities;
using MediaBrowser.Controller.Entities.Audio;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.CascadeServer.LyricFetch;

/// <summary>
/// Fetches lyrics for a single track and stores them. Two separate steps:
///
/// Fetch (<see cref="FetchAsync"/>): Kugou for word-level karaoke, LRCLIB for line-synced
/// and plain. Sources are queried independently, and in parallel: finding karaoke on Kugou
/// does not stop the LRCLIB lookup. The goal is preservation, so we keep everything each
/// source will give us.
///
/// Store (<see cref="EnsureAsync"/>): by default, sidecars next to the audio file
/// (see <see cref="Sidecars"/>). With DisableSidecarWrites on, the
/// <see cref="LiveLyricsCache"/> in the data folder instead.
///
/// Nothing already on disk is ever overwritten - a source is only queried when its own
/// output file is missing. That keeps hand-edited lyrics safe and stops repeat runs from
/// re-downloading the whole library.
///
/// Shared by the scheduled download task, the status Recheck, and the lyrics GET so they
/// cannot drift apart.
/// </summary>
public class LyricsFetcher
{
    private readonly ILogger _logger;
    private readonly KugouLyricsClient _kugou;
    private readonly LrclibClient _lrclib;
    private readonly SpicyLyricsClient _spicy;
    private readonly LiveLyricsCache _cache;
    private readonly SpicyLyricsCache _spicyCache;
    private readonly IApplicationPaths _appPaths;

    /// <summary>Initialises a new instance of <see cref="LyricsFetcher"/>.</summary>
    public LyricsFetcher(ILogger logger, IApplicationPaths appPaths)
    {
        _logger = logger;
        _kugou = new KugouLyricsClient(logger);
        _lrclib = new LrclibClient(logger);
        _spicy = new SpicyLyricsClient(logger);
        _cache = new LiveLyricsCache(appPaths);
        _spicyCache = new SpicyLyricsCache(appPaths);
        _appPaths = appPaths;
    }

    /// <summary>What one fetch found. <c>QueriedNetwork</c> is false when nothing was asked.</summary>
    public record FetchedLyrics(string? Karaoke, string? Synced, string? Plain, bool QueriedNetwork);

    /// <summary>
    /// What one <see cref="EnsureAsync"/> call stored, plus the resulting status row.
    /// <c>QueriedNetwork</c> is false when everything was already stored and no source was
    /// contacted, which lets callers skip their inter-track rate-limit delay - on a fully
    /// populated library a repeat run is otherwise almost entirely sleeping.
    /// </summary>
    public record EnsureResult(
        LyricsStatusEntry Entry, bool WroteKaraoke, bool WroteSynced, bool WrotePlain, bool QueriedNetwork);

    /// <summary>The HttpClient every fetch path uses. Caller disposes it.</summary>
    public static HttpClient CreateHttpClient(IHttpClientFactory factory)
    {
        var client = factory.CreateClient();
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (compatible; Cascade/1.0)");
        client.Timeout = TimeSpan.FromSeconds(15);
        return client;
    }

    /// <summary>Queries Kugou and/or LRCLIB. Writes nothing.</summary>
    public async Task<FetchedLyrics> FetchAsync(
        Audio item, HttpClient client, bool wantKaraoke, bool wantLrclib, CancellationToken ct)
    {
        var (title, artist) = TitleArtist(item);

        // Without a title and artist there is nothing to search on.
        if (string.IsNullOrWhiteSpace(title) || string.IsNullOrWhiteSpace(artist) || !(wantKaraoke || wantLrclib))
            return new FetchedLyrics(null, null, null, false);

        var album = item.Album ?? string.Empty;
        var duration = item.RunTimeTicks.HasValue
            ? (int)(item.RunTimeTicks.Value / TimeSpan.TicksPerSecond)
            : 0;

        var karaokeTask = wantKaraoke
            ? _kugou.FetchKaraokeAsync(client, title, artist, duration * 1000, ct)
            : Task.FromResult<string?>(null);
        var lrclibTask = wantLrclib
            ? _lrclib.FetchAsync(client, title, artist, album, duration, ct)
            : Task.FromResult<(string?, string?)>((null, null));

        await Task.WhenAll(karaokeTask, lrclibTask);
        var (synced, plain) = lrclibTask.Result;

        return new FetchedLyrics(
            karaokeTask.Result,
            string.IsNullOrWhiteSpace(synced) ? null : synced,
            string.IsNullOrWhiteSpace(plain) ? null : plain,
            true);
    }

    /// <summary>
    /// Returns the cached fetch for <paramref name="item"/>, fetching and caching it first
    /// when there is no fresh entry or <paramref name="force"/> is set. Sources whose
    /// sidecar already exists are not queried.
    /// </summary>
    public async Task<(CachedLyrics Lyrics, bool QueriedNetwork)> GetOrFetchCachedAsync(
        Audio item, HttpClient client, bool force, CancellationToken ct)
    {
        if (!force && _cache.Get(item.Id) is { } cached) return (cached, false);

        var files = Sidecars.For(item.Path);
        var fetched = await FetchAsync(item, client, !File.Exists(files.Slrc), !File.Exists(files.Lrc), ct);
        var entry = new CachedLyrics(fetched.Karaoke, fetched.Synced, fetched.Plain, DateTime.UtcNow);
        _cache.Put(item.Id, entry);
        return (entry, fetched.QueriedNetwork);
    }

    /// <summary>
    /// Fetches whatever is missing for <paramref name="item"/>, stores it (sidecars, or the
    /// data-dir cache with DisableSidecarWrites on) and returns the status entry describing
    /// what is available afterwards. <paramref name="force"/> bypasses a fresh cache entry;
    /// existing sidecars are never refetched.
    /// </summary>
    public async Task<EnsureResult> EnsureAsync(Audio item, HttpClient client, bool force, CancellationToken ct)
    {
        var files = Sidecars.For(item.Path);
        var (title, artist) = TitleArtist(item);
        var hadKaraoke = File.Exists(files.Slrc);

        if (Plugin.Config.DisableSidecarWrites)
        {
            var (cached, queried) = await GetOrFetchCachedAsync(item, client, force, ct);
            var entry = BuildEntry(title, artist, hadKaraoke || cached.Karaoke is not null, files, cached);
            return new EnsureResult(
                entry,
                queried && cached.Karaoke is not null,
                queried && cached.Synced is not null,
                queried && cached.Plain is not null,
                queried);
        }

        var hadSynced = File.Exists(files.Lrc);
        var fetched = await FetchAsync(item, client, !hadKaraoke, !hadSynced, ct);
        var (wroteKaraoke, wroteSynced, wrotePlain) = await WriteSidecarsAsync(files, fetched, title, artist, ct);

        return new EnsureResult(
            BuildEntry(title, artist, hadKaraoke || fetched.Karaoke is not null, files, null),
            wroteKaraoke, wroteSynced, wrotePlain, fetched.QueriedNetwork);
    }

    /// <summary>How many of a song's candidate Spotify ids are tried against SpicyLyrics.</summary>
    private const int MaxSpicyCandidates = 3;

    /// <summary>
    /// SpicyLyrics, when a key is set and the item resolves to an id it accepts: the cached raw
    /// response, or a fresh one (then cached for 25 days). <c>null</c> on any miss, so the
    /// caller falls through to its other sources.
    ///
    /// The id is resolved in stages, stopping at the first that answers:
    /// <list type="number">
    /// <item><paramref name="requestedId"/>, a link this user sent with the request, or a hand
    /// link stored for everyone. Taken as it is, with no length check: the user asserted it.</item>
    /// <item>The ids already remembered for this item. An entry is terminal, so if they all
    /// miss the song is left alone rather than resolved again on every play.</item>
    /// <item>The ISRC in the file's own tags, which names the recording exactly. Only a probe:
    /// its answer carries <c>Body.id</c>, the Spotify id, which is what gets remembered, so the
    /// cache stays Spotify-keyed and later plays take stage 2.</item>
    /// <item><c>GET /v1/tracks/search</c> on title, artist, album and length, taking only an
    /// <c>exact</c>-tier match plus that recording's other releases, nearest length first.</item>
    /// </list>
    ///
    /// Stages 3 and 4 run only for an item with nothing remembered, or whose last lookup found
    /// nothing over <see cref="SpotifyIdStore.MissRetry"/> ago. Every automatic answer passes
    /// <see cref="SpicyFitsTrack"/>, because an id can name a longer release whose sync drifts
    /// (a 190.7s sync against a 186.6s file ran 8s late by the end), and an ISRC in particular
    /// names one release of a recording, which a remaster is often tagged with.
    /// </summary>
    public async Task<string?> TrySpicyAsync(BaseItem item, HttpClient client, CancellationToken ct, string? requestedId = null)
    {
        if (item is not Audio audio || string.IsNullOrWhiteSpace(Plugin.Config.SpicyLyricsSecretKey)) return null;

        // 1. A link sent with this request, used for this call only and never stored.
        if (SpicyIds.NormalizeLookupId(requestedId) is { } asked)
        {
            var result = await TrySpicyByIdAsync(asked, client, respectRecentMiss: true, ct);
            return result is { Status: SpicyLyricsStatus.Hit, RawJson: { } raw } ? raw : null;
        }

        var entry = SpotifyIdStore.Get(_appPaths, audio.Id);

        // 2. What is already known, including a hand link set for the whole server.
        if (entry is { Ids.Length: > 0 })
        {
            return await FirstFittingAsync(audio, entry.Ids, client, entry.Manual, ct);
        }

        // Nothing known. A recent lookup that found nothing is left alone for a week.
        if (entry is not null && DateTime.UtcNow - entry.CheckedUtc < SpotifyIdStore.MissRetry) return null;

        // 3. The ISRC off the file's tags, as a probe for the Spotify id.
        if (await TryIsrcAsync(audio, client, ct) is { } byIsrc) return byIsrc;

        // 4. Their search.
        var found = await _spicy.SearchAsync(
            client, Plugin.Config.SpicyLyricsSecretKey, audio.Name ?? string.Empty,
            audio.Artists?.FirstOrDefault() ?? audio.AlbumArtists?.FirstOrDefault() ?? string.Empty,
            audio.Album ?? string.Empty, DurationSec(audio), ct);
        if (found is null) return null;   // could not ask: remember nothing, try again next play
        SpotifyIdStore.Set(_appPaths, audio.Id, new([.. found], false, DateTime.UtcNow));
        return found.Count > 0 ? await FirstFittingAsync(audio, found, client, manual: false, ct) : null;
    }

    /// <summary>
    /// The first of <paramref name="ids"/> SpicyLyrics has a sync for that fits this file, or
    /// <c>null</c>. A hand link skips the length check and is never reordered.
    /// </summary>
    private async Task<string?> FirstFittingAsync(
        Audio audio, IReadOnlyList<string> ids, HttpClient client, bool manual, CancellationToken ct)
    {
        foreach (var id in ids.Take(MaxSpicyCandidates))
        {
            var result = await TrySpicyByIdAsync(id, client, respectRecentMiss: true, ct);
            if (result.Status != SpicyLyricsStatus.Hit || result.RawJson is null) continue;
            if (!manual && !SpicyFitsTrack(result.RawJson, audio)) continue;
            if (!manual) SpotifyIdStore.Prefer(_appPaths, audio.Id, id);
            return result.RawJson;
        }

        return null;
    }

    /// <summary>
    /// Asks by the ISRC in the file's tags, which Jellyfin itself does not read or store, and
    /// on a usable answer remembers the Spotify id it carries.
    ///
    /// The answer is cached under that Spotify id, not under the ISRC, so there is one cache
    /// entry per track and later plays go through stage 2. A sync that does not fit the file is
    /// dropped and nothing is remembered, since a remembered id is terminal and would fail for
    /// good; search gets its turn instead, and may find a release this one did not.
    /// </summary>
    private async Task<string?> TryIsrcAsync(Audio audio, HttpClient client, CancellationToken ct)
    {
        if (audio.Path is null || SpicyIds.NormalizeIsrc(TagReader.Read(audio.Path).Isrc) is not { } isrc)
        {
            return null;
        }

        var result = await _spicy.FetchAsync(client, Plugin.Config.SpicyLyricsSecretKey, isrc, ct);
        if (result.Status != SpicyLyricsStatus.Hit || result.RawJson is null) return null;
        if (!SpicyFitsTrack(result.RawJson, audio))
        {
            _logger.LogDebug("SpicyLyrics by ISRC {Isrc} is a different release of {Name}; trying search", isrc, audio.Name);
            return null;
        }

        // Body.id came from a third party and becomes a cache file name, so it is checked.
        if (SpicyIds.SpotifyIdOf(result.RawJson) is { } spotifyId)
        {
            _spicyCache.Put(spotifyId, result.RawJson);
            SpotifyIdStore.Set(_appPaths, audio.Id, new([spotifyId], false, DateTime.UtcNow));
        }

        return result.RawJson;
    }

    /// <summary>The file's length in seconds, or <c>null</c> when Jellyfin does not know it.</summary>
    private static double? DurationSec(Audio item)
        => item.RunTimeTicks is > 0 ? TimeSpan.FromTicks(item.RunTimeTicks.Value).TotalSeconds : null;

    /// <summary>Slack for rounding and trailing silence, as in Cascade's spicyFitsTrack.</summary>
    private const double SpicyEndToleranceSec = 1.5;

    /// <summary>
    /// Whether a sync can belong to this file: vocals cannot end after the track does. Only
    /// catches a longer release; with no EndTime or no known length it passes. Same rule as
    /// the desktop's spicyFitsTrack (src/core/spicy-lyrics.ts).
    /// </summary>
    private static bool SpicyFitsTrack(string rawJson, Audio item)
    {
        if (item.RunTimeTicks is not > 0) return true;
        try
        {
            using var doc = JsonDocument.Parse(rawJson);
            var body = doc.RootElement.TryGetProperty("Body", out var b) && b.ValueKind == JsonValueKind.Object ? b : doc.RootElement;
            if (!body.TryGetProperty("EndTime", out var end) || end.ValueKind != JsonValueKind.Number) return true;
            return end.GetDouble() <= TimeSpan.FromTicks(item.RunTimeTicks.Value).TotalSeconds + SpicyEndToleranceSec;
        }
        catch (JsonException)
        {
            return true;
        }
    }

    /// <summary>
    /// SpicyLyrics for a known id (a Spotify id, an ISRC or an Apple Music id), through the
    /// same 25-day cache. The admin test route passes <paramref name="respectRecentMiss"/>
    /// false, so testing the same track twice asks again instead of being told "missed a
    /// moment ago".
    ///
    /// Only a miss SpicyLyrics stated is remembered. A request that could not be made at all,
    /// such as one refused for a bad key or missing scope, rate limited, or failed at their
    /// end, leaves no mark: otherwise one bad key would blacklist every song played for a day.
    /// </summary>
    public async Task<SpicyLyricsResult> TrySpicyByIdAsync(
        string trackId, HttpClient client, bool respectRecentMiss, CancellationToken ct)
    {
        var key = Plugin.Config.SpicyLyricsSecretKey;
        if (string.IsNullOrWhiteSpace(key)) return new(SpicyLyricsStatus.NotConfigured);
        if (SpicyIds.NormalizeLookupId(trackId) is not { } id) return new(SpicyLyricsStatus.Miss);

        if (_spicyCache.Get(id) is { } cached) return new(SpicyLyricsStatus.Hit, cached);
        if (respectRecentMiss && SpicyLyricsCache.IsRecentMiss(id)) return new(SpicyLyricsStatus.Miss);

        var result = await _spicy.FetchAsync(client, key, id, ct);
        if (result.Status == SpicyLyricsStatus.Hit && result.RawJson is not null)
        {
            _spicyCache.Put(id, result.RawJson);
        }
        else if (result.Status == SpicyLyricsStatus.Miss)
        {
            SpicyLyricsCache.MarkMiss(id);
        }

        return result;
    }

    private async Task<(bool Karaoke, bool Synced, bool Plain)> WriteSidecarsAsync(
        Sidecars files, FetchedLyrics fetched, string title, string artist, CancellationToken ct)
    {
        bool karaoke = false, synced = false, plain = false;

        if (fetched.Karaoke is not null && !File.Exists(files.Slrc))
        {
            await File.WriteAllTextAsync(files.Slrc, fetched.Karaoke, ct);
            _logger.LogDebug("Saved karaoke sidecar for \"{Title}\" by {Artist}", title, artist);
            karaoke = true;
        }

        // A track that already has only a .txt is still re-queried (FetchAsync ran because the
        // .lrc is missing), since LRCLIB may have gained a synced version since the last run.
        if (fetched.Synced is not null && !File.Exists(files.Lrc))
        {
            await File.WriteAllTextAsync(files.Lrc, fetched.Synced, ct);
            _logger.LogDebug("Saved synced sidecar for \"{Title}\" by {Artist}", title, artist);
            synced = true;
        }
        else if (fetched.Synced is null && fetched.Plain is not null && !File.Exists(files.Txt))
        {
            await File.WriteAllTextAsync(files.Txt, fetched.Plain, ct);
            _logger.LogDebug("Saved plain sidecar for \"{Title}\" by {Artist}", title, artist);
            plain = true;
        }

        return (karaoke, synced, plain);
    }

    private static (string Title, string Artist) TitleArtist(Audio item)
        => (item.Name ?? string.Empty,
            item.AlbumArtists?.FirstOrDefault() ?? item.Artists?.FirstOrDefault() ?? string.Empty);

    private static LyricsStatusEntry BuildEntry(
        string title, string artist, bool kugouAvailable, Sidecars files, CachedLyrics? cached)
        => new()
        {
            Name = title,
            Artist = artist,
            KugouAvailable = kugouAvailable,
            HasKaraoke = File.Exists(files.Slrc) || cached?.Karaoke is not null,
            HasSynced = File.Exists(files.Lrc) || cached?.Synced is not null,
            HasPlain = File.Exists(files.Txt) || cached?.Plain is not null,
            Cached = cached?.Any ?? false,
            LastChecked = DateTime.UtcNow,
        };
}
