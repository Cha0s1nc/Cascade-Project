using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Plugin.CascadeServer.LyricStore;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Model.Tasks;

namespace Jellyfin.Plugin.CascadeServer.Tasks;

/// <summary>
/// Daily sweep of expired SpicyLyrics responses. The cache also prunes on every write
/// and deletes an expired entry when it is read, but a track that is never played again
/// would otherwise sit on disk past the 30-day refetch-or-discard limit in SpicyLyrics'
/// terms. Daily plus the 25-day TTL keeps every entry under 26 days.
/// </summary>
public class PruneSpicyLyricsCacheTask : IScheduledTask
{
    private readonly IApplicationPaths _appPaths;

    /// <summary>Initialises a new instance of <see cref="PruneSpicyLyricsCacheTask"/>.</summary>
    public PruneSpicyLyricsCacheTask(IApplicationPaths appPaths)
    {
        _appPaths = appPaths;
    }

    /// <inheritdoc/>
    public string Name => "Prune SpicyLyrics and TIDAL caches";

    /// <inheritdoc/>
    public string Key => "CascadeServerPruneSpicyLyricsCache";

    /// <inheritdoc/>
    public string Description =>
        "Deletes cached SpicyLyrics responses and cached TIDAL animated covers older than 25 days. " +
        "Required by SpicyLyrics' terms (at most 30 days) and by TIDAL's, which allow temporary caching only.";

    /// <inheritdoc/>
    public string Category => "Cascade Server";

    /// <inheritdoc/>
    public IEnumerable<TaskTriggerInfo> GetDefaultTriggers()
    {
        yield return new TaskTriggerInfo
        {
            Type = TaskTriggerInfoType.DailyTrigger,
            TimeOfDayTicks = TimeSpan.FromHours(4).Ticks,
        };
    }

    /// <inheritdoc/>
    public Task ExecuteAsync(IProgress<double> progress, CancellationToken cancellationToken)
    {
        new SpicyLyricsCache(_appPaths).Prune();
        AnimatedArt.TidalCache.Prune(_appPaths);
        progress.Report(100);
        return Task.CompletedTask;
    }
}
