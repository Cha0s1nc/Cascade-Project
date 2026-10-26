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

    /// <summary>Gets or sets the client id of the administrator's own TIDAL developer app. Empty means TIDAL is off.</summary>
    public string TidalClientId { get; set; } = string.Empty;

    /// <summary>Gets or sets the client secret of the administrator's own TIDAL developer app. Empty means TIDAL is off. Never logged or returned by a route.</summary>
    public string TidalClientSecret { get; set; } = string.Empty;

    /// <summary>Gets or sets the country code sent to TIDAL; its catalog differs by country.</summary>
    public string TidalCountryCode { get; set; } = "US";

    /// <summary>Gets or sets which of TIDAL's square sizes to keep (320, 640, 750, 1080 or 1280); the nearest available is used.</summary>
    public int TidalArtSize { get; set; } = 1080;

    /// <summary>
    /// Gets or sets how a TIDAL video reaches clients: "cache" downloads it into the 25-day cache and
    /// serves it from this server; "direct" caches only the lookup and hands out TIDAL's own file URL.
    /// </summary>
    public string TidalArtDelivery { get; set; } = "cache";

    /// <summary>Gets or sets the order of sources: "sidecar-first", "tidal-first", "sidecar-only" or "tidal-only".</summary>
    public string AnimatedArtSourceOrder { get; set; } = "sidecar-first";

    /// <summary>Gets or sets the sidecar file names looked for in an album folder, in order.</summary>
    public string[] AnimatedArtSidecarNames { get; set; } = ["cover.mp4", "cover.webm"];

    /// <summary>Gets or sets the largest accepted upload, in megabytes.</summary>
    public int AnimatedArtMaxUploadMb { get; set; } = 50;

    /// <summary>Gets or sets the users (ids, any Guid format) who may upload, remove and link animated art, besides administrators.</summary>
    public string[] AnimatedArtEditUsers { get; set; } = [];

    /// <summary>
    /// Gets or sets what an administrator posted from the Announcements tab, for the inbox in
    /// every Cascade app signed in here (GET /CascadeServer/Announcements).
    /// </summary>
    public ServerAnnouncement[] Announcements { get; set; } = [];
}

/// <summary>
/// One post, in the shape of Cascade's own announcements feed (desktop/src/core/announcements.ts),
/// which also checks and caps every field, so nothing is validated here.
/// </summary>
public class ServerAnnouncement
{
    /// <summary>Gets or sets the id the apps remember it as dismissed by.</summary>
    public string Id { get; set; } = string.Empty;

    /// <summary>Gets or sets the day it was posted, as YYYY-MM-DD.</summary>
    public string Date { get; set; } = string.Empty;

    /// <summary>Gets or sets the title.</summary>
    public string Title { get; set; } = string.Empty;

    /// <summary>Gets or sets the text, plain; empty for none.</summary>
    public string Body { get; set; } = string.Empty;

    /// <summary>Gets or sets an https link to read more at; empty for none.</summary>
    public string Link { get; set; } = string.Empty;
}
