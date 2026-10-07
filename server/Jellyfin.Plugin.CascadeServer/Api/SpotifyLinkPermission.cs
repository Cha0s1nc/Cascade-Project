using System;
using System.Linq;
using System.Threading.Tasks;
using Jellyfin.Data;
using Jellyfin.Database.Implementations.Enums;
using MediaBrowser.Controller.Net;
using Microsoft.AspNetCore.Http;

namespace Jellyfin.Plugin.CascadeServer.Api;

/// <summary>
/// Who may link a song to a Spotify track for the whole server: administrators, and the
/// users an administrator picked in the plugin settings. Everyone else links for
/// themselves in Cascade, which keeps those links on their own computer.
/// </summary>
public static class SpotifyLinkPermission
{
    /// <summary>Whether the user making this request may set server-wide links.</summary>
    public static async Task<bool> ServerWideAsync(IAuthorizationContext auth, HttpContext context)
    {
        return await AllowedAsync(auth, context, Plugin.Config.ServerWideSpotifyLinkUsers);
    }

    /// <summary>Whether the user making this request is an administrator or one of <paramref name="users"/> (ids, any Guid format).</summary>
    public static async Task<bool> AllowedAsync(IAuthorizationContext auth, HttpContext context, string[]? users)
    {
        var info = await auth.GetAuthorizationInfo(context);
        if (info.User is null) return false;
        if (info.User.HasPermission(PermissionKind.IsAdministrator)) return true;
        return (users ?? []).Any(id => Guid.TryParse(id, out var g) && g == info.UserId);
    }
}
