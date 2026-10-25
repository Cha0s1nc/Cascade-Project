using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using MediaBrowser.Common.Configuration;
using Jellyfin.Plugin.CascadeServer.LyricStore;

namespace Jellyfin.Plugin.CascadeServer.AnimatedArt;

/// <summary>
/// TIDAL's lookup results and videos, in {DataDir}/animated-art/tidal/. TIDAL's terms allow only
/// temporary caching, so everything here expires after 25 days (deleted when read, on every write,
/// and by the daily prune task) and clearing the TIDAL settings deletes it all. Never in the media folders.
/// An album TIDAL has no video for is remembered for 7 days in a small .miss file, on disk so a
/// restart does not ask TIDAL about the same albums again.
/// </summary>
public static class TidalCache
{
    /// <summary>What a lookup found, in {albumId}.json.</summary>
    public record Entry(string TidalAlbumId, string ArtworkId, int Width, string Href, DateTime FetchedUtc);

    private static string Dir(IApplicationPaths paths)
    {
        var dir = Path.Combine(DataDir.Root(paths), "animated-art", "tidal");
        Directory.CreateDirectory(dir);
        return dir;
    }

    /// <summary>Where a downloaded video lives.</summary>
    public static string VideoPath(IApplicationPaths paths, Guid albumId) => Path.Combine(Dir(paths), $"{albumId:N}.mp4");

    private static string JsonPath(IApplicationPaths paths, Guid albumId) => Path.Combine(Dir(paths), $"{albumId:N}.json");

    private static string MissPath(IApplicationPaths paths, Guid albumId) => Path.Combine(Dir(paths), $"{albumId:N}.miss");

    /// <summary>The entry, or null when there is none or it expired (and is then deleted).</summary>
    public static Entry? Get(IApplicationPaths paths, Guid albumId)
    {
        var path = JsonPath(paths, albumId);
        try
        {
            if (!File.Exists(path)) return null;
            var entry = JsonSerializer.Deserialize<Entry>(File.ReadAllText(path));
            if (entry is not null && TidalParse.Fresh(entry.FetchedUtc, TidalParse.CacheTtl, DateTime.UtcNow)) return entry;
            Remove(paths, albumId);
            return null;
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>Saves a lookup result and sweeps expired entries.</summary>
    public static void Set(IApplicationPaths paths, Guid albumId, Entry entry)
    {
        ClearMiss(paths, albumId);
        WriteAtomic(JsonPath(paths, albumId), JsonSerializer.Serialize(entry));
        Prune(paths);
    }

    /// <summary>Remembers that TIDAL has no video for the album.</summary>
    public static void SetMiss(IApplicationPaths paths, Guid albumId)
    {
        WriteAtomic(MissPath(paths, albumId), DateTime.UtcNow.ToString("O"));
        Prune(paths);
    }

    /// <summary>Whether the album was recently found to have no TIDAL video.</summary>
    public static bool HasRecentMiss(IApplicationPaths paths, Guid albumId)
    {
        var path = MissPath(paths, albumId);
        try
        {
            return File.Exists(path)
                && DateTime.TryParse(File.ReadAllText(path), null, System.Globalization.DateTimeStyles.RoundtripKind, out var at)
                && TidalParse.Fresh(at, TidalParse.MissTtl, DateTime.UtcNow);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>Drops the album's entry, video and miss, so the next request looks again.</summary>
    public static void Remove(IApplicationPaths paths, Guid albumId)
    {
        foreach (var p in new[] { JsonPath(paths, albumId), VideoPath(paths, albumId), MissPath(paths, albumId) }) TryDelete(p);
    }

    /// <summary>Drops only the album's miss.</summary>
    public static void ClearMiss(IApplicationPaths paths, Guid albumId) => TryDelete(MissPath(paths, albumId));

    /// <summary>Deletes everything TIDAL gave us. Run when the TIDAL settings are cleared.</summary>
    public static void Clear(IApplicationPaths paths)
    {
        foreach (var f in Directory.EnumerateFiles(Dir(paths))) TryDelete(f);
    }

    /// <summary>Deletes expired entries, their videos and expired misses; also leftover .tmp files.</summary>
    public static void Prune(IApplicationPaths paths)
    {
        var now = DateTime.UtcNow;
        foreach (var file in Directory.EnumerateFiles(Dir(paths)).ToList())
        {
            var ext = Path.GetExtension(file);
            // The file's own time stands in for FetchedUtc for videos and misses, which are written at fetch time.
            var written = File.GetLastWriteTimeUtc(file);
            var stale = ext switch
            {
                ".json" => IsExpiredJson(file, now),
                ".mp4" => !TidalParse.Fresh(written, TidalParse.CacheTtl, now),
                ".miss" => !TidalParse.Fresh(written, TidalParse.MissTtl, now),
                _ => !TidalParse.Fresh(written, TimeSpan.FromHours(1), now),
            };
            if (!stale) continue;
            TryDelete(file);
            // A video must not outlive its entry.
            if (ext == ".json") TryDelete(Path.ChangeExtension(file, ".mp4"));
        }
    }

    private static bool IsExpiredJson(string file, DateTime now)
    {
        try
        {
            var entry = JsonSerializer.Deserialize<Entry>(File.ReadAllText(file));
            return entry is null || !TidalParse.Fresh(entry.FetchedUtc, TidalParse.CacheTtl, now);
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            return true;
        }
    }

    private static void WriteAtomic(string path, string text)
    {
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, text);
        File.Move(tmp, path, overwrite: true);
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { /* Retried by the next prune. */ }
    }
}
