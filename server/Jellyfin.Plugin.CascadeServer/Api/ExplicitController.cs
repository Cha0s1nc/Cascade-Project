using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Mime;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Plugin.CascadeServer.Explicit;
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
/// Jellyfin has no explicit flag, so the plugin works one out (a manual answer, the file's tag,
/// Deezer, iTunes) and serves it. Query answers from the store only and queues what is missing.
/// </summary>
[ApiController]
[Route("CascadeServer/Explicit")]
[Authorize]
[Produces(MediaTypeNames.Application.Json)]
public class ExplicitController : ControllerBase
{
    private const int MaxIds = 500;

    private readonly ILibraryManager _libraryManager;
    private readonly IApplicationPaths _appPaths;
    private readonly IAuthorizationContext _auth;
    private readonly ExplicitResolver _resolver;
    private readonly ILogger<ExplicitController> _logger;

    /// <summary>Initialises a new instance of <see cref="ExplicitController"/>.</summary>
    public ExplicitController(
        ILibraryManager libraryManager, IApplicationPaths appPaths, IAuthorizationContext auth,
        IHttpClientFactory httpClientFactory, ILogger<ExplicitController> logger)
    {
        _libraryManager = libraryManager;
        _appPaths = appPaths;
        _auth = auth;
        _resolver = new ExplicitResolver(logger, appPaths, httpClientFactory);
        _logger = logger;
    }

    /// <summary>The body of Query.</summary>
    /// <param name="Ids">Up to 500 item ids.</param>
    public record QueryDto(string[]? Ids);

    /// <summary>The body of PUT.</summary>
    /// <param name="Rating">"explicit", "clean", or null to remove the manual answer.</param>
    public record RatingDto(string? Rating);

    /// <summary>Known answers for many songs. Songs with no answer are left out and queued for lookup.</summary>
    /// <response code="200"><c>{ "items": { "&lt;id&gt;": "explicit" | "clean" } }</c>.</response>
    /// <response code="400">More than 500 ids.</response>
    [HttpPost("Query")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    public IActionResult Query([FromBody] QueryDto dto)
    {
        var ids = dto.Ids ?? [];
        if (ids.Length > MaxIds) return BadRequest(new { error = "At most 500 ids at a time." });

        var items = new JsonObject();
        foreach (var raw in ids.Distinct())
        {
            if (!Guid.TryParse(raw, out var id)) continue;
            var entry = ExplicitResolver.Store.Get(_appPaths, id);
            var rating = ExplicitResolver.PublicRating(entry);
            if (rating is not null) items[raw] = rating;
            else if (ExplicitResolver.NeedsLookup(entry) && !ExplicitResolver.BackedOff(id) && _libraryManager.GetItemById(id) is Audio)
            {
                ExplicitQueue.Enqueue(id, _resolver, _libraryManager, _logger);
            }
        }

        return Ok(new JsonObject { ["items"] = items });
    }

    /// <summary>One song's answer and where it came from.</summary>
    /// <param name="itemId">The song's item id.</param>
    /// <response code="200"><c>{ rating, source, manual }</c>; rating null is unknown.</response>
    /// <response code="404">Not a song.</response>
    [HttpGet("{itemId}")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public IActionResult Get([FromRoute] Guid itemId)
    {
        if (_libraryManager.GetItemById(itemId) is not Audio) return NotFound();
        var entry = ExplicitResolver.Store.Get(_appPaths, itemId);
        if (ExplicitResolver.NeedsLookup(entry) && !ExplicitResolver.BackedOff(itemId))
        {
            ExplicitQueue.Enqueue(itemId, _resolver, _libraryManager, _logger);
        }

        var rating = ExplicitResolver.PublicRating(entry);
        return Ok(new JsonObject
        {
            ["rating"] = rating,
            ["source"] = rating is null ? null : entry!.Source,
            ["manual"] = rating is not null && entry!.Manual,
        });
    }

    /// <summary>Sets or removes the manual answer. Administrators and the users picked in the settings.</summary>
    /// <param name="itemId">The song's item id.</param>
    /// <param name="dto">The rating.</param>
    /// <response code="204">Saved.</response>
    /// <response code="400">Not "explicit", "clean" or null.</response>
    /// <response code="403">Not allowed to.</response>
    /// <response code="404">Not a song.</response>
    [HttpPut("{itemId}")]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    public async Task<IActionResult> Put([FromRoute] Guid itemId, [FromBody] RatingDto dto, CancellationToken cancellationToken)
    {
        if (!await SpotifyLinkPermission.AllowedAsync(_auth, HttpContext, Plugin.Config.ExplicitEditUsers))
        {
            return StatusCode(StatusCodes.Status403Forbidden, new { error = "Only administrators and users they allow can set explicit ratings." });
        }

        if (_libraryManager.GetItemById(itemId) is not Audio audio) return NotFound();
        if (dto.Rating is not (null or "explicit" or "clean")) return BadRequest(new { error = "rating must be \"explicit\", \"clean\" or null." });
        await _resolver.SetManualAsync(audio, dto.Rating, cancellationToken);
        return NoContent();
    }
}
