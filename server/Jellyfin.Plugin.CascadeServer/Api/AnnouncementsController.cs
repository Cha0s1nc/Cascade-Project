using System.Linq;
using System.Net.Mime;
using MediaBrowser.Controller;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;

namespace Jellyfin.Plugin.CascadeServer.Api;

/// <summary>
/// What an administrator posted for everyone on this server, shown in Cascade's announcements
/// inbox beside the Cascade project's own. Anyone signed in reads it. Posting is the plugin
/// configuration (the dashboard's Announcements tab), which Jellyfin already keeps admin-only.
/// </summary>
[ApiController]
[Route("CascadeServer/Announcements")]
[Authorize]
[Produces(MediaTypeNames.Application.Json)]
public class AnnouncementsController : ControllerBase
{
    private readonly IServerApplicationHost _host;

    /// <summary>Initialises a new instance of <see cref="AnnouncementsController"/>.</summary>
    public AnnouncementsController(IServerApplicationHost host)
    {
        _host = host;
    }

    /// <summary>The posts, with the server they are from.</summary>
    /// <response code="200"><c>{ server: { id, name }, items: [{ id, date, title, body, link }] }</c>.</response>
    [HttpGet]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public IActionResult Get()
        => Ok(new
        {
            // The id keeps one server's dismissed posts apart from another's; the name labels them.
            server = new { id = _host.SystemId, name = _host.FriendlyName },
            items = Plugin.Config.Announcements.Select(a => new { id = a.Id, date = a.Date, title = a.Title, body = a.Body, link = a.Link }),
        });
}
