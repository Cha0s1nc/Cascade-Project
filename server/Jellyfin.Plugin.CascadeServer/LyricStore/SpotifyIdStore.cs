using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using MediaBrowser.Common.Configuration;

namespace Jellyfin.Plugin.CascadeServer.LyricStore;

/// <summary>
/// Which Spotify track ids a library item maps to, in {DataPath}/cascade-lyrics/spotify-ids.json.
/// Only ids, never lyrics, so unlike the SpicyLyrics cache this is kept indefinitely.
/// <c>Manual</c> marks an id a user linked by hand: lookups never overwrite it.
/// An entry with no ids is a miss, retried after <see cref="MissRetry"/>.
/// </summary>
public static class SpotifyIdStore
{
    /// <summary>One item's mapping.</summary>
    public record Entry(string[] Ids, bool Manual, DateTime CheckedUtc);

    /// <summary>How long a lookup that found nothing is trusted before asking again.</summary>
    public static readonly TimeSpan MissRetry = TimeSpan.FromDays(7);

    /// <summary>
    /// When the resolver last changed. Entries older than this were found by a resolver that
    /// no longer exists (ListenBrainz Labs, until 2026-11-21) and are dropped on load, because
    /// an entry is terminal: an empty one would block the new lookup for <see cref="MissRetry"/>
    /// on exactly the songs the change fixes, and an entry whose ids all miss would never be
    /// looked up again at all. Hand links are kept, whenever they were made. The cost of
    /// dropping one is a single lookup the next time the song plays.
    /// </summary>
    public static readonly DateTime ResolverEpoch = new(2026, 11, 21, 0, 0, 0, DateTimeKind.Utc);

    private static readonly object FileLock = new();
    private static ConcurrentDictionary<Guid, Entry>? _entries;
    private static string? _path;

    /// <summary>The item's entry, or <c>null</c> when it was never looked up.</summary>
    public static Entry? Get(IApplicationPaths appPaths, Guid itemId)
        => Load(appPaths).TryGetValue(itemId, out var e) ? e : null;

    /// <summary>Stores the item's entry and writes the file.</summary>
    public static void Set(IApplicationPaths appPaths, Guid itemId, Entry entry)
    {
        Load(appPaths)[itemId] = entry;
        Save();
    }

    /// <summary>Forgets the item, so the next lookup starts over.</summary>
    public static void Remove(IApplicationPaths appPaths, Guid itemId)
    {
        if (Load(appPaths).TryRemove(itemId, out _)) Save();
    }

    /// <summary>
    /// Moves the id that worked to the front, so the next play tries it first. Leaves a hand
    /// link alone: its order is the user's.
    /// </summary>
    public static void Prefer(IApplicationPaths appPaths, Guid itemId, string trackId)
    {
        var entry = Get(appPaths, itemId);
        if (entry is null || entry.Manual || entry.Ids.Length == 0 || entry.Ids[0] == trackId) return;
        Set(appPaths, itemId, entry with { Ids = [trackId, .. entry.Ids.Where(i => i != trackId)] });
    }

    private static ConcurrentDictionary<Guid, Entry> Load(IApplicationPaths appPaths)
    {
        if (_entries is not null) return _entries;
        lock (FileLock)
        {
            if (_entries is not null) return _entries;
            _path = Path.Combine(DataDir.Root(appPaths), "spotify-ids.json");
            var loaded = new ConcurrentDictionary<Guid, Entry>();
            try
            {
                if (File.Exists(_path))
                {
                    var raw = JsonSerializer.Deserialize<Dictionary<Guid, Entry>>(File.ReadAllText(_path));
                    foreach (var (k, v) in raw ?? [])
                    {
                        if (v?.Ids is null) continue;
                        if (!v.Manual && v.CheckedUtc < ResolverEpoch) continue;   // an older resolver's answer
                        loaded[k] = v;
                    }
                }
            }
            catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
            {
                // Unreadable: start empty. Worst case every song is looked up again.
            }

            _entries = loaded;
            return _entries;
        }
    }

    private static void Save()
    {
        lock (FileLock)
        {
            if (_entries is null || _path is null) return;
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var tmp = _path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(new Dictionary<Guid, Entry>(_entries)));
            File.Move(tmp, _path, overwrite: true);
        }
    }
}
