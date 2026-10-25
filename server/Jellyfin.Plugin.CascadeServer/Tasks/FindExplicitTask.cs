using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Data.Enums;
using Jellyfin.Plugin.CascadeServer.Explicit;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Controller.Entities;
using MediaBrowser.Controller.Entities.Audio;
using MediaBrowser.Controller.Library;
using MediaBrowser.Model.Tasks;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.CascadeServer.Tasks;

/// <summary>
/// A library-wide pass that works out which songs are explicit. Reads each file's tag, then asks
/// Deezer and iTunes about the rest, one request per second per service. Songs already answered
/// are skipped, so a repeat run only does what changed.
/// </summary>
public class FindExplicitTask : IScheduledTask
{
    private readonly ILibraryManager _libraryManager;
    private readonly IApplicationPaths _appPaths;
    private readonly ILogger<FindExplicitTask> _logger;
    private readonly IHttpClientFactory _httpClientFactory;

    /// <summary>Initialises a new instance of <see cref="FindExplicitTask"/>.</summary>
    public FindExplicitTask(
        ILibraryManager libraryManager, IApplicationPaths appPaths, ILogger<FindExplicitTask> logger, IHttpClientFactory httpClientFactory)
    {
        _libraryManager = libraryManager;
        _appPaths = appPaths;
        _logger = logger;
        _httpClientFactory = httpClientFactory;
    }

    /// <inheritdoc/>
    public string Name => "Find explicit songs";

    /// <inheritdoc/>
    public string Key => "CascadeServerFindExplicit";

    /// <inheritdoc/>
    public string Description =>
        "Finds which songs are explicit: a rating set by hand, the file's own advisory tag, then Deezer and " +
        "iTunes Search (artist, title and length must match). Songs with no answer are looked up again after 30 days.";

    /// <inheritdoc/>
    public string Category => "Cascade Server";

    /// <inheritdoc/>
    public IEnumerable<TaskTriggerInfo> GetDefaultTriggers()
    {
        yield return new TaskTriggerInfo
        {
            Type = TaskTriggerInfoType.WeeklyTrigger,
            DayOfWeek = DayOfWeek.Sunday,
            TimeOfDayTicks = TimeSpan.FromHours(5).Ticks,
        };
    }

    /// <inheritdoc/>
    public async Task ExecuteAsync(IProgress<double> progress, CancellationToken cancellationToken)
    {
        var items = _libraryManager.GetItemList(new InternalItemsQuery
        {
            IncludeItemTypes = [BaseItemKind.Audio],
            Recursive = true,
        }).OfType<Audio>().Where(a => a.Path is not null).ToList();

        var resolver = new ExplicitResolver(_logger, _appPaths, _httpClientFactory);
        for (var i = 0; i < items.Count; i++)
        {
            // Cancelling stops between songs; whatever was answered is already stored.
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                await resolver.ResolveAsync(items[i], cancellationToken);
            }
            catch (Exception ex) when (!cancellationToken.IsCancellationRequested)
            {
                _logger.LogWarning(ex, "Explicit check failed for {Title}", items[i].Name);
            }

            progress.Report(100.0 * (i + 1) / items.Count);
        }
    }
}
