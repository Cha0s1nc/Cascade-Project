using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Mime;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Plugin.CascadeServer.AnimatedArt;
using Jellyfin.Plugin.CascadeServer.Media;
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
/// A looping video cover for an album, from a <c>cover.mp4</c> sidecar (hand-placed or uploaded) or
/// from TIDAL with the administrator's own developer app. Anyone signed in reads; administrators and
/// the users picked in the settings upload, remove and link. An Audio id is accepted and resolved to
/// its album.
/// </summary>
[ApiController]
[Route("CascadeServer/AnimatedArt")]
[Authorize]
public class AnimatedArtController : ControllerBase
{
    private readonly ILibraryManager _libraryManager;
    private readonly IApplicationPaths _paths;
    private readonly IAuthorizationContext _auth;
    private readonly AnimatedArtService _service;

    /// <summary>Initialises a new instance of <see cref="AnimatedArtController"/>.</summary>
    public AnimatedArtController(
        ILibraryManager libraryManager, IApplicationPaths paths, IAuthorizationContext auth,
        IHttpClientFactory httpClientFactory, ILogger<AnimatedArtController> logger)
    {
        _libraryManager = libraryManager;
        _paths = paths;
        _auth = auth;
        _service = new AnimatedArtService(paths, httpClientFactory, logger);
    }

    /// <summary>The body of the link route.</summary>
    /// <param name="TidalAlbumId">A TIDAL album id, or null to remove the link.</param>
    public record LinkDto(string? TidalAlbumId);

    /// <summary>The album's animated cover.</summary>
    /// <param name="albumId">A MusicAlbum id, or a song's.</param>
    /// <response code="200"><c>{ source, url, contentType, width, height, updatedUtc, pending }</c>; source null means none.</response>
    /// <response code="404">Not an album or a song on one.</response>
    [HttpGet("{albumId}")]
    [Produces(MediaTypeNames.Application.Json)]
    public async Task<IActionResult> Get([FromRoute] Guid albumId, CancellationToken cancellationToken)
    {
        if (FindAlbum(albumId) is not { } album) return NotFound();
        var answer = await _service.GetAsync(album, AnimatedArtService.Tracks(album), cancellationToken);
        var art = answer.Art;
        return Ok(new JsonObject
        {
            ["source"] = art?.Source,
            ["url"] = art?.Url,
            ["contentType"] = art?.ContentType,
            ["width"] = art?.Width,
            ["height"] = art?.Height,
            ["updatedUtc"] = art?.UpdatedUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"),
            ["pending"] = answer.Pending,
        });
    }

    /// <summary>Streams the video, with range support. Accepts Jellyfin's <c>ApiKey</c> query parameter (not the legacy <c>api_key</c>, which Jellyfin 12 refuses by default), since a video element sends no headers.</summary>
    /// <param name="albumId">A MusicAlbum id, or a song's.</param>
    /// <response code="200">The file.</response>
    /// <response code="404">There is none.</response>
    [HttpGet("{albumId}/File")]
    public IActionResult GetFile([FromRoute] Guid albumId)
    {
        if (FindAlbum(albumId) is not { } album) return NotFound();
        var art = _service.ResolveCached(album, AnimatedArtService.Tracks(album));
        return art?.FilePath is { } path ? PhysicalFile(path, art.ContentType, enableRangeProcessing: true) : NotFound();
    }

    /// <summary>Saves the request body as the album's sidecar.</summary>
    /// <param name="albumId">A MusicAlbum id, or a song's.</param>
    /// <response code="204">Saved.</response>
    /// <response code="400">Not an MP4 or WebM, or the bytes do not match the declared type.</response>
    /// <response code="403">Not allowed to.</response>
    /// <response code="404">Not an album.</response>
    /// <response code="413">Larger than the upload limit.</response>
    [HttpPut("{albumId}")]
    [DisableRequestSizeLimit]
    public async Task<IActionResult> Put([FromRoute] Guid albumId, CancellationToken cancellationToken)
    {
        if (!await CanEditAsync()) return Forbidden();
        if (FindAlbum(albumId) is not { } album) return NotFound();

        var mime = Sniff.BaseType(Request.ContentType);
        if (mime is not ("video/mp4" or "video/webm")) return BadRequest(new { error = "The cover must be an MP4 or WebM video." });
        var ext = Sniff.Extension(mime)!;

        var limit = Math.Max(1, Plugin.Config.AnimatedArtMaxUploadMb) * 1024L * 1024;
        if (Request.ContentLength > limit) return TooLarge();

        var staging = _service.UploadPath(albumId, ext + ".upload");
        try
        {
            var head = new byte[16];
            var headLength = 0;
            long total = 0;
            await using (var file = System.IO.File.Create(staging))
            {
                var buffer = new byte[81920];
                int n;
                while ((n = await Request.Body.ReadAsync(buffer, cancellationToken)) > 0)
                {
                    if (headLength < head.Length)
                    {
                        var take = Math.Min(n, head.Length - headLength);
                        Array.Copy(buffer, 0, head, headLength, take);
                        headLength += take;
                        if (headLength >= 12 && !Sniff.Matches(mime, head)) return WrongBytes();
                    }

                    total += n;
                    if (total > limit) return TooLarge();
                    await file.WriteAsync(buffer.AsMemory(0, n), cancellationToken);
                }
            }

            if (total < 12 || !Sniff.Matches(mime, head.AsSpan(0, headLength))) return WrongBytes();
            Place(album, ext, staging);
            return NoContent();
        }
        catch (BadHttpRequestException)
        {
            return TooLarge();
        }
        finally
        {
            try { System.IO.File.Delete(staging); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { /* Left for the next upload to overwrite. */ }
        }
    }

    /// <summary>Removes the sidecar or upload. Never touches the TIDAL cache.</summary>
    /// <param name="albumId">A MusicAlbum id, or a song's.</param>
    /// <response code="204">Removed.</response>
    /// <response code="403">Not allowed to.</response>
    /// <response code="404">There was none, or not an album.</response>
    /// <response code="409">The sidecar is in a folder this server cannot write to.</response>
    [HttpDelete("{albumId}")]
    public async Task<IActionResult> Delete([FromRoute] Guid albumId)
    {
        if (!await CanEditAsync()) return Forbidden();
        if (FindAlbum(albumId) is not { } album) return NotFound();

        var removed = false;
        try
        {
            var folder = AnimatedArtService.AlbumFolder(album, AnimatedArtService.Tracks(album));
            foreach (var path in AllSidecars(album.Id, folder).Where(System.IO.File.Exists))
            {
                System.IO.File.Delete(path);
                removed = true;
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return Conflict(new { error = "The sidecar is in a folder this server cannot write to, so it cannot remove it." });
        }

        return removed ? NoContent() : NotFound();
    }

    /// <summary>Links the album to a TIDAL album by hand, or removes the link (null).</summary>
    /// <param name="albumId">A MusicAlbum id, or a song's.</param>
    /// <param name="dto">The TIDAL album id.</param>
    /// <response code="204">Saved.</response>
    /// <response code="400">TIDAL does not know that album.</response>
    /// <response code="403">Not allowed to.</response>
    /// <response code="404">Not an album.</response>
    /// <response code="409">No TIDAL app is set up.</response>
    [HttpPut("{albumId}/TidalAlbum")]
    public async Task<IActionResult> PutTidalAlbum([FromRoute] Guid albumId, [FromBody] LinkDto dto, CancellationToken cancellationToken)
    {
        if (!await CanEditAsync()) return Forbidden();
        if (FindAlbum(albumId) is not { } album) return NotFound();

        if (string.IsNullOrWhiteSpace(dto.TidalAlbumId))
        {
            AnimatedArtService.Links.Remove(_paths, album.Id);
        }
        else
        {
            var id = dto.TidalAlbumId.Trim();
            if (!TidalClient.Configured) return Conflict(new { error = "Set up a TIDAL app in the plugin settings first." });
            if (id.Length == 0 || !id.All(char.IsDigit)) return BadRequest(new { error = "A TIDAL album id is digits only." });
            try
            {
                if (!await _service.TidalKnowsAlbumAsync(id, cancellationToken)) return BadRequest(new { error = "TIDAL does not know that album id." });
            }
            catch (TidalRateLimitedException)
            {
                return StatusCode(StatusCodes.Status429TooManyRequests, new { error = "TIDAL says to slow down. Try again in a minute." });
            }
            catch (HttpRequestException ex)
            {
                return StatusCode(StatusCodes.Status502BadGateway, new { error = ex.Message });
            }

            AnimatedArtService.Links.Set(_paths, album.Id, new AnimatedArtService.Link(id));
        }

        TidalCache.Remove(_paths, album.Id);
        return NoContent();
    }

    /// <summary>Drops the album's TIDAL cache entry and miss, so the next request looks again.</summary>
    /// <param name="albumId">A MusicAlbum id, or a song's.</param>
    /// <response code="204">Done.</response>
    /// <response code="403">Not allowed to.</response>
    /// <response code="404">Not an album.</response>
    [HttpPost("{albumId}/Refresh")]
    public async Task<IActionResult> Refresh([FromRoute] Guid albumId)
    {
        if (!await CanEditAsync()) return Forbidden();
        if (FindAlbum(albumId) is not { } album) return NotFound();
        TidalCache.Remove(_paths, album.Id);
        return NoContent();
    }

    /// <summary>Admin only: signs in to TIDAL with the saved app and fetches one known album.</summary>
    /// <response code="200"><c>{ ok: true }</c> or <c>{ ok: false, error }</c>.</response>
    [HttpPost("TidalTest")]
    [Authorize(Policy = "RequiresElevation")]
    [Produces(MediaTypeNames.Application.Json)]
    public async Task<IActionResult> TidalTest(CancellationToken cancellationToken)
    {
        var error = await _service.TestAsync(cancellationToken);
        return Ok(error is null ? new JsonObject { ["ok"] = true } : new JsonObject { ["ok"] = false, ["error"] = error });
    }

    private MusicAlbum? FindAlbum(Guid id) => _libraryManager.GetItemById(id) switch
    {
        MusicAlbum album => album,
        Audio audio => audio.AlbumEntity as MusicAlbum,
        _ => null,
    };

    private Task<bool> CanEditAsync() => SpotifyLinkPermission.AllowedAsync(_auth, HttpContext, Plugin.Config.AnimatedArtEditUsers);

    private IActionResult Forbidden() => StatusCode(StatusCodes.Status403Forbidden, new { error = "Only administrators and users they allow can change animated covers." });

    private IActionResult TooLarge() => StatusCode(StatusCodes.Status413PayloadTooLarge, new { error = $"The cover can be at most {Plugin.Config.AnimatedArtMaxUploadMb} MB." });

    private IActionResult WrongBytes() => BadRequest(new { error = "The file does not look like the video type it was sent as." });

    /// <summary>The configured sidecar paths in the folder plus both upload copies.</summary>
    private System.Collections.Generic.IEnumerable<string> AllSidecars(Guid albumId, string? folder)
    {
        if (folder is not null)
        {
            foreach (var name in AnimatedArtService.SidecarNames()) yield return Path.Combine(folder, name);
        }

        yield return _service.UploadPath(albumId, ".mp4");
        yield return _service.UploadPath(albumId, ".webm");
    }

    /// <summary>Puts the staged upload in the album folder, or in the data dir when the folder cannot be written.</summary>
    private void Place(MusicAlbum album, string ext, string staging)
    {
        var folder = AnimatedArtService.AlbumFolder(album, AnimatedArtService.Tracks(album));
        var names = AnimatedArtService.SidecarNames();
        var name = names.FirstOrDefault(n => n.EndsWith(ext, StringComparison.OrdinalIgnoreCase)) ?? "cover" + ext;

        if (folder is not null)
        {
            var temp = Path.Combine(folder, "." + name + ".cascade.tmp");
            try
            {
                System.IO.File.Copy(staging, temp, overwrite: true);
                System.IO.File.Move(temp, Path.Combine(folder, name), overwrite: true);
                // The new cover must be the one that shows: drop every other sidecar name and any data-dir copy.
                foreach (var other in AllSidecars(album.Id, folder).Where(p => !p.Equals(Path.Combine(folder, name), StringComparison.Ordinal)))
                {
                    try { System.IO.File.Delete(other); }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { /* Read-only neighbor: leave it. */ }
                }

                return;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // A read-only mount: fall through to the data dir, as the lyrics editor does.
                try { System.IO.File.Delete(temp); }
                catch (Exception inner) when (inner is IOException or UnauthorizedAccessException) { /* Nothing was written. */ }
            }
        }

        var target = _service.UploadPath(album.Id, ext);
        System.IO.File.Move(staging, target, overwrite: true);
        var otherExt = ext == ".mp4" ? ".webm" : ".mp4";
        System.IO.File.Delete(_service.UploadPath(album.Id, otherExt));
    }
}
