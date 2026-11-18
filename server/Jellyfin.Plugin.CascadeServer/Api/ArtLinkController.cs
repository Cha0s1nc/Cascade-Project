using System;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Plugin.CascadeServer.ArtLinks;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Controller.Entities.Audio;
using MediaBrowser.Controller.Library;
using MediaBrowser.Model.Entities;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.CascadeServer.Api;

/// <summary>
/// Pictures for artists and covers for albums, as redirects: to Jellyfin's own image when it has
/// one, otherwise to the service's (Deezer for artists, iTunes for albums). Nothing is stored but the link:
/// the app fetches the picture from the service every time. Off when the administrator chose
/// stored images only. Accepts Jellyfin's <c>ApiKey</c> query parameter, since an image element
/// sends no headers.
/// </summary>
[ApiController]
[Route("CascadeServer/ArtLink")]
[Authorize]
public class ArtLinkController : ControllerBase
{
    // How long an image request waits for a lookup before answering "not yet".
    private static readonly TimeSpan Budget = TimeSpan.FromSeconds(5);

    private readonly ILibraryManager _library;
    private readonly ArtLinkService _service;

    /// <summary>Initialises a new instance of <see cref="ArtLinkController"/>.</summary>
    public ArtLinkController(ILibraryManager library, IApplicationPaths paths, IHttpClientFactory http, ILogger<ArtLinkController> logger)
    {
        _library = library;
        _service = new ArtLinkService(library, paths, http, logger);
    }

    /// <summary>Redirects to the artist's picture on Deezer.</summary>
    /// <param name="artistId">A MusicArtist id.</param>
    /// <response code="302">To the picture.</response>
    /// <response code="404">None found, not found yet, not an artist, or art links are off.</response>
    [HttpGet("Artist/{artistId}")]
    public Task<IActionResult> Artist([FromRoute] Guid artistId, CancellationToken ct)
        => RedirectAsync(_library.GetItemById(artistId) as MusicArtist, ct);

    /// <summary>Redirects to the album's cover on iTunes.</summary>
    /// <param name="albumId">A MusicAlbum id.</param>
    /// <response code="302">To the cover.</response>
    /// <response code="404">None found, not found yet, not an album, or art links are off.</response>
    [HttpGet("Album/{albumId}")]
    public Task<IActionResult> Album([FromRoute] Guid albumId, CancellationToken ct)
        => RedirectAsync(_library.GetItemById(albumId) as MusicAlbum, ct);

    private async Task<IActionResult> RedirectAsync(MediaBrowser.Controller.Entities.BaseItem? item, CancellationToken ct)
    {
        if (!ArtLinkService.Enabled || item is null) return NotFound();
        // Jellyfin's own picture first: it often has one an app was not told about.
        if (item.HasImage(ImageType.Primary, 0))
        {
            Response.Headers.CacheControl = "private, max-age=86400";
            return Redirect($"{Request.PathBase}/Items/{item.Id:N}/Images/Primary?maxWidth=600&quality=90");
        }

        var (url, pending) = await _service.LinkAsync(item, Budget, ct);
        // A found link or a miss can be reused for a day; "not yet" must be asked again.
        Response.Headers.CacheControl = pending ? "no-store" : "private, max-age=86400";
        return url is null ? NotFound() : Redirect(url);
    }
}
