using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.CascadeServer.LyricFetch;

/// <summary>Outcome of a SpicyLyrics request.</summary>
public enum SpicyLyricsStatus
{
    /// <summary>No secret key is set, so nothing was requested.</summary>
    NotConfigured,

    /// <summary>SpicyLyrics has nothing for this track: it said so (400 or 404).</summary>
    Miss,

    /// <summary>
    /// Could not be asked, which says nothing about the track: a bad key, a missing scope,
    /// a rate limit, an error at their end, a network failure, or a Retry-After pause. Never
    /// remembered against the track, or one bad key would blacklist every song played.
    /// </summary>
    Unavailable,

    /// <summary>Lyrics were returned; the raw response is in the result.</summary>
    Hit,
}

/// <summary>
/// A SpicyLyrics result; <c>RawJson</c> is set only on a hit, <c>HttpStatus</c> when the API
/// answered with something other than 200, and <c>ErrorCode</c> when it sent one of its
/// machine-readable codes (both for the admin test route's diagnosis).
/// </summary>
public record SpicyLyricsResult(
    SpicyLyricsStatus Status, string? RawJson = null, int? HttpStatus = null, string? ErrorCode = null);

/// <summary>
/// The SpicyLyrics API (spec at https://api.spicylyrics.org/v1/openapi.json, v1.1.0, checked
/// 2026-11-21; the docs site is a script shell that cannot be read, so use the spec):
/// <c>GET /v1/lyrics/{id}</c> with <c>Authorization: Bearer sl_sk_...</c>, returning an
/// envelope <c>{Body, Status, Type}</c>, and <c>GET /v1/tracks/search</c> to find the id.
///
/// <c>id</c> takes a Spotify track id, an ISRC or an Apple Music track id; whichever is sent,
/// <c>Body.id</c> comes back as the Spotify id. A lyrics response is returned raw and never
/// interpreted here, because the shape of Body.Content is not public.
///
/// Both routes share one per-application request window, so a Retry-After from either pauses
/// both.
/// </summary>
public class SpicyLyricsClient
{
    private const string BaseUrl = "https://api.spicylyrics.org/v1";

    private static DateTimeOffset _backoffUntil = DateTimeOffset.MinValue;

    private readonly ILogger _logger;

    /// <summary>Initialises a new instance of <see cref="SpicyLyricsClient"/>.</summary>
    public SpicyLyricsClient(ILogger logger)
    {
        _logger = logger;
    }

    /// <summary>Requests lyrics for one track by Spotify id, ISRC or Apple Music id.</summary>
    public async Task<SpicyLyricsResult> FetchAsync(
        HttpClient client, string? secretKey, string trackId, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(secretKey)) return new(SpicyLyricsStatus.NotConfigured);
        if (SpicyIds.NormalizeLookupId(trackId) is not { } id) return new(SpicyLyricsStatus.Miss);
        if (DateTimeOffset.UtcNow < _backoffUntil) return new(SpicyLyricsStatus.Unavailable);

        var (status, body, http, code) = await SendAsync(client, secretKey, $"lyrics/{id}", id, ct);
        if (status != SpicyLyricsStatus.Hit) return new(status, null, http, code);

        try
        {
            using var doc = JsonDocument.Parse(body!);   // only to refuse a body we cannot use
            if (doc.RootElement.ValueKind == JsonValueKind.Object && doc.RootElement.TryGetProperty("Body", out _))
            {
                return new(SpicyLyricsStatus.Hit, body);
            }
        }
        catch (JsonException)
        {
        }

        // 200 with a body this cannot read is a fault at their end, not a fact about the track.
        _logger.LogWarning("SpicyLyrics sent a body with no Body for {TrackId}", id);
        return new(SpicyLyricsStatus.Unavailable, null, http);
    }

    /// <summary>
    /// Finds the track's Spotify ids through <c>GET /v1/tracks/search</c>: the best
    /// <c>exact</c>-tier match and the other releases of that same recording, closest to
    /// <paramref name="durationSec"/> first, so the caller tries the release whose length
    /// matches the file before the rest. The duration is what tells versions apart, so it is
    /// always sent when known.
    ///
    /// Empty when there is no exact match, <c>null</c> when SpicyLyrics could not be asked, so
    /// a failure is never remembered as "this song has no id". Search does not say whether a
    /// track has lyrics, only which track it is.
    /// </summary>
    public async Task<IReadOnlyList<string>?> SearchAsync(
        HttpClient client, string? secretKey, string title, string artist, string album, double? durationSec, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(secretKey) || string.IsNullOrWhiteSpace(title)) return [];
        if (DateTimeOffset.UtcNow < _backoffUntil) return null;

        var (status, body, _, _) = await SendAsync(
            client, secretKey, $"tracks/search?{SpicyIds.SearchQuery(title, artist, album, durationSec)}", title, ct);
        if (status == SpicyLyricsStatus.Miss) return [];          // they answered: nothing matches
        if (status != SpicyLyricsStatus.Hit) return null;         // could not ask

        try
        {
            using var doc = JsonDocument.Parse(body!);
            return SpicyIds.ExactIds(doc.RootElement, durationSec);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>
    /// One request. Returns <see cref="SpicyLyricsStatus.Hit"/> with the raw body on 200, a
    /// <see cref="SpicyLyricsStatus.Miss"/> only when SpicyLyrics said something about the
    /// track itself (400, 404), and <see cref="SpicyLyricsStatus.Unavailable"/> for everything
    /// else, so a bad key or a rate limit is never held against a song.
    /// </summary>
    private async Task<(SpicyLyricsStatus Status, string? Body, int? Http, string? Code)> SendAsync(
        HttpClient client, string secretKey, string path, string what, CancellationToken ct)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, $"{BaseUrl}/{path}");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", secretKey.Trim());
            // Not required (confirmed with SpicyLyrics, 2026-09-23), but it tells them which
            // client a request came from, same identity LRCLIB gets.
            request.Headers.UserAgent.Clear();
            request.Headers.UserAgent.ParseAdd(LrclibClient.UserAgent);

            using var response = await client.SendAsync(request, ct);
            var raw = await response.Content.ReadAsStringAsync(ct);
            if (response.StatusCode == HttpStatusCode.OK) return (SpicyLyricsStatus.Hit, raw, 200, null);

            NoteRetryAfter(response.Headers.RetryAfter);
            var code = SpicyIds.ErrorCode(raw);
            var http = (int)response.StatusCode;
            // 400 and 404 are about the track. Anything else (401 and 403 for a bad key or a
            // missing scope, 429, 5xx) is about us or them, so it must not become a miss.
            var status = response.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.NotFound
                ? SpicyLyricsStatus.Miss
                : SpicyLyricsStatus.Unavailable;
            if (status == SpicyLyricsStatus.Unavailable)
            {
                _logger.LogWarning(
                    "SpicyLyrics HTTP {Status} ({Code}) for {What}; not held against the track", http, code ?? "no code", what);
            }
            else
            {
                _logger.LogDebug("SpicyLyrics HTTP {Status} ({Code}) for {What}", http, code ?? "no code", what);
            }

            return (status, null, http, code);
        }
        catch (Exception ex) when (!ct.IsCancellationRequested)
        {
            _logger.LogDebug(ex, "SpicyLyrics request failed for {What}", what);
            return (SpicyLyricsStatus.Unavailable, null, null, null);
        }
    }

    private void NoteRetryAfter(RetryConditionHeaderValue? retryAfter)
    {
        DateTimeOffset? until = retryAfter?.Delta is { } delta ? DateTimeOffset.UtcNow + delta : retryAfter?.Date;
        if (until is null || until <= _backoffUntil) return;
        _backoffUntil = until.Value;
        _logger.LogInformation("SpicyLyrics asked to retry after {Until}; pausing requests", until);
    }
}
