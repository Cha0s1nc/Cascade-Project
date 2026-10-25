using System;
using System.Collections.Concurrent;
using System.Threading;
using System.Threading.Tasks;
using MediaBrowser.Controller.Entities.Audio;
using MediaBrowser.Controller.Library;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.CascadeServer.Explicit;

/// <summary>
/// The background lookups the Query route feeds. The route answers from the store and drops
/// ids missing from it here; one worker drains the queue at the rate the services allow and
/// stops itself when it is empty (the next Query starts it again).
/// </summary>
public static class ExplicitQueue
{
    private static readonly ConcurrentQueue<Guid> Pending = new();
    private static readonly ConcurrentDictionary<Guid, byte> Queued = new();
    private static int _running;

    /// <summary>Queues a song for lookup unless it is already waiting.</summary>
    public static void Enqueue(Guid id, ExplicitResolver resolver, ILibraryManager libraryManager, ILogger logger)
    {
        if (Queued.TryAdd(id, 0)) Pending.Enqueue(id);
        if (Interlocked.CompareExchange(ref _running, 1, 0) != 0) return;
        _ = Task.Run(() => DrainAsync(resolver, libraryManager, logger));
    }

    private static async Task DrainAsync(ExplicitResolver resolver, ILibraryManager libraryManager, ILogger logger)
    {
        try
        {
            while (Pending.TryDequeue(out var id))
            {
                try
                {
                    if (libraryManager.GetItemById(id) is Audio audio) await resolver.ResolveAsync(audio, CancellationToken.None);
                }
                catch (Exception ex)
                {
                    logger.LogWarning(ex, "Explicit lookup for {Id} failed", id);
                }
                finally
                {
                    Queued.TryRemove(id, out _);
                }
            }
        }
        finally
        {
            Interlocked.Exchange(ref _running, 0);
            // An id queued between the last dequeue and the reset would otherwise wait for the next Query.
            if (!Pending.IsEmpty && Interlocked.CompareExchange(ref _running, 1, 0) == 0)
            {
                _ = Task.Run(() => DrainAsync(resolver, libraryManager, logger));
            }
        }
    }
}
