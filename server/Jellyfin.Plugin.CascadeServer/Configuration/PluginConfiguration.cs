using MediaBrowser.Model.Plugins;

namespace Jellyfin.Plugin.CascadeServer.Configuration;

/// <summary>
/// Plugin settings, edited from the form on Web/status.html. Jellyfin's plugin
/// configuration API is admin-only, so the SpicyLyrics key is never exposed to
/// normal users.
/// </summary>
public class PluginConfiguration : BasePluginConfiguration
{
    /// <summary>
    /// Gets or sets a value indicating whether fetched lyrics are kept out of the
    /// media folders. When on, the scheduled task and Recheck store what they fetch
    /// in a cache under Jellyfin's data folder instead of writing .slrc/.lrc/.txt next
    /// to the audio, and the lyrics GET fetches live on a miss. Lyrics saved from
    /// Cascade's editor are user-authored and still go next to the media.
    /// </summary>
    public bool DisableSidecarWrites { get; set; }

    /// <summary>
    /// Gets or sets the SpicyLyrics API secret key (sl_sk_...). Empty means
    /// SpicyLyrics is off.
    /// </summary>
    public string SpicyLyricsSecretKey { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the users (ids, any Guid format) allowed to link songs to Spotify
    /// tracks for the whole server. Administrators always may. Everyone else links for
    /// themselves only: Cascade keeps their links on their own computer.
    /// </summary>
    public string[] ServerWideSpotifyLinkUsers { get; set; } = [];

    /// <summary>
    /// Gets or sets the server style mode: "off", "default" or "enforced". Set through
    /// PUT /CascadeServer/Style, which validates it; kept here so it is backed up with the
    /// rest of the settings.
    /// </summary>
    public string ServerStyleMode { get; set; } = "off";

    /// <summary>Gets or sets whether the theme part of the server style is locked (enforced mode).</summary>
    public bool ServerStyleEnforceTheme { get; set; }

    /// <summary>Gets or sets whether the lyrics part of the server style is locked (enforced mode).</summary>
    public bool ServerStyleEnforceLyrics { get; set; }

    /// <summary>Gets or sets the validated preset JSON text; empty when the mode is off.</summary>
    public string ServerStylePresetJson { get; set; } = string.Empty;

    /// <summary>Gets or sets when the server style last changed, as an ISO 8601 UTC time; empty when never.</summary>
    public string ServerStyleUpdatedUtc { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the users (ids, any Guid format) who may set an explicit rating by hand,
    /// besides administrators.
    /// </summary>
    public string[] ExplicitEditUsers { get; set; } = [];

    /// <summary>Gets or sets whether Deezer is asked about songs the file's own tag says nothing about.</summary>
    public bool ExplicitLookupDeezer { get; set; } = true;

    /// <summary>Gets or sets whether iTunes Search is asked about songs the file's own tag says nothing about.</summary>
    public bool ExplicitLookupItunes { get; set; } = true;

    /// <summary>Gets or sets whether explicit songs get an "Explicit" tag in Jellyfin, for other clients to filter on.</summary>
    public bool MirrorExplicitTag { get; set; }
}
