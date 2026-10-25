using System;
using System.IO;
using System.Linq;
using System.Net.Mime;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Data;
using Jellyfin.Database.Implementations.Enums;
using Jellyfin.Plugin.CascadeServer.Media;
using MediaBrowser.Controller.Library;
using MediaBrowser.Controller.Net;
using MediaBrowser.Controller.Playlists;
using MediaBrowser.Controller.Providers;
using MediaBrowser.Model.Entities;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;

namespace Jellyfin.Plugin.CascadeServer.Api;

/// <summary>
/// Picture and description of a playlist for the people who may edit it. Jellyfin's own routes
/// for both require elevation, so a normal user who owns a playlist cannot set either. Here the
/// requester may edit when they are an administrator, the playlist's owner, or a share with
/// edit rights. Name and visibility stay on Jellyfin's own <c>POST /Playlists/{id}</c>.
/// </summary>
[ApiController]
[Route("CascadeServer/Playlists/{id}")]
[Authorize]
[Produces(MediaTypeNames.Application.Json)]
public class PlaylistEditController : ControllerBase
{
    private const int MaxImageBytes = 10 * 1024 * 1024;
    private const int MaxOverview = 2000;

    private readonly ILibraryManager _libraryManager;
    private readonly IProviderManager _providerManager;
    private readonly IAuthorizationContext _auth;

    /// <summary>Initialises a new instance of <see cref="PlaylistEditController"/>.</summary>
    public PlaylistEditController(ILibraryManager libraryManager, IProviderManager providerManager, IAuthorizationContext auth)
    {
        _libraryManager = libraryManager;
        _providerManager = providerManager;
        _auth = auth;
    }

    /// <summary>The body of <c>PUT .../Details</c>.</summary>
    /// <param name="Overview">The description; empty or null clears it.</param>
    public record DetailsDto(string? Overview);

    /// <summary>Sets the playlist's Primary image from the raw request body.</summary>
    /// <param name="id">The playlist's item id.</param>
    /// <response code="204">Saved.</response>
    /// <response code="400">Not a JPEG, PNG or WebP, or the bytes do not match the declared type.</response>
    /// <response code="403">The user may not edit this playlist.</response>
    /// <response code="404">No such playlist.</response>
    /// <response code="413">Larger than 10 MB.</response>
    [HttpPost("Image")]
    [RequestSizeLimit(MaxImageBytes + 1024)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    public async Task<IActionResult> SetImage([FromRoute] Guid id, CancellationToken cancellationToken)
    {
        var (playlist, denied) = await FindEditableAsync(id);
        if (playlist is null) return denied!;

        var mime = Sniff.BaseType(Request.ContentType);
        if (mime is not ("image/jpeg" or "image/png" or "image/webp"))
        {
            return BadRequest(new { error = "The picture must be a JPEG, PNG or WebP image." });
        }

        if (Request.ContentLength > MaxImageBytes) return TooLarge();
        var buffer = new MemoryStream();
        var chunk = new byte[81920];
        try
        {
            int n;
            while ((n = await Request.Body.ReadAsync(chunk, cancellationToken)) > 0)
            {
                if (buffer.Length + n > MaxImageBytes) return TooLarge();
                buffer.Write(chunk, 0, n);
            }
        }
        catch (BadHttpRequestException)
        {
            return TooLarge();
        }

        if (!Sniff.Matches(mime, buffer.GetBuffer().AsSpan(0, (int)Math.Min(buffer.Length, 16))))
        {
            return BadRequest(new { error = "The file does not look like the image type it was sent as." });
        }

        buffer.Position = 0;
        await _providerManager.SaveImage(playlist, buffer, mime, ImageType.Primary, null, cancellationToken);
        // SaveImage only writes the file and records it on the item. Persisting is what
        // changes the image tag clients use to notice a new picture.
        await playlist.UpdateToRepositoryAsync(ItemUpdateType.ImageUpdate, cancellationToken);
        return NoContent();
    }

    /// <summary>Removes the playlist's Primary image.</summary>
    /// <param name="id">The playlist's item id.</param>
    /// <response code="204">Removed, or there was none.</response>
    /// <response code="403">The user may not edit this playlist.</response>
    /// <response code="404">No such playlist.</response>
    [HttpDelete("Image")]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    public async Task<IActionResult> DeleteImage([FromRoute] Guid id, CancellationToken cancellationToken)
    {
        var (playlist, denied) = await FindEditableAsync(id);
        if (playlist is null) return denied!;

        if (playlist.HasImage(ImageType.Primary, 0))
        {
            await playlist.DeleteImageAsync(ImageType.Primary, 0);
            await playlist.UpdateToRepositoryAsync(ItemUpdateType.ImageUpdate, cancellationToken);
        }

        return NoContent();
    }

    /// <summary>Sets the playlist's description.</summary>
    /// <param name="id">The playlist's item id.</param>
    /// <param name="dto">The description, at most 2000 characters.</param>
    /// <response code="204">Saved.</response>
    /// <response code="400">Longer than 2000 characters.</response>
    /// <response code="403">The user may not edit this playlist.</response>
    /// <response code="404">No such playlist.</response>
    [HttpPut("Details")]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    public async Task<IActionResult> SetDetails([FromRoute] Guid id, [FromBody] DetailsDto dto, CancellationToken cancellationToken)
    {
        var (playlist, denied) = await FindEditableAsync(id);
        if (playlist is null) return denied!;

        var overview = dto.Overview ?? string.Empty;
        if (overview.Length > MaxOverview) return BadRequest(new { error = "The description can be at most 2000 characters." });
        playlist.Overview = overview.Length == 0 ? null : overview;
        await playlist.UpdateToRepositoryAsync(ItemUpdateType.MetadataEdit, cancellationToken);
        return NoContent();
    }

    private IActionResult TooLarge() => StatusCode(StatusCodes.Status413PayloadTooLarge, new { error = "The picture can be at most 10 MB." });

    private async Task<(Playlist? Playlist, IActionResult? Denied)> FindEditableAsync(Guid id)
    {
        if (_libraryManager.GetItemById(id) is not Playlist playlist) return (null, NotFound());

        var info = await _auth.GetAuthorizationInfo(HttpContext);
        var user = info.User;
        var allowed = user is not null
            && (user.HasPermission(PermissionKind.IsAdministrator)
                || playlist.OwnerUserId == user.Id
                || playlist.Shares.Any(s => s.UserId == user.Id && s.CanEdit));
        return allowed
            ? (playlist, null)
            : (null, StatusCode(StatusCodes.Status403Forbidden, new { error = "Only the playlist's owner, people it is shared with for editing, and administrators can change it." }));
    }
}
