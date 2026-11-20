using System;
using System.Net.Http;
using System.Net.Mime;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Database.Implementations.Enums;
using Jellyfin.Data;
using Jellyfin.Plugin.CascadeServer.LyricFetch;
using Jellyfin.Plugin.CascadeServer.LyricFormat;
using Jellyfin.Plugin.CascadeServer.LyricStore;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Controller.Entities.Audio;
using MediaBrowser.Controller.Library;
using MediaBrowser.Controller.Net;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.CascadeServer.Api;

/// <summary>
/// Provides GET / POST / DELETE endpoints for enhanced karaoke lyrics.
///
/// Lyrics are stored as sidecar files next to the audio file:
///   {audioFile}.slrc  - karaoke (word-level Enhanced LRC)
///   {audioFile}.lrc   - synced (line-level LRC)
///
/// Legacy data-dir files ({JellyfinData}/data/cascade-lyrics/{itemId}.*) are
/// read as a fallback so existing installs keep working, but new writes always
/// go to the sidecar location.
///
/// Any signed-in user can read lyrics. An administrator's save is shared with everyone (the
/// sidecar); anyone else's is their own copy (<see cref="UserLyrics"/>), which they see
/// first. A word-level .slrc holds Enhanced LRC or TTML (the lyrics editor's), told apart
/// by <see cref="TtmlLyrics.IsTtml"/>.
/// </summary>
[ApiController]
[Route("CascadeServer/Lyrics/{itemId}")]
[Route("Audio/{itemId}/CascadeLyrics")] // Old plugin name. Drop a couple of releases after 2.0.0.0.
[Produces(MediaTypeNames.Application.Json)]
public class LyricsController : ControllerBase
{
    // A live fetch is not tied to the request: Cascade gives up after 8s, and cancelling on
    // disconnect would throw away a slow first fetch, cache nothing, and repeat on every play.
    private static readonly TimeSpan LiveFetchBudget = TimeSpan.FromSeconds(45);

    private readonly ILibraryManager _libraryManager;
    private readonly IApplicationPaths _appPaths;
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly IAuthorizationContext _auth;
    private readonly ILogger<LyricsController> _logger;

    /// <summary>Initialises a new instance of <see cref="LyricsController"/>.</summary>
    public LyricsController(
        ILibraryManager libraryManager,
        IApplicationPaths appPaths,
        IHttpClientFactory httpClientFactory,
        IAuthorizationContext auth,
        ILogger<LyricsController> logger)
    {
        _libraryManager = libraryManager;
        _appPaths = appPaths;
        _httpClientFactory = httpClientFactory;
        _auth = auth;
        _logger = logger;
    }

    /// <summary>
    /// A word-level file's answer: Enhanced LRC as it is; TTML as the syllable shape for a
    /// client that asked (<paramref name="ttml"/>), else as Enhanced LRC. Null for TTML that
    /// does not read, so the next source is tried.
    /// </summary>
    private IActionResult? Karaoke(string text, bool ttml, string owner)
    {
        if (!TtmlLyrics.IsTtml(text)) return Ok(new { lrc = text, type = "karaoke", owner });
        var lines = TtmlLyrics.Parse(text);
        if (lines is null) return null;
        if (!ttml) return Ok(new { lrc = TtmlLyrics.ToEnhancedLrc(lines), type = lines.All(l => l.LineTimed) ? "synced" : "karaoke", owner });
        using var doc = JsonDocument.Parse(TtmlLyrics.ToSyllableJson(lines));
        return Ok(new { type = "ttml", source = "cascade", owner, lyrics = doc.RootElement.Clone() });
    }

    // ── Legacy data-dir helpers (read-only fallback) ──────────────────────────

    private string LegacySlrcPath(Guid itemId) => DataDir.LyricsPath(_appPaths, itemId, ".slrc");

    private string LegacyLrcPath(Guid itemId) => DataDir.LyricsPath(_appPaths, itemId, ".lrc");

    // ── Endpoints ─────────────────────────────────────────────────────────────

    /// <summary>
    /// Gets lyrics for the specified audio item.
    ///
    /// Priority:
    ///   0. SpicyLyrics, only when the client passes <c>syllable=true</c>, a key is set and
    ///      the item has a Spotify id - returned raw, never stored as a sidecar
    ///   1. {audioFile}.slrc sidecar  - karaoke (word-level)
    ///   2. Data-dir .slrc            - a save where the music folder was read-only
    ///   3. {audioFile}.lrc  sidecar  - synced  (line-level)
    ///   4. Data-dir .slrc and .lrc   - backward compat, for a song without a file
    ///   5. With sidecar writes disabled: the data-dir cache, fetching live from Kugou then
    ///      LRCLIB on a miss
    /// </summary>
    /// <param name="itemId">The Jellyfin item ID.</param>
    /// <param name="syllable">
    /// Set by a client that understands the SpicyLyrics response. Without it the slot is
    /// skipped, so a client that only reads <c>lrc</c> never gets a body it cannot use.
    /// </param>
    /// <param name="spicyOnly">
    /// With <c>syllable=true</c>: answer from SpicyLyrics or not at all. A client that runs
    /// its own waterfall (Cascade outside server-only mode) discards the plugin's files, so
    /// reading them, or fetching Kugou and LRCLIB live for them, was wasted on every miss.
    /// </param>
    /// <param name="spotifyId">
    /// With <c>syllable=true</c>: a Spotify track id the user linked for themselves (kept by
    /// Cascade on their computer, for users not allowed to link songs server-wide). Used for
    /// this request only, ahead of the server's own lookup, and never stored.
    /// </param>
    /// <param name="ttml">
    /// Set by a client that draws the syllable shape for Cascade's own TTML lyrics (type
    /// <c>ttml</c>). It then gets edited lyrics first, the user's own copy and then TTML saved
    /// for everyone, ahead of SpicyLyrics; without it TTML comes as Enhanced LRC.
    /// </param>
    /// <response code="200">
    /// Returns <c>{ "lrc": "...", "type": "karaoke"|"synced", "owner": "mine"|"everyone" }</c>,
    /// with <c>ttml=true</c> possibly <c>{ "type": "ttml", "source": "cascade", "owner", "lyrics": {...} }</c>
    /// (the SpicyLyrics Body shape), or with
    /// <c>syllable=true</c> possibly <c>{ "type": "syllable", "source": "spicylyrics", "spicy": {...} }</c>
    /// where <c>spicy</c> is the SpicyLyrics response exactly as received.
    /// </response>
    /// <response code="404">No lyrics found for this item.</response>
    [HttpGet]
    [Authorize]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetLyrics([FromRoute] Guid itemId, [FromQuery] bool syllable = false, [FromQuery] bool spicyOnly = false, [FromQuery] string? spotifyId = null, [FromQuery] bool ttml = false)
    {
        var item = _libraryManager.GetItemById(itemId);

        // Songs only. Handed a movie or an episode, everything below would
        // search the web for lyrics to a film's title.
        if (item is not null && item is not Audio) return NotFound();

        // Edited lyrics come first: the user's own copy, then (for a client that reads TTML)
        // TTML saved for everyone. A client that runs its own waterfall (spicyOnly) gets them
        // only if it reads TTML, since an older one would drop anything but SpicyLyrics.
        if (item is not null && (ttml || !spicyOnly))
        {
            var userId = (await _auth.GetAuthorizationInfo(HttpContext)).UserId;
            if (UserLyrics.Read(_appPaths, userId, itemId) is { } mine)
            {
                var answer = mine.Synced ? Ok(new { lrc = mine.Text, type = "synced", owner = "mine" }) : Karaoke(mine.Text, ttml, "mine");
                if (answer is not null) return answer;
            }

            // Saved for everyone: next to the audio file, or the plugin's folder when the music
            // folder is read-only.
            foreach (var file in ttml ? new[] { item.Path is null ? null : Sidecars.For(item.Path).Slrc, LegacySlrcPath(itemId) } : [])
            {
                if (file is null || !System.IO.File.Exists(file)) continue;
                var shared = System.IO.File.ReadAllText(file);
                if (TtmlLyrics.IsTtml(shared) && Karaoke(shared, ttml, "everyone") is { } edited) return edited;
                break;
            }
        }

        // 0. SpicyLyrics (opt-in, needs a key and a Spotify id; skipped otherwise)
        if (syllable && item is not null && !string.IsNullOrWhiteSpace(Plugin.Config.SpicyLyricsSecretKey))
        {
            string? raw = null;
            try
            {
                using var cts = new CancellationTokenSource(LiveFetchBudget);
                using var client = LyricsFetcher.CreateHttpClient(_httpClientFactory);
                raw = await new LyricsFetcher(_logger, _appPaths).TrySpicyAsync(item, client, cts.Token, spotifyId);
            }
            catch (OperationCanceledException)
            {
                // Out of time: fall through to the other sources.
            }

            if (raw is not null)
            {
                using var doc = JsonDocument.Parse(raw);
                return Ok(new { type = "syllable", source = "spicylyrics", spicy = doc.RootElement.Clone() });
            }
        }

        if (syllable && spicyOnly) return NotFound();

        if (item?.Path is not null)
        {
            var files = Sidecars.For(item.Path);

            // 1. Sidecar .slrc - karaoke (word-level, highest priority)
            if (System.IO.File.Exists(files.Slrc))
            {
                _logger.LogDebug("Serving sidecar karaoke for {ItemId} from {Path}", itemId, files.Slrc);
                if (Karaoke(System.IO.File.ReadAllText(files.Slrc), ttml, "everyone") is { } answer) return answer;
            }

            // 2. A save to the plugin's folder (the music folder was read-only): an edit,
            // newer than any line-level sidecar, so it comes before one.
            if (System.IO.File.Exists(LegacySlrcPath(itemId))
                && Karaoke(System.IO.File.ReadAllText(LegacySlrcPath(itemId)), ttml, "everyone") is { } saved)
                return saved;

            // 3. Sidecar .lrc - synced (line-level)
            if (System.IO.File.Exists(files.Lrc))
            {
                var lrc = System.IO.File.ReadAllText(files.Lrc);
                _logger.LogDebug("Serving sidecar synced for {ItemId} from {Path}", itemId, files.Lrc);
                return Ok(new { lrc, type = "synced" });
            }
        }

        // 4. Data-dir .slrc (a song without a file path; one with one was checked above)
        var legacySlrc = LegacySlrcPath(itemId);
        if (System.IO.File.Exists(legacySlrc))
        {
            _logger.LogDebug("Serving legacy karaoke for {ItemId}", itemId);
            if (Karaoke(System.IO.File.ReadAllText(legacySlrc), ttml, "everyone") is { } answer) return answer;
        }

        // 4. Data-dir .lrc
        var legacyLrc = LegacyLrcPath(itemId);
        if (System.IO.File.Exists(legacyLrc))
        {
            var lrc = System.IO.File.ReadAllText(legacyLrc);
            _logger.LogDebug("Serving legacy synced for {ItemId}", itemId);
            return Ok(new { lrc, type = "synced" });
        }

        // 5. No files, and sidecar writes are off: serve from the data-dir cache, fetching live.
        if (Plugin.Config.DisableSidecarWrites && item is Audio { Path: not null } audio)
        {
            CachedLyrics cached;
            try
            {
                using var cts = new CancellationTokenSource(LiveFetchBudget);
                using var client = LyricsFetcher.CreateHttpClient(_httpClientFactory);
                (cached, _) = await new LyricsFetcher(_logger, _appPaths)
                    .GetOrFetchCachedAsync(audio, client, force: false, cts.Token);
            }
            catch (OperationCanceledException)
            {
                _logger.LogInformation("Live lyrics fetch for {ItemId} ran out of time", itemId);
                return NotFound();
            }

            if (cached.Karaoke is not null) return Ok(new { lrc = cached.Karaoke, type = "karaoke" });
            if (cached.Synced is not null) return Ok(new { lrc = cached.Synced, type = "synced" });
        }

        return NotFound();
    }

    /// <summary>
    /// Saves lyrics for the specified audio item. An administrator's are shared with
    /// everyone (the sidecar); anyone else's become their own copy, which only they see.
    /// </summary>
    /// <param name="itemId">The Jellyfin item ID.</param>
    /// <param name="dto">The LRC content and type to store.</param>
    /// <response code="204">Lyrics saved successfully.</response>
    /// <response code="400">Missing or empty lyrics content.</response>
    [HttpPost]
    [Authorize]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    public async Task<IActionResult> SaveLyrics([FromRoute] Guid itemId, [FromBody] SaveLyricsDto dto)
    {
        if (string.IsNullOrWhiteSpace(dto?.Lrc))
            return BadRequest(new { error = "Lyrics content (lrc) is required." });

        var item = _libraryManager.GetItemById(itemId);
        if (item?.Path is null)
            return NotFound(new { error = "Item not found or has no file path." });

        var isSynced = string.Equals(dto.Type, "synced", StringComparison.OrdinalIgnoreCase);
        var info = await _auth.GetAuthorizationInfo(HttpContext);
        if (info.User?.HasPermission(PermissionKind.IsAdministrator) != true)
        {
            UserLyrics.Write(_appPaths, info.UserId, itemId, dto.Lrc, isSynced);
            _logger.LogInformation("Saved {User}'s own lyrics for {ItemId}", info.UserId, itemId);
            return NoContent();
        }

        var ext = isSynced ? ".lrc" : ".slrc";
        var sidecarPath = Path.ChangeExtension(item.Path, ext);
        var savedPath = sidecarPath;

        try
        {
            System.IO.File.WriteAllText(sidecarPath, dto.Lrc);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Media library is mounted read-only in some deployments (e.g. Jellyfin
            // running in a container with the library bind-mounted ro). Fall back to
            // the legacy data-dir location, which the GET endpoint already checks.
            _logger.LogWarning(
                ex, "Sidecar write failed at {Path}, falling back to legacy data dir", sidecarPath);

            savedPath = isSynced ? LegacyLrcPath(itemId) : LegacySlrcPath(itemId);
            Directory.CreateDirectory(Path.GetDirectoryName(savedPath)!);
            System.IO.File.WriteAllText(savedPath, dto.Lrc);
        }

        _logger.LogInformation(
            "Saved {Type} lyrics for {ItemId} at {Path} ({Length} chars)",
            isSynced ? "synced" : "karaoke", itemId, savedPath, dto.Lrc.Length);

        return NoContent();
    }

    /// <summary>
    /// Deletes lyrics for the specified audio item: an administrator's call the shared
    /// sidecars, anyone else's their own copy.
    /// </summary>
    /// <param name="itemId">The Jellyfin item ID.</param>
    /// <response code="204">Lyrics deleted.</response>
    /// <response code="404">No lyrics found for this item.</response>
    [HttpDelete]
    [Authorize]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> DeleteLyrics([FromRoute] Guid itemId)
    {
        var info = await _auth.GetAuthorizationInfo(HttpContext);
        if (info.User?.HasPermission(PermissionKind.IsAdministrator) != true)
            return UserLyrics.Delete(_appPaths, info.UserId, itemId) ? NoContent() : NotFound();

        var item = _libraryManager.GetItemById(itemId);
        if (item?.Path is null)
            return NotFound(new { error = "Item not found or has no file path." });

        var slrc = Path.ChangeExtension(item.Path, ".slrc");
        var lrc  = Path.ChangeExtension(item.Path, ".lrc");

        if (!System.IO.File.Exists(slrc) && !System.IO.File.Exists(lrc))
            return NotFound();

        if (System.IO.File.Exists(slrc)) System.IO.File.Delete(slrc);
        if (System.IO.File.Exists(lrc))  System.IO.File.Delete(lrc);

        _logger.LogInformation("Deleted sidecar lyrics for {ItemId}", itemId);
        return NoContent();
    }
}
