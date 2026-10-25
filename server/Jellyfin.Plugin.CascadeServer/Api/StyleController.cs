using System;
using System.IO;
using System.Net.Mime;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Jellyfin.Data;
using Jellyfin.Database.Implementations.Enums;
using Jellyfin.Plugin.CascadeServer.Style;
using MediaBrowser.Controller.Net;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;

namespace Jellyfin.Plugin.CascadeServer.Api;

/// <summary>
/// A theme and lyrics look an admin sets for everyone: offered as the default, or enforced.
/// Anyone signed in reads it; only administrators change it. The preset is stored as the JSON
/// text Cascade exported (see <see cref="StylePreset"/>); Cascade clamps every value itself.
/// </summary>
[ApiController]
[Route("CascadeServer/Style")]
[Authorize]
[Produces(MediaTypeNames.Application.Json)]
public class StyleController : ControllerBase
{
    private readonly IAuthorizationContext _auth;

    /// <summary>Initialises a new instance of <see cref="StyleController"/>.</summary>
    public StyleController(IAuthorizationContext auth)
    {
        _auth = auth;
    }

    /// <summary>The server style.</summary>
    /// <response code="200"><c>{ mode, enforce: { theme, lyrics }, preset, updatedUtc }</c>.</response>
    [HttpGet]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public IActionResult Get()
    {
        var c = Plugin.Config;
        var mode = c.ServerStyleMode is "default" or "enforced" && !string.IsNullOrEmpty(c.ServerStylePresetJson) ? c.ServerStyleMode : "off";
        JsonNode? preset = null;
        if (mode != "off")
        {
            try { preset = JsonNode.Parse(c.ServerStylePresetJson); }
            catch (JsonException) { mode = "off"; } // Hand-edited config: treat as off rather than fail the client.
        }

        // A JsonObject, so null preset and updatedUtc are sent as null as the contract says;
        // Jellyfin's serializer would leave null properties of a plain object out.
        return Ok(new JsonObject
        {
            ["mode"] = mode,
            ["enforce"] = new JsonObject { ["theme"] = c.ServerStyleEnforceTheme, ["lyrics"] = c.ServerStyleEnforceLyrics },
            ["preset"] = preset,
            ["updatedUtc"] = string.IsNullOrEmpty(c.ServerStyleUpdatedUtc) ? null : c.ServerStyleUpdatedUtc,
        });
    }

    /// <summary>Sets the server style. Administrators only.</summary>
    /// <response code="204">Saved.</response>
    /// <response code="400">Not a valid style or preset.</response>
    /// <response code="403">Not an administrator.</response>
    [HttpPut]
    [RequestSizeLimit(128 * 1024)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> Put()
    {
        if (!await IsAdminAsync()) return Forbidden();

        string body;
        try
        {
            using var reader = new StreamReader(Request.Body, Encoding.UTF8);
            body = await reader.ReadToEndAsync();
        }
        catch (Exception ex) when (ex is IOException or BadHttpRequestException)
        {
            return Bad("The request body could not be read.");
        }

        JsonObject? root;
        try { root = JsonNode.Parse(body) as JsonObject; }
        catch (JsonException) { return Bad("The request is not valid JSON."); }
        if (root is null) return Bad("The request must be a JSON object.");

        string? mode = null;
        if (root["mode"] is JsonValue m) m.TryGetValue(out mode);
        if (mode is not ("off" or "default" or "enforced")) return Bad("mode must be \"off\", \"default\" or \"enforced\".");

        var enforce = root["enforce"] as JsonObject;
        var enforceTheme = enforce?["theme"] is JsonValue t && t.TryGetValue<bool>(out var tv) && tv;
        var enforceLyrics = enforce?["lyrics"] is JsonValue l && l.TryGetValue<bool>(out var lv) && lv;

        var normalized = string.Empty;
        if (mode != "off")
        {
            if (root["preset"] is not JsonObject presetNode) return Bad("A preset is required unless the mode is \"off\".");
            if (!StylePreset.TryNormalize(presetNode.ToJsonString(), out normalized, out var error)) return Bad(error);
        }

        Save(mode, enforceTheme && mode != "off", enforceLyrics && mode != "off", normalized);
        return NoContent();
    }

    /// <summary>Back to off. Administrators only.</summary>
    /// <response code="204">Cleared.</response>
    /// <response code="403">Not an administrator.</response>
    [HttpDelete]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType(StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> Delete()
    {
        if (!await IsAdminAsync()) return Forbidden();
        Save("off", false, false, string.Empty);
        return NoContent();
    }

    private static void Save(string mode, bool enforceTheme, bool enforceLyrics, string presetJson)
    {
        var plugin = Plugin.Instance ?? throw new InvalidOperationException("The plugin is not loaded.");
        var c = plugin.Configuration;
        c.ServerStyleMode = mode;
        c.ServerStyleEnforceTheme = enforceTheme;
        c.ServerStyleEnforceLyrics = enforceLyrics;
        c.ServerStylePresetJson = presetJson;
        c.ServerStyleUpdatedUtc = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
        plugin.UpdateConfiguration(c);
    }

    private async Task<bool> IsAdminAsync()
    {
        var info = await _auth.GetAuthorizationInfo(HttpContext);
        return info.User is not null && info.User.HasPermission(PermissionKind.IsAdministrator);
    }

    private IActionResult Bad(string message) => BadRequest(new { error = message });

    private IActionResult Forbidden()
        => StatusCode(StatusCodes.Status403Forbidden, new { error = "Only administrators can change the server style." });
}
