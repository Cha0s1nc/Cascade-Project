using System;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;
using Jellyfin.Data;
using Jellyfin.Database.Implementations.Enums;
using Jellyfin.Plugin.CascadeServer.LyricFormat;
using Jellyfin.Plugin.CascadeServer.LyricStore;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Controller.Entities.Audio;
using MediaBrowser.Controller.Library;
using MediaBrowser.Controller.Net;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.StaticFiles;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.CascadeServer.Api;

/// <summary>
/// The lyrics editor (a modified AMLL TTML Tool, built into the plugin from server/editor):
/// its page at <c>/CascadeServer/Editor/</c>, and the routes it works through at
/// <c>/CascadeServer/EditorApi/</c>. A Cascade app (or the page itself, in a browser
/// signed in to Jellyfin's web app) starts a session with a Jellyfin sign-in; every other
/// route takes only the editor token, in the <c>X-Cascade-Editor</c> header, never in the
/// URL or user agent, which proxies log. See <see cref="EditorSessions"/>.
/// </summary>
[ApiController]
public class EditorController : ControllerBase
{
    private const string TokenHeader = "X-Cascade-Editor";

    // A lyrics file far past any song's; the save is read into memory.
    private const int MaxLyricsBytes = 2 * 1024 * 1024;

    private static readonly FileExtensionContentTypeProvider Types = new();

    private readonly ILibraryManager _library;
    private readonly IApplicationPaths _paths;
    private readonly IAuthorizationContext _auth;
    private readonly ILogger<EditorController> _logger;

    /// <summary>Initialises a new instance of <see cref="EditorController"/>.</summary>
    public EditorController(ILibraryManager library, IApplicationPaths paths, IAuthorizationContext auth, ILogger<EditorController> logger)
    {
        _library = library;
        _paths = paths;
        _auth = auth;
        _logger = logger;
    }

    /// <summary>Gets whether the editor's page is built into this plugin.</summary>
    public static bool Built => typeof(EditorController).Assembly.GetManifestResourceInfo("editor/index.html") is not null;

    // ── The page ─────────────────────────────────────────────────────────────

    /// <summary>Serves the editor's page and its files. No sign-in: the page asks for that itself.</summary>
    /// <param name="path">A file under the editor's folder; empty for the page.</param>
    [HttpGet("CascadeServer/Editor/{**path}")]
    [AllowAnonymous]
    public IActionResult Page([FromRoute] string? path)
    {
        // The page's own files are relative to it, so it needs the trailing slash.
        if (string.IsNullOrEmpty(path) && !(Request.Path.Value ?? string.Empty).EndsWith('/'))
            return Redirect($"{Request.PathBase}{Request.Path}/{Request.QueryString}");

        var name = string.IsNullOrEmpty(path) ? "index.html" : path;
        if (name.Contains("..", StringComparison.Ordinal)) return NotFound();
        var stream = typeof(EditorController).Assembly.GetManifestResourceStream("editor/" + name)
                     ?? typeof(EditorController).Assembly.GetManifestResourceStream("editor/" + name.Replace('/', '\\'));
        if (stream is null)
            return name == "index.html" ? StatusCode(StatusCodes.Status503ServiceUnavailable, "The lyrics editor is not built into this plugin.") : NotFound();

        // Its audio decoder runs threads (SharedArrayBuffer), which need the page isolated.
        Response.Headers["Cross-Origin-Opener-Policy"] = "same-origin";
        Response.Headers["Cross-Origin-Embedder-Policy"] = "require-corp";
        Response.Headers["Cross-Origin-Resource-Policy"] = "same-origin";
        // Built files carry a hash in their name; the page itself must be asked again.
        Response.Headers.CacheControl = name == "index.html" ? "no-cache" : "public, max-age=604800";
        return File(stream, Types.TryGetContentType(name, out var type) ? type : "application/octet-stream");
    }

    // ── Starting a session (Jellyfin sign-in) ────────────────────────────────

    /// <summary>Starts an editor session on a song for the signed-in user and returns its token.</summary>
    /// <param name="itemId">The song.</param>
    /// <response code="200"><c>{ "token": "..." }</c>.</response>
    /// <response code="404">Not a song this user can see.</response>
    [HttpPost("CascadeServer/EditorApi/Session")]
    [Authorize]
    public async Task<IActionResult> StartSession([FromQuery] Guid itemId)
    {
        var info = await _auth.GetAuthorizationInfo(HttpContext);
        if (info.User is null) return Unauthorized();
        // GetItemById alone does not check the user's libraries.
        if (_library.GetItemById(itemId) is not Audio item || !item.IsVisible(info.User))
            return NotFound(new { error = "That song was not found." });
        var s = EditorSessions.Start(info.UserId, itemId, info.User.HasPermission(PermissionKind.IsAdministrator));
        return Ok(new { token = s.Token });
    }

    // ── The editor's routes (editor token) ───────────────────────────────────

    private EditorSessions.Session? Session() => EditorSessions.Find(Request.Headers[TokenHeader].ToString());

    private Audio? Song(EditorSessions.Session s) => _library.GetItemById(s.ItemId) as Audio;

    /// <summary>The window opening claims its session; a token opens one window only.</summary>
    [HttpPost("CascadeServer/EditorApi/Open")]
    [AllowAnonymous]
    public IActionResult Open()
    {
        if (Session() is not { } s) return Unauthorized();
        return EditorSessions.Claim(s) ? NoContent() : Conflict(new { error = "This editor link was used already. Open the editor again from Cascade." });
    }

    /// <summary>
    /// The song and the lyrics to start from: the user's own copy, else the ones saved for
    /// everyone. Never SpicyLyrics (its terms allow keeping them 30 days at most and forbid
    /// building an archive) and nothing fetched from the web.
    /// </summary>
    [HttpGet("CascadeServer/EditorApi/Song")]
    [AllowAnonymous]
    public IActionResult GetSong()
    {
        if (Session() is not { } s) return Unauthorized();
        if (Song(s) is not { } item) return NotFound(new { error = "That song is gone from the library." });

        string? text = null, owner = null;
        if (UserLyrics.Read(_paths, s.UserId, s.ItemId) is { } mine) (text, owner) = (mine.Text, "mine");
        else
        {
            var files = item.Path is null ? (Sidecars?)null : Sidecars.For(item.Path);
            foreach (var file in new[] { files?.Slrc, files?.Lrc, DataDir.LyricsPath(_paths, s.ItemId, ".slrc"), DataDir.LyricsPath(_paths, s.ItemId, ".lrc") })
            {
                if (file is null || !System.IO.File.Exists(file)) continue;
                (text, owner) = (System.IO.File.ReadAllText(file), "everyone");
                break;
            }
        }

        return Ok(new
        {
            itemId = s.ItemId,
            title = item.Name,
            artist = string.Join(", ", item.Artists),
            album = item.Album,
            durationSec = (item.RunTimeTicks ?? 0) / 1e7,
            // For the editor's decoder to know the audio's kind by its name.
            ext = Path.GetExtension(item.Path ?? string.Empty).TrimStart('.').ToLowerInvariant(),
            admin = s.Admin,
            owner,
            format = text is null ? null : TtmlLyrics.IsTtml(text) ? "ttml" : "lrc",
            text,
        });
    }

    /// <summary>The song's audio file, as it is, for the editor to decode itself.</summary>
    [HttpGet("CascadeServer/EditorApi/Audio")]
    [AllowAnonymous]
    public IActionResult GetAudio()
    {
        if (Session() is not { } s) return Unauthorized();
        if (Song(s) is not { Path: { } path } || !System.IO.File.Exists(path)) return NotFound();
        Response.Headers["Cross-Origin-Resource-Policy"] = "same-origin";
        return PhysicalFile(path, Types.TryGetContentType(path, out var type) ? type : "application/octet-stream", enableRangeProcessing: true);
    }

    /// <summary>
    /// Saves the editor's TTML: as the user's own copy, or with <paramref name="everyone"/>
    /// (administrators only) as the .slrc next to the audio file that every user gets.
    /// </summary>
    /// <param name="everyone">Save for everyone instead of only this user.</param>
    [HttpPut("CascadeServer/EditorApi/Lyrics")]
    [AllowAnonymous]
    public async Task<IActionResult> SaveLyrics([FromQuery] bool everyone = false)
    {
        if (Session() is not { } s) return Unauthorized();
        if (Song(s) is not { } item) return NotFound(new { error = "That song is gone from the library." });
        if (everyone && !s.Admin) return StatusCode(StatusCodes.Status403Forbidden, new { error = "Only an administrator can save lyrics for everyone." });
        if (Request.ContentLength > MaxLyricsBytes) return BadRequest(new { error = "Those lyrics are too large." });

        string ttml;
        using (var reader = new StreamReader(Request.Body, Encoding.UTF8))
            ttml = await reader.ReadToEndAsync();
        if (ttml.Length > MaxLyricsBytes || !TtmlLyrics.IsTtml(ttml) || TtmlLyrics.Parse(ttml) is null)
            return BadRequest(new { error = "Those lyrics have no timed words to save." });

        if (!everyone)
        {
            UserLyrics.Write(_paths, s.UserId, s.ItemId, ttml, synced: false);
            _logger.LogInformation("Lyrics editor: saved {User}'s own lyrics for {Item}", s.UserId, s.ItemId);
            return Ok(new { owner = "mine" });
        }

        var saved = item.Path is null ? null : Sidecars.For(item.Path).Slrc;
        try
        {
            if (saved is null) throw new IOException("The song has no file.");
            await System.IO.File.WriteAllTextAsync(saved, ttml);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // A music folder Jellyfin may only read: the plugin's folder, which the lyrics
            // route also reads.
            _logger.LogWarning(ex, "Lyrics editor: could not write {Path}, saving in the plugin's folder", saved);
            saved = DataDir.LyricsPath(_paths, s.ItemId, ".slrc");
            Directory.CreateDirectory(Path.GetDirectoryName(saved)!);
            await System.IO.File.WriteAllTextAsync(saved, ttml);
        }

        // Their own copy would otherwise hide what they just gave everyone.
        UserLyrics.Delete(_paths, s.UserId, s.ItemId);
        _logger.LogInformation("Lyrics editor: {User} saved lyrics for everyone for {Item} at {Path}", s.UserId, s.ItemId, saved);
        return Ok(new { owner = "everyone" });
    }

    /// <summary>Drops the user's own copy, back to the lyrics saved for everyone.</summary>
    [HttpDelete("CascadeServer/EditorApi/Lyrics/Mine")]
    [AllowAnonymous]
    public IActionResult DropMine()
    {
        if (Session() is not { } s) return Unauthorized();
        return UserLyrics.Delete(_paths, s.UserId, s.ItemId) ? NoContent() : NotFound();
    }

    /// <summary>The open window checking in, so its session stays alive.</summary>
    [HttpPost("CascadeServer/EditorApi/Ping")]
    [AllowAnonymous]
    public IActionResult Ping() => Session() is null ? Unauthorized() : NoContent();

    /// <summary>The window closing: its session ends.</summary>
    [HttpPost("CascadeServer/EditorApi/Close")]
    [AllowAnonymous]
    public IActionResult Close()
    {
        EditorSessions.End(Request.Headers[TokenHeader].ToString());
        return NoContent();
    }
}
