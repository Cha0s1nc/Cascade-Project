using System;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Jellyfin.Plugin.CascadeServer.AnimatedArt;

/// <summary>TIDAL asked us to slow down; <see cref="TidalClient.PausedUntil"/> says until when.</summary>
public sealed class TidalRateLimitedException : Exception
{
    /// <summary>Initialises a new instance of <see cref="TidalRateLimitedException"/>.</summary>
    public TidalRateLimitedException()
        : base("TIDAL answered 429 (too many requests).")
    {
    }
}

/// <summary>
/// Talks to TIDAL's official API with the administrator's own developer app (client
/// credentials). Never uses anyone else's credentials, and never logs or returns the secret.
/// </summary>
public static class TidalClient
{
    private static readonly SemaphoreSlim TokenLock = new(1, 1);
    private static string? _token;
    private static string? _tokenFor;
    private static DateTime _tokenExpires;

    /// <summary>While set in the future, TIDAL is not asked anything: it sent a 429 with a Retry-After.</summary>
    public static DateTime PausedUntil { get; private set; } = DateTime.MinValue;

    /// <summary>Whether the administrator has entered both halves of a TIDAL app.</summary>
    public static bool Configured
        => !string.IsNullOrWhiteSpace(Plugin.Config.TidalClientId) && !string.IsNullOrWhiteSpace(Plugin.Config.TidalClientSecret);

    /// <summary>
    /// GETs a path under <c>https://openapi.tidal.com/v2</c> (starting with a slash, query included)
    /// and returns the parsed body, or null when TIDAL answers 404. A 401 gets one new token and one
    /// retry. A 429 throws <see cref="TidalRateLimitedException"/>; anything else non-2xx throws
    /// <see cref="HttpRequestException"/> with the status code.
    /// </summary>
    public static async Task<JsonDocument?> GetAsync(HttpClient client, string pathAndQuery, CancellationToken ct)
    {
        if (PausedUntil > DateTime.UtcNow) throw new TidalRateLimitedException();
        for (var attempt = 0; ; attempt++)
        {
            var token = await TokenAsync(client, forceNew: attempt > 0, ct);
            using var request = new HttpRequestMessage(HttpMethod.Get, "https://openapi.tidal.com/v2" + pathAndQuery);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.Accept.ParseAdd("application/vnd.api+json");
            using var response = await client.SendAsync(request, ct);

            if (response.StatusCode == HttpStatusCode.Unauthorized && attempt == 0) continue;
            if (response.StatusCode == HttpStatusCode.NotFound) return null;
            if (response.StatusCode == HttpStatusCode.TooManyRequests)
            {
                var wait = response.Headers.RetryAfter?.Delta ?? TimeSpan.FromMinutes(1);
                PausedUntil = DateTime.UtcNow + (wait > TimeSpan.FromHours(1) ? TimeSpan.FromHours(1) : wait);
                throw new TidalRateLimitedException();
            }

            if (!response.IsSuccessStatusCode) throw new HttpRequestException($"TIDAL answered {(int)response.StatusCode}.", null, response.StatusCode);
            return await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
        }
    }

    /// <summary>Forgets the token, after the credentials changed.</summary>
    public static void Reset()
    {
        _token = null;
        _tokenFor = null;
    }

    private static async Task<string> TokenAsync(HttpClient client, bool forceNew, CancellationToken ct)
    {
        var id = Plugin.Config.TidalClientId.Trim();
        var secret = Plugin.Config.TidalClientSecret.Trim();
        var fingerprint = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id + ":" + secret)));
        await TokenLock.WaitAsync(ct);
        try
        {
            if (!forceNew && _token is not null && _tokenFor == fingerprint && DateTime.UtcNow < _tokenExpires) return _token;

            using var request = new HttpRequestMessage(HttpMethod.Post, "https://auth.tidal.com/v1/oauth2/token")
            {
                Content = new FormUrlEncodedContent([new("grant_type", "client_credentials")]),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes(id + ":" + secret)));
            using var response = await client.SendAsync(request, ct);
            if (response.StatusCode == HttpStatusCode.TooManyRequests)
            {
                PausedUntil = DateTime.UtcNow + (response.Headers.RetryAfter?.Delta ?? TimeSpan.FromMinutes(1));
                throw new TidalRateLimitedException();
            }

            if (!response.IsSuccessStatusCode)
            {
                throw new HttpRequestException(
                    response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.BadRequest
                        ? "TIDAL did not accept the client id and secret."
                        : $"TIDAL's sign-in answered {(int)response.StatusCode}.",
                    null,
                    response.StatusCode);
            }

            using var doc = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
            _token = doc.RootElement.GetProperty("access_token").GetString() ?? throw new HttpRequestException("TIDAL sent no token.");
            var seconds = doc.RootElement.TryGetProperty("expires_in", out var e) && e.TryGetInt32(out var s) ? s : 3600;
            // A minute early, so a token never expires mid-request.
            _tokenExpires = DateTime.UtcNow.AddSeconds(Math.Max(30, seconds - 60));
            _tokenFor = fingerprint;
            return _token;
        }
        finally
        {
            TokenLock.Release();
        }
    }
}
